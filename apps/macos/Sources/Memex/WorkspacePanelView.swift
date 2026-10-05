import SwiftUI

struct WorkspacePanelView: View {
    @Bindable var store: Store

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Workspace panel", selection: $store.workspacePanel) {
                    ForEach(Store.WorkspacePanel.allCases) { panel in
                        Text(panel.title).tag(panel)
                    }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
                Spacer(minLength: 0)
                Button { store.showingWorkspaceChanges = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close workspace panel").accessibilityLabel("Close workspace panel")
            }.padding(10)
            Divider()
            if store.workspacePanel == .browser, let sessionID = store.selectedID {
                WorkspaceBrowserView(session: store.workspaceBrowser.session(for: sessionID))
            } else if let directory = store.selectedWorkspace {
                WorkspaceChangesView(directory: directory, isWorking: store.selectedLiveConversation?.isWorking == true,
                                     initialSelectedPath: store.selectedWorkspaceChange,
                                     reviewRequest: store.workspaceChangeReviewRequest)
            } else {
                ContentUnavailableView("Workspace unavailable", systemImage: "folder",
                    description: Text("Git changes are available for conversations with a local workspace."))
            }
        }
    }
}
