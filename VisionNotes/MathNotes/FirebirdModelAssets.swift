import CryptoKit
import Foundation

/// Pinned public model assets. Downloads contain model weights only, never notes.
/// First setup streams directly into authenticated 4 MiB encrypted chunks.
actor FirebirdModelAssets {
    static let shared = FirebirdModelAssets()
    struct Asset: Codable, Sendable { let name: String; let bytes: Int; let sha256: String }
    struct Lock: Codable, Sendable { let model: String; let revision: String; let assets: [Asset] }
    struct Receipt: Codable { let chunks: Int; let bytes: Int; let sha256: String }
    enum AssetError: Error { case missingLock, invalidLock, download, integrity, tooLarge }
    private let vault = EncryptedDataVault()
    private let root: URL
    private var installation: Task<Void, Error>?
    private static let chunkBytes = 4 * 1024 * 1024

    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VisionNotes/Models/Qwen3VL", isDirectory: true)
    }

    /// Files the local runtime reads. Any pinned checkpoint must provide them.
    private static let requiredAssets: Set<String> = [
        "config.json", "generation_config.json", "preprocessor_config.json",
        "tokenizer.json", "tokenizer_config.json"
    ]

    /// The bundled lock is the single source of the model name and revision.
    nonisolated static func bundledLock() throws -> Lock {
        guard let url = Bundle.main.url(forResource: "FirebirdModel.lock", withExtension: "json") else {
            throw AssetError.missingLock
        }
        let lock = try JSONDecoder().decode(Lock.self, from: Data(contentsOf: url))
        let names = Set(lock.assets.map(\.name))
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard lock.model.split(separator: "/").count == 2,
              lock.revision.count == 40, CharacterSet(charactersIn: lock.revision).isSubset(of: hex),
              names.count == lock.assets.count,
              requiredAssets.isSubset(of: names),
              names.contains(where: { $0.hasSuffix(".safetensors") }),
              lock.assets.allSatisfy({ !$0.name.contains("/") && !$0.name.contains("..") && $0.bytes > 0 && $0.bytes < 8_000_000_000
                  && $0.sha256.count == 64 && CharacterSet(charactersIn: $0.sha256).isSubset(of: hex) }) else {
            throw AssetError.invalidLock
        }
        return lock
    }

    private func modelLock() throws -> Lock { try Self.bundledLock() }

    func ensureInstalled() async throws {
        if let installation { return try await installation.value }
        let task = Task { try await self.install() }
        installation = task
        defer { installation = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func install() async throws {
        let lock = try modelLock()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        var protectedRoot = root; try protectedRoot.setResourceValues(flags)
        for asset in lock.assets {
            try Task.checkCancellation()
            let directory = root.appendingPathComponent(asset.name, isDirectory: true)
            let context = "firebird/\(lock.revision)/\(asset.name)"
            let receiptURL = directory.appendingPathComponent("receipt.aesgcm")
            if FileManager.default.fileExists(atPath: receiptURL.path) {
                // Existing authentication failures never become a download or cloud retry.
                let data = try vault.open(Data(contentsOf: receiptURL), context: context + "/receipt")
                let receipt = try JSONDecoder().decode(Receipt.self, from: data)
                guard receipt.bytes == asset.bytes, receipt.sha256 == asset.sha256 else { throw AssetError.integrity }
                continue
            }
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = URL(string: "https://huggingface.co/\(lock.model)/resolve/\(lock.revision)/\(asset.name)")!
            let downloader = SealedModelDownload(asset: asset, directory: directory, context: context, vault: vault)
            try await downloader.run(url: url)
        }
    }

    /// Plaintext is temporary, file-protected, excluded from backup and removed
    /// immediately after MLX evaluates the weights. Persistent files remain sealed.
    func materialize() throws -> URL {
        let lock = try modelLock()
        return try TemporaryPlaintextAccessController.shared.withMaterialization {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("VisionNotesModelLoading", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let temporary = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            do {
                for asset in lock.assets {
                    try Task.checkCancellation()
                    let directory = root.appendingPathComponent(asset.name, isDirectory: true)
                    let context = "firebird/\(lock.revision)/\(asset.name)"
                    let receiptData = try vault.open(Data(contentsOf: directory.appendingPathComponent("receipt.aesgcm")), context: context + "/receipt")
                    let receipt = try JSONDecoder().decode(Receipt.self, from: receiptData)
                    guard receipt.bytes == asset.bytes, receipt.sha256 == asset.sha256,
                          receipt.chunks == (asset.bytes + Self.chunkBytes - 1) / Self.chunkBytes else { throw AssetError.integrity }
                    let output = temporary.appendingPathComponent(asset.name)
                    guard FileManager.default.createFile(atPath: output.path, contents: nil,
                        attributes: [.protectionKey: FileProtectionType.complete]) else { throw AssetError.download }
                    let handle = try FileHandle(forWritingTo: output)
                    do {
                        var digest = SHA256(); var count = 0
                        for index in 0..<receipt.chunks {
                            try Task.checkCancellation()
                            try TemporaryPlaintextAccessController.shared.checkAvailability()
                            try autoreleasepool {
                                let sealed = try Data(contentsOf: directory.appendingPathComponent("\(index).aesgcm"))
                                let data = try vault.open(sealed, context: context + "/\(index)")
                                let expected = min(Self.chunkBytes, asset.bytes - count)
                                guard data.count == expected else { throw AssetError.integrity }
                                digest.update(data: data); count += data.count
                                try handle.write(contentsOf: data)
                            }
                        }
                        let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()
                        guard count == asset.bytes, hex == asset.sha256 else { throw AssetError.integrity }
                        try handle.close()
                    } catch { try? handle.close(); throw error }
                }
                return temporary
            } catch { try? FileManager.default.removeItem(at: temporary); throw error }
        }
    }

    static func purgeTemporaryFiles() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("VisionNotesModelLoading", isDirectory: true)
        try? FileManager.default.removeItem(at: path)
    }
}

private final class SealedModelDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let asset: FirebirdModelAssets.Asset
    private let directory: URL
    private let context: String
    private let vault: EncryptedDataVault
    private let state = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    // The following buffer/hash state is used only on the serial delegate queue.
    private var buffer = Data()
    private var digest = SHA256()
    private var received = 0
    private var chunks = 0
    private var failure: Error?
    private let chunkBytes = 4 * 1024 * 1024

    init(asset: FirebirdModelAssets.Asset, directory: URL, context: String, vault: EncryptedDataVault) {
        self.asset = asset; self.directory = directory; self.context = context; self.vault = vault
    }

    func run(url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil; config.httpCookieStorage = nil
                config.allowsCellularAccess = false; config.allowsExpensiveNetworkAccess = false
                config.timeoutIntervalForRequest = 90; config.timeoutIntervalForResource = 3600
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: url)
                state.lock()
                self.continuation = continuation; self.task = task
                let shouldCancel = cancelled
                state.unlock()
                if shouldCancel { task.cancel() }
                task.resume()
            }
        } onCancel: {
            self.state.lock(); self.cancelled = true; let task = self.task; self.state.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength == -1 || response.expectedContentLength == Int64(asset.bytes) else {
            failure = FirebirdModelAssets.AssetError.download; completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            received += data.count
            guard received <= asset.bytes else { throw FirebirdModelAssets.AssetError.tooLarge }
            digest.update(data: data); buffer.append(data)
            while buffer.count >= chunkBytes {
                try persist(Data(buffer.prefix(chunkBytes)))
                buffer.removeFirst(chunkBytes)
            }
        } catch { failure = error; dataTask.cancel() }
    }

    private func persist(_ data: Data) throws {
        let sealed = try vault.seal(data, context: context + "/\(chunks)")
        try sealed.write(to: directory.appendingPathComponent("\(chunks).aesgcm"), options: [.atomic, .completeFileProtection])
        chunks += 1
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var result: Result<Void, Error>
        do {
            state.lock(); let wasCancelled = cancelled; state.unlock()
            if wasCancelled { throw CancellationError() }
            if let failure { throw failure }
            if let error { throw error }
            let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard received == asset.bytes, hex == asset.sha256 else { throw FirebirdModelAssets.AssetError.integrity }
            if !buffer.isEmpty { try persist(buffer) }
            buffer = Data()
            let receipt = FirebirdModelAssets.Receipt(chunks: chunks, bytes: received, sha256: hex)
            let sealed = try vault.seal(JSONEncoder().encode(receipt), context: context + "/receipt")
            try sealed.write(to: directory.appendingPathComponent("receipt.aesgcm"), options: [.atomic, .completeFileProtection])
            result = .success(())
        } catch { result = .failure(error); try? FileManager.default.removeItem(at: directory) }
        state.lock(); let continuation = self.continuation; self.continuation = nil; self.task = nil; state.unlock()
        continuation?.resume(with: result)
        session.finishTasksAndInvalidate()
    }
}
