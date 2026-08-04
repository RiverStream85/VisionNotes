import CoreGraphics
import SwiftData
import UIKit
import XCTest
@testable import VisionNotes

/// Stand-in for Apple Vision so the import pipeline can be tested end to end
/// without depending on what a real recognizer returns.
private final class MockTextRecognitionService: TextRecognitionService, @unchecked Sendable {
    var blocksToReturn: [RecognizedTextBlock]
    var error: Error?
    private(set) var callCount = 0

    init(blocksToReturn: [RecognizedTextBlock] = [], error: Error? = nil) {
        self.blocksToReturn = blocksToReturn
        self.error = error
    }

    func recognizeText(in image: CGImage, languages: [String]) async throws -> [RecognizedTextBlock] {
        callCount += 1
        if let error { throw error }
        return blocksToReturn
    }
}

final class DocumentProcessingServiceTests: XCTestCase {

    private var root: URL!
    private var containers: [ModelContainer] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionNotesProcessingTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        root = nil
        containers.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: LibraryDocument.self, DocumentPage.self, TextBlock.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        containers.append(container)
        return ModelContext(container)
    }

    private func sampleImageData() throws -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw AppError.unsupportedImageFormat
        }
        return data
    }

    private func mockBlocks() -> [RecognizedTextBlock] {
        [
            RecognizedTextBlock(
                text: "second line",
                confidence: 0.8,
                boundingBox: CGRect(x: 0.1, y: 0.6, width: 0.4, height: 0.05)
            ),
            RecognizedTextBlock(
                text: "first line",
                confidence: 0.95,
                boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.4, height: 0.05)
            )
        ]
    }

    // MARK: - Image import

    @MainActor
    func testImportingAnImageSavesTextBlocksInReadingOrder() async throws {
        let context = try makeContext()
        let storage = FileStorageService(rootDirectory: root)
        let recognizer = MockTextRecognitionService(blocksToReturn: mockBlocks())
        let service = DocumentProcessingService(
            modelContext: context,
            storage: storage,
            pipeline: OCRPipeline(recognizer: recognizer)
        )

        var reportedStages: [ImportStage] = []
        let document = try await service.importImage(
            data: try sampleImageData(),
            type: .photo,
            originalFileName: "Scan.heic"
        ) { stage, _ in
            reportedStages.append(stage)
        }

        XCTAssertEqual(document.processingStatus, .completed)
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(document.title, "Scan")
        XCTAssertEqual(document.documentType, .photo)
        XCTAssertNotNil(document.thumbnailData)
        XCTAssertTrue(storage.fileExists(document.localFileName, in: .sources))
        XCTAssertTrue(reportedStages.contains(.complete))

        let page = try XCTUnwrap(document.sortedPages.first)
        XCTAssertEqual(page.recognizedText, "first line\nsecond line")
        XCTAssertEqual(page.sortedTextBlocks.map(\.text), ["first line", "second line"])
        XCTAssertEqual(page.sortedTextBlocks.map(\.readingOrder), [0, 1])
        XCTAssertEqual(recognizer.callCount, 1)
    }

    @MainActor
    func testFailedRecognitionMarksTheDocumentFailedWithAReadableMessage() async throws {
        let context = try makeContext()
        let storage = FileStorageService(rootDirectory: root)
        let recognizer = MockTextRecognitionService(error: AppError.ocrRequestFailed(reason: "boom"))
        let service = DocumentProcessingService(
            modelContext: context,
            storage: storage,
            pipeline: OCRPipeline(recognizer: recognizer)
        )

        do {
            _ = try await service.importImage(data: try sampleImageData(), type: .camera)
            XCTFail("Expected the import to throw")
        } catch {
            XCTAssertEqual(error as? AppError, .ocrRequestFailed(reason: "boom"))
        }

        let documents = try context.fetch(FetchDescriptor<LibraryDocument>())
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents.first?.processingStatus, .failed)
        let message = try XCTUnwrap(documents.first?.processingError)
        XCTAssertTrue(message.contains("Text recognition failed"))
        XCTAssertFalse(message.contains("NSError"))
    }

    @MainActor
    func testRunningOCRAgainReplacesThePreviousTextBlocks() async throws {
        let context = try makeContext()
        let storage = FileStorageService(rootDirectory: root)
        let recognizer = MockTextRecognitionService(blocksToReturn: mockBlocks())
        let service = DocumentProcessingService(
            modelContext: context,
            storage: storage,
            pipeline: OCRPipeline(recognizer: recognizer)
        )

        let document = try await service.importImage(data: try sampleImageData(), type: .photo)
        let page = try XCTUnwrap(document.sortedPages.first)
        page.recognizedText = "hand edited"
        try context.save()

        recognizer.blocksToReturn = [
            RecognizedTextBlock(
                text: "fresh result",
                confidence: 0.99,
                boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.06)
            )
        ]
        try await service.reprocess(document)

        let reloaded = try XCTUnwrap(document.sortedPages.first)
        XCTAssertEqual(reloaded.recognizedText, "fresh result")
        XCTAssertEqual(reloaded.sortedTextBlocks.map(\.text), ["fresh result"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TextBlock>()), 1, "Old blocks must not linger")
    }

    // MARK: - PDF import

    @MainActor
    func testImportingAPDFCreatesOnePageEachWithSequentialNumbers() async throws {
        let context = try makeContext()
        let storage = FileStorageService(rootDirectory: root)
        let recognizer = MockTextRecognitionService(blocksToReturn: mockBlocks())
        let service = DocumentProcessingService(
            modelContext: context,
            storage: storage,
            pipeline: OCRPipeline(recognizer: recognizer)
        )

        let (pdfData, _) = try DemoContentRenderer.renderPDF(pages: [
            [DemoContentRenderer.Line("page one")],
            [DemoContentRenderer.Line("page two")],
            [DemoContentRenderer.Line("page three")]
        ])
        let pdfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-test-\(UUID().uuidString).pdf")
        try pdfData.write(to: pdfURL)
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        var lastProgress: Double = 0
        let document = try await service.importPDF(from: pdfURL) { _, progress in
            lastProgress = max(lastProgress, progress)
        }

        XCTAssertEqual(document.processingStatus, .completed)
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertEqual(document.sortedPages.map(\.pageNumber), [1, 2, 3])
        XCTAssertEqual(recognizer.callCount, 3, "Every page must be recognized exactly once")
        XCTAssertEqual(lastProgress, 1, accuracy: 0.0001)
        XCTAssertNotNil(document.thumbnailData)

        for page in document.sortedPages {
            let fileName = try XCTUnwrap(page.imageFileName)
            XCTAssertTrue(storage.fileExists(fileName, in: .pages), "Page \(page.pageNumber) cache image missing")
            XCTAssertEqual(page.recognizedText, "first line\nsecond line")
        }
    }

    @MainActor
    func testImportingANonPDFFileReportsAReadableError() async throws {
        let context = try makeContext()
        let storage = FileStorageService(rootDirectory: root)
        let service = DocumentProcessingService(
            modelContext: context,
            storage: storage,
            pipeline: OCRPipeline(recognizer: MockTextRecognitionService())
        )

        let brokenURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-\(UUID().uuidString).pdf")
        try Data("not really a pdf".utf8).write(to: brokenURL)
        defer { try? FileManager.default.removeItem(at: brokenURL) }

        do {
            _ = try await service.importPDF(from: brokenURL)
            XCTFail("Expected the import to throw")
        } catch {
            guard case .pdfOpenFailed = (error as? AppError) else {
                return XCTFail("Expected pdfOpenFailed, got \(error)")
            }
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LibraryDocument>()), 0, "No half-imported row may remain")
    }

    // MARK: - Demo data

    @MainActor
    func testDemoNotesLoadWithPreFilledTextAndNoOCR() async throws {
        let context = try makeContext()
        let storage = FileStorageService(rootDirectory: root)
        let demo = DemoDataService(modelContext: context, storage: storage)

        XCTAssertTrue(try demo.libraryIsEmpty())
        let documents = try await demo.loadDemoNotes()

        XCTAssertEqual(documents.count, 3)
        XCTAssertFalse(try demo.libraryIsEmpty())
        XCTAssertEqual(documents.map(\.documentType), [.camera, .photo, .pdf])
        XCTAssertEqual(documents.last?.pageCount, 3)

        for document in documents {
            XCTAssertEqual(document.processingStatus, .completed)
            XCTAssertTrue(storage.fileExists(document.localFileName, in: .sources))
            for page in document.sortedPages {
                XCTAssertFalse(page.recognizedText.isEmpty, "Demo pages ship with text already recognized")
                XCTAssertFalse(page.textBlocks.isEmpty, "Demo pages ship with bounding boxes")
            }
        }

        let store = DocumentStore(modelContext: context, storage: storage)
        let results = SearchEngine().search(query: "eigenvectors", in: try store.searchSnapshots())
        XCTAssertFalse(results.isEmpty, "Demo content must be searchable straight away")
    }
}
