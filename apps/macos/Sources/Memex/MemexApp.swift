import AppKit
import SwiftUI

@main
struct MemexApp: App {
    @NSApplicationDelegateAdaptor(MemexApplicationDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("New Conversation") {
                        delegate.showBrowser()
                        delegate.store.beginNewConversation()
                    }
                        .keyboardShortcut("n")
                        .disabled(!InAppAgentRuntime.isAvailable)
                }
                CommandGroup(after: .newItem) {
                    Button("Refresh Conversations") { Task { await delegate.store.refresh() } }
                        .keyboardShortcut("r")
                    Button("Find in Conversation") { delegate.store.findConversationRequest += 1 }
                        .keyboardShortcut("f")
                        .disabled(delegate.store.selected == nil)
                    Button("Workspace Changes") { delegate.store.reviewWorkspaceChange(nil) }
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                        .disabled(delegate.store.selectedWorkspace == nil)
                    Button("Browser") { delegate.store.showWorkspaceBrowser() }
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                        .disabled(delegate.store.selected == nil)
                    Button("Toggle Terminal Drawer") { delegate.store.toggleTerminalDrawer() }
                        .keyboardShortcut("j")
                        .disabled(delegate.store.selectedWorkspace == nil && !delegate.store.showingTerminalDrawer)
                    Button("Add New Project") { delegate.store.addNewProject() }
                }
            }
    }
}

@MainActor final class MemexApplicationDelegate: NSObject, NSApplicationDelegate {
    let store = Store(filterPreferences: .standard, draftStore: .persistent(), createdConversations: .persistent(),
                      localProjects: .persistent(), newConversationDraft: .persistent())
    private var browser: NSWindowController?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        if store.workspaceTerminals.needsCloseConfirmation {
            let alert = NSAlert()
            alert.messageText = "Quit Memex?"
            alert.informativeText = "Quitting ends your workspace terminals and any processes running in them."
            alert.addButton(withTitle: "Quit and End Terminals")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        terminating = true
        Task {
            store.workspaceTerminals.shutdown()
            await store.newConversationDraft.flush()
            await store.liveConversations.disconnectAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) { showBrowser() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showBrowser()
        return false
    }
    func showBrowser() {
        if browser == nil {
            // Own the window and toolbar together. Replacing a SwiftUI WindowGroup's
            // toolbar leaves its private toolbar observations attached to old items.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 900),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Memex"
            window.minSize = NSSize(width: 900, height: 560)
            window.isReleasedWhenClosed = false
            let content = BrowserContent(store: store)
            window.contentViewController = BrowserColumnsController(store: store, sidebar: content.sidebar, reader: content.reader)
            // Installing a native content controller adopts its fitting size.
            // Restore the intended initial browser size before frame autosave.
            window.setContentSize(NSSize(width: 1380, height: 900))
            if !window.setFrameUsingName("MemexBrowser") { window.center() }
            window.setFrameAutosaveName("MemexBrowser")
            browser = NSWindowController(window: window)
        }
        if let window = browser?.window, !window.styleMask.contains(.fullScreen),
           let portrait = NSScreen.screens.first(where: { $0.frame.height > $0.frame.width }),
           window.screen !== portrait {
            let visible = portrait.visibleFrame
            let size = NSSize(width: min(window.frame.width, visible.width), height: min(window.frame.height, visible.height))
            window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                   width: size.width, height: size.height), display: false)
        }
        browser?.showWindow(nil)
        browser?.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor struct BrowserContent {
    let store: Store
    var sidebar: some View { BrowserSidebar(store: store) }
    var reader: some View { BrowserReader(store: store) }
}

private struct BrowserReader: View {
    @Bindable var store: Store

    var body: some View {
        WorkspaceTerminalDrawer(store: store) {
            Group {
                if store.scope == .home { HomeView(store: store) }
                else { ReaderView(store: store) }
            }
        }
        .sheet(isPresented: $store.showingProjectSetup) { ProjectSetupView(store: store) }
        .inspector(isPresented: $store.showingWorkspaceChanges) {
            if store.showingWorkspaceChanges, store.selected != nil, store.scope != .home {
                WorkspacePanelView(store: store)
                    .inspectorColumnWidth(min: 430, ideal: 620, max: 1000)
            }
        }
        .onChange(of: store.scope) { _, scope in
            if scope == .home {
                store.showingWorkspaceChanges = false
                store.showingTerminalDrawer = false
            }
        }
        .onChange(of: store.selectedID) { _, selectedID in
            if selectedID == nil {
                store.showingWorkspaceChanges = false
                store.showingTerminalDrawer = false
            }
        }
        .task(id: store.requestID) { await store.loadSessions() }
        .task(id: store.sessionCountRequestID) { await store.loadSessionCount() }
        .task(id: store.readerRequestID) { await store.loadRecords() }
        .task(id: store.readerRequestID) { await store.loadSelectedSessionMetadata() }
        .task { await store.loadMachines() }
        .task(id: store.machineRequestID) { await store.loadProjects() }
        .onChange(of: store.scope) { _, _ in store.sessionLimit = 200 }
        .onChange(of: store.machineSelection) { _, _ in store.sessionLimit = 200 }
    }
}

struct SessionRow: View {
    let session: Session
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.projectName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if let date = session.date {
                    Text(date, format: .dateTime.month(.abbreviated).day())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(session.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            Text(session.snippet?.nilIfBlank ?? session.source)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            if session.machineID != "local" {
                Label(session.machineID, systemImage: "desktopcomputer")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn’t load conversations", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message).font(.caption)
            Button("Try again", action: retry)
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
    }
}
