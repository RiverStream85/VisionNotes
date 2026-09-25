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
    private(set) var modelStatus = ModelStatus.checking

    enum ModelStatus: Equatable {
        case checking, ready, notDownloaded
        case downloading(received: Int64, total: Int64)
        case failed
    }

    @ObservationIgnored private let store: MathNoteJobStore
    @ObservationIgnored private let pipeline: MathNotePipeline
    @ObservationIgnored private let credentialStore: CloudProviderCredentialStore
    private var processingTask: Task<Void, Never>?
    /// The most recent selection; a slower earlier selection must not overwrite it.
    @ObservationIgnored private var requestedJobID: UUID?
    /// A job stopped because the app went to the background, resumed on return.
    @ObservationIgnored private var pausedJobID: UUID?
    @ObservationIgnored private var modelDownloadTask: Task<Void, Never>?

    init(
        store: MathNoteJobStore = .shared,
        credentialStore: CloudProviderCredentialStore = .shared
    ) {
        self.store = store
        self.credentialStore = credentialStore
        pipeline = MathNotePipeline(store: store)
    }

    var isWorking: Bool { processingTask != nil || isPreparingDraft }

    func refreshModelStatus() {
        if FirebirdModelAssets.modelDirectory() != nil {
            modelStatus = .ready
        } else if modelDownloadTask != nil {
            let snapshot = FirebirdModelDownloader.shared.snapshot()
            modelStatus = .downloading(received: snapshot.receivedBytes, total: snapshot.totalBytes)
        } else if modelStatus != .failed {
            modelStatus = .notDownloaded
        }
    }

    /// Starts or rejoins the background model download, independent of any job.
    func downloadModel() {
        guard modelDownloadTask == nil else { return }
        modelStatus = .downloading(received: 0, total: 0)
        modelDownloadTask = Task { [weak self] in
            do {
                _ = try await FirebirdModelAssets.download()
                self?.modelDownloadTask = nil
                self?.refreshModelStatus()
            } catch {
                self?.modelDownloadTask = nil
                self?.modelStatus = .failed
            }
        }
    }

    func loadJobs() async {
        do {
            jobs = try await store.listJobs()
            if let selectedJob, let refreshed = jobs.first(where: { $0.id == selectedJob.id }) {
                self.selectedJob = refreshed
            }
        } catch {
            errorMessage = "Saved Academic jobs could not be loaded: \(error.localizedDescription)"
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
                errorMessage = error.localizedDescription
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
                errorMessage = error.localizedDescription
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
                errorMessage = error.localizedDescription
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
                if requestedJobID == job.id { await selectJob(job.id) }
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
                if requestedJobID == job.id { await selectJob(job.id) }
            } catch {
                await handleRunError(error, jobID: job.id)
            }
        }
    }

    /// iOS does not allow GPU work in the background, so stop the running job
    /// there (finished pages keep their checkpoints) and continue on return.
    func pauseForBackground() {
        guard let task = processingTask, let id = activeJobID else { return }
        pausedJobID = id
        task.cancel()
    }

    func resumeAfterBackground() {
        guard let id = pausedJobID else { return }
        let running = processingTask
        Task { [weak self] in
            await running?.value
            guard let self, self.pausedJobID == id else { return }
            self.pausedJobID = nil
            await self.loadJobs()
            if let job = self.jobs.first(where: { $0.id == id }), job.stage == .cancelled {
                self.resume(job)
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
                // Check the keys first so a missing key leaves the job awaiting the cloud choice.
                _ = try ProviderKeys.load(store: credentialStore)
                _ = try await pipeline.run(
                    jobID: job.id,
                    cloudFallbackAuthorized: true,
                    progress: progressHandler
                )
                await loadJobs()
                if requestedJobID == job.id { await selectJob(job.id) }
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
            errorMessage = error.localizedDescription
        }
    }

    func saveQwen3VLCredential() {
        do {
            try credentialStore.save(qwen3VLCredentialDraft, for: .qwen3VL)
            qwen3VLCredentialDraft = ""
            credentialStatusMessage = "Qwen3-VL / SiliconFlow key saved on this device."
            refreshCloudCredentialStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeMistralCredential() {
        do {
            try credentialStore.remove(.mistral)
            mistralCredentialDraft = ""
            credentialStatusMessage = "Mistral key removed from this device."
            refreshCloudCredentialStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeQwen3VLCredential() {
        do {
            try credentialStore.remove(.qwen3VL)
            qwen3VLCredentialDraft = ""
            credentialStatusMessage = "Qwen3-VL / SiliconFlow key removed from this device."
            refreshCloudCredentialStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        processingTask?.cancel()
    }

    func selectJob(_ id: UUID) async {
        requestedJobID = id
        do {
            let job = try await store.load(id)
            let source = try await pipeline.source(jobID: id)
            let directory = try await store.directory(for: id)
            guard requestedJobID == id else { return }
            selectedJob = job
            selectedSource = source
            selectedJobDirectory = directory
        } catch {
            guard requestedJobID == id else { return }
            errorMessage = error.localizedDescription
        }
    }

    func setSelectedSource(_ source: String) {
        selectedSource = source
    }

    func rebuildSelected() {
        guard processingTask == nil, let job = selectedJob else { return }
        let source = selectedSource
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
                if selectedJob?.id == updated.id { selectedJob = updated }
                upsert(updated)
            } catch {
                errorMessage = error.localizedDescription
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
                    requestedJobID = nil
                    selectedJob = nil
                    selectedSource = ""
                    selectedJobDirectory = nil
                }
                await loadJobs()
            } catch {
                errorMessage = "The saved job could not be deleted: \(error.localizedDescription)"
            }
        }
    }

    func deleteAll() {
        cancel()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.deleteAll()
                requestedJobID = nil
                jobs = []
                selectedJob = nil
                selectedSource = ""
                selectedJobDirectory = nil
            } catch {
                errorMessage = "Saved Academic jobs could not be deleted: \(error.localizedDescription)"
            }
        }
    }

    func artifactURL(_ relativePath: String) -> URL? {
        guard let directory = selectedJobDirectory else { return nil }
        let url = directory.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
        // A background pause is expected; the job resumes on return without an alert.
        if let jobID, jobID == pausedJobID { return }
        if let jobID,
           let job = jobs.first(where: { $0.id == jobID }),
           job.stage == .awaitingCloudConsent,
           let mathError = error as? MathNoteError,
           mathError == .localInferenceUnavailable {
            // The persisted job state is the actionable event; avoid showing
            // the same condition as a generic conversion-failure alert.
            return
        }
        errorMessage = error.localizedDescription
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
