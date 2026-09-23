import CryptoKit
import Foundation

extension Notification.Name {
    /// Posted after the plaintext gate closes and before its asynchronous purge.
    static let visionNotesWillSuspendPlaintext = Notification.Name(
        "com.visionnotes.security.will-suspend-plaintext"
    )

    /// Posted after every pending purge finishes and the plaintext gate reopens.
    static let visionNotesDidResumePlaintext = Notification.Name(
        "com.visionnotes.security.did-resume-plaintext"
    )
}

/// Coordinates creation of temporary plaintext with lifecycle purges. The
/// state lock is held only to admit/finalize an operation, never while bytes are
/// decrypted or written. Suspension therefore closes admission immediately;
/// its queued purge waits for already-admitted operations to finish and makes
/// each of those operations fail as stale before it can publish a result.
final class TemporaryPlaintextAccessController: @unchecked Sendable {
    static let shared = TemporaryPlaintextAccessController()

    private let state = NSCondition()
    private let lifecycleQueue = DispatchQueue(
        label: "com.visionnotes.security.temporary-plaintext-lifecycle",
        qos: .utility
    )
    private var allowsMaterialization = true
    private var generation: UInt64 = 0
    private var activeMaterializationCount = 0
    private var purgeIsPending = false

    init(allowsMaterialization: Bool = true) {
        self.allowsMaterialization = allowsMaterialization
    }

    var isAvailable: Bool {
        state.lock()
        defer { state.unlock() }
        return allowsMaterialization && !purgeIsPending
    }

    /// Long operations must stop between chunks after lifecycle suspension.
    func checkAvailability() throws {
        guard isAvailable else { throw CancellationError() }
    }

    func withMaterialization<T>(_ operation: () throws -> T) throws -> T {
        let admittedGeneration: UInt64
        state.lock()
        guard allowsMaterialization else {
            state.unlock()
            throw CancellationError()
        }
        admittedGeneration = generation
        activeMaterializationCount += 1
        state.unlock()

        let result: T
        do {
            result = try operation()
        } catch {
            finishMaterialization()
            throw error
        }

        state.lock()
        activeMaterializationCount -= 1
        let mayPublish = allowsMaterialization && generation == admittedGeneration
        if activeMaterializationCount == 0 { state.broadcast() }
        state.unlock()

        guard mayPublish else { throw CancellationError() }
        return result
    }

    /// Closes the gate synchronously, then queues one purge for the current
    /// suspended period. The returned work item is useful to tests and shutdown
    /// coordination; UI lifecycle callers should not block waiting for it.
    @discardableResult
    func suspendAndPurge(_ purge: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        state.lock()
        let wasOpen = allowsMaterialization
        allowsMaterialization = false
        generation &+= 1
        let shouldSchedulePurge = !purgeIsPending
        purgeIsPending = true
        state.unlock()

        if wasOpen {
            postLifecycleNotification(.visionNotesWillSuspendPlaintext)
        }

        let workItem = DispatchWorkItem { [self] in
            if shouldSchedulePurge {
                waitForActiveMaterializationsToDrain()
                purge()

                state.lock()
                purgeIsPending = false
                state.broadcast()
                state.unlock()
            }
        }
        lifecycleQueue.async(execute: workItem)
        return workItem
    }

    func resume() {
        state.lock()
        let expectedGeneration = generation
        let mustWaitForPurge = purgeIsPending
        if !mustWaitForPurge {
            allowsMaterialization = true
        }
        state.unlock()

        if mustWaitForPurge {
            lifecycleQueue.async { [self] in
                state.lock()
                let mayResume = generation == expectedGeneration && !purgeIsPending
                if mayResume { allowsMaterialization = true }
                state.unlock()
                if mayResume {
                    postLifecycleNotification(.visionNotesDidResumePlaintext)
                }
            }
        } else {
            postLifecycleNotification(.visionNotesDidResumePlaintext)
        }
    }

    private func finishMaterialization() {
        state.lock()
        activeMaterializationCount -= 1
        if activeMaterializationCount == 0 { state.broadcast() }
        state.unlock()
    }

    private func waitForActiveMaterializationsToDrain() {
        state.lock()
        while activeMaterializationCount > 0 {
            state.wait()
        }
        state.unlock()
    }

    private func postLifecycleNotification(_ name: Notification.Name) {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: name, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: name, object: nil)
            }
        }
    }
}

enum EncryptedDataVaultError: LocalizedError, Equatable, Sendable {
    case unsealedData
    case invalidEnvelope
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .unsealedData:
            "Encrypted data is missing its recognized Vision Notes envelope."
        case .invalidEnvelope:
            "The encrypted Vision Notes envelope is malformed."
        case .authenticationFailed:
            "Encrypted data failed its integrity check."
        }
    }
}

/// Versioned, path-bound AES-GCM envelope used for note payloads and model
/// weights. The logical path is authenticated as AAD, so moving ciphertext to
/// a different note or model file makes decryption fail instead of silently
/// accepting swapped content.
struct EncryptedDataVault: Sendable {
    static let header = Data("VNAES1".utf8)

    private let keyProvider: @Sendable () throws -> SymmetricKey

    init(keyProvider: @escaping @Sendable () throws -> SymmetricKey = {
        try SecureKeyStore.shared.masterKey()
    }) {
        self.keyProvider = keyProvider
    }

    func seal(_ plaintext: Data, context: String) throws -> Data {
        let box = try AES.GCM.seal(
            plaintext,
            using: keyProvider(),
            authenticating: authenticatedData(context: context)
        )
        guard let combined = box.combined else { throw SecureKeyStoreError.invalidKeyMaterial }
        return Self.header + combined
    }

    func open(_ stored: Data, context: String) throws -> Data {
        // Legacy plaintext is deliberately not accepted here. Storage owners
        // may import it only inside their one-time, root-scoped migration.
        guard isSealed(stored) else { throw EncryptedDataVaultError.unsealedData }
        let combined = Data(stored.dropFirst(Self.header.count))
        let key = try keyProvider()
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(
                box,
                using: key,
                authenticating: authenticatedData(context: context)
            )
        } catch {
            // Do not leak CryptoKit's distinction between a malformed box and
            // a bad tag/key. Both mean the persisted envelope is untrusted.
            throw combined.isEmpty
                ? EncryptedDataVaultError.invalidEnvelope
                : EncryptedDataVaultError.authenticationFailed
        }
    }

    func isSealed(_ data: Data) -> Bool {
        data.starts(with: Self.header)
    }

    private func authenticatedData(context: String) -> Data {
        var data = Self.header
        data.append(0) // Domain separator between the version and logical path.
        data.append(contentsOf: context.utf8)
        return data
    }
}

enum EncryptedTextCodecError: LocalizedError {
    case missingCiphertext(field: String)
    case encryptionFailed(field: String)
    case integrityCheckFailed(field: String)
    case invalidTextEncoding(field: String)
    case verificationFailed(field: String)

    var errorDescription: String? {
        switch self {
        case .missingCiphertext(let field):
            "Encrypted \(displayName(field)) is missing."
        case .encryptionFailed(let field):
            "\(displayName(field).capitalized) could not be encrypted."
        case .integrityCheckFailed(let field):
            "Encrypted \(displayName(field)) failed its integrity check."
        case .invalidTextEncoding(let field):
            "Encrypted \(displayName(field)) does not contain valid text."
        case .verificationFailed(let field):
            "Encrypted \(displayName(field)) could not be verified before it was saved."
        }
    }

    private func displayName(_ field: String) -> String {
        field.replacingOccurrences(of: "-", with: " ")
    }
}

/// SwiftData stores AES-GCM envelopes for recognized note text and thumbnails.
/// Titles and original filenames are also sealed; timestamps remain metadata. Unlike a UI convenience
/// accessor, this codec never substitutes an empty value for a key, format, or
/// authentication failure: callers must handle the error explicitly.
enum EncryptedTextCodec {
    private static let vault = EncryptedDataVault()

    static func seal(_ text: String, recordID: UUID, field: String) throws -> Data {
        try sealData(Data(text.utf8), recordID: recordID, field: field)
    }

    static func open(_ data: Data?, recordID: UUID, field: String) throws -> String {
        let plaintext = try openData(data, recordID: recordID, field: field)
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw EncryptedTextCodecError.invalidTextEncoding(field: field)
        }
        return text
    }

    static func sealData(_ data: Data, recordID: UUID, field: String) throws -> Data {
        do {
            return try vault.seal(
                data,
                context: "swiftdata/\(field)/\(recordID.uuidString.lowercased())"
            )
        } catch {
            throw EncryptedTextCodecError.encryptionFailed(field: field)
        }
    }

    static func openData(_ data: Data?, recordID: UUID, field: String) throws -> Data {
        guard let data, !data.isEmpty else {
            throw EncryptedTextCodecError.missingCiphertext(field: field)
        }
        do {
            return try vault.open(
                data,
                context: "swiftdata/\(field)/\(recordID.uuidString.lowercased())"
            )
        } catch {
            throw EncryptedTextCodecError.integrityCheckFailed(field: field)
        }
    }
}

/// File enumeration may return a canonical /private/var URL while the app's
/// container URL uses /var. Character-count slicing corrupts relative paths.
enum StorageRelativePath {
    static func path(of file: URL, under directory: URL) throws -> String {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let components = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard components.count > root.count,
              Array(components.prefix(root.count)) == root else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return components.dropFirst(root.count).joined(separator: "/")
    }
}
