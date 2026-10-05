import SwiftUI
import WebKit

struct WorkspaceBrowserView: View {
    @ObservedObject var session: WorkspaceBrowserSession
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: session.goBack) { Image(systemName: "chevron.left") }
                    .disabled(!session.canGoBack).help("Back").accessibilityLabel("Back")
                Button(action: session.goForward) { Image(systemName: "chevron.right") }
                    .disabled(!session.canGoForward).help("Forward").accessibilityLabel("Forward")
                Button {
                    if session.isLoading { session.stopLoading() } else { session.reload() }
                } label: {
                    Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
                }
                .disabled(session.requestedURL == nil && session.currentURL == nil)
                .help(session.isLoading ? "Stop loading" : "Reload")
                .accessibilityLabel(session.isLoading ? "Stop loading" : "Reload")
                TextField("Enter URL or localhost:4000", text: $session.addressText)
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .accessibilityLabel("Browser address")
                    .onSubmit {
                        if session.submitAddress() { addressFocused = false }
                    }
            }.padding(10)
            if session.isLoading {
                ProgressView(value: session.estimatedProgress).progressViewStyle(.linear)
                    .accessibilityLabel("Loading page")
            } else { Divider() }
            if let error = session.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if session.requestedURL != nil {
                        Button("Retry", action: session.reload).controlSize(.small)
                    }
                    Button(action: session.dismissError) { Image(systemName: "xmark") }
                        .help("Dismiss error").accessibilityLabel("Dismiss browser error")
                }.padding(10).background(.quaternary)
            }
            WorkspaceBrowserWebView(webView: session.webView)
                .id(ObjectIdentifier(session))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if session.currentURL == nil && session.requestedURL == nil {
                        ContentUnavailableView("Browse", systemImage: "globe",
                            description: Text("Enter a website or a local preview address above."))
                            .allowsHitTesting(false)
                    }
                }
        }
        .onChange(of: addressFocused) { _, focused in session.isEditingAddress = focused }
        .onChange(of: session) { previous, next in
            previous.isEditingAddress = false
            next.isEditingAddress = false
            addressFocused = false
        }
        .onDisappear { session.isEditingAddress = false }
    }
}

/// Reattaching the retained web view must never trigger navigation. A host view
/// also handles a changed session without requiring callers to set a SwiftUI id.
struct WorkspaceBrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WorkspaceBrowserHost {
        let host = WorkspaceBrowserHost()
        host.attach(webView)
        return host
    }
    func updateNSView(_ host: WorkspaceBrowserHost, context: Context) { host.attach(webView) }
}

@MainActor final class WorkspaceBrowserHost: NSView {
    private(set) var webView: WKWebView?

    func attach(_ next: WKWebView) {
        guard webView !== next || next.superview !== self else { return }
        if webView?.superview === self { webView?.removeFromSuperview() }
        webView = next
        next.removeFromSuperview()
        next.frame = bounds
        next.autoresizingMask = [.width, .height]
        addSubview(next)
    }
}
