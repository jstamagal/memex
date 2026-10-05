import SwiftUI

struct SidebarConversationGroup: Identifiable {
    let name: String
    let sessions: [Session]
    var id: String { name }
}

extension Store {
    var sidebarSessions: [Session] {
        // Keep search relevance and its source-record anchors intact.
        guard query.nilIfBlank == nil else { return sessions }
        return sessions.sorted {
            let lhs = $0.lastAt ?? "", rhs = $1.lastAt ?? ""
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
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

    private enum Selection: Hashable { case home, all, conversation(String) }
    private var selection: Binding<Selection?> {
        Binding(get: {
            if store.scope == .home { return .home }
            return store.selectedID.map(Selection.conversation) ?? .all
        }, set: { value in
            switch value {
            case .home: store.scope = .home
            case .all: store.scope = .all
            case .conversation(let id):
                if let session = store.sessions.first(where: { $0.id == id }) { store.openConversation(session) }
            case nil: break
            }
        })
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
                    if store.sidebarMode == .projects {
                        ForEach(store.sidebarGroups) { group in
                            DisclosureGroup(isExpanded: Binding(get: { !collapsedProjects.contains(group.id) }, set: {
                                if $0 { collapsedProjects.remove(group.id) } else { collapsedProjects.insert(group.id) }
                            })) {
                                ForEach(group.sessions) { session in row(session, showsProject: false) }
                            } label: {
                                Label(group.name, systemImage: "folder").lineLimit(1)
                            }
                        }
                    } else {
                        ForEach(store.sidebarSessions) { session in row(session, showsProject: true) }
                    }
                    if store.loadingSessions {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else if store.hasMoreSessions, let last = store.sessions.last {
                        Button("Load older conversations") { store.loadMoreSessionsIfNeeded(visibleID: last.id) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    } else if store.sessions.isEmpty && store.listError == nil {
                        Text(store.query.isEmpty ? "No conversations" : "No matching conversations")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = store.listError {
                        Button("Retry loading conversations") { Task { await store.loadSessions() } }
                            .help(error)
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
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title).font(.system(size: 13)).lineLimit(2)
            HStack(spacing: 4) {
                Text(showsProject ? store.projectName(for: session) : session.source).lineLimit(1)
                if session.machineID != "local" { Text("· \(session.machineID)").lineLimit(1) }
                Spacer(minLength: 2)
                if let date = session.date {
                    Text(date, format: .dateTime.month(.abbreviated).day()).fixedSize()
                }
            }.font(.caption).foregroundStyle(.secondary)
            ConversationStateLabel(state: store.liveConversations.listState(for: session))
        }
        .padding(.vertical, 3)
        .tag(Selection.conversation(session.id))
        .help(session.title)
        .accessibilityElement(children: .combine)
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
