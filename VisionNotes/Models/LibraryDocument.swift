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
    var title: String
    var documentTypeRawValue: String
    /// File name (not a full path) of the original image or PDF in the sandbox.
    var localFileName: String
    /// File name the user picked the document with, when one was available.
    var originalFileName: String?
    var createdAt: Date
    var updatedAt: Date
    var pageCount: Int
    var processingStatusRawValue: String
    /// 0...1, only meaningful while `processingStatus == .processing`.
    var processingProgress: Double
    var processingError: String?
    @Attribute(.externalStorage) var thumbnailData: Data?

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
    ) {
        self.id = id
        self.title = title
        self.documentTypeRawValue = documentType.rawValue
        self.localFileName = localFileName
        self.originalFileName = originalFileName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pageCount = pageCount
        self.processingStatusRawValue = processingStatus.rawValue
        self.processingProgress = processingProgress
        self.processingError = processingError
        self.thumbnailData = thumbnailData
        self.pages = pages
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
    func textPreview(maxLength: Int = 120) -> String {
        let joined = sortedPages
            .map { $0.recognizedText }
            .joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count > maxLength else { return joined }
        return String(joined.prefix(maxLength)) + "…"
    }
}
