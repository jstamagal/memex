import SwiftUI

struct WorkspacePanelView: View {
    @Bindable var store: Store

    var body: some View {
        VStack(spacing: 0) {
            if store.selectedID != nil {
                WorkspacePanelTabs(selection: Binding(get: { store.workspacePanel }, set: store.selectWorkspacePanel),
                                   close: { store.showingWorkspaceChanges = false })
            }
            Divider()
            // Keep panes mounted so tab switches retain selections and edits.
            // File drafts also survive closing the inspector or changing chats.
            ZStack {
                Group {
                    if let directory = store.selectedWorkspace {
                        WorkspaceChangesView(directory: directory, isWorking: store.selectedLiveConversation?.isWorking == true,
                                             initialSelectedPath: store.selectedWorkspaceChange,
                                             reviewRequest: store.workspaceChangeReviewRequest,
                                             conversationID: store.selectedID,
                                             isolation: { store.selected.flatMap { store.workspaceIsolation(for: $0) } },
                                             rewindConversation: { try await store.rewindConversation(to: $0) },
                                             addReviewContext: store.selectedLiveConversation.map { live in
                                                 { context in live.appendContext(title: "Code review", text: context.promptText, source: directory.path) }
                                             },
                                             setupCommand: store.selected.flatMap { session in
                                                 store.createdConversations.contexts[session.id]?.projectID
                                             }.flatMap { id in store.localProjects.projects.first { $0.id == id }?.setupCommand })
                    } else {
                        ContentUnavailableView("Workspace unavailable", systemImage: "folder",
                            description: Text("Git changes are available for conversations with a local workspace."))
                    }
                }
                .opacity(store.workspacePanel == .changes ? 1 : 0)
                .allowsHitTesting(store.workspacePanel == .changes)
                .accessibilityHidden(store.workspacePanel != .changes)
                if let directory = store.selectedWorkspace {
                    WorkspaceFilesView(directory: directory, addContext: store.selectedLiveConversation.map { live in
                        { text in live.appendContext(title: "Workspace file", text: text, source: directory.path) }
                    })
                        .id(directory)
                        .opacity(store.workspacePanel == .files ? 1 : 0)
                        .allowsHitTesting(store.workspacePanel == .files)
                        .accessibilityHidden(store.workspacePanel != .files)
                }
                if let sessionID = store.selectedID {
                    WorkspaceBrowserTabView(tabs: store.workspaceBrowser.tabs(for: sessionID),
                                            automation: store.workspaceBrowser.automation,
                                            live: store.selectedLiveConversation,
                                            isActive: store.workspacePanel == .browser)
                        .opacity(store.workspacePanel == .browser ? 1 : 0)
                        .allowsHitTesting(store.workspacePanel == .browser)
                        .accessibilityHidden(store.workspacePanel != .browser)
                }
                if store.workspacePanel == .terminal && !store.showingTerminalDrawer {
                    WorkspaceTerminalView(store: store, placement: .rightPane)
                }
            }
        }
    }
}

private struct WorkspacePanelTabs: View {
    @Binding var selection: Store.WorkspacePanel
    let close: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            tab(.changes, title: "Changes", symbol: "doc.text.magnifyingglass")
            tab(.files, title: "Files", symbol: "folder")
            tab(.browser, title: "Browser", symbol: "globe")
            tab(.terminal, title: "Terminal", symbol: "terminal")
            Spacer(minLength: 4)
            Button(action: close) { Image(systemName: "sidebar.right").frame(width: 28, height: 28) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Hide workspace panel").accessibilityLabel("Hide workspace panel")
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(.bar)
    }

    private func tab(_ panel: Store.WorkspacePanel, title: String, symbol: String) -> some View {
        Button { selection = panel } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: selection == panel ? .medium : .regular))
                .foregroundStyle(selection == panel ? .primary : .secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 66, maxWidth: panel == .browser ? 220 : 100, alignment: .leading)
                .padding(.horizontal, 10).frame(height: 28)
                .background(selection == panel ? Color.primary.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(panel == .terminal ? "Workspace terminal (⌘J for drawer)" : panel.title)
        .accessibilityLabel(panel.title)
        .accessibilityValue(selection == panel ? "Selected" : "")
        .accessibilityAddTraits(selection == panel ? .isSelected : [])
    }
}
