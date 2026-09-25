import SwiftUI
import WebKit

/// The page as Firebird writes it, rendered with the Academic HTML + MathML
/// renderer. One web view loads an empty page once; each update replaces its
/// body in place and follows the newest text, so there is no reload flicker.
/// Updates arrive at most about once a second from `FirebirdProgress`.
struct LiveMarkdownPreview: UIViewRepresentable {
    let markdown: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .secondarySystemBackground
        view.loadHTMLString(AcademicSourceCompiler.previewShellHTML, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.show(markdown, in: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var isLoaded = false
        private var pending: String?
        private var shown: String?

        func show(_ markdown: String, in view: WKWebView) {
            guard markdown != shown else { return }
            pending = markdown
            if isLoaded { flush(view) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            flush(webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            // Only the preview shell itself loads; rendered links never navigate.
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }

        private func flush(_ view: WKWebView) {
            guard let markdown = pending else { return }
            pending = nil
            shown = markdown
            let body = AcademicSourceCompiler.previewBodyHTML(markdown: markdown)
            guard let data = try? JSONEncoder().encode(body), let literal = String(data: data, encoding: .utf8) else { return }
            view.evaluateJavaScript(
                "document.getElementById('page').innerHTML = \(literal); window.scrollTo(0, document.body.scrollHeight);"
            )
        }
    }
}
