import Foundation

/// A page, flattened out of SwiftData so search can run on plain values.
struct SearchPageSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let pageNumber: Int
    let text: String
}

/// A document, flattened out of SwiftData so search can run on plain values.
struct SearchDocumentSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let documentType: DocumentType
    let updatedAt: Date
    let pages: [SearchPageSnapshot]
}

/// A snippet of text plus the ranges inside it that matched the query.
struct TextSnippet: Hashable, Sendable {
    let text: String
    let highlightRanges: [Range<String.Index>]

    static let empty = TextSnippet(text: "", highlightRanges: [])
}

struct SearchResult: Identifiable, Hashable, Sendable {
    enum MatchKind: Hashable, Sendable {
        case titleExact
        case titlePartial
        case body
    }

    let id: String
    let documentID: UUID
    let documentTitle: String
    let documentType: DocumentType
    let pageID: UUID?
    let pageNumber: Int?
    let snippet: TextSnippet
    let matchKind: MatchKind
}

/// Local keyword search over document titles and recognized page text.
///
/// Everything here is plain string work on in-memory snapshots: no FTS index,
/// no embeddings, no network. It is fast enough for a personal library and it
/// always searches the text the user currently sees, including manual edits.
struct SearchEngine: Sendable {
    /// Characters of context kept on each side of the first match.
    var contextRadius: Int
    private let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    init(contextRadius: Int = 48) {
        self.contextRadius = contextRadius
    }

    // MARK: - Query parsing

    /// Splits a raw query into search terms: trimmed, lowercased, no empties.
    static func terms(from query: String) -> [String] {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    // MARK: - Search

    func search(query: String, in documents: [SearchDocumentSnapshot]) -> [SearchResult] {
        let terms = Self.terms(from: query)
        guard !terms.isEmpty else { return [] }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        struct Scored {
            let document: SearchDocumentSnapshot
            let titleRank: Int
            let bodyMatchCount: Int
            let results: [SearchResult]
        }

        var scored: [Scored] = []

        for document in documents {
            let titleRank = titleRank(for: document.title, query: normalizedQuery, terms: terms)
            let matchingPages = document.pages
                .filter { page in containsAllTerms(page.text, terms: terms) }
                .sorted { $0.pageNumber < $1.pageNumber }

            let bodyMatchCount = document.pages.reduce(0) { total, page in
                total + terms.reduce(0) { $0 + occurrences(of: $1, in: page.text) }
            }

            var results: [SearchResult] = matchingPages.map { page in
                SearchResult(
                    id: "\(document.id.uuidString)#\(page.id.uuidString)",
                    documentID: document.id,
                    documentTitle: document.title,
                    documentType: document.documentType,
                    pageID: page.id,
                    pageNumber: page.pageNumber,
                    snippet: snippet(in: page.text, terms: terms),
                    matchKind: .body
                )
            }

            if results.isEmpty, titleRank < 2 {
                // Title-only hit: still show the document, previewing page one.
                let firstPage = document.pages.min { $0.pageNumber < $1.pageNumber }
                results = [
                    SearchResult(
                        id: "\(document.id.uuidString)#title",
                        documentID: document.id,
                        documentTitle: document.title,
                        documentType: document.documentType,
                        pageID: firstPage?.id,
                        pageNumber: firstPage?.pageNumber,
                        snippet: previewSnippet(in: firstPage?.text ?? ""),
                        matchKind: titleRank == 0 ? .titleExact : .titlePartial
                    )
                ]
            }

            guard !results.isEmpty else { continue }
            scored.append(
                Scored(
                    document: document,
                    titleRank: titleRank,
                    bodyMatchCount: bodyMatchCount,
                    results: results
                )
            )
        }

        // Title matches first, then documents with more body matches, then the
        // most recently updated.
        scored.sort { lhs, rhs in
            if lhs.titleRank != rhs.titleRank { return lhs.titleRank < rhs.titleRank }
            if lhs.bodyMatchCount != rhs.bodyMatchCount { return lhs.bodyMatchCount > rhs.bodyMatchCount }
            if lhs.document.updatedAt != rhs.document.updatedAt {
                return lhs.document.updatedAt > rhs.document.updatedAt
            }
            return lhs.document.id.uuidString < rhs.document.id.uuidString
        }

        return scored.flatMap(\.results)
    }

    // MARK: - Matching primitives

    func contains(_ term: String, in text: String) -> Bool {
        guard !term.isEmpty else { return false }
        return text.range(of: term, options: matchOptions) != nil
    }

    func containsAllTerms(_ text: String, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        return terms.allSatisfy { contains($0, in: text) }
    }

    /// Number of non-overlapping occurrences of `term` in `text`.
    func occurrences(of term: String, in text: String) -> Int {
        guard !term.isEmpty else { return 0 }
        var count = 0
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: term, options: matchOptions, range: searchStart..<text.endIndex) {
            count += 1
            searchStart = range.upperBound > range.lowerBound
                ? range.upperBound
                : text.index(after: range.lowerBound)
        }
        return count
    }

    /// All match ranges of every term, sorted by position.
    func highlightRanges(in text: String, terms: [String]) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: term, options: matchOptions, range: searchStart..<text.endIndex) {
                ranges.append(range)
                searchStart = range.upperBound > range.lowerBound
                    ? range.upperBound
                    : text.index(after: range.lowerBound)
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    // MARK: - Snippets

    /// Builds a context snippet around the first match, with the ranges of every
    /// term occurrence inside that snippet.
    func snippet(in text: String, terms: [String]) -> TextSnippet {
        let flattened = flatten(text)
        guard !flattened.isEmpty else { return .empty }

        let firstMatch = terms
            .compactMap { flattened.range(of: $0, options: matchOptions) }
            .min { $0.lowerBound < $1.lowerBound }

        guard let firstMatch else { return previewSnippet(in: text) }

        let lower = flattened.index(firstMatch.lowerBound, offsetBy: -contextRadius, limitedBy: flattened.startIndex)
            ?? flattened.startIndex
        let upper = flattened.index(firstMatch.upperBound, offsetBy: contextRadius, limitedBy: flattened.endIndex)
            ?? flattened.endIndex

        var body = String(flattened[lower..<upper])
        let prefix = lower > flattened.startIndex ? "…" : ""
        let suffix = upper < flattened.endIndex ? "…" : ""
        body = prefix + body + suffix

        return TextSnippet(text: body, highlightRanges: highlightRanges(in: body, terms: terms))
    }

    /// Leading text with no highlighting, used for title-only matches.
    func previewSnippet(in text: String, maxLength: Int = 120) -> TextSnippet {
        let flattened = flatten(text)
        guard flattened.count > maxLength else {
            return TextSnippet(text: flattened, highlightRanges: [])
        }
        return TextSnippet(text: String(flattened.prefix(maxLength)) + "…", highlightRanges: [])
    }

    // MARK: - Private

    private func titleRank(for title: String, query: String, terms: [String]) -> Int {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedTitle.compare(query, options: matchOptions) == .orderedSame { return 0 }
        if containsAllTerms(normalizedTitle, terms: terms) { return 1 }
        return 2
    }

    /// Collapses newlines and runs of spaces so snippets read as one line.
    private func flatten(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
