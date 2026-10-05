import AppKit
import Network
import Testing
import WebKit
@testable import Memex

@MainActor @Suite(.serialized) struct WorkspaceBrowserTests {
    init() { _ = NSApplication.shared }

    @Test func normalizesWebsiteAndLocalPreviewAddresses() {
        for (input, expected) in [
            (" example.com/path?q=memex#result ", "https://example.com/path?q=memex#result"),
            ("localhost:4000/preview", "http://localhost:4000/preview"),
            ("app.localhost:5173", "http://app.localhost:5173"),
            ("127.0.0.1:4321", "http://127.0.0.1:4321"),
            ("[::1]:4321", "http://[::1]:4321"),
            ("https://localhost:4443", "https://localhost:4443"),
            ("http://example.com", "http://example.com"),
            ("preview.internal:4321", "https://preview.internal:4321")
        ] {
            #expect(WorkspaceBrowserAddress.url(from: input)?.absoluteString == expected)
        }
    }

    @Test func rejectsUnsupportedSchemesMalformedAddressesAndCredentials() {
        for input in ["", " ", "a search query", "https://", "https://example.com:99999", "localhost:0", "localhost:abc",
                      "file:///tmp/page.html", "javascript:alert(1)", "data:text/html,hello", "ftp://example.com",
                      "https://user:password@example.com", "https://example.com/\npath", "https://example.com/\u{0}"] {
            #expect(WorkspaceBrowserAddress.url(from: input) == nil)
        }
        #expect(!WorkspaceBrowserAddress.allowsNavigation(to: URL(string: "file:///tmp/page.html")!))
    }

    @Test func sessionsKeepDistinctWebViewsAndAddressDraftsAcrossPaneMounts() {
        let store = WorkspaceBrowserStore()
        let first = store.session(for: "local-chat")
        let second = store.session(for: "remote-chat")
        first.addressText = "localhost:4000/unfinished"
        #expect(first !== second)
        #expect(first.webView !== second.webView)
        let host = WorkspaceBrowserHost()
        host.attach(first.webView)
        host.attach(second.webView)
        host.attach(store.session(for: "local-chat").webView)
        #expect(host.webView === first.webView)
        #expect(first.addressText == "localhost:4000/unfinished")
        #expect(first.requestedURL == nil)
        #expect(first.webView.configuration.userContentController.userScripts.isEmpty)
        first.addressText = "javascript:alert(1)"
        #expect(!first.submitAddress())
        #expect(first.error != nil)
        #expect(first.requestedURL == nil)
        store.removeSession(for: "remote-chat")
        #expect(store.session(for: "remote-chat") !== second)
        #expect(store.session(for: "local-chat") === first)
    }

    @Test func realPageHistorySurvivesChatSwitchingAndReattachment() async throws {
        let server = try WorkspaceBrowserHTTPFixture()
        defer { server.stop() }
        try await waitUntil { server.port != nil }
        let port = try #require(server.port)
        let store = WorkspaceBrowserStore()
        let session = store.session(for: "chat-one")
        let host = WorkspaceBrowserHost(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.attach(session.webView)
        session.addressText = "localhost:\(port)/one"
        try #require(session.submitAddress())
        try await waitUntil { session.title == "Page one" && !session.isLoading }
        session.addressText = "localhost:\(port)/two"
        try #require(session.submitAddress())
        try await waitUntil { session.title == "Page two" && session.canGoBack && !session.isLoading }

        let historyItem = session.webView.backForwardList.currentItem
        let requestCount = server.requestCount
        host.attach(store.session(for: "chat-two").webView)
        host.attach(store.session(for: "chat-one").webView)
        // A new host models destroying/recreating the inspector when hidden.
        let reopened = WorkspaceBrowserHost(frame: host.frame)
        reopened.attach(session.webView)
        for _ in 0..<10 { reopened.attach(session.webView) }
        host.attach(session.webView)
        #expect(session.webView.superview === host)
        #expect(session.webView.backForwardList.currentItem === historyItem)
        #expect(session.title == "Page two")
        #expect(server.requestCount == requestCount)
        session.goBack()
        try await waitUntil { session.title == "Page one" && session.canGoForward && !session.isLoading }
        session.goForward()
        try await waitUntil { session.title == "Page two" && !session.isLoading }
        let beforeReload = server.requestCount
        session.reload()
        try await waitUntil { server.requestCount > beforeReload && !session.isLoading }
        #expect(session.error == nil)
    }

    @Test func navigationFailuresAreRecoverableAndCancellationIsNotAnError() {
        let session = WorkspaceBrowserSession()
        #expect(session.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
        session.webView(session.webView, didFailProvisionalNavigation: nil,
                        withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        #expect(session.error == nil)
        session.webView(session.webView, didFailProvisionalNavigation: nil,
                        withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        #expect(session.error != nil)
        session.dismissError()
        #expect(session.error == nil)
        session.webViewWebContentProcessDidTerminate(session.webView)
        #expect(session.error?.contains("Reload") == true)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "Timed out waiting for local WebKit navigation")
    }
}

/// Loopback-only pages exercise WebKit's real load and back-forward list without
/// relying on an external website or a protocol mock WebKit would bypass.
private final class WorkspaceBrowserHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "memex.browser-test-http")
    private let lock = NSLock()
    private var count = 0
    private var boundPort: UInt16?
    var port: UInt16? { lock.withLock { boundPort } }
    var requestCount: Int { lock.withLock { count } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state, let port = self.listener.port?.rawValue, port > 0 else { return }
            self.lock.withLock { self.boundPort = port }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
                guard let self, let data else { connection.cancel(); return }
                self.lock.withLock { self.count += 1 }
                let request = String(decoding: data, as: UTF8.self)
                let page = request.hasPrefix("GET /two ") ? "two" : "one"
                let body = "<html><head><title>Page \(page)</title></head><body>Page \(page)</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }
}
