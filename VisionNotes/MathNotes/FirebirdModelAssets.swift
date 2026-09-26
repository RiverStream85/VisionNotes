import Foundation

/// The pinned public GLM-OCR checkpoint (MIT weights, never note content).
/// A development build may bundle it; otherwise a background download stores it
/// once in Application Support. Either way the files load in place.
enum FirebirdModelAssets {
    struct Asset: Codable, Sendable { let name: String; let bytes: Int }
    struct Lock: Codable, Sendable { let model: String; let revision: String; let assets: [Asset] }
    enum AssetError: Error { case missingLock, download }

    /// The bundled lock is the single source of the model name, revision and files.
    static func bundledLock() throws -> Lock {
        guard let url = Bundle.main.url(forResource: "FirebirdModel.lock", withExtension: "json") else {
            throw AssetError.missingLock
        }
        return try JSONDecoder().decode(Lock.self, from: Data(contentsOf: url))
    }

    /// Where downloaded files live, keyed by revision so a new pin never mixes files.
    static func downloadDirectory(for lock: Lock) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VisionNotes/Models/\(lock.revision)", isDirectory: true)
    }

    /// A complete model folder: bundled with the app (development builds, see the
    /// "Bundle Firebird model" build phase) or already downloaded.
    static func modelDirectory() -> URL? {
        guard let lock = try? bundledLock() else { return nil }
        let candidates = [Bundle.main.url(forResource: "FirebirdModel", withExtension: nil),
                          downloadDirectory(for: lock)]
        return candidates.compactMap { $0 }.first { isComplete($0, lock: lock) }
    }

    static func isComplete(_ directory: URL, lock: Lock) -> Bool {
        lock.assets.allSatisfy { size(of: directory.appendingPathComponent($0.name)) == $0.bytes }
    }

    /// Downloads whatever is missing and returns the model folder. Cancelling the
    /// caller only stops waiting; transfers continue in the background session.
    static func download() async throws -> URL {
        let lock = try bundledLock()
        let directory = downloadDirectory(for: lock)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        var folder = directory; try folder.setResourceValues(flags)
        let missing = lock.assets.filter { size(of: directory.appendingPathComponent($0.name)) != $0.bytes }
        let present = lock.assets.filter { asset in !missing.contains { $0.name == asset.name } }
        FirebirdModelDownloader.shared.expect(lock.assets, present: present)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for asset in missing {
                let url = URL(string: "https://huggingface.co/\(lock.model)/resolve/\(lock.revision)/\(asset.name)")!
                group.addTask { try await FirebirdModelDownloader.shared.fetch(asset, from: url, into: directory) }
            }
            try await group.waitForAll()
        }
        return directory
    }

    /// Removes model storage from earlier builds: the AES-GCM chunked copy, its
    /// temporary decrypted folders, and folders for revisions no longer pinned.
    static func removeObsoleteFiles() {
        let manager = FileManager.default
        let models = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VisionNotes/Models", isDirectory: true)
        let current = (try? bundledLock()).map(\.revision)
        for entry in (try? manager.contentsOfDirectory(atPath: models.path)) ?? [] where entry != current {
            try? manager.removeItem(at: models.appendingPathComponent(entry))
        }
        try? manager.removeItem(at: manager.temporaryDirectory.appendingPathComponent("VisionNotesModelLoading"))
    }

    static func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }
}

/// Background transfer of the model files. iOS continues it while the screen is
/// locked or the app is suspended, and relaunches the app to deliver results.
/// A cancelled caller only stops waiting, so a later attempt picks up the same
/// transfer or the finished file instead of starting over.
final class FirebirdModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = FirebirdModelDownloader()
    static let sessionIdentifier = "com.visionnotes.firebird-model"
    /// Posted on the main queue, at most twice per second, while bytes arrive.
    static let progressDidChange = Notification.Name("com.visionnotes.firebird-model.progress")

    struct Snapshot: Equatable, Sendable {
        let receivedBytes: Int64
        let totalBytes: Int64
    }

    // All mutable state below is guarded by `state`.
    private let state = NSLock()
    private var storedSession: URLSession?
    private var waiters: [String: [UUID: CheckedContinuation<Void, Error>]] = [:]
    private var destinations: [String: URL] = [:]
    private var received: [String: Int64] = [:]
    private var expected: [String: Int64] = [:]
    private var lastPost = Date.distantPast
    private var backgroundCompletion: (() -> Void)?

    private var session: URLSession {
        state.withLock {
            if let storedSession { return storedSession }
            let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            configuration.allowsCellularAccess = false
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            storedSession = session
            return session
        }
    }

    /// Called from the app delegate when iOS relaunches the app for this session.
    func resumeBackgroundEvents(completionHandler: @escaping () -> Void) {
        state.withLock { backgroundCompletion = completionHandler }
        _ = session
    }

    func expect(_ assets: [FirebirdModelAssets.Asset], present: [FirebirdModelAssets.Asset]) {
        state.withLock {
            for asset in assets { expected[asset.name] = Int64(asset.bytes) }
            for asset in present { received[asset.name] = Int64(asset.bytes) }
        }
    }

    func snapshot() -> Snapshot {
        state.withLock {
            Snapshot(receivedBytes: received.values.reduce(0, +), totalBytes: expected.values.reduce(0, +))
        }
    }

    /// Resumes when `asset` is in `directory`, starting a transfer only if none is running.
    func fetch(_ asset: FirebirdModelAssets.Asset, from url: URL, into directory: URL) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.withLock {
                    waiters[asset.name, default: [:]][id] = continuation
                    destinations[asset.name] = directory.appendingPathComponent(asset.name)
                }
                if Task.isCancelled { return resolve(asset.name, id, .failure(CancellationError())) }
                let session = self.session
                session.getAllTasks { tasks in
                    let running = tasks.first {
                        $0.taskDescription == asset.name && $0.state != .completed && $0.state != .canceling
                    }
                    if let running {
                        running.resume()
                    } else {
                        let task = session.downloadTask(with: url)
                        task.taskDescription = asset.name
                        task.countOfBytesClientExpectsToReceive = Int64(asset.bytes)
                        task.resume()
                    }
                }
            }
        } onCancel: {
            resolve(asset.name, id, .failure(CancellationError()))
        }
    }

    private func resolve(_ name: String, _ id: UUID, _ result: Result<Void, Error>) {
        let continuation = state.withLock { waiters[name]?.removeValue(forKey: id) }
        continuation?.resume(with: result)
    }

    private func finish(_ name: String, _ result: Result<Void, Error>) {
        let continuations = state.withLock { () -> [CheckedContinuation<Void, Error>] in
            if case .success = result { received[name] = expected[name] ?? received[name] ?? 0 }
            return Array((waiters.removeValue(forKey: name) ?? [:]).values)
        }
        continuations.forEach { $0.resume(with: result) }
        postProgress()
    }

    private func postProgress() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.progressDidChange, object: nil) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let name = downloadTask.taskDescription else { return }
        // iOS deletes `location` when this method returns, so move it now. After a
        // relaunch no caller may be waiting; fall back to the pinned folder.
        let destination = state.withLock { destinations[name] }
            ?? (try? FirebirdModelAssets.bundledLock()).map {
                FirebirdModelAssets.downloadDirectory(for: $0).appendingPathComponent(name)
            }
        let result: Result<Void, Error>
        do {
            guard let destination, (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                throw FirebirdModelAssets.AssetError.download
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        finish(name, result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let name = task.taskDescription else { return }
        finish(name, .failure(error))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let name = downloadTask.taskDescription else { return }
        let post = state.withLock { () -> Bool in
            received[name] = totalBytesWritten
            guard Date().timeIntervalSince(lastPost) >= 0.5 else { return false }
            lastPost = Date()
            return true
        }
        if post { postProgress() }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = state.withLock { () -> (() -> Void)? in
            defer { backgroundCompletion = nil }
            return backgroundCompletion
        }
        DispatchQueue.main.async { completion?() }
    }
}
