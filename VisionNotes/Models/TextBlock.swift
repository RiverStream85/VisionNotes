import CoreGraphics
import Foundation
import SwiftData

/// One recognized text observation on a page.
///
/// The bounding box is stored as four doubles in Vision's normalized coordinate
/// space (origin bottom-left, values in 0...1) so it stays resolution
/// independent. Use `BoundingBoxConverter` to map it into view coordinates.
@Model
final class TextBlock {
    @Attribute(.unique) var id: UUID
    var page: DocumentPage?
    var text: String
    var confidence: Float
    var boundingBoxX: Double
    var boundingBoxY: Double
    var boundingBoxWidth: Double
    var boundingBoxHeight: Double
    var readingOrder: Int

    init(
        id: UUID = UUID(),
        page: DocumentPage? = nil,
        text: String,
        confidence: Float,
        boundingBoxX: Double,
        boundingBoxY: Double,
        boundingBoxWidth: Double,
        boundingBoxHeight: Double,
        readingOrder: Int
    ) {
        self.id = id
        self.page = page
        self.text = text
        self.confidence = confidence
        self.boundingBoxX = boundingBoxX
        self.boundingBoxY = boundingBoxY
        self.boundingBoxWidth = boundingBoxWidth
        self.boundingBoxHeight = boundingBoxHeight
        self.readingOrder = readingOrder
    }

    convenience init(recognized: RecognizedTextBlock, page: DocumentPage? = nil) {
        self.init(
            page: page,
            text: recognized.text,
            confidence: recognized.confidence,
            boundingBoxX: recognized.boundingBox.origin.x,
            boundingBoxY: recognized.boundingBox.origin.y,
            boundingBoxWidth: recognized.boundingBox.size.width,
            boundingBoxHeight: recognized.boundingBox.size.height,
            readingOrder: recognized.readingOrder
        )
    }

    /// Normalized rect in Vision's coordinate space.
    var normalizedBoundingBox: CGRect {
        CGRect(
            x: boundingBoxX,
            y: boundingBoxY,
            width: boundingBoxWidth,
            height: boundingBoxHeight
        )
    }
}
