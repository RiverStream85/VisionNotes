import Foundation
import SwiftData

/// All SwiftData reads and writes the UI needs, in one place.
///
/// Deleting goes through here rather than `modelContext.delete` directly, so
/// the local files always disappear together with the database rows.
@MainActor
struct DocumentStore {
    let modelContext: ModelContext
    let storage: FileStorageServicing
    private let migrationState = LegacyContentMigrationState()

    init(modelContext: ModelContext, storage: FileStorageServicing = FileStorageService.shared) {
        self.modelContext = modelContext
        self.storage = storage
    }

    // MARK: - Reading

    func allDocuments() throws -> [LibraryDocument] {
        let descriptor = FetchDescriptor<LibraryDocument>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        do {
            try migrateLegacyContent()
            return try modelContext.fetch(descriptor)
        } catch {
            if error is EncryptedTextCodecError { throw error }
            throw AppError.persistenceSaveFailed(reason: error.localizedDescription)
        }
    }

    func document(with id: UUID) throws -> LibraryDocument? {
        var descriptor = FetchDescriptor<LibraryDocument>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        do {
            try migrateLegacyContent()
            return try modelContext.fetch(descriptor).first
        } catch {
            if error is EncryptedTextCodecError { throw error }
            throw AppError.persistenceSaveFailed(reason: error.localizedDescription)
        }
    }

    func documentCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<LibraryDocument>())
    }

    /// Flattens the library into plain values for `SearchEngine`.
    func searchSnapshots() throws -> [SearchDocumentSnapshot] {
        try allDocuments().map { document in
            SearchDocumentSnapshot(
                id: document.id,
                title: try document.title,
                documentType: document.documentType,
                updatedAt: document.updatedAt,
                pages: try document.sortedPages.map { page in
                    SearchPageSnapshot(
                        id: page.id,
                        pageNumber: page.pageNumber,
                        text: try page.decryptedRecognizedText()
                    )
                }
            )
        }
    }

    // MARK: - Writing

    func rename(_ document: LibraryDocument, to title: String) throws {
        let cleaned = FileNameGenerator.sanitizedTitle(title)
        guard !cleaned.isEmpty else { return }
        try document.setTitle(cleaned)
        document.updatedAt = Date()
        try save()
    }

    func updateRecognizedText(_ text: String, on page: DocumentPage) throws {
        try page.setRecognizedText(text)
        page.document?.updatedAt = Date()
        try save()
    }

    /// Migrates the original plaintext SwiftData columns in place. Each value
    /// is encrypted and reopened successfully before its legacy column is
    /// cleared, and a single SwiftData save commits the batch.
    func migrateLegacyContent() throws {
        guard !migrationState.isComplete else { return }
        let documents: [LibraryDocument]
        let pages: [DocumentPage]
        let blocks: [TextBlock]
        do {
            documents = try modelContext.fetch(FetchDescriptor<LibraryDocument>())
            // Fetch child entities independently so any rows orphaned by an
            // older SwiftData cascade bug do not leave plaintext behind.
            pages = try modelContext.fetch(FetchDescriptor<DocumentPage>(
                predicate: #Predicate {
                    $0.recognizedTextCiphertext == nil || $0.legacyRecognizedText != ""
                }
            ))
            blocks = try modelContext.fetch(FetchDescriptor<TextBlock>(
                predicate: #Predicate {
                    $0.textCiphertext == nil || $0.legacyText != ""
                }
            ))
        } catch {
            throw AppError.persistenceSaveFailed(reason: error.localizedDescription)
        }
        try migrateLegacyContent(documents: documents, pages: pages, blocks: blocks)
        migrationState.isComplete = true
    }

    /// Removes a document, its pages, its text blocks and every local file.
    func delete(_ document: LibraryDocument) throws {
        purge(document)
        try save()
    }

    func delete(documentsAt offsets: IndexSet, in documents: [LibraryDocument]) throws {
        for index in offsets where documents.indices.contains(index) {
            purge(documents[index])
        }
        try save()
    }

    func deleteAll() throws {
        for document in try allDocuments() {
            purge(document)
        }
        try save()
    }

    /// The relationships declare `deleteRule: .cascade`, but the child rows are
    /// also deleted by hand: SwiftData does not apply the rule reliably across
    /// OS versions, and an orphaned page would keep turning up in search
    /// results that can no longer be opened.
    private func purge(_ document: LibraryDocument) {
        deleteFiles(of: document)
        for page in document.pages {
            for block in page.textBlocks {
                modelContext.delete(block)
            }
            modelContext.delete(page)
        }
        modelContext.delete(document)
    }

    func save() throws {
        try migrateLegacyContent()
        try persistChanges()
    }

    private func persistChanges() throws {
        guard modelContext.hasChanges else { return }
        do {
            try modelContext.save()
        } catch {
            throw AppError.persistenceSaveFailed(reason: error.localizedDescription)
        }
    }

    private func migrateLegacyContent(
        documents: [LibraryDocument],
        pages: [DocumentPage],
        blocks: [TextBlock]
    ) throws {
        var changed = false
        for document in documents {
            changed = try document.migrateLegacyMetadataIfNeeded() || changed
            changed = try document.migrateLegacyThumbnailIfNeeded() || changed
        }
        for page in pages {
            changed = try page.migrateLegacyRecognizedTextIfNeeded() || changed
        }
        for block in blocks {
            changed = try block.migrateLegacyTextIfNeeded() || changed
        }
        if changed {
            try persistChanges()
        }
    }

    // MARK: - Files

    /// Best effort: a file that is already gone must not block the delete.
    func deleteFiles(of document: LibraryDocument) {
        storage.deleteIgnoringMissing(fileName: document.localFileName, in: .sources)
        let pageDirectory = PageImageLocator.directory(for: document.documentType)
        for page in document.pages {
            storage.deleteIgnoringMissing(fileName: page.imageFileName, in: pageDirectory)
        }
    }
}

@MainActor
private final class LegacyContentMigrationState {
    var isComplete = false
}
