import Foundation
import Observation
import SwiftData

/// Local keyword search over the library.
@MainActor
@Observable
final class SearchViewModel {
    var query: String = ""
    private(set) var results: [SearchResult] = []
    private(set) var isSearching = false
    private(set) var hasSearched = false
    var errorAlert: ErrorAlert?

    @ObservationIgnored private let engine = SearchEngine()

    var terms: [String] { SearchEngine.terms(from: query) }

    nonisolated init() {}

    /// Reads the library on the main actor (SwiftData requires it), then runs
    /// the matching itself off the main actor on plain value snapshots.
    func runSearch(modelContext: ModelContext) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            hasSearched = false
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            let snapshots = try DocumentStore(modelContext: modelContext).searchSnapshots()
            let engine = self.engine
            let matches = await Task.detached(priority: .userInitiated) {
                engine.search(query: trimmed, in: snapshots)
            }.value
            guard !Task.isCancelled else { return }
            results = matches
            hasSearched = true
        } catch {
            errorAlert = ErrorAlert(error)
            results = []
            hasSearched = true
        }
    }

    func clear() {
        query = ""
        results = []
        hasSearched = false
    }
}
