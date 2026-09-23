import Foundation
import SwiftData

/// One imported item in the library: a camera capture, a photo, or a PDF.
///
/// The enum values are persisted as their raw strings. SwiftData stores raw
/// strings reliably across schema versions and keeps `#Predicate` usable, while
/// the typed `documentType` / `processingStatus` accessors keep call sites clean.
@Model
final class LibraryDocument {
    @Attribute(.unique) var id: UUID
    @Attribute(originalName: "title") var legacyTitle: String = ""
    var titleCiphertext: Data?
    var documentTypeRawValue: String
    /// File name (not a full path) of the original image or PDF in the sandbox.
    var localFileName: String
    /// File name the user picked the document with, when one was available.
    @Attribute(originalName: "originalFileName") var legacyOriginalFileName: String?
    var originalFileNameCiphertext: Data?
    var createdAt: Date
    var updatedAt: Date
    var pageCount: Int
    var processingStatusRawValue: String
    /// 0...1, only meaningful while `processingStatus == .processing`.
    var processingProgress: Double
    var processingError: String?
    @Attribute(.externalStorage, originalName: "thumbnailData") var legacyThumbnailData: Data?
    @Attribute(.externalStorage) var thumbnailCiphertext: Data?

    @Relationship(deleteRule: .cascade, inverse: \DocumentPage.document)
    var pages: [DocumentPage]

    init(
        id: UUID = UUID(),
        title: String,
        documentType: DocumentType,
        localFileName: String,
        originalFileName: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        pageCount: Int = 0,
        processingStatus: ProcessingStatus = .pending,
        processingProgress: Double = 0,
        processingError: String? = nil,
        thumbnailData: Data? = nil,
        pages: [DocumentPage] = []
    ) throws {
        self.id = id
        self.legacyTitle = ""
        self.titleCiphertext = nil
        self.documentTypeRawValue = documentType.rawValue
        self.localFileName = localFileName
        self.legacyOriginalFileName = nil
        self.originalFileNameCiphertext = nil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pageCount = pageCount
        self.processingStatusRawValue = processingStatus.rawValue
        self.processingProgress = processingProgress
        self.processingError = processingError
        self.legacyThumbnailData = nil
        self.thumbnailCiphertext = nil
        self.pages = pages
        try setTitle(title)
        if let originalFileName {
            originalFileNameCiphertext = try EncryptedTextCodec.sealData(Data(originalFileName.utf8), recordID: id, field: "original-file-name")
        }
        if let thumbnailData {
            try setThumbnailData(thumbnailData)
        }
    }

    var title: String {
        get throws {
            let data = try EncryptedTextCodec.openData(titleCiphertext, recordID: id, field: "document-title")
            guard let value = String(data: data, encoding: .utf8) else {
                throw EncryptedTextCodecError.invalidTextEncoding(field: "document-title")
            }
            return value
        }
    }

    func setTitle(_ value: String) throws {
        let data = Data(value.utf8)
        let sealed = try EncryptedTextCodec.sealData(data, recordID: id, field: "document-title")
        guard try EncryptedTextCodec.openData(sealed, recordID: id, field: "document-title") == data else {
            throw EncryptedTextCodecError.verificationFailed(field: "document-title")
        }
        titleCiphertext = sealed
        legacyTitle = ""
    }

    @discardableResult
    func migrateLegacyMetadataIfNeeded() throws -> Bool {
        var changed = false
        if titleCiphertext == nil {
            try setTitle(legacyTitle)
            changed = true
        } else if !legacyTitle.isEmpty {
            guard try title == legacyTitle else {
                throw EncryptedTextCodecError.verificationFailed(field: "document-title")
            }
            legacyTitle = ""
            changed = true
        }
        if let name = legacyOriginalFileName {
            let data = Data(name.utf8)
            let sealed = try originalFileNameCiphertext ?? EncryptedTextCodec.sealData(data, recordID: id, field: "original-file-name")
            guard try EncryptedTextCodec.openData(sealed, recordID: id, field: "original-file-name") == data else {
                throw EncryptedTextCodecError.verificationFailed(field: "original-file-name")
            }
            originalFileNameCiphertext = sealed
            legacyOriginalFileName = nil
            changed = true
        }
        return changed
    }

    var documentType: DocumentType {
        get { DocumentType(rawValue: documentTypeRawValue) ?? .photo }
        set { documentTypeRawValue = newValue.rawValue }
    }

    var processingStatus: ProcessingStatus {
        get { ProcessingStatus(rawValue: processingStatusRawValue) ?? .pending }
        set { processingStatusRawValue = newValue.rawValue }
    }

    /// Pages in reading order. The stored relationship is unordered.
    var sortedPages: [DocumentPage] {
        pages.sorted { $0.pageNumber < $1.pageNumber }
    }

    /// Short preview of the recognized text, used in library rows.
    func textPreview(maxLength: Int = 120) throws -> String {
        let joined = try sortedPages
            .map { try $0.decryptedRecognizedText() }
            .joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count > maxLength else { return joined }
        return String(joined.prefix(maxLength)) + "…"
    }

    func decryptedThumbnailData() throws -> Data? {
        guard thumbnailCiphertext != nil else {
            if legacyThumbnailData == nil { return nil }
            throw EncryptedTextCodecError.missingCiphertext(field: "document-thumbnail")
        }
        return try EncryptedTextCodec.openData(
            thumbnailCiphertext,
            recordID: id,
            field: "document-thumbnail"
        )
    }

    func setThumbnailData(_ data: Data?) throws {
        guard let data else {
            thumbnailCiphertext = nil
            legacyThumbnailData = nil
            return
        }
        let ciphertext = try EncryptedTextCodec.sealData(
            data,
            recordID: id,
            field: "document-thumbnail"
        )
        let verified = try EncryptedTextCodec.openData(
            ciphertext,
            recordID: id,
            field: "document-thumbnail"
        )
        guard verified == data else {
            throw EncryptedTextCodecError.verificationFailed(field: "document-thumbnail")
        }
        thumbnailCiphertext = ciphertext
        legacyThumbnailData = nil
    }

    @discardableResult
    func migrateLegacyThumbnailIfNeeded() throws -> Bool {
        guard let legacyThumbnailData else { return false }
        if thumbnailCiphertext != nil {
            let decrypted = try decryptedThumbnailData()
            guard decrypted == legacyThumbnailData else {
                throw EncryptedTextCodecError.verificationFailed(field: "document-thumbnail")
            }
            self.legacyThumbnailData = nil
            return true
        }
        try setThumbnailData(legacyThumbnailData)
        return true
    }
}
