import Foundation
import SwiftData

/// One page of a document. Image documents always have exactly one page.
@Model
final class DocumentPage {
    @Attribute(.unique) var id: UUID
    var document: LibraryDocument?
    /// 1-based page number, matching what the reader shows the user.
    var pageNumber: Int
    var recognizedText: String
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
    ) {
        self.id = id
        self.document = document
        self.pageNumber = pageNumber
        self.recognizedText = recognizedText
        self.imageFileName = imageFileName
        self.createdAt = createdAt
        self.textBlocks = textBlocks
    }

    /// Text blocks in natural reading order.
    var sortedTextBlocks: [TextBlock] {
        textBlocks.sorted { $0.readingOrder < $1.readingOrder }
    }
}
