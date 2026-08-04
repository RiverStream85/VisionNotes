import Foundation
import Observation
import SwiftData

/// Library actions that touch storage: demo data, rename, delete, re-run OCR.
@MainActor
@Observable
final class LibraryViewModel {
    var errorAlert: ErrorAlert?
    var isLoadingDemo = false
    private(set) var reprocessingDocumentIDs: Set<UUID> = []

    /// `nonisolated` so SwiftUI views can create the view model in a property
    /// initializer, which is not main-actor isolated.
    nonisolated init() {}

    /// Renders the sample pages off the main actor, then inserts them.
    func loadDemoNotes(modelContext: ModelContext) async {
        guard !isLoadingDemo else { return }
        isLoadingDemo = true
        defer { isLoadingDemo = false }
        do {
            try await DemoDataService(modelContext: modelContext).loadDemoNotes()
        } catch {
            errorAlert = ErrorAlert(error)
        }
    }

    func rename(_ document: LibraryDocument, to title: String, modelContext: ModelContext) {
        do {
            try DocumentStore(modelContext: modelContext).rename(document, to: title)
        } catch {
            errorAlert = ErrorAlert(error)
        }
    }

    func delete(_ document: LibraryDocument, modelContext: ModelContext) {
        do {
            try DocumentStore(modelContext: modelContext).delete(document)
        } catch {
            errorAlert = ErrorAlert(error)
        }
    }

    func delete(at offsets: IndexSet, in documents: [LibraryDocument], modelContext: ModelContext) {
        do {
            try DocumentStore(modelContext: modelContext).delete(documentsAt: offsets, in: documents)
        } catch {
            errorAlert = ErrorAlert(error)
        }
    }

    /// Re-runs OCR over a whole document. Progress is written to the model, so
    /// the row updates itself while this runs.
    func reprocess(_ document: LibraryDocument, modelContext: ModelContext) async {
        let id = document.id
        guard !reprocessingDocumentIDs.contains(id) else { return }
        reprocessingDocumentIDs.insert(id)
        defer { reprocessingDocumentIDs.remove(id) }

        let service = DocumentProcessingService(modelContext: modelContext)
        do {
            try await service.reprocess(document)
        } catch {
            let appError = AppError.wrap(error) { AppError.ocrRequestFailed(reason: $0) }
            if appError != .processingCancelled {
                errorAlert = ErrorAlert(appError)
            }
        }
    }
}
