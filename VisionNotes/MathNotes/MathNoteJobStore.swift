import Foundation

/// Stores each Academic job as plain files in its own folder under
/// Application Support. iOS Data Protection encrypts them at rest; the
/// renderer and previews read and write the job folder directly.
actor MathNoteJobStore {
    static let shared = MathNoteJobStore()

    private let rootURL: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootURL = support.appendingPathComponent("AcademicJobs", isDirectory: true)
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func createJob(title: String? = nil, normalizedPages: [Data]) throws -> MathNoteJobManifest {
        guard !normalizedPages.isEmpty else { throw MathNoteError.emptyDraft }
        let id = UUID()
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
        let manifests = directories.compactMap { directory -> MathNoteJobManifest? in
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else { return nil }
            return try? decoder.decode(MathNoteJobManifest.self, from: data)
        }
        return manifests.sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(_ id: UUID) throws -> MathNoteJobManifest {
        let url = jobURL(for: id).appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: url.path) else { throw MathNoteError.jobNotFound }
        return try decoder.decode(MathNoteJobManifest.self, from: Data(contentsOf: url))
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

    /// Consumes the job's one-shot upload authorization. Call this before
    /// constructing a provider request; retries must be confirmed again.
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
        try write(encoder.encode(manifest), relativePath: "manifest.json", jobID: manifest.id)
    }

    func write(_ data: Data, relativePath: String, jobID: UUID, overwrite: Bool = true) throws {
        let url = try safeURL(relativePath: relativePath, jobID: jobID)
        if !overwrite, fileManager.fileExists(atPath: url.path) { return }
        try ensureRoot()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func write(_ string: String, relativePath: String, jobID: UUID, overwrite: Bool = true) throws {
        try write(Data(string.utf8), relativePath: relativePath, jobID: jobID, overwrite: overwrite)
    }

    func read(relativePath: String, jobID: UUID) throws -> Data {
        try Data(contentsOf: safeURL(relativePath: relativePath, jobID: jobID), options: [.mappedIfSafe])
    }

    func readString(relativePath: String, jobID: UUID) throws -> String {
        String(decoding: try read(relativePath: relativePath, jobID: jobID), as: UTF8.self)
    }

    func exists(relativePath: String, jobID: UUID) -> Bool {
        guard let url = try? safeURL(relativePath: relativePath, jobID: jobID) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func url(relativePath: String, jobID: UUID) throws -> URL {
        try safeURL(relativePath: relativePath, jobID: jobID)
    }

    /// The job's folder, where the renderer writes exports and previews read them.
    func directory(for id: UUID) throws -> URL {
        let url = jobURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { throw MathNoteError.jobNotFound }
        return url
    }

    func delete(_ id: UUID) throws {
        let url = jobURL(for: id)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    func deleteAll() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        for url in try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
            try fileManager.removeItem(at: url)
        }
    }

    private func ensureRoot() throws {
        guard !fileManager.fileExists(atPath: rootURL.path) else { return }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = rootURL
        try? mutableRoot.setResourceValues(values)
    }

    private func jobURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func safeURL(relativePath: String, jobID: UUID) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else {
            throw MathNoteError.message("An unsafe job path was rejected.")
        }
        return jobURL(for: jobID).appendingPathComponent(relativePath)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
