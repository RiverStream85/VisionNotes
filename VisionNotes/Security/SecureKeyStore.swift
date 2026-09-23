import CryptoKit
import Foundation
import LocalAuthentication
import Security
import UIKit

enum SecureKeyStoreError: LocalizedError {
    case keychain(OSStatus)
    case randomGeneration(OSStatus)
    case invalidKeyMaterial

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "The device key store returned status \(status)."
        case .randomGeneration(let status):
            "The secure random-number generator returned status \(status)."
        case .invalidKeyMaterial:
            "The saved encryption key could not be opened."
        }
    }
}

/// Owns the 256-bit application master key. On physical devices the key is
/// wrapped by a non-exportable Secure Enclave agreement key. Simulators fall
/// back to a ThisDeviceOnly Keychain item so tests exercise the same AES-GCM
/// storage path without pretending a Secure Enclave exists.
final class SecureKeyStore: @unchecked Sendable {
    static let shared = SecureKeyStore()

    private let service = "com.visionnotes.encryption"
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?
    private var lifecycleObservers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.protectedDataWillBecomeUnavailableNotification
        ] {
            lifecycleObservers.append(
                center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    self?.discardCachedKey()
                }
            )
        }
    }

    deinit {
        let center = NotificationCenter.default
        lifecycleObservers.forEach(center.removeObserver)
    }

    func masterKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }

        let key: SymmetricKey
        if SecureEnclave.isAvailable {
            key = try loadOrCreateSecureEnclaveWrappedKey()
        } else {
            key = try loadOrCreateKeychainKey()
        }
        cachedKey = key
        return key
    }

    private func discardCachedKey() {
        lock.lock()
        cachedKey = nil
        lock.unlock()
    }

    private func loadOrCreateSecureEnclaveWrappedKey() throws -> SymmetricKey {
        let enclaveKey: SecureEnclave.P256.KeyAgreement.PrivateKey
        if let representation = try Keychain.read(service: service, account: "secure-enclave-reference") {
            enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                dataRepresentation: representation,
                authenticationContext: LAContext()
            )
        } else {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.privateKeyUsage],
                &error
            ) else {
                throw error?.takeRetainedValue() ?? SecureKeyStoreError.invalidKeyMaterial
            }
            enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                compactRepresentable: false,
                accessControl: access,
                authenticationContext: LAContext()
            )
            try Keychain.write(
                enclaveKey.dataRepresentation,
                service: service,
                account: "secure-enclave-reference"
            )
        }

        if let encodedEnvelope = try Keychain.read(service: service, account: "wrapped-master-key") {
            let envelope = try JSONDecoder().decode(WrappedKeyEnvelope.self, from: encodedEnvelope)
            let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: envelope.ephemeralPublicKey)
            let shared = try enclaveKey.sharedSecretFromKeyAgreement(with: peer)
            let wrappingKey = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: envelope.salt,
                sharedInfo: Data("VisionNotes Secure Enclave master key".utf8),
                outputByteCount: 32
            )
            let box = try AES.GCM.SealedBox(combined: envelope.sealedMasterKey)
            return SymmetricKey(data: try AES.GCM.open(box, using: wrappingKey))
        }

        let masterKey = SymmetricKey(size: .bits256)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try enclaveKey.sharedSecretFromKeyAgreement(with: ephemeral.publicKey)
        let salt = try randomData(count: 32)
        let wrappingKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("VisionNotes Secure Enclave master key".utf8),
            outputByteCount: 32
        )
        let masterData = masterKey.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(masterData, using: wrappingKey)
        guard let combined = sealed.combined else { throw SecureKeyStoreError.invalidKeyMaterial }
        let envelope = WrappedKeyEnvelope(
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            salt: salt,
            sealedMasterKey: combined
        )
        try Keychain.write(
            try JSONEncoder().encode(envelope),
            service: service,
            account: "wrapped-master-key"
        )
        return masterKey
    }

    private func loadOrCreateKeychainKey() throws -> SymmetricKey {
        if let data = try Keychain.read(service: service, account: "simulator-master-key") {
            guard data.count == 32 else { throw SecureKeyStoreError.invalidKeyMaterial }
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try Keychain.write(data, service: service, account: "simulator-master-key")
        return key
    }

    private func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw SecureKeyStoreError.randomGeneration(status)
        }
        return Data(bytes)
    }
}

/// Records one-way storage migrations outside the filesystem being migrated.
/// A deleted or rolled-back marker file therefore cannot reopen the legacy
/// plaintext-import path after an installation has completed migration.
struct DeviceMigrationStateStore: Sendable {
    static let shared = DeviceMigrationStateStore()

    private let service = "com.visionnotes.storage-migrations"
    private let completePayload = Data("complete-v1".utf8)

    func isComplete(scope: String, rootURL: URL) throws -> Bool {
        guard let data = try Keychain.read(
            service: service,
            account: account(scope: scope, rootURL: rootURL)
        ) else {
            return false
        }
        guard data == completePayload else {
            throw SecureKeyStoreError.invalidKeyMaterial
        }
        return true
    }

    func markComplete(scope: String, rootURL: URL) throws {
        try Keychain.write(
            completePayload,
            service: service,
            account: account(scope: scope, rootURL: rootURL)
        )
    }

    private func account(scope: String, rootURL: URL) -> String {
        var identity = Data(scope.utf8)
        identity.append(0)
        identity.append(contentsOf: rootURL.standardizedFileURL.path.utf8)
        let digest = SHA256.hash(data: identity)
        return "aes-gcm-v1-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct WrappedKeyEnvelope: Codable {
    let ephemeralPublicKey: Data
    let salt: Data
    let sealedMasterKey: Data
}

private enum Keychain {
    static func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecureKeyStoreError.keychain(status)
        }
        return data
    }

    static func write(_ data: Data, service: String, account: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SecureKeyStoreError.keychain(updateStatus)
        }
        let add = identity.merging(attributes) { _, new in new }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SecureKeyStoreError.keychain(addStatus) }
    }
}
