import XCTest
@testable import VisionNotes

final class FileNameGeneratorTests: XCTestCase {

    private let id = UUID(uuidString: "5B2C4D6E-1111-2222-3333-444455556666")!

    func testSourceFileNameUsesLowercasedIDAndTypeExtension() {
        XCTAssertEqual(
            FileNameGenerator.sourceFileName(documentID: id, type: .pdf),
            "doc_5b2c4d6e-1111-2222-3333-444455556666.pdf"
        )
        XCTAssertEqual(
            FileNameGenerator.sourceFileName(documentID: id, type: .photo),
            "doc_5b2c4d6e-1111-2222-3333-444455556666.jpg"
        )
        XCTAssertEqual(
            FileNameGenerator.sourceFileName(documentID: id, type: .camera),
            "doc_5b2c4d6e-1111-2222-3333-444455556666.jpg"
        )
    }

    func testPageImageFileNamesArePaddedSoTheySortNaturally() {
        let first = FileNameGenerator.pageImageFileName(documentID: id, pageNumber: 1)
        let tenth = FileNameGenerator.pageImageFileName(documentID: id, pageNumber: 10)
        let hundredth = FileNameGenerator.pageImageFileName(documentID: id, pageNumber: 100)

        XCTAssertTrue(first.hasSuffix("_0001.jpg"))
        XCTAssertTrue(tenth.hasSuffix("_0010.jpg"))
        XCTAssertTrue(hundredth.hasSuffix("_0100.jpg"))
        XCTAssertEqual([tenth, first, hundredth].sorted(), [first, tenth, hundredth])
    }

    func testGeneratedNamesNeverContainPathSeparators() {
        let names = [
            FileNameGenerator.sourceFileName(documentID: id, type: .pdf),
            FileNameGenerator.pageImageFileName(documentID: id, pageNumber: 7)
        ]
        for name in names {
            XCTAssertFalse(name.contains("/"))
            XCTAssertFalse(name.contains(".."))
        }
    }

    func testTitleFromFileNameDropsExtensionAndCleansUp() {
        let title = FileNameGenerator.title(
            fromOriginalFileName: "  Meeting/Notes:  2026 .pdf",
            type: .pdf,
            date: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(title, "Meeting Notes 2026")
    }

    func testTitleFallsBackToTypeAndDate() {
        let title = FileNameGenerator.title(
            fromOriginalFileName: nil,
            type: .camera,
            date: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(title.hasPrefix("Camera "))
        XCTAssertTrue(title.count > "Camera ".count)
    }

    func testSanitizedTitleIsTruncatedToMaxLength() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(FileNameGenerator.sanitizedTitle(long, maxLength: 20).count, 20)
    }

    func testSanitizedTitleCollapsesWhitespace() {
        XCTAssertEqual(FileNameGenerator.sanitizedTitle("  a \n b\t\tc "), "a b c")
    }
}
