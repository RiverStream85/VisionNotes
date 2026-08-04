import XCTest
@testable import VisionNotes

final class ReadingOrderSorterTests: XCTestCase {

    private let sorter = ReadingOrderSorter()

    /// Vision's Y axis grows upward, so `y` here is the distance from the
    /// bottom of the page.
    private func block(_ text: String, x: Double, y: Double, width: Double = 0.3, height: Double = 0.05) -> RecognizedTextBlock {
        RecognizedTextBlock(
            text: text,
            confidence: 0.9,
            boundingBox: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    func testSortsTopToBottom() {
        let blocks = [
            block("bottom", x: 0.1, y: 0.10),
            block("top", x: 0.1, y: 0.80),
            block("middle", x: 0.1, y: 0.45)
        ]
        let ordered = sorter.ordered(blocks)
        XCTAssertEqual(ordered.map(\.text), ["top", "middle", "bottom"])
        XCTAssertEqual(ordered.map(\.readingOrder), [0, 1, 2])
    }

    func testSortsLeftToRightWithinTheSameLine() {
        let blocks = [
            block("right", x: 0.6, y: 0.80, width: 0.2),
            block("left", x: 0.1, y: 0.802, width: 0.2),
            block("middle", x: 0.35, y: 0.799, width: 0.2)
        ]
        let ordered = sorter.ordered(blocks)
        XCTAssertEqual(ordered.map(\.text), ["left", "middle", "right"])
    }

    func testTwoColumnPageReadsLeftColumnFirst() {
        let blocks = [
            block("L1", x: 0.05, y: 0.80, width: 0.35),
            block("R1", x: 0.55, y: 0.80, width: 0.35),
            block("L2", x: 0.05, y: 0.60, width: 0.35),
            block("R2", x: 0.55, y: 0.60, width: 0.35)
        ]
        let ordered = sorter.ordered(blocks)
        XCTAssertEqual(ordered.map(\.text), ["L1", "L2", "R1", "R2"])
    }

    func testFullWidthHeadingDisablesColumnSplit() {
        // A heading spanning the gutter means the page is not a clean two
        // column layout, so plain top-to-bottom order is used instead.
        let blocks = [
            block("Heading", x: 0.05, y: 0.90, width: 0.9),
            block("L1", x: 0.05, y: 0.70, width: 0.35),
            block("R1", x: 0.55, y: 0.70, width: 0.35),
            block("L2", x: 0.05, y: 0.50, width: 0.35),
            block("R2", x: 0.55, y: 0.50, width: 0.35)
        ]
        let ordered = sorter.ordered(blocks)
        XCTAssertEqual(ordered.map(\.text), ["Heading", "L1", "R1", "L2", "R2"])
    }

    func testSingleBlockKeepsReadingOrderZero() {
        let ordered = sorter.ordered([block("only", x: 0.1, y: 0.5)])
        XCTAssertEqual(ordered.count, 1)
        XCTAssertEqual(ordered[0].readingOrder, 0)
    }

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(sorter.ordered([]).isEmpty)
    }

    func testComposedTextJoinsLinesTopToBottom() {
        let blocks = sorter.ordered([
            block("second line", x: 0.1, y: 0.60),
            block("first", x: 0.1, y: 0.80, width: 0.2),
            block("line", x: 0.32, y: 0.80, width: 0.2)
        ])
        let text = PageTextComposer.composeText(from: blocks)
        XCTAssertEqual(text, "first line\nsecond line")
    }

    func testComposedTextKeepsColumnsSeparate() {
        let blocks = sorter.ordered([
            block("L1", x: 0.05, y: 0.80, width: 0.35),
            block("R1", x: 0.55, y: 0.80, width: 0.35),
            block("L2", x: 0.05, y: 0.60, width: 0.35),
            block("R2", x: 0.55, y: 0.60, width: 0.35)
        ])
        let text = PageTextComposer.composeText(from: blocks)
        XCTAssertEqual(text, "L1\nL2\nR1\nR2")
    }
}
