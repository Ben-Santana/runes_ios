import SwiftUI
import WebKit

struct MetaLoginView: UIViewRepresentable {
    let request: MetaLoginRequest
    let completed: (URL) -> Void
    let failed: () -> Void
    /// Each step the page takes, as a host and path with nothing after them. For finding where a sign-in stops.
    var trace: ((String) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(completed: completed, failed: failed, redirect: request.redirect, trace: trace) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        for scheme in ["fb-viewapp", "oculus"] { configuration.setURLSchemeHandler(context.coordinator, forURLScheme: scheme) }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.load(URLRequest(url: request.url)); return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.finished = true; view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKURLSchemeHandler {
        let completed: (URL) -> Void; let failed: () -> Void
        let redirect: String?, trace: ((String) -> Void)?
        var finished = false
        init(completed: @escaping (URL) -> Void, failed: @escaping () -> Void, redirect: String? = nil, trace: ((String) -> Void)? = nil) {
            self.completed = completed; self.failed = failed; self.redirect = redirect; self.trace = trace
        }
        /// Where a step went, without the query, which can hold tokens.
        private func place(_ url: URL?) -> String {
            guard let url else { return "nowhere" }
            return url.scheme == "https" ? "\(url.host ?? "")\(url.path.prefix(60))" : "\(url.scheme ?? "no scheme"):"
        }
        private func capture(_ url: URL) {
            guard !finished else { return }; finished = true; completed(url)
        }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            capture(urlSchemeTask.request.url!)
            urlSchemeTask.didFailWithError(URLError(.cancelled))
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            let main = navigationAction.targetFrame?.isMainFrame != false
            if ["fb-viewapp", "oculus"].contains(url.scheme ?? "") { trace?("sign-in: ended at \(place(url))"); capture(url); decisionHandler(.cancel); return }
            if let redirect, url.absoluteString.hasPrefix(redirect) { trace?("sign-in: ended at \(place(url))"); capture(url); decisionHandler(.cancel); return }
            // Login content stays in-process; never launch another app or plaintext URL.
            guard url.scheme == "https" || url.absoluteString == "about:blank" else { trace?("sign-in: blocked \(place(url))"); decisionHandler(.cancel); return }
            if main { trace?("sign-in: to \(place(url))\(navigationAction.targetFrame == nil ? " (new window)" : "")") }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse { trace?("sign-in: HTTP \(response.statusCode) from \(place(response.url))") }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }; return nil
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !finished, (error as NSError).code != NSURLErrorCancelled else { return }
            trace?("sign-in: failed to load, \((error as NSError).domain) \((error as NSError).code)"); finished = true; failed()
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !finished, (error as NSError).code != NSURLErrorCancelled else { return }; finished = true; failed()
        }
    }
}
