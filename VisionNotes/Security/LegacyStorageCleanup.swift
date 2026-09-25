import Foundation
import Security

/// Removes storage left by builds that encrypted notes at the app level:
/// the old SwiftData store, AES-GCM file folders, decrypted temporary copies
/// and the Keychain keys. Current data lives elsewhere, so this is idempotent.
enum LegacyStorageCleanup {
    static func run() {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let obsolete = ["VisionNotes/Sources", "VisionNotes/Pages", "VisionNotes/.aes-gcm-v1-migration-complete",
                        "MathNoteJobs", "default.store", "default.store-shm", "default.store-wal"]
        for path in obsolete { try? manager.removeItem(at: support.appendingPathComponent(path)) }
        for folder in ["VisionNotes-Decrypted", "VisionNotes-Academic"] {
            try? manager.removeItem(at: manager.temporaryDirectory.appendingPathComponent(folder))
        }
        for service in ["com.visionnotes.encryption", "com.visionnotes.storage-migrations"] {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
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
