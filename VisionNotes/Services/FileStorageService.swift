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
    func releaseMaterializedFile(fileName: String, in directory: StorageDirectory)
    func delete(fileName: String, in directory: StorageDirectory) throws
    func deleteIgnoringMissing(fileName: String?, in directory: StorageDirectory)
}

final class FileStorageService: FileStorageServicing, @unchecked Sendable {
    static let shared = FileStorageService()
    static let migrationMarkerName = ".aes-gcm-v1-migration-complete"

    /// The first storage instance in a process removes plaintext left by a
    /// previous launch. Each instance then receives an isolated subdirectory so
    /// tests and previews cannot collide with the shared service.
    private static let processMaterializedRoot: URL = {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionNotes-Decrypted", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        return root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    }()

    private let fileManager = FileManager.default
    private let rootDirectory: URL
    private let materializedRoot: URL
    private let vault: EncryptedDataVault
    private let migrationStateStore: DeviceMigrationStateStore
    private let plaintextAccessController: TemporaryPlaintextAccessController
    /// Serialises the root migration, directory creation and concurrent writes.
    private let lock = NSRecursiveLock()
    private var isStoragePrepared = false

    /// - Parameter rootDirectory: defaults to `Application Support/VisionNotes`.
    ///   Tests pass a temporary directory.
    init(
        rootDirectory: URL? = nil,
        vault: EncryptedDataVault = EncryptedDataVault(),
        migrationStateStore: DeviceMigrationStateStore = .shared,
        plaintextAccessController: TemporaryPlaintextAccessController = .shared
    ) {
        self.vault = vault
        self.migrationStateStore = migrationStateStore
        self.plaintextAccessController = plaintextAccessController
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
        materializedRoot = Self.processMaterializedRoot
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    }

    deinit {
        try? fileManager.removeItem(at: materializedRoot)
    }

    /// Removes every framework-compatible plaintext copy owned by this
    /// service. Persistent source and page files remain AES-GCM sealed.
    func purgeMaterializedFiles() {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: materializedRoot)
    }

    // MARK: - Locations

    func url(for fileName: String, in directory: StorageDirectory) throws -> URL {
        try plaintextAccessController.withMaterialization {
            lock.lock()
            defer { lock.unlock() }
            try prepareStorageIfNeeded()
            let encrypted = try encryptedURL(for: fileName, in: directory)
            let destination = try materializedURL(for: fileName, in: directory)
            guard fileManager.fileExists(atPath: encrypted.path) else { return destination }
            let plaintext = try openPersistedFile(
                at: encrypted,
                fileName: fileName,
                directory: directory
            )
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try plaintext.write(
                to: destination,
                options: [.atomic, .completeFileProtection]
            )
            return destination
        }
    }

    func fileExists(_ fileName: String, in directory: StorageDirectory) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Existence itself is not sensitive and this non-throwing protocol API
        // must not turn a migration/key error into a false "missing" result.
        guard let url = try? persistentURL(for: fileName, in: directory) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    // MARK: - Writing

    @discardableResult
    func write(_ data: Data, fileName: String, in directory: StorageDirectory) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        try prepareStorageIfNeeded()
        let destination = try encryptedURL(for: fileName, in: directory)
        let sealed = try vault.seal(
            data,
            context: encryptionContext(fileName: fileName, directory: directory)
        )
        do {
            try sealed.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
            try? fileManager.removeItem(at: materializedURL(for: fileName, in: directory))
            return destination
        } catch {
            throw AppError.fileWriteFailed(reason: error.localizedDescription)
        }
    }

    @discardableResult
    func copyItem(at sourceURL: URL, toFileName fileName: String, in directory: StorageDirectory) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        try prepareStorageIfNeeded()
        let destination = try encryptedURL(for: fileName, in: directory)
        // Files handed over by the document picker live outside the sandbox.
        let needsScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScopedAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let plaintext: Data
        do {
            plaintext = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        } catch {
            throw AppError.fileCopyFailed(reason: error.localizedDescription)
        }
        let sealed = try vault.seal(
            plaintext,
            context: encryptionContext(fileName: fileName, directory: directory)
        )
        do {
            try sealed.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
            try? fileManager.removeItem(at: materializedURL(for: fileName, in: directory))
            return destination
        } catch {
            throw AppError.fileCopyFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - Reading

    func data(forFileName fileName: String, in directory: StorageDirectory) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try prepareStorageIfNeeded()
        let source = try encryptedURL(for: fileName, in: directory)
        guard fileManager.fileExists(atPath: source.path) else {
            throw AppError.fileMissing(fileName: fileName)
        }
        return try openPersistedFile(at: source, fileName: fileName, directory: directory)
    }

    func releaseMaterializedFile(fileName: String, in directory: StorageDirectory) {
        lock.lock()
        defer { lock.unlock() }
        guard let url = try? materializedURL(for: fileName, in: directory) else { return }
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Deleting

    func delete(fileName: String, in directory: StorageDirectory) throws {
        lock.lock()
        defer { lock.unlock() }
        let materialized = try materializedURL(for: fileName, in: directory)
        defer { try? fileManager.removeItem(at: materialized) }
        try prepareStorageIfNeeded()
        let target = try encryptedURL(for: fileName, in: directory)
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

    // MARK: - Private

    private func directoryURL(_ directory: StorageDirectory) throws -> URL {
        try prepareStorageIfNeeded()
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
        _ = try directoryURL(directory)
        return try persistentURL(for: fileName, in: directory)
    }

    private func persistentURL(for fileName: String, in directory: StorageDirectory) throws -> URL {
        guard !fileName.isEmpty, !fileName.hasPrefix("/"), !fileName.contains("..") else {
            throw AppError.fileWriteFailed(reason: "An unsafe file name was rejected.")
        }
        let directoryURL = rootDirectory.appendingPathComponent(directory.rawValue, isDirectory: true)
        let url = directoryURL.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        guard url.path.hasPrefix(directoryURL.standardizedFileURL.path + "/") else {
            throw AppError.fileWriteFailed(reason: "An unsafe file name was rejected.")
        }
        return url
    }

    private func materializedURL(for fileName: String, in directory: StorageDirectory) throws -> URL {
        guard !fileName.isEmpty, !fileName.hasPrefix("/"), !fileName.contains("..") else {
            throw AppError.fileWriteFailed(reason: "An unsafe file name was rejected.")
        }
        let directoryURL = materializedRoot
            .appendingPathComponent(directory.rawValue, isDirectory: true)
        let url = directoryURL.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        guard url.path.hasPrefix(directoryURL.standardizedFileURL.path + "/") else {
            throw AppError.fileWriteFailed(reason: "An unsafe file name was rejected.")
        }
        return url
    }

    private func prepareStorageIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isStoragePrepared else { return }

        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = rootDirectory
        try? mutableRoot.setResourceValues(values)

        let marker = rootDirectory.appendingPathComponent(Self.migrationMarkerName)
        let markerExists = fileManager.fileExists(atPath: marker.path)
        if try migrationStateStore.isComplete(scope: "library-files", rootURL: rootDirectory) {
            if markerExists {
                let markerData = try Data(contentsOf: marker)
                guard markerData == Self.migrationMarkerPayload else {
                    throw AppError.fileIntegrityFailed(fileName: Self.migrationMarkerName)
                }
            } else {
                try Self.migrationMarkerPayload.write(
                    to: marker,
                    options: [.atomic, .completeFileProtectionUnlessOpen]
                )
            }
            isStoragePrepared = true
            return
        }

        if markerExists {
            let markerData = try Data(contentsOf: marker)
            guard markerData == Self.migrationMarkerPayload else {
                throw AppError.fileIntegrityFailed(fileName: Self.migrationMarkerName)
            }
            // A legacy marker without the independent Keychain state is
            // accepted only if every stored file is already authenticated.
            // Headerless bytes at this point are an integrity failure, never
            // an invitation to reopen plaintext migration.
            try verifyAllPersistentFilesAreSealed()
            try migrationStateStore.markComplete(scope: "library-files", rootURL: rootDirectory)
            isStoragePrepared = true
            return
        }

        try migrateLegacyPlaintextFiles()
        // Set the independent state first. If the process stops before the
        // convenience marker is written, the next launch recreates the marker
        // without accepting headerless bytes.
        try migrationStateStore.markComplete(scope: "library-files", rootURL: rootDirectory)
        try Self.migrationMarkerPayload.write(
            to: marker,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        isStoragePrepared = true
    }

    private func migrateLegacyPlaintextFiles() throws {
        for directory in StorageDirectory.allCases {
            let directoryRoot = rootDirectory.appendingPathComponent(directory.rawValue, isDirectory: true)
            guard fileManager.fileExists(atPath: directoryRoot.path),
                let enumerator = fileManager.enumerator(
                    at: directoryRoot,
                    includingPropertiesForKeys: [.isRegularFileKey]
                ) else { continue }

            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let relativePath = try StorageRelativePath.path(of: fileURL, under: directoryRoot)
                let stored = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                let context = encryptionContext(fileName: relativePath, directory: directory)

                if vault.isSealed(stored) {
                    do {
                        _ = try vault.open(stored, context: context)
                    } catch let error as SecureKeyStoreError {
                        throw error
                    } catch {
                        throw AppError.fileIntegrityFailed(fileName: relativePath)
                    }
                    continue
                }

                let sealed = try vault.seal(stored, context: context)
                try sealed.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            }
        }
    }

    private func verifyAllPersistentFilesAreSealed() throws {
        for directory in StorageDirectory.allCases {
            let directoryRoot = rootDirectory.appendingPathComponent(directory.rawValue, isDirectory: true)
            guard fileManager.fileExists(atPath: directoryRoot.path),
                  let enumerator = fileManager.enumerator(
                    at: directoryRoot,
                    includingPropertiesForKeys: [.isRegularFileKey]
                  ) else { continue }

            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let relativePath = try StorageRelativePath.path(of: fileURL, under: directoryRoot)
                let stored = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                guard vault.isSealed(stored) else {
                    throw AppError.fileIntegrityFailed(fileName: relativePath)
                }
                do {
                    _ = try vault.open(
                        stored,
                        context: encryptionContext(fileName: relativePath, directory: directory)
                    )
                } catch let error as SecureKeyStoreError {
                    throw error
                } catch {
                    throw AppError.fileIntegrityFailed(fileName: relativePath)
                }
            }
        }
    }

    private func openPersistedFile(
        at url: URL,
        fileName: String,
        directory: StorageDirectory
    ) throws -> Data {
        let stored = try Data(contentsOf: url, options: [.mappedIfSafe])
        do {
            return try vault.open(
                stored,
                context: encryptionContext(fileName: fileName, directory: directory)
            )
        } catch let error as SecureKeyStoreError {
            throw error
        } catch is EncryptedDataVaultError {
            throw AppError.fileIntegrityFailed(fileName: fileName)
        }
    }

    private func encryptionContext(fileName: String, directory: StorageDirectory) -> String {
        "library/\(directory.rawValue)/\(fileName)"
    }

    private static let migrationMarkerPayload = Data("VisionNotes AES-GCM migration 1\n".utf8)
}
