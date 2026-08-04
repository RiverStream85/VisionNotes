import CoreGraphics
import Foundation

/// A plain value produced by a `TextRecognitionService`.
///
/// Keeping the OCR output free of SwiftData lets the recognition and ordering
/// code run off the main actor and stay directly unit-testable.
struct RecognizedTextBlock: Identifiable, Hashable, Sendable {
    let id: UUID
    let text: String
    let confidence: Float
    /// Vision's normalized rect: origin bottom-left, values in 0...1.
    let boundingBox: CGRect
    /// Position in natural reading order, assigned by a `TextBlockOrdering`.
    var readingOrder: Int

    init(
        id: UUID = UUID(),
        text: String,
        confidence: Float,
        boundingBox: CGRect,
        readingOrder: Int = 0
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.readingOrder = readingOrder
    }

    /// `CGRect` is not `Hashable`, so equality and hashing are spelled out
    /// over its components.
    static func == (lhs: RecognizedTextBlock, rhs: RecognizedTextBlock) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && lhs.confidence == rhs.confidence
            && lhs.boundingBox.equalTo(rhs.boundingBox)
            && lhs.readingOrder == rhs.readingOrder
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(text)
        hasher.combine(confidence)
        hasher.combine(boundingBox.origin.x)
        hasher.combine(boundingBox.origin.y)
        hasher.combine(boundingBox.size.width)
        hasher.combine(boundingBox.size.height)
        hasher.combine(readingOrder)
    }

    func withReadingOrder(_ order: Int) -> RecognizedTextBlock {
        RecognizedTextBlock(
            id: id,
            text: text,
            confidence: confidence,
            boundingBox: boundingBox,
            readingOrder: order
        )
    }
}
