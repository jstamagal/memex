import SwiftUI

struct SidebarConversationGroup: Identifiable {
    let name: String
    let sessions: [Session]
    var id: String { name }
}

extension Store {
    var sidebarSessions: [Session] {
        // Keep search relevance and its source-record anchors intact.
        conversationLibrary.sorted(librarySessions, preservingSearchRank: query.nilIfBlank != nil)
    }

    var sidebarGroups: [SidebarConversationGroup] {
        let groups = Dictionary(grouping: sidebarSessions, by: projectName(for:))
            .map { SidebarConversationGroup(name: $0.key, sessions: $0.value) }
        return groups.sorted { lhs, rhs in
            switch projectSort {
            case .recent:
                let left = lhs.sessions.map { $0.lastAt ?? "" }.max() ?? ""
                let right = rhs.sessions.map { $0.lastAt ?? "" }.max() ?? ""
                if left != right { return left > right }
            case .conversations:
                let left = projects.first { $0.project == lhs.name }?.sessionCount ?? lhs.sessions.count
                let right = projects.first { $0.project == rhs.name }?.sessionCount ?? rhs.sessions.count
                if left != right { return left > right }
            case .name: break
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

struct BrowserSidebar: View {
    @Bindable var store: Store
    @State private var collapsedProjects: Set<String> = []
    @State private var selectedConversations: Set<String> = []
    @State private var renameSession: Session?
    @State private var renamedTitle = ""
    @State private var showingRename = false
    @State private var removal: [Session] = []
    @State private var showingRemoval = false
    @State private var showingNotifications = false

    private enum Selection: Hashable { case home, all, conversation(String) }
    private var selection: Binding<Set<Selection>> {
        Binding(get: {
            if !selectedConversations.isEmpty { return Set(selectedConversations.map(Selection.conversation)) }
            if store.scope == .home { return [.home] }
            return store.selectedID.map { [.conversation($0)] } ?? [.all]
        }, set: { value in
            let ids = Set(value.compactMap { if case .conversation(let id) = $0 { return id }; return nil })
            selectedConversations = ids
            if ids.count == 1, let id = ids.first,
               let session = store.librarySessions.first(where: { $0.id == id }) {
                store.openConversation(store.nativeLibrarySession(session))
            } else if ids.isEmpty {
                if value.contains(.home) { store.scope = .home }
                else if value.contains(.all) { store.scope = .all }
            }
        })
    }

    private var pinned: [Session] {
        guard store.conversationLibraryScope == .active, store.query.nilIfBlank == nil else { return [] }
        return store.sidebarSessions.filter { store.conversationLibrary.isPinned($0) }
    }
    private var unpinned: [Session] {
        let ids = Set(pinned.map(\.id))
        return store.sidebarSessions.filter { !ids.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section {
                    Label("Home", systemImage: "house").tag(Selection.home)
                    Label("All conversations", systemImage: "bubble.left.and.bubble.right").tag(Selection.all)
                }
                Section {
                    sidebarOptions
                    Picker("Conversation library", selection: $store.conversationLibraryScope) {
                        ForEach(ConversationLibrary.Scope.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).accessibilityLabel("Conversation library")
                    if store.conversationLibraryScope == .removed {
                        Text("Removed only from Memex. Provider history, saved drafts and running agents are retained.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if selectedConversations.count > 1 {
                        Menu("\(selectedConversations.count) selected") {
                            managementActions(store.librarySelection(selectedConversations))
                        }
                    }
                    if let project = store.selectedProject {
                        HStack {
                            Text(project).lineLimit(1)
                            Spacer()
                            Button {
                                store.homeProject = nil
                                if store.scope != .home { store.scope = .all }
                            } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).help("Show all projects")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    if !pinned.isEmpty {
                        Section("Pinned") {
                            conversationRows(pinned, showsProject: true)
                        }
                    }
                    if store.sidebarMode == .projects {
                        ForEach(store.sidebarGroups) { group in
                            let rows = group.sessions.filter { session in !pinned.contains { $0.id == session.id } }
                            if !rows.isEmpty {
                                DisclosureGroup(isExpanded: Binding(get: { !collapsedProjects.contains(group.id) }, set: {
                                    if $0 { collapsedProjects.remove(group.id) } else { collapsedProjects.insert(group.id) }
                                })) {
                                    conversationRows(rows, showsProject: false)
                                } label: {
                                    Label(group.name, systemImage: "folder").lineLimit(1)
                                }
                            }
                        }
                    } else {
                        conversationRows(unpinned, showsProject: true)
                    }
                    if store.loadingSessions {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else if store.hasMoreSessions, let last = store.sessions.last {
                        Button("Load older conversations") { store.loadMoreSessionsIfNeeded(visibleID: last.id) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    } else if store.librarySessions.isEmpty && store.listError == nil {
                        Text(store.query.isEmpty ? "No conversations" : "No matching conversations")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = store.listError {
                        Button("Retry loading conversations") { Task { await store.loadSessions() } }
                            .help(error)
                    }
                    if let error = store.conversationLibrary.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Button("Reload organization") { store.conversationLibrary.reload() }
                    }
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 6) {
                Picker("Machines", selection: $store.machineSelection) {
                    Text("All Machines").tag(MachineSelection.all)
                    ForEach(store.machines) { Text($0.label).tag(MachineSelection.machine($0.id)) }
                }
                .labelsHidden().pickerStyle(.menu).buttonStyle(.borderless)
                .frame(maxWidth: .infinity).accessibilityLabel("Machines")
                if store.loadingMachines { ProgressView().controlSize(.mini) }
                if let error = store.machineError {
                    Button { Task { await store.loadMachines() } } label: { Image(systemName: "exclamationmark.triangle") }
                        .buttonStyle(.plain).help(error).accessibilityLabel("Retry loading machines")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(SidebarBackground().ignoresSafeArea())
        .onChange(of: store.selectedID) { _, id in
            selectedConversations = Set(id.map { [$0] } ?? [])
        }
        .onChange(of: store.conversationLibraryScope) { _, _ in
            selectedConversations = []
            store.finishLibraryAction(true)
        }
        .onChange(of: store.librarySessions.map(\.id)) { _, ids in
            selectedConversations.formIntersection(ids)
        }
        .alert("Rename conversation", isPresented: $showingRename) {
            TextField("Title", text: $renamedTitle)
            Button("Cancel", role: .cancel) { renameSession = nil }
            Button("Save") {
                if let session = renameSession { _ = store.conversationLibrary.rename(session, to: renamedTitle) }
                renameSession = nil
            }
        } message: {
            Text("This title is used in Memex. Clear it to restore the original provider title.")
        }
        .alert("Remove \(removal.count == 1 ? "conversation" : "\(removal.count) conversations") from Memex?",
               isPresented: $showingRemoval) {
            Button("Cancel", role: .cancel) { removal = [] }
            Button("Remove from Memex", role: .destructive) {
                store.finishLibraryAction(store.conversationLibrary.remove(removal))
                removal = []
            }
        } message: {
            Text("Provider history and saved drafts will not be deleted, and running agents will not be stopped. Restore these conversations from Removed from Memex in the sidebar.")
        }
        .sheet(isPresented: $showingNotifications) {
            ConversationNotificationSettingsView(notifications: store.conversationNotifications)
        }
    }

    private func conversationRows(_ sessions: [Session], showsProject: Bool) -> some View {
        ForEach(sessions) { session in row(session, showsProject: showsProject) }
            .onMove { offsets, destination in
                let native = sessions.map(store.nativeLibrarySession)
                _ = store.conversationLibrary.reorder(native, from: offsets, to: destination)
            }
            .moveDisabled(store.query.nilIfBlank != nil || store.conversationLibraryScope != .active)
    }

    @ViewBuilder
    private func managementActions(_ sessions: [Session]) -> some View {
        if sessions.count == 1, let session = sessions.first {
            Button("Rename…") {
                renameSession = session
                renamedTitle = store.conversationTitle(session)
                showingRename = true
            }
            if store.conversationLibrary.entries[session.id]?.title != nil {
                Button("Restore original title") { _ = store.conversationLibrary.rename(session, to: "") }
            }
        }
        if !sessions.isEmpty {
            if store.conversationLibraryScope == .removed {
                Button("Restore to conversations") { store.finishLibraryAction(store.conversationLibrary.restore(sessions)) }
            } else {
                let allPinned = sessions.allSatisfy { store.conversationLibrary.isPinned($0) }
                Button(allPinned ? "Unpin" : "Pin") { _ = store.conversationLibrary.pin(sessions, pinned: !allPinned) }
                if store.conversationLibraryScope == .archived {
                    Button("Restore to conversations") { store.finishLibraryAction(store.conversationLibrary.archive(sessions, archived: false)) }
                } else {
                    Button("Archive") { store.finishLibraryAction(store.conversationLibrary.archive(sessions, archived: true)) }
                }
                Divider()
                Button("Remove from Memex…", role: .destructive) { removal = sessions; showingRemoval = true }
            }
        }
    }

    private var sidebarOptions: some View {
        HStack {
            Text(store.sidebarMode == .projects ? "Projects" : "Chats")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Add New Project") { store.addNewProject() }
                if !store.localProjects.projects.isEmpty {
                    Menu("New chat in project") {
                        ForEach(store.localProjects.projects) { project in
                            Button(project.name) { store.beginNewConversation(project: project) }
                        }
                    }
                    Button("Manage projects…") { store.manageProjects() }
                }
                Divider()
                Picker("Show chats", selection: $store.sidebarMode) {
                    ForEach(Store.SidebarMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.inline)
                if store.sidebarMode == .projects {
                    Divider()
                    Picker("Sort projects", selection: Binding(get: { store.projectSort }, set: { store.setProjectSort($0) })) {
                        ForEach(ProjectSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.inline)
                }
                Divider()
                Button("Sort visible chats by recent activity") {
                    _ = store.conversationLibrary.resetOrder(store.librarySessions.map(store.nativeLibrarySession))
                }
                Button("Notification preferences…") { showingNotifications = true }
                Button("Refresh conversations") { Task { await store.refresh() } }
                    .disabled(store.loadingSessions)
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 20).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Sidebar options").accessibilityLabel("Sidebar options")
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ session: Session, showsProject: Bool) -> some View {
        let state = store.liveConversations.listState(for: session)
        return VStack(alignment: .leading, spacing: 4) {
            Text(session.title).font(.system(size: 13)).lineLimit(2)
            HStack(spacing: 4) {
                if store.conversationLibrary.isPinned(session) { Image(systemName: "pin.fill").accessibilityLabel("Pinned") }
                Text(showsProject ? store.projectName(for: session) : session.source).lineLimit(1)
                if session.machineID != "local" { Text("· \(session.machineID)").lineLimit(1) }
                Spacer(minLength: 2)
                if state.activity == .openElsewhere {
                    Image(systemName: "lock")
                        .font(.system(size: 10))
                        .help("Open elsewhere")
                        .accessibilityLabel("Open elsewhere")
                }
                if let date = session.date {
                    Text(date, format: .dateTime.month(.abbreviated).day()).fixedSize()
                }
            }.font(.caption).foregroundStyle(.secondary)
            ConversationStateLabel(state: .init(activity: state.activity == .openElsewhere ? nil : state.activity,
                                               hasDraft: state.hasDraft))
        }
        .padding(.vertical, 3)
        .tag(Selection.conversation(session.id))
        .help(session.title)
        .accessibilityElement(children: .combine)
        .contextMenu {
            managementActions(store.librarySelection(selectedConversations.contains(session.id)
                ? selectedConversations : [session.id]))
        }
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
