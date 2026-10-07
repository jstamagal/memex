import SwiftUI

struct ConversationHistoryActions: View {
    @Bindable var store: Store
    let session: Session
    @State private var showingBranch = false
    @State private var operation: ConversationHistoryMutation.Operation?
    @State private var selectedBoundary: String?
    @State private var confirmingMutation = false
    @State private var inspectedOperation: ConversationRelationships.Pending?

    private var pending: [ConversationRelationships.Pending] {
        store.conversationRelationships.pending.filter { $0.source.id == session.id }
    }
    private var boundaries: [ConversationHistoryBoundary] { store.selectedHistoryBoundaries }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.title).font(.headline).lineLimit(1).truncationMode(.tail)
                    .help(session.title)
                Menu {
                    if let link = store.conversationRelationships.parent(of: session.id) {
                        Button("Open parent: \(link.parent.title)") { store.openRelatedConversation(link.parent) }
                    }
                    let children = store.conversationRelationships.children(of: session.id)
                    if !children.isEmpty {
                        Menu("Branches (\(children.count))") {
                            ForEach(children) { link in
                                Button(link.child.title) { store.openRelatedConversation(link.child) }
                            }
                        }
                    }
                    Button("Branch with context…") { showingBranch = true }
                    Button("Fork native history…") { beginMutation(.fork) }
                        .disabled(store.selectedLiveConversation?.canMutateHistory != true || boundaries.isEmpty)
                    Button("Rewind conversation…") { beginMutation(.revert) }
                        .disabled(store.selectedLiveConversation?.canMutateHistory != true || boundaries.isEmpty)
                    if store.conversationRelationships.parent(of: session.id) != nil {
                        Button("Add context to parent draft") { perform { try await store.mergeContextToParent(from: session) } }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                .menuIndicator(.hidden)
                .accessibilityLabel("Conversation actions")
                .help("Conversation actions")
                .disabled(store.historyActionInProgress || !pending.isEmpty)
                if store.historyActionInProgress { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }.font(.caption).buttonStyle(.borderless)
            ForEach(pending) { request in
                HStack(alignment: .top) {
                    Text("A previous \(request.operation) request needs inspection. It will not be retried automatically.")
                    if let result = request.result {
                        Button("Open result") { store.openRelatedConversation(result) }
                    }
                    Button("Mark inspected…") { inspectedOperation = request }
                }.font(.caption).foregroundStyle(.orange)
            }
            if let error = store.historyActionError ?? store.conversationRelationships.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let warning = store.workspaceCheckpointWarning {
                Text(warning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .sheet(isPresented: $showingBranch) { ConversationContextBranchSheet(store: store, source: session) }
        .sheet(isPresented: Binding(get: { operation != nil }, set: { if !$0 { operation = nil } })) {
            mutationSheet
        }
        .confirmationDialog("Mark the previous history request as inspected?", isPresented: Binding(
            get: { inspectedOperation != nil }, set: { if !$0 { inspectedOperation = nil } }), titleVisibility: .visible) {
            Button("Mark inspected") {
                guard let request = inspectedOperation else { return }
                do { try store.conversationRelationships.acknowledge(request); store.historyActionError = nil }
                catch { store.historyActionError = error.localizedDescription }
                inspectedOperation = nil
            }
            Button("Cancel", role: .cancel) { inspectedOperation = nil }
        } message: {
            Text("Inspect native history and any resulting conversation first. Clearing this recovery marker does not undo provider changes or send any message.")
        }
    }

    private var mutationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(operation == .fork ? "Fork native history" : "Rewind conversation").font(.title2)
            Text(operation == .fork
                 ? "Create a native branch through the selected turn. The source conversation and workspace files remain unchanged."
                 : "Remove the selected turn and later turns from the resumed conversation. Claude preserves the original as a separate branch. Workspace files are unchanged; use Checkpoints to restore an owned worktree separately.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Turn", selection: $selectedBoundary) {
                ForEach(boundaries) { boundary in Text(boundary.title).tag(Optional(boundary.id)) }
            }
            HStack {
                Spacer()
                Button("Cancel") { operation = nil }.keyboardShortcut(.cancelAction)
                Button(operation == .fork ? "Fork" : "Rewind", role: operation == .revert ? .destructive : nil) {
                    confirmingMutation = true
                }.disabled(selectedBoundary == nil || store.historyActionInProgress)
            }
        }.padding(24).frame(width: 540)
            .confirmationDialog("Apply this native history change?", isPresented: $confirmingMutation, titleVisibility: .visible) {
                Button(operation == .fork ? "Fork" : "Rewind", role: operation == .revert ? .destructive : nil) {
                    guard let operation, let boundary = boundaries.first(where: { $0.id == selectedBoundary }) else { return }
                    self.operation = nil
                    perform { _ = try await store.mutateConversation(source: session, operation: operation, boundary: boundary) }
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    private func beginMutation(_ value: ConversationHistoryMutation.Operation) {
        selectedBoundary = boundaries.last?.id
        operation = value
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        store.historyActionError = nil
        Task { do { try await action() } catch { store.historyActionError = error.localizedDescription } }
    }
}

struct ConversationContextBranchSheet: View {
    @Bindable var store: Store
    let source: Session
    var plan: ConversationWork.Plan? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var provider = "codex"
    @State private var isolatedWorkspace = false
    @State private var providers: [ConversationProviderDescriptor] = ConversationProviderCatalog.builtins
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Branch with context").font(.title2)
            Text("Prepare a new conversation on this Mac with a captured copy of this conversation as an attachment. Review its model, permissions and draft before sending.")
                .foregroundStyle(.secondary)
            if let plan {
                Text("The selected plan and implementation instructions will be added to the new draft.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView { Text(plan.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 160)
            }
            Picker("Provider", selection: $provider) {
                ForEach(providers) { Text($0.name).tag($0.id) }
            }
            if store.canAccessLocalFiles(for: source), source.cwd != nil {
                Toggle("Create an isolated worktree from the repository’s default branch", isOn: $isolatedWorkspace)
                Text(isolatedWorkspace ? "The new worktree starts from the configured default branch. Uncommitted files are not copied."
                     : "The branch shares the current working folder. Both conversations can edit the same files.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("The new conversation receives its own local folder.").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Prepare branch") {
                    Task {
                        do {
                            _ = try await store.branchWithContext(source: source, provider: provider,
                                isolatedWorkspace: isolatedWorkspace, plan: plan)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(store.historyActionInProgress).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540)
            .onAppear {
                do {
                    providers = try ConversationProviderCatalog.load().creatableProviders
                    if providers.contains(where: { $0.id == source.source }) { provider = source.source }
                } catch { self.error = error.localizedDescription }
            }
    }
}
