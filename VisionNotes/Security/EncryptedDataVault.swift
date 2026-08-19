import CryptoKit
import Foundation

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
            authenticating: Data(context.utf8)
        )
        guard let combined = box.combined else { throw SecureKeyStoreError.invalidKeyMaterial }
        return Self.header + combined
    }

    func open(_ stored: Data, context: String) throws -> Data {
        // One-time compatibility path for development builds created before
        // encrypted storage. Every caller rewrites legacy plaintext on its next
        // successful write; new data is never persisted without the header.
        guard isSealed(stored) else { return stored }
        let combined = stored.dropFirst(Self.header.count)
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(
            box,
            using: keyProvider(),
            authenticating: Data(context.utf8)
        )
    }

    func isSealed(_ data: Data) -> Bool {
        data.starts(with: Self.header)
    }
}

/// SwiftData stores only these AES-GCM envelopes for recognized note text.
/// Titles and timestamps remain searchable metadata; page and block contents
/// are decrypted only through their computed model properties.
enum EncryptedTextCodec {
    private static let vault = EncryptedDataVault()

    static func seal(_ text: String, recordID: UUID, field: String) -> Data {
        do {
            return try vault.seal(
                Data(text.utf8),
                context: "swiftdata/\(field)/\(recordID.uuidString.lowercased())"
            )
        } catch {
            assertionFailure("VisionNotes could not seal note text.")
            return Data()
        }
    }

    static func open(_ data: Data, recordID: UUID, field: String) -> String {
        guard !data.isEmpty else { return "" }
        do {
            let plaintext = try vault.open(
                data,
                context: "swiftdata/\(field)/\(recordID.uuidString.lowercased())"
            )
            return String(data: plaintext, encoding: .utf8) ?? ""
        } catch {
            assertionFailure("VisionNotes could not open sealed note text.")
            return ""
        }
    }
}
