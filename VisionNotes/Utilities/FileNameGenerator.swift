import Foundation

/// Builds the sandbox file names used by `FileStorageService`.
///
/// Names are derived from the document's UUID, never from user text, so a file
/// name can never contain path separators or characters the file system
/// dislikes. Titles are sanitised separately, for display only.
enum FileNameGenerator {

    static func sourceFileName(documentID: UUID, type: DocumentType) -> String {
        "doc_\(documentID.uuidString.lowercased()).\(type.fileExtension)"
    }

    static func pageImageFileName(documentID: UUID, pageNumber: Int) -> String {
        let padded = String(format: "%04d", max(pageNumber, 0))
        return "page_\(documentID.uuidString.lowercased())_\(padded).jpg"
    }

    /// A readable title from a file name, or a dated fallback.
    static func title(fromOriginalFileName fileName: String?, type: DocumentType, date: Date) -> String {
        if let fileName {
            let base = (fileName as NSString).deletingPathExtension
            let cleaned = sanitizedTitle(base)
            if !cleaned.isEmpty { return cleaned }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(type.displayName) \(formatter.string(from: date))"
    }

    /// Trims whitespace, collapses runs of spaces, drops characters that make
    /// titles hard to read, and caps the length.
    static func sanitizedTitle(_ raw: String, maxLength: Int = 80) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\t\r")
        let stripped = raw.components(separatedBy: illegal).joined(separator: " ")
        let collapsed = stripped
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }
}
