import Foundation

/// Sub-folders inside the app's private storage root.
enum StorageDirectory: String, CaseIterable, Sendable {
    /// Original imported images and PDFs.
    case sources = "Sources"
    /// Cached page renders used by the readers and the OCR editor.
    case pages = "Pages"
}

/// File-system side of persistence. SwiftData only ever stores file *names*;
/// the bytes live here, under Application Support, protected at rest by iOS
/// Data Protection.
protocol FileStorageServicing: AnyObject, Sendable {
    func url(for fileName: String, in directory: StorageDirectory) throws -> URL
    func fileExists(_ fileName: String, in directory: StorageDirectory) -> Bool
    @discardableResult func write(_ data: Data, fileName: String, in directory: StorageDirectory) throws -> URL
    @discardableResult func copyItem(at sourceURL: URL, toFileName fileName: String, in directory: StorageDirectory) throws -> URL
    func data(forFileName fileName: String, in directory: StorageDirectory) throws -> Data
    func delete(fileName: String, in directory: StorageDirectory) throws
    func deleteIgnoringMissing(fileName: String?, in directory: StorageDirectory)
}

final class FileStorageService: FileStorageServicing, @unchecked Sendable {
    static let shared = FileStorageService()

    private let fileManager = FileManager.default
    private let rootDirectory: URL

    /// - Parameter rootDirectory: defaults to `Application Support/VisionNotes/Library`.
    ///   Tests pass a temporary directory.
    init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            self.rootDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VisionNotes/Library", isDirectory: true)
        }
    }

    func url(for fileName: String, in directory: StorageDirectory) throws -> URL {
        guard !fileName.isEmpty, !fileName.hasPrefix("/"), !fileName.contains("..") else {
            throw AppError.fileWriteFailed(reason: "An unsafe file name was rejected.")
        }
        return rootDirectory
            .appendingPathComponent(directory.rawValue, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    func fileExists(_ fileName: String, in directory: StorageDirectory) -> Bool {
        guard let url = try? url(for: fileName, in: directory) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    @discardableResult
    func write(_ data: Data, fileName: String, in directory: StorageDirectory) throws -> URL {
        let destination = try preparedURL(for: fileName, in: directory)
        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            throw AppError.fileWriteFailed(reason: error.localizedDescription)
        }
    }

    @discardableResult
    func copyItem(at sourceURL: URL, toFileName fileName: String, in directory: StorageDirectory) throws -> URL {
        let destination = try preparedURL(for: fileName, in: directory)
        // Files handed over by the document picker live outside the sandbox.
        let needsScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScopedAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination
        } catch {
            throw AppError.fileCopyFailed(reason: error.localizedDescription)
        }
    }

    func data(forFileName fileName: String, in directory: StorageDirectory) throws -> Data {
        let source = try url(for: fileName, in: directory)
        guard fileManager.fileExists(atPath: source.path) else {
            throw AppError.fileMissing(fileName: fileName)
        }
        return try Data(contentsOf: source, options: [.mappedIfSafe])
    }

    func delete(fileName: String, in directory: StorageDirectory) throws {
        let target = try url(for: fileName, in: directory)
        guard fileManager.fileExists(atPath: target.path) else { return }
        do {
            try fileManager.removeItem(at: target)
        } catch {
            throw AppError.fileDeleteFailed(reason: error.localizedDescription)
        }
    }

    /// Best-effort delete used during cleanup, where a missing file is not a
    /// problem worth interrupting the user for.
    func deleteIgnoringMissing(fileName: String?, in directory: StorageDirectory) {
        guard let fileName, !fileName.isEmpty else { return }
        try? delete(fileName: fileName, in: directory)
    }

    /// The destination URL with its folder created; the root is excluded from backup.
    private func preparedURL(for fileName: String, in directory: StorageDirectory) throws -> URL {
        let destination = try url(for: fileName, in: directory)
        if !fileManager.fileExists(atPath: rootDirectory.path) {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var root = rootDirectory
            try? root.setResourceValues(values)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return destination
    }
}
