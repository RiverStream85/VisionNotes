import XCTest
@testable import VisionNotes

final class FileStorageServiceTests: XCTestCase {

    private var root: URL!
    private var storage: FileStorageService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionNotesTests-\(UUID().uuidString)", isDirectory: true)
        storage = FileStorageService(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        storage = nil
        root = nil
        try super.tearDownWithError()
    }

    func testWriteThenReadRoundTrip() throws {
        let payload = Data("hello vision".utf8)
        try storage.write(payload, fileName: "a.txt", in: .sources)

        XCTAssertTrue(storage.fileExists("a.txt", in: .sources))
        XCTAssertEqual(try storage.data(forFileName: "a.txt", in: .sources), payload)
    }

    func testDirectoriesAreIsolatedFromEachOther() throws {
        try storage.write(Data("one".utf8), fileName: "same.jpg", in: .sources)
        try storage.write(Data("two".utf8), fileName: "same.jpg", in: .pages)

        XCTAssertEqual(try storage.data(forFileName: "same.jpg", in: .sources), Data("one".utf8))
        XCTAssertEqual(try storage.data(forFileName: "same.jpg", in: .pages), Data("two".utf8))
    }

    func testReadingAMissingFileThrowsAReadableError() {
        XCTAssertThrowsError(try storage.data(forFileName: "nope.jpg", in: .pages)) { error in
            XCTAssertEqual(error as? AppError, .fileMissing(fileName: "nope.jpg"))
        }
    }

    func testDeleteRemovesTheFile() throws {
        try storage.write(Data("x".utf8), fileName: "gone.jpg", in: .pages)
        try storage.delete(fileName: "gone.jpg", in: .pages)
        XCTAssertFalse(storage.fileExists("gone.jpg", in: .pages))
    }

    func testDeletingAMissingFileIsNotAnError() {
        XCTAssertNoThrow(try storage.delete(fileName: "never-existed.jpg", in: .pages))
        storage.deleteIgnoringMissing(fileName: nil, in: .pages)
        storage.deleteIgnoringMissing(fileName: "", in: .pages)
    }

    func testCopyItemImportsAFileFromOutsideTheSandbox() throws {
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-\(UUID().uuidString).pdf")
        try Data("pdf bytes".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }

        try storage.copyItem(at: external, toFileName: "copied.pdf", in: .sources)
        XCTAssertEqual(try storage.data(forFileName: "copied.pdf", in: .sources), Data("pdf bytes".utf8))
    }

    func testCopyingOverAnExistingFileReplacesIt() throws {
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-\(UUID().uuidString).pdf")
        try Data("new".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }

        try storage.write(Data("old".utf8), fileName: "target.pdf", in: .sources)
        try storage.copyItem(at: external, toFileName: "target.pdf", in: .sources)
        XCTAssertEqual(try storage.data(forFileName: "target.pdf", in: .sources), Data("new".utf8))
    }

    func testCopyingAMissingSourceThrowsACopyError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).pdf")
        XCTAssertThrowsError(try storage.copyItem(at: missing, toFileName: "x.pdf", in: .sources)) { error in
            guard case .fileCopyFailed = (error as? AppError) else {
                return XCTFail("Expected a fileCopyFailed error, got \(error)")
            }
        }
    }
}
