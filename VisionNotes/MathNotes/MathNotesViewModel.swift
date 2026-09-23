import Foundation
import Observation
import PDFKit
import UIKit
import UniformTypeIdentifiers

struct MathNoteDraftPage: Identifiable {
    let id: UUID
    var data: Data

    init(id: UUID = UUID(), data: Data) {
        self.id = id
        self.data = data
    }

    var image: UIImage? { UIImage(data: data) }
}

@MainActor
@Observable
final class MathNotesViewModel {
    private(set) var jobs: [MathNoteJobManifest] = []
    private(set) var draftPages: [MathNoteDraftPage] = []
    private(set) var isPreparingDraft = false
    private(set) var activeJobID: UUID?
    private(set) var selectedJob: MathNoteJobManifest?
    private(set) var selectedSource = ""
    private(set) var selectedJobDirectory: URL?
    private(set) var hasMistralCredential = false
    private(set) var hasQwen3VLCredential = false
    private(set) var credentialStatusMessage: String?
    var draftTitle = ""
    var mistralCredentialDraft = ""
    var qwen3VLCredentialDraft = ""
    var errorMessage: String?

    @ObservationIgnored private let store: MathNoteJobStore
    @ObservationIgnored private let pipeline: MathNotePipeline
    @ObservationIgnored private let credentialStore: CloudProviderCredentialStore
    private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var previewReleaseTail: Task<Void, Never>?
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var previewConsumerJobID: UUID?

    init(
        store: MathNoteJobStore = .shared,
        credentialStore: CloudProviderCredentialStore = .shared
    ) {
        self.store = store
        self.credentialStore = credentialStore
        pipeline = MathNotePipeline(store: store)
    }

    var isWorking: Bool { processingTask != nil || isPreparingDraft }

    func loadJobs() async {
        do {
            jobs = try await store.listJobs()
            if let selectedJob, let refreshed = jobs.first(where: { $0.id == selectedJob.id }) {
                self.selectedJob = refreshed
            }
        } catch {
            errorMessage = "Saved Academic jobs could not be loaded."
        }
    }

    func addRawImageData(_ values: [Data]) {
        guard !values.isEmpty else { return }
        isPreparingDraft = true
        Task { [weak self] in
            guard let self else { return }
            defer { isPreparingDraft = false }
            do {
                for value in values {
                    let normalized = try await MathImagePreprocessor.normalizeSource(value)
                    draftPages.append(MathNoteDraftPage(data: normalized))
                }
            } catch {
                errorMessage = error.mathNoteSafeMessage
            }
        }
    }

    func addScannedImages(_ images: [UIImage]) {
        let values = images.compactMap { $0.jpegData(compressionQuality: 0.98) }
        addRawImageData(values)
    }

    func importFile(_ url: URL) {
        isPreparingDraft = true
        Task { [weak self] in
            guard let self else { return }
            defer { isPreparingDraft = false }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
                if type?.conforms(to: .pdf) == true {
                    let pages = try await Self.renderPDFPages(url)
                    for page in pages {
                        let normalized = try await MathImagePreprocessor.normalizeSource(page)
                        draftPages.append(MathNoteDraftPage(data: normalized))
                    }
                } else {
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    let normalized = try await MathImagePreprocessor.normalizeSource(data)
                    draftPages.append(MathNoteDraftPage(data: normalized))
                }
            } catch {
                errorMessage = error.mathNoteSafeMessage
            }
        }
    }

    func moveDraftPages(from offsets: IndexSet, to destination: Int) {
        draftPages.move(fromOffsets: offsets, toOffset: destination)
    }

    func deleteDraftPages(at offsets: IndexSet) {
        draftPages.remove(atOffsets: offsets)
    }

    func rotateDraftPage(_ id: UUID) {
        guard let index = draftPages.firstIndex(where: { $0.id == id }) else { return }
        let source = draftPages[index].data
        isPreparingDraft = true
        Task { [weak self] in
            guard let self else { return }
            defer { isPreparingDraft = false }
            do {
                let rotated = try await MathImagePreprocessor.rotateSource(source)
                guard let current = draftPages.firstIndex(where: { $0.id == id }) else { return }
                draftPages[current].data = rotated
            } catch {
                errorMessage = error.mathNoteSafeMessage
            }
        }
    }

    func clearDraft() {
        draftPages.removeAll()
        draftTitle = ""
    }

    func startConversion() {
        guard processingTask == nil else { return }
        let pages = draftPages.map(\.data)
        guard !pages.isEmpty else {
            errorMessage = MathNoteError.emptyDraft.localizedDescription
            return
        }
        let title = draftTitle
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { processingTask = nil }
            var createdJobID: UUID?
            do {
                let job = try await store.createJob(title: title, normalizedPages: pages)
                createdJobID = job.id
                activeJobID = job.id
                draftPages.removeAll()
                draftTitle = ""
                upsert(job)
                _ = try await pipeline.run(jobID: job.id, progress: progressHandler)
                await loadJobs()
                if previewConsumerJobID == job.id { await selectJob(job.id) }
            } catch {
                await handleRunError(error, jobID: createdJobID)
            }
        }
    }

    func resume(_ job: MathNoteJobManifest) {
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { processingTask = nil }
            activeJobID = job.id
            do {
                _ = try await pipeline.run(jobID: job.id, progress: progressHandler)
                await loadJobs()
                if previewConsumerJobID == job.id { await selectJob(job.id) }
            } catch {
                await handleRunError(error, jobID: job.id)
            }
        }
    }

    func useCloudFallback(_ job: MathNoteJobManifest) {
        guard processingTask == nil, job.stage == .awaitingCloudConsent else { return }
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { processingTask = nil }
            activeJobID = job.id
            do {
                // Validate both BYOK values before recording consent so a clean
                // install stays in the recoverable awaiting state.
                _ = try ProviderKeys.load(store: credentialStore)
                let consented = try await store.setCloudFallbackConsent(job.id, allowed: true)
                upsert(consented)
                if selectedJob?.id == job.id { selectedJob = consented }
                _ = try await pipeline.run(
                    jobID: job.id,
                    cloudFallbackAuthorized: true,
                    progress: progressHandler
                )
                await loadJobs()
                if previewConsumerJobID == job.id { await selectJob(job.id) }
            } catch {
                refreshCloudCredentialStatus()
                await handleRunError(error, jobID: job.id)
            }
        }
    }

    func refreshCloudCredentialStatus() {
        hasMistralCredential = credentialExists(.mistral)
        hasQwen3VLCredential = credentialExists(.qwen3VL)
    }

    func saveMistralCredential() {
        do {
            try credentialStore.save(mistralCredentialDraft, for: .mistral)
            mistralCredentialDraft = ""
            credentialStatusMessage = "Mistral key saved on this device."
            refreshCloudCredentialStatus()
        } catch {
            errorMessage = error.mathNoteSafeMessage
        }
    }

    func saveQwen3VLCredential() {
        do {
            try credentialStore.save(qwen3VLCredentialDraft, for: .qwen3VL)
            qwen3VLCredentialDraft = ""
            credentialStatusMessage = "Qwen3-VL / SiliconFlow key saved on this device."
            refreshCloudCredentialStatus()
        } catch {
            errorMessage = error.mathNoteSafeMessage
        }
    }

    func removeMistralCredential() {
        do {
            try credentialStore.remove(.mistral)
            mistralCredentialDraft = ""
            credentialStatusMessage = "Mistral key removed from this device."
            refreshCloudCredentialStatus()
        } catch {
            errorMessage = "The Mistral key could not be removed from the device Keychain."
        }
    }

    func removeQwen3VLCredential() {
        do {
            try credentialStore.remove(.qwen3VL)
            qwen3VLCredentialDraft = ""
            credentialStatusMessage = "Qwen3-VL / SiliconFlow key removed from this device."
            refreshCloudCredentialStatus()
        } catch {
            errorMessage = "The Qwen3-VL / SiliconFlow key could not be removed from the device Keychain."
        }
    }

    func cancel() {
        processingTask?.cancel()
    }

    func selectJob(_ id: UUID) async {
        previewGeneration &+= 1
        let generation = previewGeneration
        previewConsumerJobID = id
        do {
            if let previewReleaseTail { await previewReleaseTail.value }
            if let previousID = selectedJob?.id, previousID != id {
                await store.releaseMaterializedPreview(
                    for: previousID,
                    expectedURL: selectedJobDirectory
                )
                selectedJobDirectory = nil
            }
            let job = try await store.load(id)
            let source = try await pipeline.source(jobID: id)
            let directory: URL?
            if job.stage == .complete {
                directory = try await store.materializedDirectory(for: id)
            } else {
                await store.releaseMaterializedPreview(for: id)
                directory = nil
            }

            guard previewGeneration == generation, previewConsumerJobID == id else {
                if let directory {
                    await store.releaseMaterializedPreview(for: id, expectedURL: directory)
                }
                return
            }
            selectedJob = job
            selectedSource = source
            selectedJobDirectory = directory
        } catch {
            guard previewGeneration == generation, previewConsumerJobID == id else { return }
            errorMessage = error.mathNoteSafeMessage
        }
    }

    func setSelectedSource(_ source: String) {
        selectedSource = source
    }

    func rebuildSelected() {
        guard processingTask == nil, let job = selectedJob else { return }
        let source = selectedSource
        let generation = previewGeneration
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { processingTask = nil }
            activeJobID = job.id
            do {
                let updated = try await pipeline.rebuild(
                    jobID: job.id,
                    markdown: source,
                    progress: progressHandler
                )
                let shouldMaterialize = previewGeneration == generation
                    && previewConsumerJobID == updated.id
                let materializedDirectory = shouldMaterialize
                    ? try await store.materializedDirectory(for: updated.id)
                    : nil
                selectedJob = updated
                if previewGeneration == generation, previewConsumerJobID == updated.id {
                    selectedJobDirectory = materializedDirectory
                } else if let materializedDirectory {
                    await store.releaseMaterializedPreview(
                        for: updated.id,
                        expectedURL: materializedDirectory
                    )
                }
                upsert(updated)
            } catch {
                errorMessage = error.mathNoteSafeMessage
                await loadJobs()
            }
        }
    }

    func delete(_ job: MathNoteJobManifest) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if activeJobID == job.id { cancel() }
                try await store.delete(job.id)
                if selectedJob?.id == job.id {
                    previewGeneration &+= 1
                    previewConsumerJobID = nil
                    selectedJob = nil
                    selectedSource = ""
                    selectedJobDirectory = nil
                }
                await loadJobs()
            } catch {
                errorMessage = "The saved job could not be deleted."
            }
        }
    }

    func deleteAll() {
        cancel()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.deleteAll()
                previewGeneration &+= 1
                previewConsumerJobID = nil
                jobs = []
                selectedJob = nil
                selectedSource = ""
                selectedJobDirectory = nil
            } catch {
                errorMessage = "Saved Academic jobs could not be deleted."
            }
        }
    }

    func artifactURL(_ relativePath: String) -> URL? {
        guard let directory = selectedJobDirectory else { return nil }
        let url = directory.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func releaseMaterializedPreview(for jobID: UUID) {
        previewGeneration &+= 1
        if previewConsumerJobID == jobID { previewConsumerJobID = nil }
        let expectedURL = selectedJob?.id == jobID ? selectedJobDirectory : nil
        if selectedJob?.id == jobID {
            selectedJobDirectory = nil
        }
        let predecessor = previewReleaseTail
        let store = self.store
        let task = Task {
            if let predecessor { await predecessor.value }
            await store.releaseMaterializedPreview(for: jobID, expectedURL: expectedURL)
        }
        previewReleaseTail = task
    }

    /// Cancels pipeline work before lifecycle plaintext purging and drops the
    /// current preview. Encrypted checkpoints remain available for Resume.
    func suspendForProtectedLifecycle() {
        processingTask?.cancel()
        if let jobID = previewConsumerJobID {
            releaseMaterializedPreview(for: jobID)
        }
    }

    func sourcePageURLs() -> [URL] {
        guard let job = selectedJob, let directory = selectedJobDirectory else { return [] }
        return job.pages.sorted { $0.index < $1.index }.map {
            directory.appendingPathComponent($0.sourcePath)
        }
    }

    private var progressHandler: MathNotePipeline.ProgressHandler {
        { [self] manifest in await receiveProgress(manifest) }
    }

    private func receiveProgress(_ manifest: MathNoteJobManifest) {
        activeJobID = manifest.id
        upsert(manifest)
        if selectedJob?.id == manifest.id { selectedJob = manifest }
    }

    private func upsert(_ manifest: MathNoteJobManifest) {
        if let index = jobs.firstIndex(where: { $0.id == manifest.id }) {
            jobs[index] = manifest
        } else {
            jobs.insert(manifest, at: 0)
        }
        jobs.sort { $0.updatedAt > $1.updatedAt }
    }

    private func credentialExists(_ provider: CloudProviderCredentialStore.Provider) -> Bool {
        guard let value = try? credentialStore.value(for: provider) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func handleRunError(_ error: Error, jobID: UUID?) async {
        await loadJobs()
        if let jobID,
           let job = jobs.first(where: { $0.id == jobID }),
           job.stage == .awaitingCloudConsent,
           let mathError = error as? MathNoteError,
           mathError == .localInferenceUnavailable {
            // The persisted job state is the actionable event; avoid showing
            // the same condition as a generic conversion-failure alert.
            return
        }
        errorMessage = error.mathNoteSafeMessage
    }

    nonisolated private static func renderPDFPages(_ url: URL) async throws -> [Data] {
        try await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                throw MathNoteError.message("The selected PDF has no readable pages.")
            }
            var values: [Data] = []
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let scale = min(3, 2_400 / max(bounds.width, bounds.height))
                let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                    UIColor.white.setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                    context.cgContext.saveGState()
                    context.cgContext.translateBy(x: 0, y: size.height)
                    context.cgContext.scaleBy(x: scale, y: -scale)
                    page.draw(with: .mediaBox, to: context.cgContext)
                    context.cgContext.restoreGState()
                }
                guard let data = image.jpegData(compressionQuality: 0.96) else {
                    throw MathNoteError.invalidImage
                }
                values.append(data)
            }
            return values
        }.value
    }
}
