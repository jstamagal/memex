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
                        delegate.store.showingNewConversation = true
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
                    Button("Workspace Changes") { delegate.store.showingWorkspaceChanges.toggle() }
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                        .disabled(delegate.store.selectedWorkspace == nil)
                }
            }
    }
}

@MainActor final class MemexApplicationDelegate: NSObject, NSApplicationDelegate {
    let store = Store(filterPreferences: .standard, draftStore: .persistent(), createdConversations: .persistent())
    private var browser: NSWindowController?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
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
            window.contentViewController = BrowserColumnsController(store: store, sidebar: content.sidebar,
                conversations: content.conversations, reader: content.reader)
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
    var conversations: some View { BrowserConversationList(store: store) }
    var reader: some View { BrowserReader(store: store) }
}

private struct BrowserReader: View {
    @Bindable var store: Store

    var body: some View {
        Group {
            if store.scope == .home { HomeView(store: store) }
            else { ReaderView(store: store) }
        }
        .sheet(isPresented: $store.showingNewConversation) { NewConversationView(store: store) }
        .inspector(isPresented: $store.showingWorkspaceChanges) {
            if store.showingWorkspaceChanges, let directory = store.selectedWorkspace, store.scope != .home {
                WorkspaceChangesView(directory: directory, isWorking: store.selectedLiveConversation?.isWorking == true,
                                     initialSelectedPath: store.selectedWorkspaceChange,
                                     reviewRequest: store.workspaceChangeReviewRequest) {
                    store.showingWorkspaceChanges = false
                }
                    .inspectorColumnWidth(min: 430, ideal: 620, max: 1000)
            }
        }
        .onChange(of: store.scope) { _, scope in
            if scope == .home { store.showingWorkspaceChanges = false }
        }
        .onChange(of: store.selectedWorkspace) { _, directory in
            if directory == nil { store.showingWorkspaceChanges = false }
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

private struct BrowserSidebar: View {
    @Bindable var store: Store

    var body: some View { sidebar }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Group {
                if #available(macOS 26.0, *) {
                    sidebarList
                        .scrollEdgeEffectStyle(.soft, for: .top)
                } else {
                    sidebarList
                }
            }
            Divider()
            machinePicker
        }
        // The material must continue beneath the native titlebar as well as
        // the list and footer, otherwise its safe-area edge makes a color seam.
        .background(SidebarBackground().ignoresSafeArea())
    }

    private var machinePicker: some View {
        HStack(spacing: 6) {
            Picker("Machines", selection: $store.machineSelection) {
                Text("All Machines").tag(MachineSelection.all)
                ForEach(store.machines) { machine in
                    Text(machine.label).tag(MachineSelection.machine(machine.id))
                }
            }
            .labelsHidden().pickerStyle(.menu)
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Machines")
            if store.loadingMachines { ProgressView().controlSize(.mini) }
            if let error = store.machineError {
                Button { Task { await store.loadMachines() } } label: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .buttonStyle(.plain).help(error)
                .accessibilityLabel("Retry loading machines")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sidebarList: some View {
        List(selection: $store.scope) {
            Section {
                Label("Home", systemImage: "house")
                    .tag(Store.Scope.home)
                Label("All conversations", systemImage: "bubble.left.and.bubble.right")
                    .tag(Store.Scope.all)
            }
            Section {
                ForEach(store.projects) { project in
                    HStack {
                        Label(project.project, systemImage: "folder").lineLimit(1)
                        Spacer(minLength: 4)
                        Text(project.sessionCount, format: .number)
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(Store.Scope.project(project.project))
                    .help("\(project.project): \(project.sessionCount) conversations across all time, excluding permission reviews")
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    if store.loadingProjects { ProgressView().controlSize(.mini) }
                    if let error = store.projectsError {
                        Button { Task { await store.loadProjects() } } label: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .buttonStyle(.plain).help(error)
                        .accessibilityLabel("Retry loading projects")
                    }
                    Menu {
                        Picker("Sort by", selection: Binding(get: { store.projectSort }, set: { store.setProjectSort($0) })) {
                            ForEach(ProjectSort.allCases, id: \.self) { sort in
                                Text(sort.title).tag(sort)
                            }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Button("Refresh projects") { Task { await store.loadProjects() } }
                            .disabled(store.loadingProjects)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .padding(.trailing, 8)
                    .help("Sort projects").accessibilityLabel("Sort projects")
                }
            }

        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

}

private struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct BrowserConversationList: View {
    @Bindable var store: Store

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.listError {
                ErrorBanner(message: error) { Task { await store.loadSessions() } }
            }
            NativeConversationList(sessions: store.sessions, selectedID: store.selectedID,
                states: Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.id, store.liveConversations.listState(for: $0)) }),
                query: store.query,
                select: { store.selectedID = $0 },
                loadMore: { store.loadMoreSessionsIfNeeded(visibleID: $0) })
            .overlay {
                if store.sessions.isEmpty && !store.loadingSessions && store.listError == nil {
                    ContentUnavailableView {
                        Label(store.filters.isActive ? "No matching conversations" : (store.query.isEmpty ? "No conversations yet" : "No matches"),
                              systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text(store.filters.isActive ? "Try another timeframe, provider, or conversation type." :
                             (store.query.isEmpty ? "Run memex index to index your local history, then refresh." : "Try different words or another project."))
                    } actions: {
                        if store.filters.isActive { Button("Reset Filters") { store.filters = .defaults } }
                    }
                }
            }

        }
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
