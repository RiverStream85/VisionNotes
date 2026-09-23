import Foundation

/// Stores every Academic job payload as a path-bound AES-GCM envelope. Plain
/// files are materialized under the process temporary directory only while a
/// renderer or preview needs them; the persistent app-container copy remains
/// encrypted.
actor MathNoteJobStore {
    static let shared = MathNoteJobStore()
    static let migrationMarkerName = ".aes-gcm-v1-migration-complete"

    private static let processMaterializedRoot: URL = {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionNotes-Academic", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        return root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    }()

    nonisolated static func purgeProcessMaterializedFiles() {
        try? FileManager.default.removeItem(at: processMaterializedRoot)
    }

    private let rootURL: URL
    private let materializedRoot: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let vault: EncryptedDataVault
    private let migrationStateStore: DeviceMigrationStateStore
    private let plaintextAccessController: TemporaryPlaintextAccessController
    private var isStoragePrepared = false
    private var previewDirectories: [UUID: URL] = [:]

    init(
        rootURL: URL? = nil,
        vault: EncryptedDataVault = EncryptedDataVault(),
        migrationStateStore: DeviceMigrationStateStore = .shared,
        plaintextAccessController: TemporaryPlaintextAccessController = .shared
    ) {
        if let rootURL {
            self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootURL = support.appendingPathComponent("MathNoteJobs", isDirectory: true)
        }
        materializedRoot = Self.processMaterializedRoot
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        self.vault = vault
        self.migrationStateStore = migrationStateStore
        self.plaintextAccessController = plaintextAccessController
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func createJob(title: String? = nil, normalizedPages: [Data]) throws -> MathNoteJobManifest {
        guard !normalizedPages.isEmpty else { throw MathNoteError.emptyDraft }
        try ensureRoot()

        let id = UUID()
        let directory = jobURL(for: id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var pageRecords: [MathNotePageRecord] = []
        for (offset, data) in normalizedPages.enumerated() {
            try Task.checkCancellation()
            let relativePath = String(format: "pages/page-%03d.jpg", offset + 1)
            try write(data, relativePath: relativePath, jobID: id)
            pageRecords.append(MathNotePageRecord(index: offset, sourcePath: relativePath))
        }

        let defaultTitle = "Math Notes \(Date.now.formatted(date: .abbreviated, time: .shortened))"
        let manifest = MathNoteJobManifest(
            id: id,
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? defaultTitle,
            pages: pageRecords
        )
        try save(manifest)
        return manifest
    }

    func listJobs() throws -> [MathNoteJobManifest] {
        try ensureRoot()
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var manifests: [MathNoteJobManifest] = []
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            manifests.append(
                try loadManifest(at: directory.appendingPathComponent("manifest.json"), jobID: id)
            )
        }
        return manifests.sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(_ id: UUID) throws -> MathNoteJobManifest {
        try ensureRoot()
        let url = jobURL(for: id).appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: url.path) else { throw MathNoteError.jobNotFound }
        return try loadManifest(at: url, jobID: id)
    }

    func update(
        _ id: UUID,
        stage: MathNoteStage,
        failureMessage: String? = nil,
        uncertainCount: Int? = nil,
        stageProgress: Double? = nil,
        stageDetail: String? = nil
    ) throws -> MathNoteJobManifest {
        let removesMaterializedFiles: Bool
        switch stage {
        case .awaitingCloudConsent, .complete, .failed, .cancelled:
            removesMaterializedFiles = true
        default:
            removesMaterializedFiles = false
        }
        defer {
            if removesMaterializedFiles { removeMaterializedFiles(for: id) }
        }

        var manifest = try load(id)
        manifest.stage = stage
        manifest.failureMessage = failureMessage
        if let uncertainCount { manifest.uncertainCount = uncertainCount }
        manifest.stageProgress = stageProgress.map { min(max($0, 0), 1) }
        manifest.stageDetail = stageDetail
        manifest.updatedAt = Date()
        try save(manifest)
        return manifest
    }

    func setCloudFallbackConsent(_ id: UUID, allowed: Bool) throws -> MathNoteJobManifest {
        var manifest = try load(id)
        manifest.cloudFallbackAllowed = allowed
        manifest.updatedAt = Date()
        try save(manifest)
        return manifest
    }

    /// Atomically consumes the job's one-shot upload authorization. Call this
    /// before constructing a provider request; retries must be confirmed again.
    func consumeCloudFallbackConsent(_ id: UUID) throws -> MathNoteJobManifest {
        var manifest = try load(id)
        guard manifest.allowsCloudFallback else {
            throw MathNoteError.cloudFallbackNotAuthorized
        }
        manifest.cloudFallbackAllowed = false
        manifest.updatedAt = Date()
        try save(manifest)
        return manifest
    }

    func save(_ manifest: MathNoteJobManifest) throws {
        try ensureRoot()
        let directory = jobURL(for: manifest.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(encoder.encode(manifest), relativePath: "manifest.json", jobID: manifest.id)
    }

    func write(_ data: Data, relativePath: String, jobID: UUID, overwrite: Bool = true) throws {
        try ensureRoot()
        let url = try safeURL(relativePath: relativePath, jobID: jobID)
        if !overwrite, fileManager.fileExists(atPath: url.path) { return }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sealed = try vault.seal(data, context: context(relativePath: relativePath, jobID: jobID))
        try sealed.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? fileManager.removeItem(at: materializedFileURL(relativePath: relativePath, jobID: jobID))
    }

    func write(_ string: String, relativePath: String, jobID: UUID, overwrite: Bool = true) throws {
        guard let data = string.data(using: .utf8) else {
            throw MathNoteError.message("Text could not be encoded as UTF-8.")
        }
        try write(data, relativePath: relativePath, jobID: jobID, overwrite: overwrite)
    }

    func read(relativePath: String, jobID: UUID) throws -> Data {
        try ensureRoot()
        let url = try safeURL(relativePath: relativePath, jobID: jobID)
        let stored = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try vault.open(stored, context: context(relativePath: relativePath, jobID: jobID))
    }

    func readString(relativePath: String, jobID: UUID) throws -> String {
        let data = try read(relativePath: relativePath, jobID: jobID)
        guard let value = String(data: data, encoding: .utf8) else {
            throw MathNoteError.message("Saved source is not valid UTF-8.")
        }
        return value
    }

    func exists(relativePath: String, jobID: UUID) -> Bool {
        guard let url = try? safeURL(relativePath: relativePath, jobID: jobID) else { return false }
        do {
            try ensureRoot()
        } catch {
            // Keep the non-throwing API honest about physical existence. Any
            // subsequent read/write still surfaces the preparation error.
            return fileManager.fileExists(atPath: url.path)
        }
        return fileManager.fileExists(atPath: url.path)
    }

    func materializedURL(relativePath: String, jobID: UUID) throws -> URL {
        try plaintextAccessController.withMaterialization {
            let destination = try materializedFileURL(relativePath: relativePath, jobID: jobID)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try read(relativePath: relativePath, jobID: jobID)
                .write(to: destination, options: [.atomic, .completeFileProtection])
            return destination
        }
    }

    func materializedDirectory(for id: UUID) throws -> URL {
        try plaintextAccessController.withMaterialization {
            try ensureRoot()
            if let previous = previewDirectories.removeValue(forKey: id) {
                try? fileManager.removeItem(at: previous)
            }
            let destination = materializedRoot
                .appendingPathComponent("previews", isDirectory: true)
                .appendingPathComponent(
                    "\(id.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
                    isDirectory: true
                )
            do {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                try materializeTree(jobID: id, at: destination)
                previewDirectories[id] = destination
                return destination
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }
    }

    func workingDirectory(for id: UUID) throws -> URL {
        try plaintextAccessController.withMaterialization {
            try ensureRoot()
            let destination = materializedRoot
                .appendingPathComponent("\(id.uuidString.lowercased())-work", isDirectory: true)
            try? fileManager.removeItem(at: destination)
            do {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                try materializeTree(jobID: id, at: destination)
                return destination
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }
    }

    func absorbWorkingDirectory(_ directory: URL, jobID: UUID) throws {
        try plaintextAccessController.withMaterialization {
            try absorbAllowedWorkingDirectory(directory, jobID: jobID)
        }
    }

    private func absorbAllowedWorkingDirectory(_ directory: URL, jobID: UUID) throws {
        guard directory.standardizedFileURL.path.hasPrefix(materializedRoot.standardizedFileURL.path + "/") else {
            throw MathNoteError.message("An unsafe working directory was rejected.")
        }
        defer { try? fileManager.removeItem(at: directory) }
        guard fileManager.fileExists(atPath: directory.path) else {
            throw CancellationError()
        }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { throw CancellationError() }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = try StorageRelativePath.path(of: fileURL, under: directory)
            guard relative != "manifest.json" else { continue }
            try write(
                Data(contentsOf: fileURL, options: [.mappedIfSafe]),
                relativePath: relative,
                jobID: jobID
            )
        }
    }

    func delete(_ id: UUID) throws {
        defer { removeMaterializedFiles(for: id) }
        try ensureRoot()
        let url = jobURL(for: id)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    func deleteAll() throws {
        defer {
            previewDirectories.removeAll()
            try? fileManager.removeItem(at: materializedRoot)
        }
        try ensureRoot()
        let contents = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        let marker = rootURL.appendingPathComponent(Self.migrationMarkerName).standardizedFileURL
        for url in contents where url.standardizedFileURL != marker {
            try fileManager.removeItem(at: url)
        }
    }

    /// Removes all decrypted previews and renderer inputs owned by this store.
    /// Persistent job files are unaffected and remain AES-GCM sealed.
    func purgeMaterializedFiles() {
        previewDirectories.removeAll()
        try? fileManager.removeItem(at: materializedRoot)
    }

    /// Releases only UI-facing previews. Renderer work directories belong to
    /// the pipeline and must survive navigation changes until that pipeline
    /// absorbs or discards them itself.
    func releaseMaterializedPreview(for id: UUID, expectedURL: URL? = nil) {
        guard let current = previewDirectories[id] else { return }
        if let expectedURL,
           expectedURL.standardizedFileURL != current.standardizedFileURL {
            return
        }
        previewDirectories[id] = nil
        try? fileManager.removeItem(at: current)
    }

    private func ensureRoot() throws {
        guard !isStoragePrepared else { return }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = rootURL
        try? mutableRoot.setResourceValues(values)

        let marker = rootURL.appendingPathComponent(Self.migrationMarkerName)
        let markerExists = fileManager.fileExists(atPath: marker.path)
        if try migrationStateStore.isComplete(scope: "academic-jobs", rootURL: rootURL) {
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
            try verifyAllJobFilesAreSealed()
            try migrationStateStore.markComplete(scope: "academic-jobs", rootURL: rootURL)
            isStoragePrepared = true
            return
        }

        try migrateLegacyPlaintextJobs()
        try migrationStateStore.markComplete(scope: "academic-jobs", rootURL: rootURL)
        try Self.migrationMarkerPayload.write(
            to: marker,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        isStoragePrepared = true
    }

    private func migrateLegacyPlaintextJobs() throws {
        let jobDirectories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        for directory in jobDirectories {
            guard let jobID = UUID(uuidString: directory.lastPathComponent),
                  let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey]
                  ) else { continue }

            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let relativePath = try StorageRelativePath.path(of: fileURL, under: directory)
                let stored = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                let fileContext = context(relativePath: relativePath, jobID: jobID)

                if vault.isSealed(stored) {
                    _ = try vault.open(stored, context: fileContext)
                    continue
                }

                let sealed = try vault.seal(stored, context: fileContext)
                try sealed.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            }
        }
    }

    private func verifyAllJobFilesAreSealed() throws {
        let jobDirectories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        for directory in jobDirectories {
            guard let jobID = UUID(uuidString: directory.lastPathComponent),
                  let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey]
                  ) else { continue }

            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let relativePath = try StorageRelativePath.path(of: fileURL, under: directory)
                let stored = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                guard vault.isSealed(stored) else {
                    throw AppError.fileIntegrityFailed(fileName: relativePath)
                }
                do {
                    _ = try vault.open(
                        stored,
                        context: context(relativePath: relativePath, jobID: jobID)
                    )
                } catch let error as SecureKeyStoreError {
                    throw error
                } catch {
                    throw AppError.fileIntegrityFailed(fileName: relativePath)
                }
            }
        }
    }

    private func materializeTree(jobID: UUID, at destination: URL) throws {
        let source = jobURL(for: jobID)
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = try StorageRelativePath.path(of: fileURL, under: source)
            let target = destination.appendingPathComponent(relative)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try read(relativePath: relative, jobID: jobID)
                .write(to: target, options: [.atomic, .completeFileProtection])
        }
    }

    private func jobURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func materializedJobURL(for id: UUID) -> URL {
        materializedRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func removeMaterializedFiles(for id: UUID) {
        releaseMaterializedPreview(for: id)
        try? fileManager.removeItem(at: materializedJobURL(for: id))
        try? fileManager.removeItem(
            at: materializedRoot.appendingPathComponent("\(id.uuidString.lowercased())-work", isDirectory: true)
        )
    }

    private func materializedFileURL(relativePath: String, jobID: UUID) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else {
            throw MathNoteError.message("An unsafe job path was rejected.")
        }
        return materializedJobURL(for: jobID).appendingPathComponent(relativePath)
    }

    private func safeURL(relativePath: String, jobID: UUID) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else {
            throw MathNoteError.message("An unsafe job path was rejected.")
        }
        let directory = jobURL(for: jobID).standardizedFileURL
        let url = directory.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(directory.path + "/") else {
            throw MathNoteError.message("An unsafe job path was rejected.")
        }
        return url
    }

    private func context(relativePath: String, jobID: UUID) -> String {
        "academic/\(jobID.uuidString.lowercased())/\(relativePath)"
    }

    private func loadManifest(at url: URL, jobID: UUID) throws -> MathNoteJobManifest {
        let stored = try Data(contentsOf: url, options: [.mappedIfSafe])
        let plaintext = try vault.open(stored, context: context(relativePath: "manifest.json", jobID: jobID))
        return try decoder.decode(MathNoteJobManifest.self, from: plaintext)
    }

    private static let migrationMarkerPayload = Data("VisionNotes AES-GCM migration 1\n".utf8)
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
