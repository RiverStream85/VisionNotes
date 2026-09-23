import CryptoKit
import XCTest
@testable import VisionNotes

final class FileStorageServiceTests: XCTestCase {

    private var root: URL!
    private var storage: FileStorageService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionNotesTests-\(UUID().uuidString)", isDirectory: true)
        storage = FileStorageService(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        storage = nil
        root = nil
        try super.tearDownWithError()
    }

    func testWriteThenReadRoundTrip() throws {
        let payload = Data("hello vision".utf8)
        try storage.write(payload, fileName: "a.txt", in: .sources)

        XCTAssertTrue(storage.fileExists("a.txt", in: .sources))
        XCTAssertEqual(try storage.data(forFileName: "a.txt", in: .sources), payload)
        let persisted = try Data(contentsOf: root.appendingPathComponent("Sources/a.txt"))
        XCTAssertNotEqual(persisted, payload)
        XCTAssertTrue(persisted.starts(with: EncryptedDataVault.header))
    }

    func testDirectoriesAreIsolatedFromEachOther() throws {
        try storage.write(Data("one".utf8), fileName: "same.jpg", in: .sources)
        try storage.write(Data("two".utf8), fileName: "same.jpg", in: .pages)

        XCTAssertEqual(try storage.data(forFileName: "same.jpg", in: .sources), Data("one".utf8))
        XCTAssertEqual(try storage.data(forFileName: "same.jpg", in: .pages), Data("two".utf8))
    }

    func testReadingAMissingFileThrowsAReadableError() {
        XCTAssertThrowsError(try storage.data(forFileName: "nope.jpg", in: .pages)) { error in
            XCTAssertEqual(error as? AppError, .fileMissing(fileName: "nope.jpg"))
        }
    }

    func testDeleteRemovesTheFile() throws {
        try storage.write(Data("x".utf8), fileName: "gone.jpg", in: .pages)
        try storage.delete(fileName: "gone.jpg", in: .pages)
        XCTAssertFalse(storage.fileExists("gone.jpg", in: .pages))
    }

    func testPurgingMaterializedFilesRemovesDecryptedCopyOnly() throws {
        let payload = Data("temporary plaintext".utf8)
        try storage.write(payload, fileName: "preview.txt", in: .sources)
        let materialized = try storage.url(for: "preview.txt", in: .sources)
        XCTAssertEqual(try Data(contentsOf: materialized), payload)

        storage.purgeMaterializedFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: materialized.path))
        XCTAssertEqual(try storage.data(forFileName: "preview.txt", in: .sources), payload)
    }

    func testMaterializationStaysBlockedAfterLifecyclePurgeUntilResume() throws {
        let isolatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionNotesGateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: isolatedRoot) }

        let gate = TemporaryPlaintextAccessController()
        let key = SymmetricKey(data: Data(repeating: 0x45, count: 32))
        let isolatedStorage = FileStorageService(
            rootDirectory: isolatedRoot,
            vault: EncryptedDataVault(keyProvider: { key }),
            plaintextAccessController: gate
        )
        let payload = Data("lifecycle secret".utf8)
        try isolatedStorage.write(payload, fileName: "private.pdf", in: .sources)

        let materialized = try isolatedStorage.url(for: "private.pdf", in: .sources)
        XCTAssertEqual(try Data(contentsOf: materialized), payload)

        let purgeWorkItem = gate.suspendAndPurge {
            isolatedStorage.purgeMaterializedFiles()
        }
        XCTAssertEqual(purgeWorkItem.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: materialized.path))
        XCTAssertThrowsError(try isolatedStorage.url(for: "private.pdf", in: .sources)) { error in
            XCTAssertTrue(error is CancellationError)
        }

        gate.resume()
        let reopened = try isolatedStorage.url(for: "private.pdf", in: .sources)
        XCTAssertEqual(try Data(contentsOf: reopened), payload)
        isolatedStorage.releaseMaterializedFile(fileName: "private.pdf", in: .sources)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.path))
        XCTAssertEqual(try isolatedStorage.data(forFileName: "private.pdf", in: .sources), payload)
    }

    func testLifecycleSuspensionRejectsInFlightPublicationBeforePurging() throws {
        let gate = TemporaryPlaintextAccessController()
        let operationStarted = DispatchSemaphore(value: 0)
        let allowOperationToFinish = DispatchSemaphore(value: 0)
        let staleOperationWasCancelled = DispatchSemaphore(value: 0)
        let staleOperationUnexpectedlyFinished = DispatchSemaphore(value: 0)
        let purgeRan = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try gate.withMaterialization {
                    operationStarted.signal()
                    allowOperationToFinish.wait()
                    return "stale plaintext URL"
                }
                staleOperationUnexpectedlyFinished.signal()
            } catch is CancellationError {
                staleOperationWasCancelled.signal()
            } catch {
                staleOperationUnexpectedlyFinished.signal()
            }
        }

        XCTAssertEqual(operationStarted.wait(timeout: .now() + 2), .success)
        let purgeWorkItem = gate.suspendAndPurge { purgeRan.signal() }

        XCTAssertThrowsError(try gate.withMaterialization { "new plaintext URL" }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(purgeWorkItem.wait(timeout: .now() + 0.05), .timedOut)

        allowOperationToFinish.signal()
        XCTAssertEqual(staleOperationWasCancelled.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(staleOperationUnexpectedlyFinished.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(purgeRan.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(purgeWorkItem.wait(timeout: .now() + 2), .success)

        gate.resume()
        XCTAssertEqual(try gate.withMaterialization { "fresh plaintext URL" }, "fresh plaintext URL")
    }

    func testDeletingAMissingFileIsNotAnError() {
        XCTAssertNoThrow(try storage.delete(fileName: "never-existed.jpg", in: .pages))
        storage.deleteIgnoringMissing(fileName: nil, in: .pages)
        storage.deleteIgnoringMissing(fileName: "", in: .pages)
    }

    func testCopyItemImportsAFileFromOutsideTheSandbox() throws {
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-\(UUID().uuidString).pdf")
        try Data("pdf bytes".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }

        try storage.copyItem(at: external, toFileName: "copied.pdf", in: .sources)
        XCTAssertEqual(try storage.data(forFileName: "copied.pdf", in: .sources), Data("pdf bytes".utf8))
    }

    func testCopyingOverAnExistingFileReplacesIt() throws {
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-\(UUID().uuidString).pdf")
        try Data("new".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }

        try storage.write(Data("old".utf8), fileName: "target.pdf", in: .sources)
        try storage.copyItem(at: external, toFileName: "target.pdf", in: .sources)
        XCTAssertEqual(try storage.data(forFileName: "target.pdf", in: .sources), Data("new".utf8))
    }

    func testCopyingAMissingSourceThrowsACopyError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).pdf")
        XCTAssertThrowsError(try storage.copyItem(at: missing, toFileName: "x.pdf", in: .sources)) { error in
            guard case .fileCopyFailed = (error as? AppError) else {
                return XCTFail("Expected a fileCopyFailed error, got \(error)")
            }
        }
    }

    func testVaultRejectsMissingAlteredAndUnknownHeaders() throws {
        let key = SymmetricKey(data: Data(repeating: 0x31, count: 32))
        let vault = EncryptedDataVault(keyProvider: { key })
        let context = "library/Sources/private.txt"
        let sealed = try vault.seal(Data("private".utf8), context: context)

        let stripped = Data(sealed.dropFirst(EncryptedDataVault.header.count))
        assertVaultError(.unsealedData) {
            _ = try vault.open(stripped, context: context)
        }

        var altered = sealed
        altered[altered.startIndex] ^= 0x01
        assertVaultError(.unsealedData) {
            _ = try vault.open(altered, context: context)
        }

        let unknownVersion = Data("VNAES9".utf8) + stripped
        assertVaultError(.unsealedData) {
            _ = try vault.open(unknownVersion, context: context)
        }
    }

    func testVaultAuthenticatesHeaderVersionAndContext() throws {
        let key = SymmetricKey(data: Data(repeating: 0x52, count: 32))
        let vault = EncryptedDataVault(keyProvider: { key })
        let context = "library/Pages/page.jpg"
        let plaintext = Data("page bytes".utf8)
        let sealed = try vault.seal(plaintext, context: context)

        assertVaultError(.authenticationFailed) {
            _ = try vault.open(sealed, context: context + ".moved")
        }

        // A box made with the old context-only AAD has the right visible
        // header, but must fail because the current header/version is also AAD.
        let legacyBox = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: Data(context.utf8)
        )
        let legacyCombined = try XCTUnwrap(legacyBox.combined)
        let legacyEnvelope = EncryptedDataVault.header + legacyCombined
        assertVaultError(.authenticationFailed) {
            _ = try vault.open(legacyEnvelope, context: context)
        }

        var tampered = sealed
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        assertVaultError(.authenticationFailed) {
            _ = try vault.open(tampered, context: context)
        }
    }

    func testLegacyPlaintextMigratesOnceThenPlaintextIsRejected() throws {
        let migrationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionNotesLegacyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: migrationRoot) }
        let sources = migrationRoot.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let legacyURL = sources.appendingPathComponent("legacy.txt")
        let plaintext = Data("pre-encryption note".utf8)
        try plaintext.write(to: legacyURL)

        let key = SymmetricKey(data: Data(repeating: 0x73, count: 32))
        let vault = EncryptedDataVault(keyProvider: { key })
        let migratedStorage = FileStorageService(rootDirectory: migrationRoot, vault: vault)

        XCTAssertEqual(
            try migratedStorage.data(forFileName: "legacy.txt", in: .sources),
            plaintext
        )
        let persisted = try Data(contentsOf: legacyURL)
        XCTAssertTrue(persisted.starts(with: EncryptedDataVault.header))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: migrationRoot
                    .appendingPathComponent(FileStorageService.migrationMarkerName)
                    .path
            )
        )

        // Once the root marker exists, a replacement plaintext file is never
        // interpreted as a legacy payload.
        try plaintext.write(to: legacyURL, options: .atomic)
        XCTAssertThrowsError(
            try migratedStorage.data(forFileName: "legacy.txt", in: .sources)
        ) { error in
            XCTAssertEqual(
                error as? AppError,
                .fileIntegrityFailed(fileName: "legacy.txt")
            )
        }

        // Deleting the convenience filesystem marker must not reopen the
        // plaintext migration path. The independent Keychain state survives.
        try FileManager.default.removeItem(
            at: migrationRoot.appendingPathComponent(FileStorageService.migrationMarkerName)
        )
        let reopenedStorage = FileStorageService(rootDirectory: migrationRoot, vault: vault)
        XCTAssertThrowsError(
            try reopenedStorage.data(forFileName: "legacy.txt", in: .sources)
        ) { error in
            XCTAssertEqual(error as? AppError, .fileIntegrityFailed(fileName: "legacy.txt"))
        }
    }

    func testLegacyAcademicJobMigratesBeforeMarkerThenRejectsPlaintext() async throws {
        let migrationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionNotesLegacyJobTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: migrationRoot) }
        let jobID = UUID()
        let jobRoot = migrationRoot
            .appendingPathComponent(jobID.uuidString.lowercased(), isDirectory: true)
        let pagesRoot = jobRoot.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: pagesRoot, withIntermediateDirectories: true)

        let pagePath = "pages/page-001.jpg"
        let pageURL = jobRoot.appendingPathComponent(pagePath)
        let pageData = Data("legacy page".utf8)
        try pageData.write(to: pageURL)
        let manifest = MathNoteJobManifest(
            id: jobID,
            title: "Legacy",
            pages: [MathNotePageRecord(index: 0, sourcePath: pagePath)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: jobRoot.appendingPathComponent("manifest.json"))

        let key = SymmetricKey(data: Data(repeating: 0x24, count: 32))
        let vault = EncryptedDataVault(keyProvider: { key })
        let store = MathNoteJobStore(rootURL: migrationRoot, vault: vault)

        let loaded = try await store.load(jobID)
        let migratedPage = try await store.read(relativePath: pagePath, jobID: jobID)
        let persistedPage = try Data(contentsOf: pageURL)
        XCTAssertEqual(loaded.title, "Legacy")
        XCTAssertEqual(migratedPage, pageData)
        XCTAssertTrue(persistedPage.starts(with: EncryptedDataVault.header))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: migrationRoot
                    .appendingPathComponent(MathNoteJobStore.migrationMarkerName)
                    .path
            )
        )

        try pageData.write(to: pageURL, options: .atomic)
        do {
            _ = try await store.read(relativePath: pagePath, jobID: jobID)
            XCTFail("Plaintext must not be accepted after the Academic root is migrated.")
        } catch let error as EncryptedDataVaultError {
            XCTAssertEqual(error, .unsealedData)
        }


        try FileManager.default.removeItem(
            at: migrationRoot.appendingPathComponent(MathNoteJobStore.migrationMarkerName)
        )
        let reopenedStore = MathNoteJobStore(rootURL: migrationRoot, vault: vault)
        do {
            _ = try await reopenedStore.read(relativePath: pagePath, jobID: jobID)
            XCTFail("Deleting the marker must not reopen Academic plaintext migration.")
        } catch let error as EncryptedDataVaultError {
            XCTAssertEqual(error, .unsealedData)
        }
    }

    private func assertVaultError(
        _ expected: EncryptedDataVaultError,
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? EncryptedDataVaultError, expected, file: file, line: line)
        }
    }
}
