import Foundation

actor MathNoteJobStore {
    static let shared = MathNoteJobStore()

    private let rootURL: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootURL = support.appendingPathComponent("MathNoteJobs", isDirectory: true)
        }
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
        try fileManager.createDirectory(
            at: directory.appendingPathComponent("pages", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: directory.appendingPathComponent("assets", isDirectory: true),
            withIntermediateDirectories: true
        )

        var pageRecords: [MathNotePageRecord] = []
        for (offset, data) in normalizedPages.enumerated() {
            try Task.checkCancellation()
            let relativePath = String(format: "pages/page-%03d.jpg", offset + 1)
            try writeAtomically(data, to: directory.appendingPathComponent(relativePath))
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
            try? loadManifest(at: directory.appendingPathComponent("manifest.json"))
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(_ id: UUID) throws -> MathNoteJobManifest {
        let url = jobURL(for: id).appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: url.path) else { throw MathNoteError.jobNotFound }
        return try loadManifest(at: url)
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

    func save(_ manifest: MathNoteJobManifest) throws {
        let directory = jobURL(for: manifest.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(manifest)
        try writeAtomically(data, to: directory.appendingPathComponent("manifest.json"))
    }

    func write(_ data: Data, relativePath: String, jobID: UUID, overwrite: Bool = true) throws {
        let url = try safeURL(relativePath: relativePath, jobID: jobID)
        if !overwrite, fileManager.fileExists(atPath: url.path) { return }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomically(data, to: url)
    }

    func write(_ string: String, relativePath: String, jobID: UUID, overwrite: Bool = true) throws {
        guard let data = string.data(using: .utf8) else {
            throw MathNoteError.message("Text could not be encoded as UTF-8.")
        }
        try write(data, relativePath: relativePath, jobID: jobID, overwrite: overwrite)
    }

    func read(relativePath: String, jobID: UUID) throws -> Data {
        try Data(contentsOf: safeURL(relativePath: relativePath, jobID: jobID))
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

    func url(relativePath: String, jobID: UUID) throws -> URL {
        try safeURL(relativePath: relativePath, jobID: jobID)
    }

    func directory(for id: UUID) -> URL {
        jobURL(for: id)
    }

    func delete(_ id: UUID) throws {
        let url = jobURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func deleteAll() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        let contents = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        for url in contents {
            try fileManager.removeItem(at: url)
        }
    }

    private func ensureRoot() throws {
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
        let directory = jobURL(for: jobID).standardizedFileURL
        let url = directory.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(directory.path + "/") else {
            throw MathNoteError.message("An unsafe job path was rejected.")
        }
        return url
    }

    private func loadManifest(at url: URL) throws -> MathNoteJobManifest {
        try decoder.decode(MathNoteJobManifest.self, from: Data(contentsOf: url))
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
