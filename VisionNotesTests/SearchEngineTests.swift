import XCTest
@testable import VisionNotes

final class SearchEngineTests: XCTestCase {

    private let engine = SearchEngine()
    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    private func document(
        title: String,
        type: DocumentType = .photo,
        updatedAt: Date? = nil,
        pages: [String]
    ) -> SearchDocumentSnapshot {
        SearchDocumentSnapshot(
            id: UUID(),
            title: title,
            documentType: type,
            updatedAt: updatedAt ?? reference,
            pages: pages.enumerated().map { index, text in
                SearchPageSnapshot(id: UUID(), pageNumber: index + 1, text: text)
            }
        )
    }

    // MARK: - Query parsing

    func testTermsTrimsAndLowercasesAndDropsEmpties() {
        XCTAssertEqual(SearchEngine.terms(from: "  Eigen  VALUE \n "), ["eigen", "value"])
        XCTAssertTrue(SearchEngine.terms(from: "   ").isEmpty)
    }

    func testEmptyQueryReturnsNoResults() {
        let documents = [document(title: "Notes", pages: ["anything"])]
        XCTAssertTrue(engine.search(query: "   ", in: documents).isEmpty)
    }

    // MARK: - Matching

    func testSearchIgnoresCase() {
        let documents = [document(title: "Lecture", pages: ["Eigenvalues and eigenvectors"])]
        XCTAssertEqual(engine.search(query: "EIGENVALUES", in: documents).count, 1)
        XCTAssertEqual(engine.search(query: "eigenvalues", in: documents).count, 1)
    }

    func testSearchIgnoresSurroundingWhitespace() {
        let documents = [document(title: "Lecture", pages: ["Eigenvalues"])]
        XCTAssertEqual(engine.search(query: "   eigenvalues   ", in: documents).count, 1)
    }

    func testChineseKeywordSearch() {
        let documents = [
            document(title: "线性代数 课堂笔记", pages: ["矩阵 A 的特征值满足 det(A - λI) = 0。"]),
            document(title: "English only", pages: ["nothing relevant here"])
        ]
        let results = engine.search(query: "特征值", in: documents)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.documentTitle, "线性代数 课堂笔记")
        XCTAssertEqual(results.first?.pageNumber, 1)
    }

    func testChineseTitleSearchMatchesWithoutBodyHit() {
        let documents = [document(title: "课堂笔记", pages: ["no chinese in the body"])]
        let results = engine.search(query: "课堂", in: documents)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.matchKind, .titlePartial)
    }

    func testMultipleKeywordsMustAllAppear() {
        let documents = [
            document(title: "Both", pages: ["alpha and beta live here"]),
            document(title: "One", pages: ["alpha only"])
        ]
        let results = engine.search(query: "alpha beta", in: documents)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.documentTitle, "Both")
    }

    func testKeywordsMayAppearInAnyOrder() {
        let documents = [document(title: "Notes", pages: ["beta comes before alpha"])]
        XCTAssertEqual(engine.search(query: "alpha beta", in: documents).count, 1)
    }

    func testMatchesEveryPageThatContainsTheTerms() {
        let documents = [
            document(title: "Report", pages: ["vision on page one", "nothing", "vision again on page three"])
        ]
        let results = engine.search(query: "vision", in: documents)
        XCTAssertEqual(results.map(\.pageNumber), [1, 3])
    }

    // MARK: - Ranking

    func testExactTitleMatchOutranksBodyMatches() {
        let bodyHeavy = document(title: "Random", pages: ["vision vision vision vision"])
        let exactTitle = document(title: "Vision", pages: ["unrelated text"])
        let results = engine.search(query: "vision", in: [bodyHeavy, exactTitle])
        XCTAssertEqual(results.first?.documentTitle, "Vision")
        XCTAssertEqual(results.first?.matchKind, .titleExact)
    }

    func testPartialTitleMatchOutranksBodyOnlyMatch() {
        let bodyOnly = document(title: "Random", pages: ["vision appears twice: vision"])
        let partialTitle = document(title: "Vision Notes Draft", pages: ["unrelated"])
        let results = engine.search(query: "vision", in: [bodyOnly, partialTitle])
        XCTAssertEqual(results.first?.documentTitle, "Vision Notes Draft")
    }

    func testMoreBodyMatchesRankHigher() {
        let few = document(title: "A", pages: ["ocr"])
        let many = document(title: "B", pages: ["ocr ocr ocr"])
        let results = engine.search(query: "ocr", in: [few, many])
        XCTAssertEqual(results.first?.documentTitle, "B")
    }

    func testMostRecentlyUpdatedWinsWhenScoresTie() {
        let older = document(title: "Older", updatedAt: reference, pages: ["ocr"])
        let newer = document(title: "Newer", updatedAt: reference.addingTimeInterval(60), pages: ["ocr"])
        let results = engine.search(query: "ocr", in: [older, newer])
        XCTAssertEqual(results.first?.documentTitle, "Newer")
    }

    // MARK: - Snippets

    func testSnippetIsBuiltAroundTheFirstMatchAndHighlightsIt() {
        let text = String(repeating: "padding ", count: 20) + "needle" + String(repeating: " trailing", count: 20)
        let snippet = engine.snippet(in: text, terms: ["needle"])

        XCTAssertTrue(snippet.text.contains("needle"))
        XCTAssertTrue(snippet.text.hasPrefix("…"))
        XCTAssertTrue(snippet.text.hasSuffix("…"))
        XCTAssertEqual(snippet.highlightRanges.count, 1)
        let highlighted = snippet.highlightRanges.map { String(snippet.text[$0]) }
        XCTAssertEqual(highlighted, ["needle"])
    }

    func testShortTextSnippetHasNoEllipsis() {
        let snippet = engine.snippet(in: "a short line with vision in it", terms: ["vision"])
        XCTAssertEqual(snippet.text, "a short line with vision in it")
        XCTAssertEqual(snippet.highlightRanges.count, 1)
    }

    func testSnippetCollapsesNewlinesIntoOneLine() {
        let snippet = engine.snippet(in: "first line\nsecond vision line", terms: ["vision"])
        XCTAssertFalse(snippet.text.contains("\n"))
        XCTAssertTrue(snippet.text.contains("first line second vision line"))
    }

    func testSnippetHighlightsEveryOccurrenceOfEveryTerm() {
        let snippet = engine.snippet(in: "alpha beta alpha", terms: ["alpha", "beta"])
        XCTAssertEqual(snippet.highlightRanges.count, 3)
    }

    func testSnippetHighlightIsCaseInsensitive() {
        let snippet = engine.snippet(in: "Vision and vision", terms: ["vision"])
        XCTAssertEqual(snippet.highlightRanges.count, 2)
    }

    func testChineseSnippetHighlight() {
        let snippet = engine.snippet(in: "矩阵的特征值和特征向量", terms: ["特征"])
        XCTAssertEqual(snippet.highlightRanges.count, 2)
    }

    func testOccurrenceCounting() {
        XCTAssertEqual(engine.occurrences(of: "ab", in: "abab ab"), 3)
        XCTAssertEqual(engine.occurrences(of: "zz", in: "abab"), 0)
        XCTAssertEqual(engine.occurrences(of: "", in: "abab"), 0)
    }
}
