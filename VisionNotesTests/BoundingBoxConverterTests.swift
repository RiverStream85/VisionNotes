import XCTest
@testable import VisionNotes

final class BoundingBoxConverterTests: XCTestCase {

    private let imageSize = CGSize(width: 200, height: 100)

    func testNormalizedRectFlipsYAxisIntoImageSpace() {
        // Vision reports the origin at the bottom-left; the top-left origin of
        // the same box is (1 - y - height) in normalized terms.
        let normalized = CGRect(x: 0.25, y: 0.6, width: 0.5, height: 0.2)
        let rect = BoundingBoxConverter.imageRect(fromNormalized: normalized, imageSize: imageSize)

        XCTAssertEqual(rect.origin.x, 50, accuracy: 0.0001)
        XCTAssertEqual(rect.origin.y, 20, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 100, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 20, accuracy: 0.0001)
    }

    func testTopOfPageMapsToTopOfImage() {
        let topOfPage = CGRect(x: 0, y: 0.9, width: 1, height: 0.1)
        let rect = BoundingBoxConverter.imageRect(fromNormalized: topOfPage, imageSize: imageSize)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.0001)

        let bottomOfPage = CGRect(x: 0, y: 0, width: 1, height: 0.1)
        let bottomRect = BoundingBoxConverter.imageRect(fromNormalized: bottomOfPage, imageSize: imageSize)
        XCTAssertEqual(bottomRect.maxY, imageSize.height, accuracy: 0.0001)
    }

    func testRoundTripConversionReturnsOriginalRect() {
        let normalized = CGRect(x: 0.1, y: 0.15, width: 0.3, height: 0.25)
        let inImage = BoundingBoxConverter.imageRect(fromNormalized: normalized, imageSize: imageSize)
        let backToNormalized = BoundingBoxConverter.normalizedRect(fromImageRect: inImage, imageSize: imageSize)

        XCTAssertEqual(backToNormalized.origin.x, normalized.origin.x, accuracy: 0.0001)
        XCTAssertEqual(backToNormalized.origin.y, normalized.origin.y, accuracy: 0.0001)
        XCTAssertEqual(backToNormalized.width, normalized.width, accuracy: 0.0001)
        XCTAssertEqual(backToNormalized.height, normalized.height, accuracy: 0.0001)
    }

    func testZeroSizedImageDoesNotProduceInvalidRects() {
        let rect = BoundingBoxConverter.imageRect(
            fromNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: .zero
        )
        XCTAssertEqual(rect, .zero)
    }

    func testFittedImageFrameCentersInsideWiderContainer() {
        let frame = BoundingBoxConverter.fittedImageFrame(
            imageSize: CGSize(width: 100, height: 100),
            containerSize: CGSize(width: 300, height: 100)
        )
        XCTAssertEqual(frame.width, 100, accuracy: 0.0001)
        XCTAssertEqual(frame.height, 100, accuracy: 0.0001)
        XCTAssertEqual(frame.origin.x, 100, accuracy: 0.0001)
        XCTAssertEqual(frame.origin.y, 0, accuracy: 0.0001)
    }

    func testDisplayRectAccountsForLetterboxingAndFlip() {
        // A square image inside a wide container is letterboxed left and right.
        let rect = BoundingBoxConverter.displayRect(
            normalized: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
            imageSize: CGSize(width: 100, height: 100),
            containerSize: CGSize(width: 300, height: 100)
        )
        XCTAssertEqual(rect.origin.x, 100, accuracy: 0.0001)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 50, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 50, accuracy: 0.0001)
    }
}
