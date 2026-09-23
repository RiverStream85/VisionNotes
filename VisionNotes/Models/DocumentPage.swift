import Foundation
import SwiftData

/// One page of a document. Image documents always have exactly one page.
@Model
final class DocumentPage {
    @Attribute(.unique) var id: UUID
    var document: LibraryDocument?
    /// 1-based page number, matching what the reader shows the user.
    var pageNumber: Int
    /// Retains the original column long enough for an in-place migration. It
    /// is cleared immediately after a verified AES-GCM envelope is written.
    @Attribute(originalName: "recognizedText") var legacyRecognizedText: String
    @Attribute(.externalStorage) var recognizedTextCiphertext: Data?
    /// File name of the page image in the sandbox (original image, or the
    /// cached render of a PDF page). `nil` when no cache could be written.
    var imageFileName: String?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \TextBlock.page)
    var textBlocks: [TextBlock]

    init(
        id: UUID = UUID(),
        document: LibraryDocument? = nil,
        pageNumber: Int,
        recognizedText: String = "",
        imageFileName: String? = nil,
        createdAt: Date = Date(),
        textBlocks: [TextBlock] = []
    ) throws {
        self.id = id
        self.document = document
        self.pageNumber = pageNumber
        legacyRecognizedText = ""
        recognizedTextCiphertext = nil
        self.imageFileName = imageFileName
        self.createdAt = createdAt
        self.textBlocks = textBlocks
        try setRecognizedText(recognizedText)
    }

    func decryptedRecognizedText() throws -> String {
        try EncryptedTextCodec.open(
            recognizedTextCiphertext,
            recordID: id,
            field: "page-recognized-text"
        )
    }

    func setRecognizedText(_ text: String) throws {
        let ciphertext = try EncryptedTextCodec.seal(
            text,
            recordID: id,
            field: "page-recognized-text"
        )
        let verified = try EncryptedTextCodec.open(
            ciphertext,
            recordID: id,
            field: "page-recognized-text"
        )
        guard verified == text else {
            throw EncryptedTextCodecError.verificationFailed(field: "page-recognized-text")
        }
        recognizedTextCiphertext = ciphertext
        legacyRecognizedText = ""
    }

    /// Converts the legacy String column exactly once. Existing ciphertext is
    /// never replaced with legacy plaintext if authentication fails.
    @discardableResult
    func migrateLegacyRecognizedTextIfNeeded() throws -> Bool {
        if recognizedTextCiphertext != nil {
            guard !legacyRecognizedText.isEmpty else { return false }
            let decrypted = try decryptedRecognizedText()
            guard decrypted == legacyRecognizedText else {
                throw EncryptedTextCodecError.verificationFailed(field: "page-recognized-text")
            }
            legacyRecognizedText = ""
            return true
        }

        let plaintext = legacyRecognizedText
        try setRecognizedText(plaintext)
        return true
    }

    /// Text blocks in natural reading order.
    var sortedTextBlocks: [TextBlock] {
        textBlocks.sorted { $0.readingOrder < $1.readingOrder }
    }
}
