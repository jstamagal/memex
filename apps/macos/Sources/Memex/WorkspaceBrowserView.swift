import SwiftUI
import WebKit

struct WorkspaceBrowserView: View {
    @ObservedObject var session: WorkspaceBrowserSession
    var isActive = true
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Button(action: session.goBack) { Image(systemName: "chevron.left").frame(width: 26, height: 28) }
                        .disabled(!session.canGoBack).help("Back").accessibilityLabel("Back")
                    Button(action: session.goForward) { Image(systemName: "chevron.right").frame(width: 26, height: 28) }
                        .disabled(!session.canGoForward).help("Forward").accessibilityLabel("Forward")
                    Button {
                        if session.isLoading { session.stopLoading() } else { session.reload() }
                    } label: {
                        Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise").frame(width: 26, height: 28)
                    }
                    .disabled(session.requestedURL == nil && session.currentURL == nil)
                    .help(session.isLoading ? "Stop loading" : "Reload")
                    .accessibilityLabel(session.isLoading ? "Stop loading" : "Reload")
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 3).background(.quaternary.opacity(0.5), in: Capsule())
                TextField("Enter a URL", text: $session.addressText)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                    .overlay(Capsule().strokeBorder(addressFocused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
                    .focused($addressFocused)
                    .accessibilityLabel("Browser address")
                    .onSubmit {
                        if session.submitAddress() { addressFocused = false }
                    }
            }.padding(.horizontal, 8).padding(.vertical, 6)
                .background(.bar)
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
        .onChange(of: isActive) { _, active in
            addressFocused = active && session.currentURL == nil && session.requestedURL == nil
            // Invisible WebKit content must not keep receiving keyboard input.
            if let window = session.webView.window {
                if active && !addressFocused { window.makeFirstResponder(session.webView) }
                else if !active, let responder = window.firstResponder as? NSView,
                        responder.isDescendant(of: session.webView) {
                    window.makeFirstResponder(nil)
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
