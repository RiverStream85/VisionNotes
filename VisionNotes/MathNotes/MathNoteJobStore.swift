import Foundation

/// Stores every Academic job payload as a path-bound AES-GCM envelope. Plain
/// files are materialized under the process temporary directory only while a
/// renderer or preview needs them; the persistent app-container copy remains
/// encrypted.
actor MathNoteJobStore {
    static let shared = MathNoteJobStore()

    private let rootURL: URL
    private let materializedRoot: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let vault: EncryptedDataVault

    init(rootURL: URL? = nil, vault: EncryptedDataVault = EncryptedDataVault()) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootURL = support.appendingPathComponent("MathNoteJobs", isDirectory: true)
        }
        materializedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionNotes-Academic", isDirectory: true)
        self.vault = vault
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
        return directories.compactMap { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent) else { return nil }
            return try? loadManifest(at: directory.appendingPathComponent("manifest.json"), jobID: id)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(_ id: UUID) throws -> MathNoteJobManifest {
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

    func save(_ manifest: MathNoteJobManifest) throws {
        let directory = jobURL(for: manifest.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(encoder.encode(manifest), relativePath: "manifest.json", jobID: manifest.id)
    }

    func write(_ data: Data, relativePath: String, jobID: UUID, overwrite: Bool = true) throws {
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
        let url = try safeURL(relativePath: relativePath, jobID: jobID)
        let stored = try Data(contentsOf: url, options: [.mappedIfSafe])
        let plaintext = try vault.open(stored, context: context(relativePath: relativePath, jobID: jobID))
        if !vault.isSealed(stored) {
            try write(plaintext, relativePath: relativePath, jobID: jobID)
        }
        return plaintext
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
        return fileManager.fileExists(atPath: url.path)
    }

    func materializedURL(relativePath: String, jobID: UUID) throws -> URL {
        let destination = try materializedFileURL(relativePath: relativePath, jobID: jobID)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try read(relativePath: relativePath, jobID: jobID)
            .write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        return destination
    }

    func materializedDirectory(for id: UUID) throws -> URL {
        let destination = materializedJobURL(for: id)
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try materializeTree(jobID: id, at: destination)
        return destination
    }

    func workingDirectory(for id: UUID) throws -> URL {
        let destination = materializedRoot
            .appendingPathComponent("\(id.uuidString.lowercased())-work", isDirectory: true)
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try materializeTree(jobID: id, at: destination)
        return destination
    }

    func absorbWorkingDirectory(_ directory: URL, jobID: UUID) throws {
        guard directory.standardizedFileURL.path.hasPrefix(materializedRoot.standardizedFileURL.path + "/") else {
            throw MathNoteError.message("An unsafe working directory was rejected.")
        }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = String(fileURL.path.dropFirst(directory.path.count + 1))
            guard relative != "manifest.json" else { continue }
            try write(
                Data(contentsOf: fileURL, options: [.mappedIfSafe]),
                relativePath: relative,
                jobID: jobID
            )
        }
    }

    func delete(_ id: UUID) throws {
        let url = jobURL(for: id)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        try? fileManager.removeItem(at: materializedJobURL(for: id))
        try? fileManager.removeItem(
            at: materializedRoot.appendingPathComponent("\(id.uuidString.lowercased())-work", isDirectory: true)
        )
    }

    func deleteAll() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        let contents = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        for url in contents { try fileManager.removeItem(at: url) }
        try? fileManager.removeItem(at: materializedRoot)
    }

    private func ensureRoot() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = rootURL
        try? mutableRoot.setResourceValues(values)
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
            let relative = String(fileURL.path.dropFirst(source.path.count + 1))
            let target = destination.appendingPathComponent(relative)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try read(relativePath: relative, jobID: jobID)
                .write(to: target, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }

    private func jobURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func materializedJobURL(for id: UUID) -> URL {
        materializedRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
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
        let manifest = try decoder.decode(MathNoteJobManifest.self, from: plaintext)
        if !vault.isSealed(stored) { try save(manifest) }
        return manifest
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
