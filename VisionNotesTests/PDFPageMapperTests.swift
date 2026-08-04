import XCTest
@testable import VisionNotes

final class PDFPageMapperTests: XCTestCase {

    func testPageNumbersAreOneBasedWhilePDFKitIndicesAreZeroBased() {
        XCTAssertEqual(PDFPageMapper.pageIndex(forPageNumber: 1), 0)
        XCTAssertEqual(PDFPageMapper.pageNumber(forIndex: 0), 1)
        XCTAssertEqual(PDFPageMapper.pageIndex(forPageNumber: 42), 41)
        XCTAssertEqual(PDFPageMapper.pageNumber(forIndex: 41), 42)
    }

    func testRoundTripIsStable() {
        for pageNumber in 1...50 {
            let index = PDFPageMapper.pageIndex(forPageNumber: pageNumber)
            XCTAssertEqual(PDFPageMapper.pageNumber(forIndex: index), pageNumber)
        }
    }

    func testClampingKeepsPageNumbersInsideTheDocument() {
        XCTAssertEqual(PDFPageMapper.clampedPageNumber(0, pageCount: 3), 1)
        XCTAssertEqual(PDFPageMapper.clampedPageNumber(-7, pageCount: 3), 1)
        XCTAssertEqual(PDFPageMapper.clampedPageNumber(2, pageCount: 3), 2)
        XCTAssertEqual(PDFPageMapper.clampedPageNumber(9, pageCount: 3), 3)
    }

    func testClampingAnEmptyDocumentReturnsNil() {
        XCTAssertNil(PDFPageMapper.clampedPageNumber(1, pageCount: 0))
    }

    func testValidityCheck() {
        XCTAssertTrue(PDFPageMapper.isValidPageNumber(1, pageCount: 1))
        XCTAssertFalse(PDFPageMapper.isValidPageNumber(0, pageCount: 1))
        XCTAssertFalse(PDFPageMapper.isValidPageNumber(2, pageCount: 1))
    }

    func testProgressReportsFractionOfCompletedPages() {
        XCTAssertEqual(PDFPageMapper.progress(completedPages: 0, pageCount: 4), 0, accuracy: 0.0001)
        XCTAssertEqual(PDFPageMapper.progress(completedPages: 1, pageCount: 4), 0.25, accuracy: 0.0001)
        XCTAssertEqual(PDFPageMapper.progress(completedPages: 4, pageCount: 4), 1, accuracy: 0.0001)
        XCTAssertEqual(PDFPageMapper.progress(completedPages: 9, pageCount: 4), 1, accuracy: 0.0001)
        XCTAssertEqual(PDFPageMapper.progress(completedPages: 1, pageCount: 0), 0, accuracy: 0.0001)
    }
}
