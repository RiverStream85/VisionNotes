import Foundation
import UIKit
@preconcurrency import WebKit

protocol AcademicDocumentRendering: Sendable {
    func render(markdown: String, manifest: MathNoteJobManifest, jobDirectory: URL) async throws
}

struct AcademicDocumentRenderer: AcademicDocumentRendering {
    static let semanticPDFMaximumBytes = 80 * 1_024 * 1_024

    func render(markdown: String, manifest: MathNoteJobManifest, jobDirectory: URL) async throws {
        try Task.checkCancellation()
        let artifacts = manifest.artifacts
        let html = try AcademicSourceCompiler.standaloneHTML(
            markdown: markdown,
            title: manifest.title,
            assetRoot: jobDirectory
        )
        let latex = AcademicSourceCompiler.standaloneLaTeX(markdown: markdown, title: manifest.title)

        try write(markdown, to: jobDirectory.appendingPathComponent(artifacts.markdown))
        try write(latex, to: jobDirectory.appendingPathComponent(artifacts.latex))
        try write(html, to: jobDirectory.appendingPathComponent(artifacts.html))

        let pageURLs = manifest.pages.sorted { $0.index < $1.index }.map {
            jobDirectory.appendingPathComponent($0.sourcePath)
        }
        let pageData = try pageURLs.map { try Data(contentsOf: $0, options: [.mappedIfSafe]) }
        try write(
            AcademicSourceCompiler.facsimileHTML(title: manifest.title, pageData: pageData),
            to: jobDirectory.appendingPathComponent(artifacts.facsimileHTML)
        )
        try write(
            AcademicSourceCompiler.facsimileLaTeX(title: manifest.title, pageCount: pageData.count),
            to: jobDirectory.appendingPathComponent(artifacts.facsimileLatex)
        )

        let facsimileURL = jobDirectory.appendingPathComponent(artifacts.facsimilePDF)
        try await Task.detached(priority: .userInitiated) {
            let data = try FacsimilePDFBuilder.makePDF(pageURLs: pageURLs)
            try data.write(to: facsimileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        }.value

        try Task.checkCancellation()
        let htmlURL = jobDirectory.appendingPathComponent(artifacts.html)
        let pdfData = try await SemanticWebKitPDFRenderer().render(
            htmlURL: htmlURL,
            readAccessURL: jobDirectory
        )
        guard pdfData.count <= Self.semanticPDFMaximumBytes else { throw MathNoteError.renderTooLarge }
        try pdfData.write(
            to: jobDirectory.appendingPathComponent(artifacts.pdf),
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )

        try Task.checkCancellation()
        try await Task.detached(priority: .utility) {
            let entries = try StoredZIPWriter.entries(
                in: jobDirectory,
                excludingNames: [artifacts.archive]
            )
            try StoredZIPWriter.write(
                entries: entries,
                to: jobDirectory.appendingPathComponent(artifacts.archive)
            )
        }.value
    }

    private func write(_ string: String, to url: URL) throws {
        guard let data = string.data(using: .utf8) else {
            throw MathNoteError.message("A document could not be encoded as UTF-8.")
        }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

enum FacsimilePDFBuilder {
    static func makePDF(pageURLs: [URL]) throws -> Data {
        guard !pageURLs.isEmpty else { throw MathNoteError.emptyDraft }
        let pageBounds = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        return renderer.pdfData { context in
            for url in pageURLs {
                if Task.isCancelled { return }
                guard let image = UIImage(contentsOfFile: url.path) else { continue }
                context.beginPage()
                UIColor.white.setFill()
                context.fill(pageBounds)
                let inset = pageBounds.insetBy(dx: 10, dy: 10)
                let scale = min(inset.width / image.size.width, inset.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let rect = CGRect(
                    x: pageBounds.midX - size.width / 2,
                    y: pageBounds.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                image.draw(in: rect)
            }
        }
    }
}

@MainActor
private final class SemanticWebKitPDFRenderer: NSObject, WKNavigationDelegate {
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var pdfContinuation: CheckedContinuation<Data, Error>?
    private var pdfTimeoutTask: Task<Void, Never>?
    private var webView: WKWebView?

    func render(htmlURL: URL, readAccessURL: URL) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 794, height: 1123), configuration: configuration)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        self.webView = webView
        defer {
            timeoutTask?.cancel()
            pdfTimeoutTask?.cancel()
            webView.stopLoading()
            self.webView = nil
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loadContinuation = continuation
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 45_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.finishLoading(.failure(MathNoteError.renderTimedOut))
                }
                webView.loadFileURL(htmlURL, allowingReadAccessTo: readAccessURL)
            }
        } onCancel: { [self] in
            Task { @MainActor in
                webView.stopLoading()
                finishLoading(.failure(CancellationError()))
            }
        }

        try Task.checkCancellation()
        // The generated document has no page scripts, remote fonts or remote images:
        // math is static MathML and figures are embedded data URLs. `didFinish` therefore
        // represents resource readiness. Give WebKit one layout cycle before asking it to
        // paginate instead of returning a JavaScript Promise through evaluateJavaScript.
        try await settleLayout(in: webView)
        let data = try await createPDF(in: webView)
        return data
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in self?.finishLoading(.success(())) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.finishLoading(.failure(MathNoteError.message("The local document preview failed to load.")))
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.finishLoading(.failure(MathNoteError.message("The local document preview failed to load.")))
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(url.isFileURL || url.absoluteString == "about:blank" ? .allow : .cancel)
    }

    private func finishLoading(_ result: Result<Void, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        continuation.resume(with: result)
    }

    private func settleLayout(in webView: WKWebView) async throws {
        webView.setNeedsLayout()
        webView.layoutIfNeeded()
        webView.scrollView.setNeedsLayout()
        webView.scrollView.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        try Task.checkCancellation()
        webView.layoutIfNeeded()
        webView.scrollView.layoutIfNeeded()
    }

    private func createPDF(in webView: WKWebView) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pdfContinuation = continuation
                pdfTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 45_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.finishPDF(.failure(MathNoteError.renderTimedOut))
                }
                let configuration = WKPDFConfiguration()
                webView.createPDF(configuration: configuration) { [weak self] result in
                    Task { @MainActor in
                        switch result {
                        case .success(let data): self?.finishPDF(.success(data))
                        case .failure:
                            self?.finishPDF(.failure(MathNoteError.message("The semantic PDF could not be rendered.")))
                        }
                    }
                }
            }
        } onCancel: { [self] in
            Task { @MainActor in finishPDF(.failure(CancellationError())) }
        }
    }

    private func finishPDF(_ result: Result<Data, Error>) {
        pdfTimeoutTask?.cancel()
        pdfTimeoutTask = nil
        guard let continuation = pdfContinuation else { return }
        pdfContinuation = nil
        continuation.resume(with: result)
    }
}
