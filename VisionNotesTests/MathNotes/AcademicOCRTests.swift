import PDFKit
import UIKit
import XCTest
@testable import VisionNotes

final class AcademicOCRTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
        try super.tearDownWithError()
    }

    func testMistralAndVisionRequestConstructionKeepsKeyOutOfBody() throws {
        let key = "request-test-secret"
        let source = Data([0x01, 0x02, 0x03])
        let mistral = try ProviderRequestBuilder.mistralOCR(
            data: source,
            mimeType: "application/pdf",
            key: key
        )

        XCTAssertEqual(mistral.request.url, ProviderRequestBuilder.mistralEndpoint)
        XCTAssertEqual(mistral.request.httpMethod, "POST")
        XCTAssertEqual(mistral.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        let mistralBody = try XCTUnwrap(String(data: mistral.body, encoding: .utf8))
        XCTAssertTrue(mistralBody.contains("data:application/pdf;base64,"))
        XCTAssertTrue(mistralBody.contains(MistralOCRClient.model))
        XCTAssertFalse(mistralBody.contains(key))

        let vision = try ProviderRequestBuilder.siliconFlowVision(
            imageData: source,
            mimeType: "image/png",
            prompt: "transcribe",
            key: key
        )
        let visionBody = try XCTUnwrap(String(data: vision.body, encoding: .utf8))
        XCTAssertTrue(visionBody.contains("data:image/png;base64,"))
        XCTAssertTrue(visionBody.contains(SiliconFlowVisionClient.model))
        XCTAssertFalse(visionBody.contains(key))
    }

    func testRetryableStatusRetriesAndHonorsZeroRetryAfter() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [
            (429, ["Retry-After": "0"], Data()),
            (200, [:], Data("ok".utf8))
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: URL(string: "https://example.invalid/test")!)
        request.httpMethod = "POST"
        let prepared = PreparedProviderRequest(request: request, body: Data("{}".utf8))

        let result = try await RetryingProviderHTTPClient(session: session).upload(prepared)

        XCTAssertEqual(String(data: result, encoding: .utf8), "ok")
        XCTAssertEqual(URLProtocolStub.requestCount, 2)
    }

    func testZeroRetryClientReturnsAfterOneProviderFailure() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [(503, [:], Data())]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: URL(string: "https://example.invalid/test")!)
        request.httpMethod = "POST"
        let prepared = PreparedProviderRequest(request: request, body: Data("{}".utf8))

        await XCTAssertThrowsErrorAsync {
            _ = try await RetryingProviderHTTPClient(
                session: session,
                maximumRetries: 0
            ).upload(prepared)
        }

        XCTAssertEqual(URLProtocolStub.requestCount, 1)
    }

    func testVisionIncompleteErrorExplainsSavedCheckpointCount() {
        let error = MathNoteError.visionRequestsIncomplete(completed: 3, total: 4)

        XCTAssertTrue(error.localizedDescription.contains("3 of 4"))
        XCTAssertTrue(error.localizedDescription.contains("unfinished"))
    }

    func testCropPlannerCoversPageWithOverlapAndCapsTallPages() {
        let portrait = MathCropPlanner.normalizedRects(for: CGSize(width: 1_600, height: 2_200))
        XCTAssertEqual(portrait.count, 3)
        XCTAssertEqual(portrait.first?.minY ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(portrait.last?.maxY ?? -1, 1, accuracy: 0.0001)
        for pair in zip(portrait, portrait.dropFirst()) {
            XCTAssertLessThan(pair.1.minY, pair.0.maxY)
            let overlap = pair.0.maxY - pair.1.minY
            XCTAssertEqual(overlap / pair.0.height, 0.20, accuracy: 0.001)
        }

        let unusuallyTall = MathCropPlanner.normalizedRects(for: CGSize(width: 600, height: 2_400))
        XCTAssertEqual(unusuallyTall.count, MathCropPlanner.maximumCropCount)
        XCTAssertEqual(unusuallyTall.last?.maxY ?? -1, 1, accuracy: 0.0001)
    }

    func testMistralParserSanitizesAndPreservesEveryEmbeddedImageOnce() throws {
        let payload: [String: Any] = [
            "pages": [[
                "markdown": "# Page\n\n![diagram](figure one)",
                "images": [
                    ["id": "figure one", "image_base64": "data:image/png;base64,\(Data("one".utf8).base64EncodedString())"],
                    ["id": "../second figure", "image_base64": "data:image/png;base64,\(Data("two".utf8).base64EncodedString())"]
                ]
            ]]
        ]
        let parsed = try MistralOCRParser.parse(JSONSerialization.data(withJSONObject: payload))

        XCTAssertEqual(parsed.pages.count, 1)
        XCTAssertEqual(parsed.assets.count, 2)
        XCTAssertFalse(parsed.assets.map(\.localName).contains(where: { $0.contains("..") || $0.contains("/") }))
        for asset in parsed.assets {
            XCTAssertEqual(parsed.pages[0].components(separatedBy: "assets/\(asset.localName)").count - 1, 1)
        }
    }

    func testLocalHTMLHasOfflinePolicyMathMLAndClickableContents() throws {
        let directory = makeTemporaryDirectory()
        let markdown = """
        # Algebraic Geometry
        ## Proposition 1
        For $\\bar K \\subseteq \\mathbb K$, $$\\frac{a_1}{b^2} \\le \\infty$$.
        $\\begin{array}{c}
        \\text{diagram with } \\boxed{x^2 = 1} \\\\
        x \\Leftrightarrow y \\mapsto z \\dots
        \\end{array}$
        [unclear: final symbol]
        """
        let html = try AcademicSourceCompiler.standaloneHTML(
            markdown: markdown,
            title: "Fixture",
            assetRoot: directory
        )
        let latex = AcademicSourceCompiler.standaloneLaTeX(markdown: markdown, title: "Fixture")

        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertTrue(html.contains("<math"))
        XCTAssertTrue(html.contains("<mfrac>"))
        XCTAssertTrue(html.contains("<mtable>"))
        XCTAssertTrue(html.contains("<menclose notation=\"box\">"))
        XCTAssertTrue(html.contains("diagram with</mtext><mspace width=\"0.25em\"/>"))
        XCTAssertTrue(html.contains("↦"))
        XCTAssertFalse(html.contains("<p>$\\begin{array}"))
        XCTAssertTrue(html.contains("aria-label=\"Table of contents\""))
        XCTAssertTrue(html.contains("href=\"#section-1\""))
        XCTAssertTrue(html.contains("id=\"section-1\""))
        XCTAssertTrue(latex.contains("\\tableofcontents"))
        XCTAssertTrue(latex.contains("\\usepackage{xeCJK}"))
    }

    func testJobStorePersistsPageOrderAndDeletesExplicitly() async throws {
        let directory = makeTemporaryDirectory()
        let store = MathNoteJobStore(rootURL: directory)
        let job = try await store.createJob(
            title: "Ordered",
            normalizedPages: [Data("first".utf8), Data("second".utf8)]
        )
        _ = try await store.update(job.id, stage: .baseOCR)
        let loaded = try await store.load(job.id)

        XCTAssertEqual(loaded.title, "Ordered")
        XCTAssertEqual(loaded.pages.map(\.index), [0, 1])
        XCTAssertEqual(loaded.pages.map(\.sourcePath), ["pages/page-001.jpg", "pages/page-002.jpg"])
        XCTAssertEqual(loaded.stage, .baseOCR)
        try await store.delete(job.id)
        await XCTAssertThrowsErrorAsync { _ = try await store.load(job.id) }
    }

    func testCachedRebuildUsesOnlyLocalRendererAndProducesArchive() async throws {
        let directory = makeTemporaryDirectory()
        let store = MathNoteJobStore(rootURL: directory)
        let renderer = RendererSpy()
        let pipeline = MathNotePipeline(store: store, renderer: renderer, bundle: .main)
        let job = try await store.createJob(title: "Cached", normalizedPages: [Data("page".utf8)])
        try await store.write("# Cached\n\n$x^2$", relativePath: "edited-source.md", jobID: job.id)

        let rebuilt = try await pipeline.rebuild(jobID: job.id, markdown: "# Edited\n\n$\\frac{1}{2}$")
        let renderCount = await renderer.renderCount
        let archiveExists = await store.exists(relativePath: rebuilt.artifacts.archive, jobID: job.id)
        let editedSource = try await store.readString(relativePath: "edited-source.md", jobID: job.id)

        XCTAssertEqual(rebuilt.stage, .complete)
        XCTAssertEqual(renderCount, 1)
        XCTAssertTrue(archiveExists)
        XCTAssertEqual(editedSource, "# Edited\n\n$\\frac{1}{2}$")
    }

    func testZIPWriterCreatesStandardHeadersAndExcludesCredentialNamedFiles() throws {
        let directory = makeTemporaryDirectory()
        let archiveURL = directory.appendingPathComponent("artifacts.zip")
        let entries = [
            StoredZIPWriter.Entry(path: "document.md", data: Data("# Notes".utf8), modificationDate: .distantPast),
            StoredZIPWriter.Entry(path: "assets/figure.png", data: Data([1, 2, 3]), modificationDate: .distantPast)
        ]
        try StoredZIPWriter.write(entries: entries, to: archiveURL)
        let archive = try Data(contentsOf: archiveURL)

        XCTAssertEqual(Array(archive.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        let text = String(decoding: archive, as: UTF8.self)
        XCTAssertTrue(text.contains("document.md"))
        XCTAssertTrue(text.contains("assets/figure.png"))
        XCTAssertFalse(text.lowercased().contains("providerkeys"))
    }

    func testExactlyOneProviderKeyResourceExistsInBundle() throws {
        let resources = Bundle.main.urls(forResourcesWithExtension: "plist", subdirectory: nil) ?? []
        let providerResources = resources.filter { $0.lastPathComponent == "ProviderKeys.plist" }
        XCTAssertEqual(providerResources.count, 1)

        let data = try Data(contentsOf: XCTUnwrap(providerResources.first))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertNotNil(plist["MistralAPIKey"] as? String)
        XCTAssertNotNil(plist["SiliconFlowAPIKey"] as? String)
    }

    func testNormalizationPreservesOrientationAndFacsimilePageCount() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            UIColor.black.setStroke()
            context.cgContext.stroke(CGRect(x: 20, y: 20, width: 160, height: 260))
        }
        let encoded = try XCTUnwrap(source.jpegData(compressionQuality: 1))
        let normalized = try await MathImagePreprocessor.normalizeSource(encoded)
        let normalizedImage = try XCTUnwrap(UIImage(data: normalized))
        XCTAssertEqual(normalizedImage.imageOrientation, .up)
        XCTAssertEqual(normalizedImage.size.width, 200, accuracy: 1)
        XCTAssertEqual(normalizedImage.size.height, 300, accuracy: 1)

        let pageURL = makeTemporaryDirectory().appendingPathComponent("page.jpg")
        try normalized.write(to: pageURL)
        let pdf = try FacsimilePDFBuilder.makePDF(pageURLs: [pageURL, pageURL])
        XCTAssertEqual(PDFDocument(data: pdf)?.pageCount, 2)
    }

    func testUnclearMarkerCountIsDeterministic() {
        XCTAssertEqual(
            MathNotePipeline.uncertainCount(in: "a [unclear: x] b [UNCLEAR: y or z] c"),
            2
        )
    }

    func testManifestDecodesJobsCreatedBeforeDetailedProgressFields() throws {
        let manifest = MathNoteJobManifest(
            title: "Legacy",
            pages: [MathNotePageRecord(index: 0, sourcePath: "pages/page-001.jpg")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(manifest)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "stageProgress")
        object.removeValue(forKey: "stageDetail")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(MathNoteJobManifest.self, from: legacyData)

        XCTAssertNil(decoded.stageProgress)
        XCTAssertNil(decoded.stageDetail)
        XCTAssertEqual(decoded.displayedProgress, MathNoteStage.draft.progress)
    }

    @MainActor
    func testWebKitRendererProducesSemanticPDFForOfflineMathFixture() async throws {
        let directory = makeTemporaryDirectory()
        let pagesDirectory = directory.appendingPathComponent("pages", isDirectory: true)
        let assetsDirectory = directory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: pagesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            UIColor.black.setStroke()
            context.cgContext.stroke(CGRect(x: 40, y: 40, width: 520, height: 720))
        }
        let pageData = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        try pageData.write(to: pagesDirectory.appendingPathComponent("page-001.jpg"))
        var manifest = MathNoteJobManifest(
            title: "Renderer Smoke Test",
            pages: [MathNotePageRecord(index: 0, sourcePath: "pages/page-001.jpg")]
        )
        manifest.stage = .rendering
        let markdown = """
        # Contents Fixture
        ## Fraction and matrix
        $$\\frac{a_1}{b^2} \\le \\infty$$

        $$\\begin{pmatrix}1 & 0 \\\\ 0 & 1\\end{pmatrix}$$

        中文注释 and $\\bar K \\subseteq \\mathbb K$.
        """

        try await AcademicDocumentRenderer().render(
            markdown: markdown,
            manifest: manifest,
            jobDirectory: directory
        )

        let pdfURL = directory.appendingPathComponent(manifest.artifacts.pdf)
        let archiveURL = directory.appendingPathComponent(manifest.artifacts.archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))
        XCTAssertGreaterThan(try Data(contentsOf: pdfURL).count, 1_000)
        XCTAssertGreaterThan(PDFDocument(url: pdfURL)?.pageCount ?? 0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionNotesTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }
}

private actor RendererSpy: AcademicDocumentRendering {
    private(set) var renderCount = 0

    func render(markdown: String, manifest: MathNoteJobManifest, jobDirectory: URL) async throws {
        renderCount += 1
        try Data(markdown.utf8).write(
            to: jobDirectory.appendingPathComponent(manifest.artifacts.markdown),
            options: .atomic
        )
    }
}

private final class URLProtocolStub: URLProtocol {
    static var responses: [(Int, [String: String], Data)] = []
    static var requestCount = 0
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        responses = []
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let index = min(Self.requestCount, max(Self.responses.count - 1, 0))
        Self.requestCount += 1
        let response = Self.responses[index]
        Self.lock.unlock()
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.0,
            httpVersion: "HTTP/1.1",
            headerFields: response.1
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.2)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
