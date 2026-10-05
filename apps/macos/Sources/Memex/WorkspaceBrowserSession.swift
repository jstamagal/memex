import AppKit
import Combine
import Foundation
import WebKit

enum WorkspaceBrowserAddress {
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let explicitScheme = text.contains("://")
        let candidate = explicitScheme ? text : "https://" + text
        guard var components = URLComponents(string: candidate),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.scheme?.lowercased() == "https" || components.scheme?.lowercased() == "http",
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        if !explicitScheme, isLoopback(host) { components.scheme = "http" }
        guard let url = components.url, allowsNavigation(to: url) else { return nil }
        return url
    }

    static func allowsNavigation(to url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }

    private static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") || host == "[::1]" || host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy {
            guard let value = Int($0) else { return false }
            return (0...255).contains(value)
        }
    }
}

/// Owned by the window's Store, rather than a transient inspector view. No page
/// observation is published through the conversation or transcript model.
@MainActor final class WorkspaceBrowserStore {
    private var sessions: [String: WorkspaceBrowserSession] = [:]

    func session(for conversationID: String) -> WorkspaceBrowserSession {
        if let session = sessions[conversationID] { return session }
        let session = WorkspaceBrowserSession()
        sessions[conversationID] = session
        return session
    }

    /// Call only when a chat is discarded, not when its inspector is hidden.
    func removeSession(for conversationID: String) {
        sessions.removeValue(forKey: conversationID)?.webView.stopLoading()
    }
}

@MainActor final class WorkspaceBrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var addressText = ""
    @Published private(set) var currentURL: URL?
    @Published private(set) var title = "Browser"
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var estimatedProgress = 0.0
    @Published private(set) var error: String?
    private(set) var requestedURL: URL?
    var isEditingAddress = false
    private var observers: Set<AnyCancellable> = []

    override init() {
        // Keep WebKit's normal origin isolation, TLS validation and content
        // protections. This pane installs no scripts or native message bridge.
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.publisher(for: \.url).receive(on: RunLoop.main).sink { [weak self] url in
            guard let self else { return }
            self.currentURL = url
            if !self.isEditingAddress, let url { self.addressText = url.absoluteString }
        }.store(in: &observers)
        webView.publisher(for: \.title).receive(on: RunLoop.main).sink { [weak self] title in
            self?.title = title?.nilIfBlank ?? "Browser"
        }.store(in: &observers)
        webView.publisher(for: \.canGoBack).receive(on: RunLoop.main).sink { [weak self] value in
            self?.canGoBack = value
        }.store(in: &observers)
        webView.publisher(for: \.canGoForward).receive(on: RunLoop.main).sink { [weak self] value in
            self?.canGoForward = value
        }.store(in: &observers)
        webView.publisher(for: \.isLoading).receive(on: RunLoop.main).sink { [weak self] value in
            self?.isLoading = value
        }.store(in: &observers)
        webView.publisher(for: \.estimatedProgress).receive(on: RunLoop.main).sink { [weak self] value in
            self?.estimatedProgress = value
        }.store(in: &observers)
    }

    @discardableResult func submitAddress() -> Bool {
        guard let url = WorkspaceBrowserAddress.url(from: addressText) else {
            error = "Enter an HTTP or HTTPS address, such as localhost:4000."
            return false
        }
        isEditingAddress = false
        return navigate(to: url)
    }

    @discardableResult func navigate(to url: URL) -> Bool {
        guard WorkspaceBrowserAddress.allowsNavigation(to: url) else {
            error = "This browser opens HTTP and HTTPS pages."
            return false
        }
        error = nil
        requestedURL = url
        addressText = url.absoluteString
        webView.load(URLRequest(url: url))
        return true
    }

    func goBack() {
        guard webView.canGoBack else { return }
        error = nil
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        error = nil
        webView.goForward()
    }

    func reload() {
        let failed = error != nil
        error = nil
        if failed, let requestedURL { _ = navigate(to: requestedURL) }
        else if webView.url != nil { webView.reload() }
        else if let requestedURL { _ = navigate(to: requestedURL) }
    }

    func stopLoading() { webView.stopLoading() }
    func dismissError() { error = nil }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // Keep ordinary inline subframes, but never hand external schemes to
        // other applications or give a page local-file navigation access.
        guard navigationAction.targetFrame?.isMainFrame != false else {
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
            decisionHandler(["http", "https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
            return
        }
        guard let url = navigationAction.request.url, WorkspaceBrowserAddress.allowsNavigation(to: url) else {
            error = "This browser opens HTTP and HTTPS pages."
            decisionHandler(.cancel)
            return
        }
        requestedURL = url
        error = nil
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Keep user-activated target=_blank links inside the retained pane.
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           WorkspaceBrowserAddress.allowsNavigation(to: url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        recordFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        recordFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        error = "The page stopped responding. Reload to try again."
    }

    private func recordFailure(_ failure: any Error) {
        let failure = failure as NSError
        guard !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) else { return }
        error = failure.localizedDescription
    }
}
