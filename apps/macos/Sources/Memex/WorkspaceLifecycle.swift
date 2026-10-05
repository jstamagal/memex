import Foundation
import MemexExecutionHostCore

typealias WorkspaceCheckout = MemexExecutionHostCore.WorkspaceCheckout
typealias ManagedWorkspaceEntry = MemexExecutionHostCore.ManagedWorkspaceEntry

extension ConversationWorkspaceClient {
    func checkouts(directory: URL) async throws -> [WorkspaceCheckout] {
        try await WorkspaceGitCommand.run { try store.checkouts(directory: directory, command: $0) }
    }
    func attach(directory: URL) async throws -> ConversationWorkspace {
        try await WorkspaceGitCommand.run { try store.attach(directory: directory, command: $0) }
    }
    func managedWorkspaces() async throws -> [ManagedWorkspaceEntry] {
        try await Task.detached(priority: .utility) { try store.managedWorkspaces() }.value
    }
    func setArchived(_ workspace: ConversationWorkspace, archived: Bool) async throws {
        try await WorkspaceGitCommand.run { try store.setArchived(workspace, archived: archived, command: $0) }
    }
    func removeCleanCheckout(_ workspace: ConversationWorkspace, otherWorkspaceDirectories: [URL], isBusy: Bool) async throws {
        try await WorkspaceGitCommand.run {
            try store.removeCleanCheckout(workspace, otherWorkspaceDirectories: otherWorkspaceDirectories, isBusy: isBusy, command: $0)
        }
    }
    func reattach(_ workspace: ConversationWorkspace) async throws -> ConversationWorkspace {
        try await WorkspaceGitCommand.run { try store.reattach(workspace, command: $0) }
    }
}
