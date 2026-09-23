import CryptoKit
import Foundation
import Observation
import PDFKit
import UIKit
import XCTest
@testable import VisionNotes

final class AcademicOCRTests: XCTestCase {
    func testLocalFencedEquationsRenderAsMathInsteadOfSourceCode() throws {
        let generated = ["```latex", #"\begin{align*}"#, #"a &= b \\"#, "c &= d", #"\end{align*}"#, "```"].joined(separator: "\n")
        let markdown = FirebirdLocalModel.normalizeMarkdown(generated)
        XCTAssertTrue(markdown.hasPrefix("$$\n\\begin{aligned}"))
        XCTAssertFalse(markdown.contains("```"))
        let html = try AcademicSourceCompiler.standaloneHTML(markdown: markdown, title: "Test", assetRoot: FileManager.default.temporaryDirectory)
        XCTAssertTrue(html.contains("<mtable>"))
        XCTAssertTrue(html.contains("<mi>a</mi>"))
        XCTAssertTrue(html.contains("<mi>d</mi>"))
        let incomplete = "```latex\n\\begin{align*}\na=b"
        XCTAssertEqual(FirebirdLocalModel.normalizeMarkdown(incomplete), incomplete)
    }

    func testExportPathsResolveContainerAliasesAndRejectEscapes() throws {
        let parent = makeTemporaryDirectory()
        let real = parent.appendingPathComponent("real", isDirectory: true)
        let alias = parent.appendingPathComponent("alias", isDirectory: true)
        let page = real.appendingPathComponent("pages/page-001.jpg")
        try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: page)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        XCTAssertEqual(try StorageRelativePath.path(of: page, under: alias), "pages/page-001.jpg")
        XCTAssertEqual(try StoredZIPWriter.entries(in: alias).map(\.path), ["pages/page-001.jpg"])
        XCTAssertThrowsError(try StorageRelativePath.path(of: parent.appendingPathComponent("outside"), under: alias))
    }

    func testAliasedJobRootCanPrepareEncryptedExports() async throws {
        let parent = makeTemporaryDirectory()
        let real = parent.appendingPathComponent("jobs", isDirectory: true)
        let alias = parent.appendingPathComponent("jobs-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let store = MathNoteJobStore(rootURL: alias)
        let page = Data("private source page".utf8)
        let job = try await store.createJob(title: "Alias regression", normalizedPages: [page])
        try await store.write("$x=1$", relativePath: "machine-source.md", jobID: job.id)
        let work = try await store.workingDirectory(for: job.id)
        defer { try? FileManager.default.removeItem(at: work) }
        XCTAssertEqual(try Data(contentsOf: work.appendingPathComponent(job.pages[0].sourcePath)), page)
        let entries = try StoredZIPWriter.entries(in: work)
        XCTAssertTrue(entries.contains { $0.path == "machine-source.md" })
        try await store.absorbWorkingDirectory(work, jobID: job.id)
        let reopened = try await store.read(relativePath: job.pages[0].sourcePath, jobID: job.id)
        XCTAssertEqual(reopened, page)
    }

    @MainActor
    func testCompletedJobReopensEncryptedSourcePreview() async throws {
        let store = MathNoteJobStore(rootURL: makeTemporaryDirectory())
        let page = Data("saved page".utf8)
        let job = try await store.createJob(title: "Preview", normalizedPages: [page])
        try await store.write("$x=1$", relativePath: "machine-source.md", jobID: job.id)
        _ = try await store.update(job.id, stage: .complete)
        let model = MathNotesViewModel(store: store)
        await model.selectJob(job.id)
        XCTAssertEqual(model.selectedSource, "$x=1$")
        XCTAssertFalse(model.isWorking)
        let url = try XCTUnwrap(model.sourcePageURLs().first)
        XCTAssertEqual(try Data(contentsOf: url), page)
        model.releaseMaterializedPreview(for: job.id)
    }

    @MainActor
    func testWorkingStateNotifiesWhenTaskFinishes() async throws {
        let store = MathNoteJobStore(rootURL: makeTemporaryDirectory())
        let job = try await store.createJob(title: "Task state", normalizedPages: [Data("page".utf8)])
        // A missing saved job fails before inference or any network request.
        try await store.delete(job.id)
        let model = MathNotesViewModel(store: store)
        model.resume(job)
        XCTAssertTrue(model.isWorking)
        let finished = expectation(description: "Working state changes when task finishes")
        withObservationTracking {
            _ = model.isWorking
        } onChange: {
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertFalse(model.isWorking)
    }

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
        let mistralJSON = try JSONSerialization.jsonObject(with: mistral.body) as! [String: Any]
        let document = mistralJSON["document"] as! [String: Any]
        XCTAssertTrue((document["document_url"] as? String)?.hasPrefix("data:application/pdf;base64,") == true)
        XCTAssertTrue(mistralBody.contains(MistralOCRClient.model))
        XCTAssertFalse(mistralBody.contains(key))

        let vision = try ProviderRequestBuilder.siliconFlowVision(
            imageData: source,
            mimeType: "image/png",
            prompt: "transcribe",
            key: key
        )
        let visionBody = try XCTUnwrap(String(data: vision.body, encoding: .utf8))
        let visionJSON = try JSONSerialization.jsonObject(with: vision.body) as! [String: Any]
        XCTAssertEqual(visionJSON["model"] as? String, SiliconFlowVisionClient.model)
        let messages = visionJSON["messages"] as! [[String: Any]]
        let content = messages.last!["content"] as! [[String: Any]]
        let image = content.first { $0["type"] as? String == "image_url" }!["image_url"] as! [String: Any]
        XCTAssertTrue((image["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
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
        XCTAssertFalse(loaded.allowsCloudFallback)
        let persistedPage = directory
            .appendingPathComponent(job.id.uuidString.lowercased())
            .appendingPathComponent("pages/page-001.jpg")
        let ciphertext = try Data(contentsOf: persistedPage)
        XCTAssertTrue(ciphertext.starts(with: EncryptedDataVault.header))
        XCTAssertFalse(String(decoding: ciphertext, as: UTF8.self).contains("first"))
        try await store.delete(job.id)
        await XCTAssertThrowsErrorAsync { _ = try await store.load(job.id) }
    }

    func testAwaitingConsentPurgesDecryptedJobFiles() async throws {
        let directory = makeTemporaryDirectory()
        let store = MathNoteJobStore(rootURL: directory)
        let job = try await store.createJob(
            title: "Temporary cleanup",
            normalizedPages: [Data("page".utf8)]
        )
        let materialized = try await store.materializedDirectory(for: job.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: materialized.path))

        _ = try await store.update(job.id, stage: .awaitingCloudConsent)

        XCTAssertFalse(FileManager.default.fileExists(atPath: materialized.path))
        let persistedPage = try await store.read(
            relativePath: "pages/page-001.jpg",
            jobID: job.id
        )
        XCTAssertEqual(persistedPage, Data("page".utf8))
    }

    func testPreviewReleaseCannotDeleteRendererWorkOrANewerPreview() async throws {
        let directory = makeTemporaryDirectory()
        let store = MathNoteJobStore(rootURL: directory)
        let job = try await store.createJob(
            title: "Preview ownership",
            normalizedPages: [Data("page".utf8)]
        )

        let firstPreview = try await store.materializedDirectory(for: job.id)
        let workDirectory = try await store.workingDirectory(for: job.id)
        let secondPreview = try await store.materializedDirectory(for: job.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPreview.path))

        await store.releaseMaterializedPreview(for: job.id, expectedURL: firstPreview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPreview.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workDirectory.path))

        await store.releaseMaterializedPreview(for: job.id, expectedURL: secondPreview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondPreview.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workDirectory.path))
        try FileManager.default.removeItem(at: workDirectory)
    }

    func testTypedLocalFailureAwaitsConsentAndPreservesCheckpointAndError() async throws {
        let directory = makeTemporaryDirectory()
        let store = MathNoteJobStore(rootURL: directory)
        let pageData = try makeBlankPageData()
        let job = try await store.createJob(
            title: "Consent boundary",
            normalizedPages: [pageData, pageData]
        )
        let cachedPage = MathNotePageRefinement(
            pageIndex: 0,
            provider: "On-device",
            model: FirebirdLocalModel.modelIdentifier,
            overviewTranscript: "cached local evidence",
            overviewUsage: nil,
            crops: [],
            mergeTranscript: "# Cached local result",
            mergeUsage: nil,
            finalMarkdown: "# Cached local result"
        )
        let cachedData = try JSONEncoder().encode(cachedPage)
        try await store.write(
            cachedData,
            relativePath: "firebird-qwen3vl-9c4f5209-input-v2-page-001.json",
            jobID: job.id
        )
        let renderer = RendererSpy()
        let pipeline = MathNotePipeline(
            store: store,
            renderer: renderer,
            localReconstructor: { _ in throw MathNoteError.localInferenceUnavailable }
        )

        do {
            _ = try await pipeline.run(jobID: job.id)
            XCTFail("Expected the local model failure to pause for consent")
        } catch {
            XCTAssertEqual(error as? MathNoteError, .localInferenceUnavailable)
        }

        let paused = try await store.load(job.id)
        let preservedCheckpoint = try await store.read(
            relativePath: "firebird-qwen3vl-9c4f5209-input-v2-page-001.json",
            jobID: job.id
        )
        let cloudOCRExists = await store.exists(relativePath: "cloud-ocr.json", jobID: job.id)
        let renderCount = await renderer.renderCount
        XCTAssertEqual(paused.stage, .awaitingCloudConsent)
        XCTAssertFalse(paused.allowsCloudFallback)
        XCTAssertEqual(paused.failureMessage, MathNoteError.localInferenceUnavailable.localizedDescription)
        XCTAssertEqual(paused.stageDetail, "Local state saved · nothing uploaded")
        XCTAssertEqual(preservedCheckpoint, cachedData)
        XCTAssertFalse(cloudOCRExists)
        XCTAssertEqual(renderCount, 0)
    }

    func testNonAvailabilityLocalErrorRemainsFailedAndCannotRequestCloudConsent() async throws {
        let directory = makeTemporaryDirectory()
        let store = MathNoteJobStore(rootURL: directory)
        let job = try await store.createJob(
            title: "Integrity boundary",
            normalizedPages: [try makeBlankPageData()]
        )
        let pipeline = MathNotePipeline(
            store: store,
            renderer: RendererSpy(),
            localReconstructor: { _ in throw MathNoteError.invalidImage }
        )

        await XCTAssertThrowsErrorAsync { _ = try await pipeline.run(jobID: job.id) }

        let failed = try await store.load(job.id)
        let cloudOCRExists = await store.exists(relativePath: "cloud-ocr.json", jobID: job.id)
        XCTAssertEqual(failed.stage, .failed)
        XCTAssertNotEqual(failed.stage, .awaitingCloudConsent)
        XCTAssertFalse(failed.allowsCloudFallback)
        XCTAssertFalse(cloudOCRExists)
    }

    func testCloudFallbackAuthorizationIsOneShot() async throws {
        let directory = makeTemporaryDirectory()
        let store = MathNoteJobStore(rootURL: directory)
        let job = try await store.createJob(
            title: "One-shot cloud authorization",
            normalizedPages: [Data("page".utf8)]
        )

        _ = try await store.setCloudFallbackConsent(job.id, allowed: true)
        let consumed = try await store.consumeCloudFallbackConsent(job.id)

        XCTAssertFalse(consumed.allowsCloudFallback)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.consumeCloudFallbackConsent(job.id)
        }
    }

    func testPersistedFlagAloneCannotAuthorizeAnUpload() async throws {
        let directory = makeTemporaryDirectory()
        let store = MathNoteJobStore(rootURL: directory)
        let job = try await store.createJob(
            title: "Stale authorization",
            normalizedPages: [try makeBlankPageData()]
        )
        _ = try await store.setCloudFallbackConsent(job.id, allowed: true)
        let pipeline = MathNotePipeline(
            store: store,
            renderer: RendererSpy(),
            localReconstructor: { _ in throw MathNoteError.localInferenceUnavailable }
        )

        await XCTAssertThrowsErrorAsync { _ = try await pipeline.run(jobID: job.id) }

        let paused = try await store.load(job.id)
        let cloudOCRExists = await store.exists(relativePath: "cloud-ocr.json", jobID: job.id)
        XCTAssertEqual(paused.stage, .awaitingCloudConsent)
        XCTAssertFalse(paused.allowsCloudFallback)
        XCTAssertFalse(cloudOCRExists)
    }

    func testCancelledRetryClearsUnusedCloudAuthorization() async throws {
        let directory = makeTemporaryDirectory()
        let store = MathNoteJobStore(rootURL: directory)
        let job = try await store.createJob(
            title: "Cancelled authorization",
            normalizedPages: [try makeBlankPageData()]
        )
        _ = try await store.setCloudFallbackConsent(job.id, allowed: true)
        let pipeline = MathNotePipeline(
            store: store,
            renderer: RendererSpy(),
            localReconstructor: { _ in throw CancellationError() }
        )

        await XCTAssertThrowsErrorAsync { _ = try await pipeline.run(jobID: job.id) }

        let cancelled = try await store.load(job.id)
        XCTAssertEqual(cancelled.stage, .cancelled)
        XCTAssertFalse(cancelled.allowsCloudFallback)
    }

    func testCachedRebuildUsesOnlyLocalRendererAndProducesArchive() async throws {
        let directory = makeTemporaryDirectory()
        let store = MathNoteJobStore(rootURL: directory)
        let renderer = RendererSpy()
        let pipeline = MathNotePipeline(store: store, renderer: renderer)
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

    func testProviderKeysAreNotBundledAsPlistResources() throws {
        let resources = Bundle.main.urls(forResourcesWithExtension: "plist", subdirectory: nil) ?? []
        let providerResources = resources.filter { $0.lastPathComponent == "ProviderKeys.plist" }
        XCTAssertTrue(providerResources.isEmpty)
    }

    func testAESGCMVaultAuthenticatesPathAndRejectsTampering() throws {
        let key = SymmetricKey(data: Data(repeating: 0x4f, count: 32))
        let vault = EncryptedDataVault(keyProvider: { key })
        let plaintext = Data("private theorem notes".utf8)
        let sealed = try vault.seal(plaintext, context: "notes/a")

        XCTAssertTrue(sealed.starts(with: EncryptedDataVault.header))
        XCTAssertEqual(try vault.open(sealed, context: "notes/a"), plaintext)
        XCTAssertThrowsError(try vault.open(sealed, context: "notes/b"))

        var tampered = sealed
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        XCTAssertThrowsError(try vault.open(tampered, context: "notes/a"))
    }

    func testNormalizationPreservesOrientationAndFacsimilePageCount() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            UIColor.black.setStroke()
            context.cgContext.move(to: CGPoint(x: 20, y: 20))
            context.cgContext.addLine(to: CGPoint(x: 180, y: 280))
            context.cgContext.strokePath()
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
        object.removeValue(forKey: "cloudFallbackAllowed")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(MathNoteJobManifest.self, from: legacyData)

        XCTAssertNil(decoded.stageProgress)
        XCTAssertNil(decoded.stageDetail)
        XCTAssertEqual(decoded.displayedProgress, MathNoteStage.draft.progress)
    }

    @MainActor
    func testWebKitRendererProducesOfflinePDFFromMathFixture() async throws {
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
        let markdownURL = directory.appendingPathComponent(manifest.artifacts.markdown)
        let latexURL = directory.appendingPathComponent(manifest.artifacts.latex)
        let htmlURL = directory.appendingPathComponent(manifest.artifacts.html)
        let archiveURL = directory.appendingPathComponent(manifest.artifacts.archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markdownURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: latexURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: htmlURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))
        XCTAssertGreaterThan(try Data(contentsOf: pdfURL).count, 1_000)
        XCTAssertGreaterThan(PDFDocument(url: pdfURL)?.pageCount ?? 0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        XCTAssertTrue(html.contains("<math "))
        XCTAssertTrue(html.contains("<mfrac>"))
        let archive = String(decoding: try Data(contentsOf: archiveURL), as: UTF8.self)
        XCTAssertTrue(archive.contains(manifest.artifacts.html))
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionNotesTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeBlankPageData() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 160), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 160))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
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
