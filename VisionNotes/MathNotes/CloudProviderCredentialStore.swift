import Foundation
import Security

/// Cloud credentials are optional and are consulted only after a job records
/// explicit fallback consent. Values never enter plist resources or logs.
final class CloudProviderCredentialStore: @unchecked Sendable {
    enum Provider: String, Sendable {
        case mistral
        case qwen3VL = "qwen3-vl"
    }

    static let shared = CloudProviderCredentialStore()
    private let service = "com.visionnotes.cloud-fallback"

    func value(for provider: Provider) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw MathNoteError.missingProviderKeys }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw MathNoteError.invalidProviderKeys
        }
        return value
    }

    func save(_ value: String, for provider: Provider) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw MathNoteError.emptyProviderKey
        }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let update = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw CloudCredentialKeychainError.status(update) }
        let add = identity.merging(attributes) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw CloudCredentialKeychainError.status(status) }
    }

    func remove(_ provider: Provider) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudCredentialKeychainError.status(status)
        }
    }
}

enum CloudCredentialKeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        guard case .status(let status) = self else { return nil }
        return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
    }
}
