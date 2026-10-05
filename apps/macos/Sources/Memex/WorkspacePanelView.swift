import SwiftUI

struct WorkspacePanelView: View {
    @Bindable var store: Store

    var body: some View {
        VStack(spacing: 0) {
            if let sessionID = store.selectedID {
                WorkspacePanelTabs(selection: Binding(get: { store.workspacePanel }, set: store.selectWorkspacePanel),
                                   browser: store.workspaceBrowser.session(for: sessionID),
                                   close: { store.showingWorkspaceChanges = false })
            }
            Divider()
            // Keep both panes mounted so a tab switch never resets the diff's
            // selected file, native scroll position, or the browser's page.
            ZStack {
                Group {
                    if let directory = store.selectedWorkspace {
                        WorkspaceChangesView(directory: directory, isWorking: store.selectedLiveConversation?.isWorking == true,
                                             initialSelectedPath: store.selectedWorkspaceChange,
                                             reviewRequest: store.workspaceChangeReviewRequest)
                    } else {
                        ContentUnavailableView("Workspace unavailable", systemImage: "folder",
                            description: Text("Git changes are available for conversations with a local workspace."))
                    }
                }
                .opacity(store.workspacePanel == .changes ? 1 : 0)
                .allowsHitTesting(store.workspacePanel == .changes)
                .accessibilityHidden(store.workspacePanel != .changes)
                if let sessionID = store.selectedID {
                    WorkspaceBrowserView(session: store.workspaceBrowser.session(for: sessionID),
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
    @ObservedObject var browser: WorkspaceBrowserSession
    let close: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            tab(.changes, title: "Changes", symbol: "doc.text.magnifyingglass")
            tab(.browser, title: browser.title, symbol: "globe")
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
        .help(panel == .browser ? browser.currentURL?.absoluteString ?? "Browser"
              : panel == .terminal ? "Workspace terminal (⌘J for drawer)" : "Uncommitted changes")
        .accessibilityLabel(panel.title)
        .accessibilityValue(selection == panel ? "Selected" : "")
        .accessibilityAddTraits(selection == panel ? .isSelected : [])
    }
}
