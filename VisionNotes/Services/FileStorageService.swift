import Foundation

/// Sub-folders inside the app's private storage root.
enum StorageDirectory: String, CaseIterable, Sendable {
    /// Original imported images and PDFs.
    case sources = "Sources"
    /// Cached page renders used by the readers and the OCR editor.
    case pages = "Pages"
}

/// File-system side of persistence. SwiftData only ever stores file *names*;
/// the bytes live here, under Application Support.
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
    private let materializedRoot: URL
    private let vault: EncryptedDataVault
    /// Serialises directory creation and writes across concurrent imports.
    private let lock = NSLock()

    /// - Parameter rootDirectory: defaults to `Application Support/VisionNotes`.
    ///   Tests pass a temporary directory.
    init(rootDirectory: URL? = nil, vault: EncryptedDataVault = EncryptedDataVault()) {
        self.vault = vault
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.temporaryDirectory
            self.rootDirectory = base.appendingPathComponent("VisionNotes", isDirectory: true)
        }
        materializedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionNotes-Decrypted", isDirectory: true)
    }

    // MARK: - Locations

    func url(for fileName: String, in directory: StorageDirectory) throws -> URL {
        let encrypted = try encryptedURL(for: fileName, in: directory)
        let destination = try materializedURL(for: fileName, in: directory)
        guard fileManager.fileExists(atPath: encrypted.path) else { return destination }
        let plaintext = try vault.open(
            Data(contentsOf: encrypted, options: [.mappedIfSafe]),
            context: encryptionContext(fileName: fileName, directory: directory)
        )
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plaintext.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        return destination
    }

    func fileExists(_ fileName: String, in directory: StorageDirectory) -> Bool {
        guard let url = try? encryptedURL(for: fileName, in: directory) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    // MARK: - Writing

    @discardableResult
    func write(_ data: Data, fileName: String, in directory: StorageDirectory) throws -> URL {
        let destination = try encryptedURL(for: fileName, in: directory)
        do {
            let sealed = try vault.seal(
                data,
                context: encryptionContext(fileName: fileName, directory: directory)
            )
            try sealed.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
            try? fileManager.removeItem(at: materializedURL(for: fileName, in: directory))
            return destination
        } catch {
            throw AppError.fileWriteFailed(reason: error.localizedDescription)
        }
    }

    @discardableResult
    func copyItem(at sourceURL: URL, toFileName fileName: String, in directory: StorageDirectory) throws -> URL {
        let destination = try encryptedURL(for: fileName, in: directory)
        // Files handed over by the document picker live outside the sandbox.
        let needsScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScopedAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            let plaintext = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
            let sealed = try vault.seal(
                plaintext,
                context: encryptionContext(fileName: fileName, directory: directory)
            )
            try sealed.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
            try? fileManager.removeItem(at: materializedURL(for: fileName, in: directory))
            return destination
        } catch {
            throw AppError.fileCopyFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - Reading

    func data(forFileName fileName: String, in directory: StorageDirectory) throws -> Data {
        let source = try encryptedURL(for: fileName, in: directory)
        guard fileManager.fileExists(atPath: source.path) else {
            throw AppError.fileMissing(fileName: fileName)
        }
        do {
            return try vault.open(
                Data(contentsOf: source, options: [.mappedIfSafe]),
                context: encryptionContext(fileName: fileName, directory: directory)
            )
        } catch {
            throw AppError.fileMissing(fileName: fileName)
        }
    }

    // MARK: - Deleting

    func delete(fileName: String, in directory: StorageDirectory) throws {
        let target = try encryptedURL(for: fileName, in: directory)
        guard fileManager.fileExists(atPath: target.path) else { return }
        do {
            try fileManager.removeItem(at: target)
            try? fileManager.removeItem(at: materializedURL(for: fileName, in: directory))
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

    // MARK: - Private

    private func directoryURL(_ directory: StorageDirectory) throws -> URL {
        let url = rootDirectory.appendingPathComponent(directory.rawValue, isDirectory: true)
        lock.lock()
        defer { lock.unlock() }
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw AppError.fileWriteFailed(reason: error.localizedDescription)
            }
        }
        return url
    }

    private func encryptedURL(for fileName: String, in directory: StorageDirectory) throws -> URL {
        guard !fileName.isEmpty, !fileName.hasPrefix("/"), !fileName.contains("..") else {
            throw AppError.fileWriteFailed(reason: "An unsafe file name was rejected.")
        }
        return try directoryURL(directory).appendingPathComponent(fileName, isDirectory: false)
    }

    private func materializedURL(for fileName: String, in directory: StorageDirectory) throws -> URL {
        guard !fileName.isEmpty, !fileName.hasPrefix("/"), !fileName.contains("..") else {
            throw AppError.fileWriteFailed(reason: "An unsafe file name was rejected.")
        }
        return materializedRoot
            .appendingPathComponent(directory.rawValue, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func encryptionContext(fileName: String, directory: StorageDirectory) -> String {
        "library/\(directory.rawValue)/\(fileName)"
    }
}
