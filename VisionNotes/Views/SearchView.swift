import SwiftData
import SwiftUI

@MainActor
struct SearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var documents: [LibraryDocument]
    @State private var viewModel = SearchViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.results.isEmpty {
                    placeholder
                } else {
                    resultList
                }
            }
            .navigationTitle("Search")
            .searchable(
                text: $viewModel.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search titles and recognized text"
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .task(id: viewModel.query) {
                // Small debounce so typing does not re-scan the library on
                // every keystroke.
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await viewModel.runSearch(modelContext: modelContext)
            }
            .errorAlert($viewModel.errorAlert)
        }
    }

    // MARK: - Content

    private var resultList: some View {
        List(viewModel.results) { result in
            if let document = document(for: result) {
                NavigationLink {
                    DocumentReaderView(
                        document: document,
                        initialPageNumber: result.pageNumber,
                        highlightTerms: viewModel.terms
                    )
                } label: {
                    SearchResultRow(result: result)
                }
            } else {
                SearchResultRow(result: result)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("searchResultsList")
    }

    @ViewBuilder
    private var placeholder: some View {
        if viewModel.isSearching {
            ProgressView("Searching…")
        } else if viewModel.hasSearched {
            ContentUnavailableView.search(text: viewModel.query)
        } else {
            ContentUnavailableView {
                Label("Search your notes", systemImage: "magnifyingglass")
            } description: {
                Text("Find any word from a title or from the text recognized on a page. Search is case insensitive and works in English and Chinese. Multiple words must all appear.")
            }
        }
    }

    private func document(for result: SearchResult) -> LibraryDocument? {
        documents.first { $0.id == result.documentID }
    }
}

struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(result.documentTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                SourceTypeBadge(type: result.documentType)
            }

            if let pageNumber = result.pageNumber {
                Text("Page \(pageNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if result.snippet.text.isEmpty {
                Text("Title match")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            } else {
                HighlightedText(snippet: result.snippet)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    SearchView()
        .modelContainer(ModelContainerProvider.makeContainer(inMemory: true).container)
}
