import Foundation
import SwiftData

/// Runs an import end to end: copy the file into the sandbox, render pages,
/// recognize text with Apple Vision, and persist the result.
///
/// The service itself is `@MainActor` because it owns a `ModelContext`, which
/// is not thread safe. Everything expensive — decoding, rendering, OCR — is
/// awaited on `nonisolated` helpers that run on the cooperative pool, so the
/// main thread only ever does short model updates.
@MainActor
final class DocumentProcessingService {
    typealias ProgressHandler = (ImportStage, Double) -> Void

    private let modelContext: ModelContext
    private let storage: FileStorageServicing
    private let pipeline: OCRPipeline
    private let pdfRenderer: PDFPageRendering
    private let store: DocumentStore

    init(
        modelContext: ModelContext,
        storage: FileStorageServicing = FileStorageService.shared,
        pipeline: OCRPipeline = OCRPipeline(),
        pdfRenderer: PDFPageRendering = PDFKitPageRenderer()
    ) {
        self.modelContext = modelContext
        self.storage = storage
        self.pipeline = pipeline
        self.pdfRenderer = pdfRenderer
        self.store = DocumentStore(modelContext: modelContext, storage: storage)
    }

    // MARK: - Image import

    @discardableResult
    func importImage(
        data: Data,
        type: DocumentType,
        originalFileName: String? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> LibraryDocument {
        progress?(.preparingFile, 0.05)

        let documentID = UUID()
        let prepared: PreparedImage
        do {
            prepared = try await ImagePreparer.prepare(data)
        } catch {
            throw AppError.wrap(error) { _ in AppError.photoLoadFailed }
        }

        let fileName = FileNameGenerator.sourceFileName(documentID: documentID, type: type)
        try storage.write(prepared.sourceData, fileName: fileName, in: .sources)

        let now = Date()
        let document = LibraryDocument(
            id: documentID,
            title: FileNameGenerator.title(fromOriginalFileName: originalFileName, type: type, date: now),
            documentType: type,
            localFileName: fileName,
            originalFileName: originalFileName,
            createdAt: now,
            updatedAt: now,
            pageCount: 1,
            processingStatus: .processing,
            processingProgress: 0.2,
            thumbnailData: prepared.thumbnailData
        )
        modelContext.insert(document)

        let page = DocumentPage(
            pageNumber: 1,
            recognizedText: "",
            imageFileName: fileName
        )
        modelContext.insert(page)
        // Append on the to-many side: SwiftData maintains the inverse from
        // here, and only relationships it knows about are cascade-deleted.
        document.pages.append(page)
        try store.save()

        progress?(.recognizingText, 0.35)

        do {
            let recognized = try await pipeline.recognizePage(fromImageData: prepared.sourceData)
            try Task.checkCancellation()

            progress?(.savingResults, 0.85)
            page.recognizedText = recognized.text
            page.textBlocks = recognized.blocks.map { TextBlock(recognized: $0) }
            document.processingStatus = .completed
            document.processingProgress = 1
            document.processingError = nil
            document.updatedAt = Date()
            try store.save()
            progress?(.complete, 1)
            return document
        } catch {
            handleFailure(error, for: document)
            throw AppError.wrap(error) { AppError.ocrRequestFailed(reason: $0) }
        }
    }

    // MARK: - PDF import

    @discardableResult
    func importPDF(
        from sourceURL: URL,
        progress: ProgressHandler? = nil
    ) async throws -> LibraryDocument {
        progress?(.preparingFile, 0.02)

        let documentID = UUID()
        let originalFileName = sourceURL.lastPathComponent
        let fileName = FileNameGenerator.sourceFileName(documentID: documentID, type: .pdf)
        try storage.copyItem(at: sourceURL, toFileName: fileName, in: .sources)
        let localURL = try storage.url(for: fileName, in: .sources)

        let pageCount: Int
        do {
            pageCount = try await pdfRenderer.pageCount(at: localURL)
        } catch {
            storage.deleteIgnoringMissing(fileName: fileName, in: .sources)
            throw AppError.wrap(error) { _ in AppError.pdfOpenFailed(fileName: originalFileName) }
        }

        let now = Date()
        let document = LibraryDocument(
            id: documentID,
            title: FileNameGenerator.title(fromOriginalFileName: originalFileName, type: .pdf, date: now),
            documentType: .pdf,
            localFileName: fileName,
            originalFileName: originalFileName,
            createdAt: now,
            updatedAt: now,
            pageCount: pageCount,
            processingStatus: .processing,
            processingProgress: 0
        )
        modelContext.insert(document)
        try store.save()

        do {
            try await processPDFPages(
                document: document,
                localURL: localURL,
                pageCount: pageCount,
                progress: progress
            )
            document.processingStatus = .completed
            document.processingProgress = 1
            document.processingError = nil
            document.updatedAt = Date()
            try store.save()
            progress?(.complete, 1)
            return document
        } catch {
            handleFailure(error, for: document)
            throw AppError.wrap(error) { AppError.ocrRequestFailed(reason: $0) }
        }
    }

    // MARK: - Re-running OCR

    /// Re-recognizes every page of an existing document, replacing the stored
    /// text and text blocks. Used by "Run OCR Again".
    func reprocess(_ document: LibraryDocument, progress: ProgressHandler? = nil) async throws {
        progress?(.preparingFile, 0.05)
        document.processingStatus = .processing
        document.processingProgress = 0
        document.processingError = nil
        try store.save()

        do {
            if document.documentType == .pdf {
                let localURL = try storage.url(for: document.localFileName, in: .sources)
                guard storage.fileExists(document.localFileName, in: .sources) else {
                    throw AppError.fileMissing(fileName: document.localFileName)
                }
                let pageCount = try await pdfRenderer.pageCount(at: localURL)
                for page in document.pages {
                    modelContext.delete(page)
                }
                document.pageCount = pageCount
                try store.save()
                try await processPDFPages(
                    document: document,
                    localURL: localURL,
                    pageCount: pageCount,
                    progress: progress
                )
            } else {
                let data = try storage.data(forFileName: document.localFileName, in: .sources)
                progress?(.recognizingText, 0.4)
                let recognized = try await pipeline.recognizePage(fromImageData: data)
                try Task.checkCancellation()
                progress?(.savingResults, 0.85)

                let page = document.sortedPages.first ?? {
                    let created = DocumentPage(
                        pageNumber: 1,
                        imageFileName: document.localFileName
                    )
                    modelContext.insert(created)
                    document.pages.append(created)
                    return created
                }()
                for block in page.textBlocks {
                    modelContext.delete(block)
                }
                page.recognizedText = recognized.text
                page.textBlocks = recognized.blocks.map { TextBlock(recognized: $0) }
                document.pageCount = 1
            }

            document.processingStatus = .completed
            document.processingProgress = 1
            document.processingError = nil
            document.updatedAt = Date()
            try store.save()
            progress?(.complete, 1)
        } catch {
            handleFailure(error, for: document)
            throw AppError.wrap(error) { AppError.ocrRequestFailed(reason: $0) }
        }
    }

    /// Re-runs OCR for a single page, without touching the rest of the document.
    func reprocessPage(_ page: DocumentPage) async throws -> RecognizedPage {
        guard let document = page.document else {
            throw AppError.fileMissing(fileName: "page \(page.pageNumber)")
        }

        let recognized: RecognizedPage
        if document.documentType == .pdf {
            let localURL = try storage.url(for: document.localFileName, in: .sources)
            guard storage.fileExists(document.localFileName, in: .sources) else {
                throw AppError.fileMissing(fileName: document.localFileName)
            }
            let rendered = try await pdfRenderer.renderPageImages(
                pageNumber: page.pageNumber,
                at: localURL
            )
            recognized = try await pipeline.recognizePage(fromImageData: rendered.ocrImageData)
        } else {
            let data = try storage.data(forFileName: document.localFileName, in: .sources)
            recognized = try await pipeline.recognizePage(fromImageData: data)
        }

        for block in page.textBlocks {
            modelContext.delete(block)
        }
        page.recognizedText = recognized.text
        page.textBlocks = recognized.blocks.map { TextBlock(recognized: $0) }
        document.updatedAt = Date()
        try store.save()
        return recognized
    }

    // MARK: - Private

    /// One page at a time: render, OCR, persist, release. Nothing holds on to a
    /// page bitmap once its text has been saved.
    private func processPDFPages(
        document: LibraryDocument,
        localURL: URL,
        pageCount: Int,
        progress: ProgressHandler?
    ) async throws {
        for pageNumber in 1...max(pageCount, 1) {
            try Task.checkCancellation()
            guard isLive(document) else { throw CancellationError() }

            let base = PDFPageMapper.progress(completedPages: pageNumber - 1, pageCount: pageCount)
            progress?(.renderingPages, base)

            let rendered = try await pdfRenderer.renderPageImages(pageNumber: pageNumber, at: localURL)
            let cacheFileName = FileNameGenerator.pageImageFileName(
                documentID: document.id,
                pageNumber: pageNumber
            )
            try storage.write(rendered.cacheImageData, fileName: cacheFileName, in: .pages)

            if pageNumber == 1, document.thumbnailData == nil {
                document.thumbnailData = try? await ImagePreparer.thumbnail(from: rendered.cacheImageData)
            }

            progress?(.recognizingText, base + 0.5 / Double(max(pageCount, 1)))
            let recognized = try await pipeline.recognizePage(fromImageData: rendered.ocrImageData)
            try Task.checkCancellation()
            guard isLive(document) else { throw CancellationError() }

            let page = DocumentPage(
                pageNumber: pageNumber,
                recognizedText: recognized.text,
                imageFileName: cacheFileName
            )
            modelContext.insert(page)
            document.pages.append(page)
            page.textBlocks = recognized.blocks.map { TextBlock(recognized: $0) }

            document.processingProgress = PDFPageMapper.progress(
                completedPages: pageNumber,
                pageCount: pageCount
            )
            progress?(.savingResults, document.processingProgress)
            try store.save()
        }
    }

    /// A document the user deleted mid-import loses its context; carrying on
    /// would write rows nothing points at.
    private func isLive(_ document: LibraryDocument) -> Bool {
        document.modelContext != nil
    }

    /// Marks a failed document, or cleans it up completely when the user
    /// cancelled the import.
    private func handleFailure(_ error: Error, for document: LibraryDocument) {
        let appError = AppError.wrap(error) { AppError.ocrRequestFailed(reason: $0) }

        guard isLive(document) else { return }

        if appError == .processingCancelled {
            try? store.delete(document)
            return
        }

        document.processingStatus = .failed
        document.processingProgress = 0
        document.processingError = [appError.errorDescription, appError.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: " ")
        document.updatedAt = Date()
        try? store.save()
    }
}
