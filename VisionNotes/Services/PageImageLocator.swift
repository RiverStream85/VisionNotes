import Foundation

/// Where a page's image lives on disk.
///
/// Image documents reuse their stored original; PDF documents use the cached
/// page render. Keeping the rule in one place stops the readers, the OCR editor
/// and the delete path from disagreeing.
enum PageImageLocator {
    static func directory(for documentType: DocumentType) -> StorageDirectory {
        documentType == .pdf ? .pages : .sources
    }

    static func imageData(
        for page: DocumentPage,
        storage: FileStorageServicing
    ) throws -> Data {
        guard let fileName = page.imageFileName else {
            throw AppError.fileMissing(fileName: "page \(page.pageNumber)")
        }
        let type = page.document?.documentType ?? .photo
        return try storage.data(forFileName: fileName, in: directory(for: type))
    }

    static func imageURL(
        for page: DocumentPage,
        storage: FileStorageServicing
    ) throws -> URL {
        guard let fileName = page.imageFileName else {
            throw AppError.fileMissing(fileName: "page \(page.pageNumber)")
        }
        let type = page.document?.documentType ?? .photo
        return try storage.url(for: fileName, in: directory(for: type))
    }
}
