import Foundation
import OSLog

struct MathNotePipeline: Sendable {
    typealias ProgressHandler = @Sendable (MathNoteJobManifest) async -> Void
    typealias LocalReconstructor = @Sendable (Data) async throws -> FirebirdCompletion

    private let store: MathNoteJobStore
    private let renderer: any AcademicDocumentRendering
    private let localReconstructor: @Sendable (Data, @escaping @Sendable (String) async -> Void) async throws -> FirebirdCompletion

    init(
        store: MathNoteJobStore = .shared,
        renderer: any AcademicDocumentRendering = AcademicDocumentRenderer(),
        localReconstructor: LocalReconstructor? = nil
    ) {
        self.store = store
        self.renderer = renderer
        if let localReconstructor {
            self.localReconstructor = { data, _ in try await localReconstructor(data) }
        } else {
            let localModel = FirebirdLocalModel()
            self.localReconstructor = { imageData, detail in
                try await localModel.reconstruct(imageData: imageData, progress: detail)
            }
        }
    }

    func run(
        jobID: UUID,
        cloudFallbackAuthorized: Bool = false,
        progress: ProgressHandler? = nil
    ) async throws -> MathNoteJobManifest {
        var operation = "Preparing source"
        do {
            var manifest = try await transition(jobID, to: .preparing, progress: progress)
            let pageURLs = try await sourcePageURLs(manifest)

            if !(await store.exists(relativePath: "input.pdf", jobID: jobID)) {
                let inputPDF = try await Task.detached(priority: .userInitiated) {
                    try FacsimilePDFBuilder.makePDF(pageURLs: pageURLs)
                }.value
                try await store.write(inputPDF, relativePath: "input.pdf", jobID: jobID)
            }

            manifest = try await transition(jobID, to: .baseOCR, progress: progress)
            manifest = try await transition(jobID, to: .refining, progress: progress)
            let refinements: [MathNotePageRefinement]
            do {
                operation = "Local reconstruction"
                refinements = try await localRefinements(manifest: manifest, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MathNoteError where error == .localInferenceUnavailable {
                // Only a model-availability/execution failure is eligible for
                // the optional network path. Storage, authentication, parsing,
                // and integrity failures must never cause an upload.
                guard cloudFallbackAuthorized, manifest.allowsCloudFallback else { throw error }
                // Consent authorizes one cloud attempt. Consume the persisted
                // flag before constructing any request so a crash, provider
                // error, or later Retry can never upload again silently.
                _ = try await store.consumeCloudFallbackConsent(jobID)
                refinements = try await cloudRefinements(manifest: manifest, progress: progress)
            }

            // If the local retry recovered without needing the network, clear
            // the unused authorization as well. No completed job retains a
            // latent permission for a later upload.
            if manifest.allowsCloudFallback {
                manifest = try await store.setCloudFallbackConsent(jobID, allowed: false)
            }

            guard refinements.count == manifest.pageCount else {
                throw MathNoteError.refinementPageMismatch(
                    expected: manifest.pageCount,
                    actual: refinements.count
                )
            }
            operation = "Saving reconstruction"
            let record = MathNoteRefinementRecord(pages: refinements)
            try await store.write(
                Self.encoder.encode(record),
                relativePath: "refinement.json",
                jobID: jobID
            )

            let generated = refinements
                .sorted { $0.pageIndex < $1.pageIndex }
                .map(\.finalMarkdown)
                .joined(separator: "\n\n<div class=\"page-break\"></div>\n\n")
            try await store.write(generated, relativePath: "machine-source.md", jobID: jobID)
            let source: String
            if await store.exists(relativePath: "edited-source.md", jobID: jobID) {
                source = try await store.readString(relativePath: "edited-source.md", jobID: jobID)
            } else {
                source = generated
                try await store.write(source, relativePath: "edited-source.md", jobID: jobID)
            }

            manifest = try await transition(jobID, to: .rendering, progress: progress)
            operation = "Preparing export files"
            let jobDirectory = try await store.workingDirectory(for: jobID)
            defer { try? FileManager.default.removeItem(at: jobDirectory) }
            operation = "Rendering PDF export"
            try await renderer.render(markdown: source, manifest: manifest, jobDirectory: jobDirectory)
            operation = "Packaging exports"
            try await rebuildArchive(manifest: manifest, directory: jobDirectory)
            operation = "Encrypting exports"
            try await store.absorbWorkingDirectory(jobDirectory, jobID: jobID)
            let uncertainCount = Self.uncertainCount(in: source)
            manifest = try await store.update(
                jobID,
                stage: .complete,
                failureMessage: nil,
                uncertainCount: uncertainCount
            )
            await progress?(manifest)
            return manifest
        } catch is CancellationError {
            _ = try? await store.setCloudFallbackConsent(jobID, allowed: false)
            let manifest = try? await store.update(jobID, stage: .cancelled)
            if let manifest { await progress?(manifest) }
            throw MathNoteError.cancelled
        } catch let error as MathNoteError where error == .cancelled {
            _ = try? await store.setCloudFallbackConsent(jobID, allowed: false)
            let manifest = try? await store.update(jobID, stage: .cancelled)
            if let manifest { await progress?(manifest) }
            throw error
        } catch let error as MathNoteError where error == .localInferenceUnavailable {
            _ = try? await store.setCloudFallbackConsent(jobID, allowed: false)
            let current = try? await store.load(jobID)
            // Keep any completed sealed local page checkpoints and a safe local
            // error. The one-shot flag has been cleared, so nothing may enter
            // the network path until a later explicit confirmation.
            let manifest = try? await store.update(
                jobID,
                stage: .awaitingCloudConsent,
                failureMessage: error.mathNoteSafeMessage,
                stageProgress: current?.stageProgress ?? MathNoteStage.awaitingCloudConsent.progress,
                stageDetail: "Local state saved · nothing uploaded"
            )
            if let manifest { await progress?(manifest) }
            throw error
        } catch {
            // Record only the stage, error type and numeric code, never userInfo,
            // localized descriptions, note content, paths, or provider keys.
            let code = (error as NSError).code
            let errorType = String(reflecting: type(of: error))
            Logger(subsystem: "VisionNotes", category: "AcademicPipeline")
                .error("Failed stage: \(operation, privacy: .public); type: \(errorType, privacy: .public); code: \(code)")
            _ = try? await store.setCloudFallbackConsent(jobID, allowed: false)
            let manifest = try? await store.update(
                jobID,
                stage: .failed,
                failureMessage: error.mathNoteSafeMessage,
                stageDetail: "\(operation) · error \(code)"
            )
            if let manifest { await progress?(manifest) }
            throw error
        }
    }

    /// Rebuilds all local deliverables from edited Markdown without loading a key or calling a provider.
    func rebuild(jobID: UUID, markdown: String, progress: ProgressHandler? = nil) async throws -> MathNoteJobManifest {
        do {
            var manifest = try await store.load(jobID)
            if manifest.allowsCloudFallback {
                manifest = try await store.setCloudFallbackConsent(jobID, allowed: false)
            }
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw MathNoteError.message("The source document is empty.") }

            if await store.exists(relativePath: "edited-source.md", jobID: jobID) {
                let previous = try await store.read(relativePath: "edited-source.md", jobID: jobID)
                let stamp = Self.historyFormatter.string(from: Date())
                try await store.write(
                    previous,
                    relativePath: "edits/history-\(stamp).md",
                    jobID: jobID,
                    overwrite: false
                )
            }
            try await store.write(trimmed, relativePath: "edited-source.md", jobID: jobID)
            manifest = try await transition(jobID, to: .rendering, progress: progress)
            let jobDirectory = try await store.workingDirectory(for: jobID)
            defer { try? FileManager.default.removeItem(at: jobDirectory) }
            try await renderer.render(markdown: trimmed, manifest: manifest, jobDirectory: jobDirectory)
            try await rebuildArchive(manifest: manifest, directory: jobDirectory)
            try await store.absorbWorkingDirectory(jobDirectory, jobID: jobID)
            manifest = try await store.update(
                jobID,
                stage: .complete,
                failureMessage: nil,
                uncertainCount: Self.uncertainCount(in: trimmed)
            )
            await progress?(manifest)
            return manifest
        } catch is CancellationError {
            let manifest = try? await store.update(jobID, stage: .cancelled)
            if let manifest { await progress?(manifest) }
            throw MathNoteError.cancelled
        } catch let error as MathNoteError where error == .cancelled {
            let manifest = try? await store.update(jobID, stage: .cancelled)
            if let manifest { await progress?(manifest) }
            throw error
        } catch {
            let manifest = try? await store.update(
                jobID,
                stage: .failed,
                failureMessage: error.mathNoteSafeMessage
            )
            if let manifest { await progress?(manifest) }
            throw error
        }
    }

    func source(jobID: UUID) async throws -> String {
        if await store.exists(relativePath: "edited-source.md", jobID: jobID) {
            return try await store.readString(relativePath: "edited-source.md", jobID: jobID)
        }
        if await store.exists(relativePath: "machine-source.md", jobID: jobID) {
            return try await store.readString(relativePath: "machine-source.md", jobID: jobID)
        }
        return ""
    }

    private func localRefinements(
        manifest: MathNoteJobManifest,
        progress: ProgressHandler?
    ) async throws -> [MathNotePageRefinement] {
        var refinements: [MathNotePageRefinement] = []
        for pageIndex in manifest.pages.indices {
            try Task.checkCancellation()
            let cachePath = String(format: "firebird-qwen3vl-9c4f5209-input-v2-page-%03d.json", pageIndex + 1)
            if await store.exists(relativePath: cachePath, jobID: manifest.id) {
                let cached = try Self.decoder.decode(
                    MathNotePageRefinement.self,
                    from: await store.read(relativePath: cachePath, jobID: manifest.id)
                )
                guard cached.pageIndex == pageIndex, cached.model == FirebirdLocalModel.modelIdentifier else {
                    throw MathNoteError.message("The local model checkpoint does not match this page.")
                }
                refinements.append(cached)
                try await reportRefinementProgress(
                    jobID: manifest.id,
                    pageIndex: pageIndex,
                    pageCount: manifest.pageCount,
                    localFraction: 1,
                    detail: "Page \(pageIndex + 1) of \(manifest.pageCount) · encrypted Firebird checkpoint",
                    progress: progress
                )
                continue
            }

            try await reportRefinementProgress(
                jobID: manifest.id,
                pageIndex: pageIndex,
                pageCount: manifest.pageCount,
                localFraction: 0.1,
                detail: "Page \(pageIndex + 1) of \(manifest.pageCount) · local model setup / reconstruction",
                progress: progress
            )
            let sourceData = try await store.read(
                relativePath: manifest.pages[pageIndex].sourcePath,
                jobID: manifest.id
            )
            let completion: FirebirdCompletion
            do {
                completion = try await localReconstructor(sourceData) { detail in
                    // No page content is included in status updates.
                    guard !Task.isCancelled else { return }
                    try? await reportRefinementProgress(
                        jobID: manifest.id, pageIndex: pageIndex, pageCount: manifest.pageCount,
                        localFraction: 0.1, detail: detail, progress: progress)
                }
            } catch FirebirdLocalFailure.outputLimit(let markdown) {
                // An incomplete draft must never become a completed page checkpoint.
                try await store.write(Data(markdown.utf8),
                    relativePath: String(format: "local-incomplete-page-%03d.md", pageIndex + 1),
                    jobID: manifest.id, overwrite: true)
                throw MathNoteError.message("Local reconstruction reached its output limit before finishing. An incomplete draft was saved encrypted. Try a smaller section of this page; no data was uploaded.")
            }
            let page = MathNotePageRefinement(
                pageIndex: pageIndex,
                provider: "On-device",
                model: completion.modelIdentifier,
                overviewTranscript: completion.markdown,
                overviewUsage: nil,
                crops: [],
                mergeTranscript: completion.markdown,
                mergeUsage: nil,
                finalMarkdown: completion.markdown
            )
            try await store.write(
                Self.encoder.encode(page),
                relativePath: cachePath,
                jobID: manifest.id,
                overwrite: false
            )
            refinements.append(page)
            try await reportRefinementProgress(
                jobID: manifest.id,
                pageIndex: pageIndex,
                pageCount: manifest.pageCount,
                localFraction: 1,
                detail: "Page \(pageIndex + 1) of \(manifest.pageCount) · local reconstruction sealed",
                progress: progress
            )
        }
        return refinements
    }

    /// Retained cloud path. This helper is reachable only after the manifest
    /// records explicit user consent and the local Firebird path fails.
    private func cloudRefinements(
        manifest: MathNoteJobManifest,
        progress: ProgressHandler?
    ) async throws -> [MathNotePageRefinement] {
        guard manifest.allowsCloudFallback else { throw MathNoteError.cloudFallbackNotAuthorized }
        let keys = try ProviderKeys.load()
        let rawOCR: Data
        if await store.exists(relativePath: "cloud-ocr.json", jobID: manifest.id) {
            rawOCR = try await store.read(relativePath: "cloud-ocr.json", jobID: manifest.id)
        } else {
            let inputPDF = try await store.read(relativePath: "input.pdf", jobID: manifest.id)
            rawOCR = try await MistralOCRClient(key: keys.mistral).recognize(
                documentData: inputPDF,
                mimeType: "application/pdf"
            )
            try await store.write(
                rawOCR,
                relativePath: "cloud-ocr.json",
                jobID: manifest.id,
                overwrite: false
            )
        }

        let parsed = try MistralOCRParser.parse(rawOCR)
        guard parsed.pages.count == manifest.pageCount else {
            throw MathNoteError.refinementPageMismatch(expected: manifest.pageCount, actual: parsed.pages.count)
        }
        for asset in parsed.assets {
            try await store.write(
                asset.data,
                relativePath: "assets/\(asset.localName)",
                jobID: manifest.id,
                overwrite: false
            )
        }

        var refinements: [MathNotePageRefinement] = []
        for pageIndex in manifest.pages.indices {
            try Task.checkCancellation()
            let cachePath = String(format: "cloud-refinement-page-%03d.json", pageIndex + 1)
            if await store.exists(relativePath: cachePath, jobID: manifest.id) {
                let data = try await store.read(relativePath: cachePath, jobID: manifest.id)
                refinements.append(try Self.decoder.decode(MathNotePageRefinement.self, from: data))
                continue
            }

            let sourceData = try await store.read(
                relativePath: manifest.pages[pageIndex].sourcePath,
                jobID: manifest.id
            )
            let inputs = try await MathImagePreprocessor.prepareVisionInputs(sourceData: sourceData)
            let client = SiliconFlowVisionClient(key: keys.siliconFlow)
            let evidence = try await transcribe(
                inputs: inputs,
                client: client,
                jobID: manifest.id,
                pageIndex: pageIndex
            ) { completed, total in
                try await reportRefinementProgress(
                    jobID: manifest.id,
                    pageIndex: pageIndex,
                    pageCount: manifest.pageCount,
                    localFraction: 0.78 * Double(completed) / Double(max(total, 1)),
                    detail: "Cloud fallback · page \(pageIndex + 1) · \(completed)/\(total)",
                    progress: progress
                )
            }
            let merge = try await client.merge(
                prompt: MathNotePrompts.merge(
                    overview: evidence.overview.text,
                    crops: evidence.crops.map(\.text),
                    legacy: parsed.pages[pageIndex]
                )
            )
            let page = MathNotePageRefinement(
                pageIndex: pageIndex,
                provider: "Mistral + SiliconFlow",
                model: "\(MistralOCRClient.model) + \(SiliconFlowVisionClient.model)",
                overviewTranscript: evidence.overview.text,
                overviewUsage: evidence.overview.usage,
                crops: evidence.crops.enumerated().map { offset, completion in
                    MathNoteCropTranscript(index: offset, transcript: completion.text, usage: completion.usage)
                },
                mergeTranscript: merge.text,
                mergeUsage: merge.usage,
                finalMarkdown: merge.text
            )
            try await store.write(
                Self.encoder.encode(page),
                relativePath: cachePath,
                jobID: manifest.id,
                overwrite: false
            )
            refinements.append(page)
        }
        return refinements
    }

    private func sourcePageURLs(_ manifest: MathNoteJobManifest) async throws -> [URL] {
        var urls: [URL] = []
        for page in manifest.pages.sorted(by: { $0.index < $1.index }) {
            urls.append(try await store.materializedURL(relativePath: page.sourcePath, jobID: manifest.id))
        }
        return urls
    }

    private func transition(
        _ id: UUID,
        to stage: MathNoteStage,
        progress: ProgressHandler?
    ) async throws -> MathNoteJobManifest {
        try Task.checkCancellation()
        let manifest = try await store.update(
            id,
            stage: stage,
            failureMessage: nil,
            stageProgress: stage.progress,
            stageDetail: nil
        )
        await progress?(manifest)
        return manifest
    }

    private func reportRefinementProgress(
        jobID: UUID,
        pageIndex: Int,
        pageCount: Int,
        localFraction: Double,
        detail: String,
        progress: ProgressHandler?
    ) async throws {
        let pages = max(pageCount, 1)
        let globalFraction = (Double(pageIndex) + min(max(localFraction, 0), 1)) / Double(pages)
        let start = MathNoteStage.refining.progress
        let end = MathNoteStage.rendering.progress - 0.01
        let manifest = try await store.update(
            jobID,
            stage: .refining,
            failureMessage: nil,
            stageProgress: start + (end - start) * globalFraction,
            stageDetail: detail
        )
        await progress?(manifest)
    }

    private func transcribe(
        inputs: MathVisionInputs,
        client: SiliconFlowVisionClient,
        jobID: UUID,
        pageIndex: Int,
        onProgress: (@Sendable (Int, Int) async throws -> Void)? = nil
    ) async throws -> (overview: SiliconFlowCompletion, crops: [SiliconFlowCompletion]) {
        enum InputKind: Sendable {
            case overview
            case crop(Int)
        }
        struct Work: Sendable {
            let kind: InputKind
            let image: MathVisionImage

            func cachePath(pageIndex: Int) -> String {
                let prefix = String(format: "vision-page-%03d", pageIndex + 1)
                switch kind {
                case .overview:
                    return "\(prefix)-overview.json"
                case .crop(let index):
                    return String(format: "\(prefix)-crop-%03d.json", index + 1)
                }
            }
        }
        enum Event: Sendable {
            case completion(InputKind, SiliconFlowCompletion, String)
            case failed
            case deadline
        }
        let work = [Work(kind: .overview, image: inputs.overview)] + inputs.crops.enumerated().map {
            Work(kind: .crop($0.offset), image: $0.element)
        }
        var results: [(InputKind, SiliconFlowCompletion)] = []

        var pending: [Work] = []
        for item in work {
            let cachePath = item.cachePath(pageIndex: pageIndex)
            if await store.exists(relativePath: cachePath, jobID: jobID) {
                let cached = try await store.read(relativePath: cachePath, jobID: jobID)
                results.append((item.kind, try Self.decoder.decode(SiliconFlowCompletion.self, from: cached)))
            } else {
                pending.append(item)
            }
        }
        try await onProgress?(results.count, work.count)

        if !pending.isEmpty {
            try await withThrowingTaskGroup(of: Event.self) { group in
                for item in pending {
                    group.addTask {
                        do {
                            let prompt: String
                            switch item.kind {
                            case .overview: prompt = MathNotePrompts.overview
                            case .crop: prompt = MathNotePrompts.crop
                            }
                            let completion = try await client.transcribe(
                                imageData: item.image.data,
                                mimeType: item.image.mimeType,
                                prompt: prompt
                            )
                            return .completion(
                                item.kind,
                                completion,
                                item.cachePath(pageIndex: pageIndex)
                            )
                        } catch {
                            return .failed
                        }
                    }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: Self.visionBatchDeadlineNanoseconds)
                    return .deadline
                }

                var remaining = pending.count
                while remaining > 0, let event = try await group.next() {
                    switch event {
                    case .completion(let kind, let completion, let cachePath):
                        try await store.write(
                            Self.encoder.encode(completion),
                            relativePath: cachePath,
                            jobID: jobID,
                            overwrite: false
                        )
                        results.append((kind, completion))
                        remaining -= 1
                        try await onProgress?(results.count, work.count)
                    case .failed:
                        remaining -= 1
                    case .deadline:
                        remaining = 0
                    }
                }
                group.cancelAll()
            }
        }

        guard results.count == work.count else {
            throw MathNoteError.visionRequestsIncomplete(completed: results.count, total: work.count)
        }

        guard let overview = results.first(where: {
            if case .overview = $0.0 { return true }
            return false
        })?.1 else { throw MathNoteError.malformedProviderResponse }
        let crops = results.compactMap { kind, completion -> (Int, SiliconFlowCompletion)? in
            if case .crop(let index) = kind { return (index, completion) }
            return nil
        }.sorted { $0.0 < $1.0 }.map(\.1)
        guard crops.count == inputs.crops.count else { throw MathNoteError.malformedProviderResponse }
        return (overview, crops)
    }

    private func rebuildArchive(manifest: MathNoteJobManifest, directory: URL) async throws {
        try await Task.detached(priority: .utility) {
            let entries = try StoredZIPWriter.entries(
                in: directory,
                excludingNames: [manifest.artifacts.archive]
            )
            try StoredZIPWriter.write(
                entries: entries,
                to: directory.appendingPathComponent(manifest.artifacts.archive)
            )
        }.value
    }

    static func uncertainCount(in source: String) -> Int {
        let expression = try? NSRegularExpression(pattern: #"\[unclear:\s*[^\]]*\]"#, options: [.caseInsensitive])
        let range = NSRange(source.startIndex..., in: source)
        return expression?.numberOfMatches(in: source, range: range) ?? 0
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let historyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    private static let visionBatchDeadlineNanoseconds: UInt64 = 210_000_000_000
}
