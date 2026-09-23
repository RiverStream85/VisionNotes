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
    @Attribute(originalName: "text") var legacyText: String
    @Attribute(.externalStorage) var textCiphertext: Data?
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
    ) throws {
        self.id = id
        self.page = page
        legacyText = ""
        textCiphertext = nil
        self.confidence = confidence
        self.boundingBoxX = boundingBoxX
        self.boundingBoxY = boundingBoxY
        self.boundingBoxWidth = boundingBoxWidth
        self.boundingBoxHeight = boundingBoxHeight
        self.readingOrder = readingOrder
        try setText(text)
    }

    func decryptedText() throws -> String {
        try EncryptedTextCodec.open(
            textCiphertext,
            recordID: id,
            field: "recognized-text-block"
        )
    }

    func setText(_ text: String) throws {
        let ciphertext = try EncryptedTextCodec.seal(
            text,
            recordID: id,
            field: "recognized-text-block"
        )
        let verified = try EncryptedTextCodec.open(
            ciphertext,
            recordID: id,
            field: "recognized-text-block"
        )
        guard verified == text else {
            throw EncryptedTextCodecError.verificationFailed(field: "recognized-text-block")
        }
        textCiphertext = ciphertext
        legacyText = ""
    }

    @discardableResult
    func migrateLegacyTextIfNeeded() throws -> Bool {
        if textCiphertext != nil {
            guard !legacyText.isEmpty else { return false }
            let decrypted = try decryptedText()
            guard decrypted == legacyText else {
                throw EncryptedTextCodecError.verificationFailed(field: "recognized-text-block")
            }
            legacyText = ""
            return true
        }

        let plaintext = legacyText
        try setText(plaintext)
        return true
    }

    convenience init(recognized: RecognizedTextBlock, page: DocumentPage? = nil) throws {
        try self.init(
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
