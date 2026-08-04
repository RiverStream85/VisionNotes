import SwiftUI

/// Routes a document to the reader that fits its type.
@MainActor
struct DocumentReaderView: View {
    let document: LibraryDocument
    var initialPageNumber: Int?
    var highlightTerms: [String] = []

    var body: some View {
        Group {
            if document.documentType == .pdf {
                PDFReaderView(
                    document: document,
                    initialPageNumber: initialPageNumber,
                    highlightTerms: highlightTerms
                )
            } else {
                ImageReaderView(
                    document: document,
                    highlightTerms: highlightTerms
                )
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
