import SwiftData
import XCTest
@testable import VisionNotes

/// SwiftData-backed tests: cascade deletion, local file cleanup, and the
/// snapshots that feed search.
final class DocumentStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionNotesStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    @MainActor
    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: LibraryDocument.self, DocumentPage.self, TextBlock.self,
            configurations: configuration
        )
        // Keep the container alive for the lifetime of the test.
        containers.append(container)
        return ModelContext(container)
    }

    private var containers: [ModelContainer] = []

    @MainActor
    @discardableResult
    private func makeDocument(
        in context: ModelContext,
        storage: FileStorageService,
        title: String,
        pageTexts: [String],
        type: DocumentType = .pdf
    ) throws -> LibraryDocument {
        let id = UUID()
        let sourceName = FileNameGenerator.sourceFileName(documentID: id, type: type)
        try storage.write(Data("source".utf8), fileName: sourceName, in: .sources)

        let document = LibraryDocument(
            id: id,
            title: title,
            documentType: type,
            localFileName: sourceName,
            pageCount: pageTexts.count,
            processingStatus: .completed,
            processingProgress: 1
        )
        context.insert(document)

        for (index, text) in pageTexts.enumerated() {
            let pageNumber = index + 1
            let pageFileName = FileNameGenerator.pageImageFileName(documentID: id, pageNumber: pageNumber)
            try storage.write(Data("page".utf8), fileName: pageFileName, in: .pages)

            let page = DocumentPage(
                pageNumber: pageNumber,
                recognizedText: text,
                imageFileName: pageFileName
            )
            context.insert(page)
            document.pages.append(page)
            page.textBlocks = (0..<3).map { blockIndex in
                TextBlock(
                    text: "block \(blockIndex)",
                    confidence: 0.9,
                    boundingBoxX: 0.1,
                    boundingBoxY: 0.1,
                    boundingBoxWidth: 0.2,
                    boundingBoxHeight: 0.05,
                    readingOrder: blockIndex
                )
            }
        }
        try context.save()
        return document
    }

    // MARK: - Tests

    @MainActor
    func testDeletingADocumentAlsoDeletesPagesBlocksAndFiles() throws {
        let context = try makeContext()
        let storage = FileStorageService(rootDirectory: root)
        let store = DocumentStore(modelContext: context, storage: storage)

        let document = try makeDocument(
            in: context,
            storage: storage,
            title: "Report",
            pageTexts: ["page one", "page two"]
        )
        let sourceName = document.localFileName
        let pageFileNames = document.sortedPages.compactMap(\.imageFileName)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DocumentPage>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TextBlock>()), 6)

        try store.delete(document)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LibraryDocument>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DocumentPage>()), 0, "Pages must cascade")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TextBlock>()), 0, "Text blocks must cascade")

        XCTAssertFalse(storage.fileExists(sourceName, in: .sources), "The stored source file must be removed")
        for fileName in pageFileNames {
            XCTAssertFalse(storage.fileExists(fileName, in: .pages), "Cached page images must be removed")
        }
    }

    @MainActor
    func testDeletingOneDocumentLeavesOthersIntact() throws {
        let context = try makeContext()
        let storage = FileStorageService(rootDirectory: root)
        let store = DocumentStore(modelContext: context, storage: storage)

        let first = try makeDocument(in: context, storage: storage, title: "First", pageTexts: ["a"])
        let second = try makeDocument(in: context, storage: storage, title: "Second", pageTexts: ["b", "c"])

        try store.delete(first)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LibraryDocument>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DocumentPage>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TextBlock>()), 6)
        XCTAssertTrue(storage.fileExists(second.localFileName, in: .sources))
    }

    @MainActor
    func testDeletingWhenLocalFilesAreAlreadyGoneStillSucceeds() throws {
        let context = try makeContext()
        let storage = FileStorageService(rootDirectory: root)
        let store = DocumentStore(modelContext: context, storage: storage)

        let document = try makeDocument(in: context, storage: storage, title: "Orphan", pageTexts: ["a"])
        try storage.delete(fileName: document.localFileName, in: .sources)

        XCTAssertNoThrow(try store.delete(document))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LibraryDocument>()), 0)
    }

    @MainActor
    func testDeletingByOffsetsRemovesTheRightRows() throws {
        let context = try makeContext()
        let storage = FileStorageService(rootDirectory: root)
        let store = DocumentStore(modelContext: context, storage: storage)

        try makeDocument(in: context, storage: storage, title: "Keep", pageTexts: ["a"])
        try makeDocument(in: context, storage: storage, title: "Remove", pageTexts: ["b"])

        let documents = try store.allDocuments().sorted { $0.title < $1.title }
        try store.delete(documentsAt: IndexSet(integer: 1), in: documents)

        let remaining = try store.allDocuments()
        XCTAssertEqual(remaining.map(\.title), ["Keep"])
    }

    @MainActor
    func testSearchSnapshotsMirrorStoredPages() throws {
        let context = try makeContext()
        let storage = FileStorageService(rootDirectory: root)
        let store = DocumentStore(modelContext: context, storage: storage)

        try makeDocument(in: context, storage: storage, title: "Lecture", pageTexts: ["特征值", "eigenvalues"])

        let snapshots = try store.searchSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].pages.map(\.pageNumber), [1, 2])

        let results = SearchEngine().search(query: "特征值", in: snapshots)
        XCTAssertEqual(results.map(\.pageNumber), [1])
    }

    @MainActor
    func testEditedTextIsImmediatelySearchable() throws {
        let context = try makeContext()
        let storage = FileStorageService(rootDirectory: root)
        let store = DocumentStore(modelContext: context, storage: storage)

        let document = try makeDocument(in: context, storage: storage, title: "Notes", pageTexts: ["before"])
        guard let page = document.sortedPages.first else { return XCTFail("Expected one page") }

        try store.updateRecognizedText("corrected by hand", on: page)

        let results = SearchEngine().search(query: "corrected", in: try store.searchSnapshots())
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.pageNumber, 1)
        XCTAssertTrue(SearchEngine().search(query: "before", in: try store.searchSnapshots()).isEmpty)
    }

    @MainActor
    func testRenameSanitizesTheTitle() throws {
        let context = try makeContext()
        let storage = FileStorageService(rootDirectory: root)
        let store = DocumentStore(modelContext: context, storage: storage)

        let document = try makeDocument(in: context, storage: storage, title: "Old", pageTexts: ["a"])
        try store.rename(document, to: "  New/Title  ")

        XCTAssertEqual(document.title, "New Title")
    }
}
