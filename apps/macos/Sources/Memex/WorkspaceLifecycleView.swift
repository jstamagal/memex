import AppKit
import SwiftUI

struct WorkspaceLifecycleView: View {
    let client: ConversationWorkspaceClient
    let referencedDirectories: () -> [URL]
    let didSelect: (ConversationWorkspace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ManagedWorkspaceEntry] = []
    @State private var showingArchived = false
    @State private var busy = false
    @State private var error: String?
    @State private var cleanup: ConversationWorkspace?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Managed workspaces").font(.headline)
                Spacer()
                Toggle("Show archived", isOn: $showingArchived)
                Button("Done") { dismiss() }.disabled(busy)
            }
            Text("Archive keeps all files. Remove clean checkout frees its folder only when no retained chat uses it, and keeps the branch for reattachment.")
                .font(.caption).foregroundStyle(.secondary)
            List(entries.filter { showingArchived || !$0.archived }) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.workspace.branch ?? entry.id).font(.headline)
                    Text(entry.workspace.workingDirectory.path).font(.caption).textSelection(.enabled)
                    HStack {
                        Button(entry.removed ? "Reattach" : "Use folder") { run {
                            let workspace = try await client.reattach(entry.workspace)
                            didSelect(workspace)
                            dismiss()
                        } }.disabled(entry.workspace.state != .ready)
                        Button(entry.archived ? "Unarchive" : "Archive") { run {
                            try await client.setArchived(entry.workspace, archived: !entry.archived)
                        } }.disabled(entry.workspace.state != .ready)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([entry.workspace.workingDirectory]) }
                            .disabled(entry.removed)
                        if !entry.removed {
                            Button("Remove clean checkout…", role: .destructive) { cleanup = entry.workspace }
                                .disabled(entry.workspace.state != .ready)
                        }
                    }.font(.caption)
                    if entry.workspace.state == .failed { Text(entry.workspace.failure ?? "Preparation failed; resources retained.").font(.caption).foregroundStyle(.orange) }
                }.padding(.vertical, 4)
            }.frame(minHeight: 280).disabled(busy)
            if busy { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(20).frame(width: 650)
        .task { await refresh() }
        .confirmationDialog("Remove this clean checkout?", isPresented: Binding(get: { cleanup != nil }, set: { if !$0 { cleanup = nil } }), titleVisibility: .visible) {
            Button("Remove clean checkout", role: .destructive) {
                guard let workspace = cleanup else { return }
                cleanup = nil
                run { try await client.removeCleanCheckout(workspace, otherWorkspaceDirectories: referencedDirectories(), isBusy: false) }
            }
            Button("Cancel", role: .cancel) { cleanup = nil }
        } message: {
            Text("The operation refuses staged, unstaged, untracked or ignored files, and any checkout referenced by another chat. Its branch and commits remain. Archive instead to retain all files.")
        }
        .interactiveDismissDisabled(busy)
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation(); await refresh() }
            catch { self.error = error.localizedDescription }
        }
    }

    @MainActor private func refresh() async {
        do { entries = try await client.managedWorkspaces() }
        catch { self.error = error.localizedDescription }
    }
}
