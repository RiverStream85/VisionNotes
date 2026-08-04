import Foundation

/// Translates between PDFKit's 0-based page indices and the 1-based page
/// numbers stored on `DocumentPage` and shown in the reader.
enum PDFPageMapper {

    static func pageIndex(forPageNumber pageNumber: Int) -> Int {
        pageNumber - 1
    }

    static func pageNumber(forIndex index: Int) -> Int {
        index + 1
    }

    /// Clamps a page number into `1...pageCount`, returning `nil` for an empty
    /// document so callers cannot land on a page that does not exist.
    static func clampedPageNumber(_ pageNumber: Int, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        return min(max(pageNumber, 1), pageCount)
    }

    static func isValidPageNumber(_ pageNumber: Int, pageCount: Int) -> Bool {
        pageNumber >= 1 && pageNumber <= pageCount
    }

    /// Progress in 0...1 after finishing `completedPages` of `pageCount`.
    static func progress(completedPages: Int, pageCount: Int) -> Double {
        guard pageCount > 0 else { return 0 }
        let clamped = min(max(completedPages, 0), pageCount)
        return Double(clamped) / Double(pageCount)
    }
}
