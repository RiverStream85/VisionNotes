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
    var draftTitle = ""
    var errorMessage: String?

    @ObservationIgnored private let store: MathNoteJobStore
    @ObservationIgnored private let pipeline: MathNotePipeline
    @ObservationIgnored private var processingTask: Task<Void, Never>?

    init(store: MathNoteJobStore = .shared) {
        self.store = store
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
            do {
                let job = try await store.createJob(title: title, normalizedPages: pages)
                activeJobID = job.id
                draftPages.removeAll()
                draftTitle = ""
                upsert(job)
                _ = try await pipeline.run(jobID: job.id, progress: progressHandler)
                await loadJobs()
                await selectJob(job.id)
            } catch {
                errorMessage = error.mathNoteSafeMessage
                await loadJobs()
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
                await selectJob(job.id)
            } catch {
                errorMessage = error.mathNoteSafeMessage
                await loadJobs()
            }
        }
    }

    func cancel() {
        processingTask?.cancel()
    }

    func selectJob(_ id: UUID) async {
        do {
            let job = try await store.load(id)
            selectedJob = job
            selectedSource = try await pipeline.source(jobID: id)
            selectedJobDirectory = await store.directory(for: id)
        } catch {
            errorMessage = error.mathNoteSafeMessage
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
                selectedJob = updated
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
