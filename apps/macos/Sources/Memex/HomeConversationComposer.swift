import SwiftUI

#if canImport(SQACPUI)
import SQACPUI

struct HomeConversationComposer: View {
    @Bindable var store: Store
    @State private var repository: ConversationWorkspaceRepository?
    @State private var inspecting = false
    @State private var workspaceError: String?

    private var baseRefs: [String] {
        Array(Set((repository?.localBranches ?? []) + [repository?.defaultBaseRef, store.newConversationDraft.value.baseRef].compactMap { $0 })).sorted()
    }

    var body: some View {
        @Bindable var draft = store.newConversationDraft
        VStack(alignment: .leading, spacing: 12) {
            Text("What would you like to work on?").font(.title2.weight(.semibold))
            if draft.value.createdSessionID != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your conversation was created. Open it to review the saved prompt before sending.")
                    Button("Open created conversation") { Task { await store.openCreatedConversationFromHome() } }
                }
                .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            AcpComposerView(
                text: $draft.value.text,
                placeholder: "Ask the agent…",
                isRunning: false,
                canSend: store.canStartConversation && !inspecting
                    && (draft.value.workspaceMode == .existingDirectory || (repository != nil && draft.value.baseRef != nil)),
                focusRequestID: draft.focusRequest,
                composerFont: .system(size: 14),
                onSubmit: { Task { await store.startConversationFromHome() } },
                onCancel: {},
                leadingAccessory: { controls },
                sendButton: { AcpSendButton().accessibilityLabel("Start conversation") },
                cancelButton: { AcpStopButton() }
            )
            .disabled(store.startingConversation || draft.value.createdSessionID != nil)
            if store.startingConversation {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(draft.value.workspaceMode == .newWorktree ? "Preparing worktree and conversation…" : "Creating conversation…")
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let workspace = draft.value.preparedWorkspace, workspace.state == .ready {
                Text("Prepared worktree: \(workspace.workingDirectory.path)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let workspace = draft.value.preparedWorkspace, workspace.state == .failed {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Worktree preparation failed. Its files were retained at \(workspace.worktreeRoot?.path ?? workspace.workingDirectory.path).")
                        .textSelection(.enabled)
                    Button("Prepare another worktree") {
                        draft.value.preparedWorkspace = nil
                        store.newConversationError = nil
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.newConversationError ?? draft.error ?? store.localProjects.error ?? workspaceError {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if draft.error != nil {
                Button("Retry saving draft") { Task { await draft.retrySave() } }
                    .font(.caption)
            }
        }
        .frame(maxWidth: ConversationReadingLane.maximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .task(id: store.newConversationProject) { await inspectProject() }
    }

    private var controls: some View {
        @Bindable var draft = store.newConversationDraft
        return HStack(spacing: 12) {
            Menu {
                ForEach(["codex", "claude"], id: \.self) { provider in
                    Button { draft.value.provider = provider } label: {
                        let name = provider == "codex" ? "Codex" : "Claude Code"
                        if draft.value.provider == provider { Label(name, systemImage: "checkmark") }
                        else { Text(name) }
                    }
                }
            } label: {
                Text(draft.value.provider == "codex" ? "Codex" : "Claude Code")
            }
            .help("Uses this provider’s configured defaults. Model and permissions are available in the conversation.")
            Menu {
                ForEach(store.localProjects.projects) { project in
                    Button {
                        draft.selectProject(project)
                        store.newConversationError = nil
                    } label: {
                        if draft.value.projectID == project.id { Label(project.name, systemImage: "checkmark") }
                        else { Text(project.name) }
                    }
                }
                if !store.localProjects.projects.isEmpty { Divider() }
                Button("Set up projects…") { store.showingProjectSetup = true }
            } label: {
                Label(store.newConversationProject?.name ?? "Choose project", systemImage: "folder")
                    .lineLimit(1)
            }
            .help(store.newConversationProject?.directoryPath ?? "Save a local folder to start a conversation.")
            Menu {
                Button("Existing folder") { draft.selectWorkspace(.existingDirectory, baseRef: draft.value.baseRef) }
                Button("New worktree") {
                    draft.selectWorkspace(.newWorktree, baseRef: draft.value.baseRef ?? repository?.defaultBaseRef)
                }.disabled(repository == nil || inspecting)
            } label: {
                Label(draft.value.workspaceMode == .newWorktree ? "New worktree" : "Existing folder",
                      systemImage: draft.value.workspaceMode == .newWorktree ? "arrow.triangle.branch" : "folder")
            }
            .disabled(store.newConversationProject == nil)
            .help(repository == nil ? "A Git repository is required to create a worktree." : "Choose where this conversation will work.")
            if draft.value.workspaceMode == .newWorktree {
                Menu {
                    ForEach(baseRefs, id: \.self) { ref in
                        Button(ref) { draft.selectWorkspace(.newWorktree, baseRef: ref) }
                    }
                } label: {
                    Text(draft.value.baseRef ?? "Choose base branch").lineLimit(1)
                }
                .help("The worktree starts from this local Git ref. Uncommitted changes stay in the original folder.")
            }
        }
        .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 12)).foregroundStyle(.secondary)
    }

    @MainActor private func inspectProject() async {
        repository = nil
        workspaceError = nil
        guard let project = store.newConversationProject else { inspecting = false; return }
        inspecting = true
        defer { if store.newConversationProject == project { inspecting = false } }
        do {
            let repository = try await store.workspaceClient.inspect(directory: project.directory)
            guard !Task.isCancelled, store.newConversationProject == project else { return }
            self.repository = repository
            if store.newConversationDraft.value.baseRef == nil, let defaultRef = repository?.defaultBaseRef {
                store.newConversationDraft.value.baseRef = defaultRef
            }
        } catch is CancellationError {} catch {
            if store.newConversationProject == project { workspaceError = error.localizedDescription }
        }
    }
}
#else
struct HomeConversationComposer: View {
    let store: Store
    var body: some View { EmptyView() }
}
#endif
