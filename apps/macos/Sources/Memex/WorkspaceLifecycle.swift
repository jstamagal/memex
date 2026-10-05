import Foundation

struct WorkspaceCheckout: Identifiable, Sendable, Equatable {
    let directory: URL
    let branch: String?
    let commit: String?
    let locked: Bool
    var id: String { directory.path }
}

struct ManagedWorkspaceEntry: Identifiable, Sendable {
    let workspace: ConversationWorkspace
    let archived: Bool
    let removed: Bool
    var id: String { workspace.id }
}

extension ConversationWorkspaceClient {
    private struct Lifecycle: Codable { var archived = false; var removed = false }

    func checkouts(directory: URL) async throws -> [WorkspaceCheckout] {
        try await WorkspaceGitCommand.run { command in
            let root = try WorkspaceGitCommand.root(directory, command: command)
            let bytes = try WorkspaceGitCommand.data(root, ["worktree", "list", "--porcelain", "-z"], command: command)
            var result: [WorkspaceCheckout] = []
            var path: String?
            var branch: String?
            var commit: String?
            var locked = false
            func append() {
                if let path {
                    result.append(.init(directory: URL(fileURLWithPath: path, isDirectory: true)
                        .standardizedFileURL.resolvingSymlinksInPath(), branch: branch, commit: commit, locked: locked))
                }
                path = nil; branch = nil; commit = nil; locked = false
            }
            for field in bytes.split(separator: 0, omittingEmptySubsequences: false).map({ String(decoding: $0, as: UTF8.self) }) {
                if field.isEmpty { append() }
                else if field.hasPrefix("worktree ") { path = String(field.dropFirst(9)) }
                else if field.hasPrefix("branch refs/heads/") { branch = String(field.dropFirst(18)) }
                else if field.hasPrefix("HEAD ") { commit = String(field.dropFirst(5)) }
                else if field == "locked" || field.hasPrefix("locked ") { locked = true }
            }
            append()
            return result
        }
    }

    /// Reuse an existing checkout as-is, without claiming ownership of an
    /// arbitrary directory or copying another chat's dirty files.
    func attach(directory: URL) async throws -> ConversationWorkspace {
        let root = try await WorkspaceGitCommand.run { try WorkspaceGitCommand.root(directory, command: $0) }
        let manifest = root.deletingLastPathComponent().appendingPathComponent("workspace.json")
        let canonicalManaged = managedRoot.standardizedFileURL.resolvingSymlinksInPath()
        if root.path.hasPrefix(canonicalManaged.path + "/"),
           let workspace = try? JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: manifest)),
           workspace.worktreeRoot?.standardizedFileURL.resolvingSymlinksInPath() == root,
           workspace.metadataURL == manifest, workspace.state == .ready {
            return workspace
        }
        return try await prepare(directory: directory, mode: .existingDirectory)
    }

    func managedWorkspaces() async throws -> [ManagedWorkspaceEntry] {
        let managedRoot = self.managedRoot
        return try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            guard manager.fileExists(atPath: managedRoot.path) else { return [] }
            return try manager.contentsOfDirectory(at: managedRoot, includingPropertiesForKeys: [.isDirectoryKey])
                .compactMap { reservation in
                    let manifest = reservation.appendingPathComponent("workspace.json")
                    guard manager.fileExists(atPath: manifest.path) else { return nil }
                    let workspace = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: manifest))
                    guard reservation.lastPathComponent == workspace.id else { throw WorkspaceGitError(message: "A workspace manifest has an unexpected identity: \(manifest.path)") }
                    let lifecycle = try Self.readLifecycle(workspace)
                    return ManagedWorkspaceEntry(workspace: workspace, archived: lifecycle.archived, removed: lifecycle.removed)
                }
        }.value
    }

    /// Archiving hides the entry but deliberately retains every file, including
    /// ignored output and uncommitted work. Disk cleanup is a separate action.
    func setArchived(_ workspace: ConversationWorkspace, archived: Bool) async throws {
        try await WorkspaceGitCommand.run { command in
            try Self.validateManaged(workspace, managedRoot: managedRoot, requireCheckout: false, command: command)
            var lifecycle = try Self.readLifecycle(workspace)
            lifecycle.archived = archived
            try Self.writeLifecycle(lifecycle, workspace: workspace)
        }
    }

    /// Removes only an idle, owned, entirely clean checkout. Ignored files count
    /// as work. The branch and all commits remain for explicit reattachment.
    func removeCleanCheckout(_ workspace: ConversationWorkspace, otherWorkspaceDirectories: [URL], isBusy: Bool) async throws {
        try await WorkspaceGitCommand.run { command in
            let isolation = WorkspaceIsolation(workspace: workspace, otherWorkspaceDirectories: otherWorkspaceDirectories, isBusy: isBusy)
            try WorkspaceCheckpointClient.validateIsolation(isolation, managedRoot: managedRoot, command: command)
            guard let checkout = workspace.worktreeRoot, let repository = workspace.repositoryRoot,
                  let branch = workspace.branch else { throw WorkspaceGitError(message: "Workspace ownership is unavailable.") }
            let current = try WorkspaceGitCommand.text(checkout, ["branch", "--show-current"], command: command)
            guard current == branch else { throw WorkspaceGitError(message: "The checkout changed branches. Keep it or reattach it explicitly before cleanup.") }
            let status = try WorkspaceGitCommand.text(checkout, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored"], command: command)
            guard status.isEmpty else { throw WorkspaceGitError(message: "This checkout contains staged, unstaged, untracked or ignored files. Cleanup was refused; archive it to retain those files.") }
            _ = try WorkspaceGitCommand.text(repository, ["worktree", "remove", "--", checkout.path], command: command, timeout: 120)
            var lifecycle = try Self.readLifecycle(workspace)
            lifecycle.removed = true
            lifecycle.archived = true
            try Self.writeLifecycle(lifecycle, workspace: workspace)
        }
    }

    func reattach(_ workspace: ConversationWorkspace) async throws -> ConversationWorkspace {
        try await WorkspaceGitCommand.run { command in
            try Self.validateManaged(workspace, managedRoot: managedRoot, requireCheckout: false, command: command)
            guard let checkout = workspace.worktreeRoot, let repository = workspace.repositoryRoot,
                  let branch = workspace.branch else { throw WorkspaceGitError(message: "Workspace ownership is unavailable.") }
            if !FileManager.default.fileExists(atPath: checkout.path) {
                _ = try WorkspaceGitCommand.text(repository, ["worktree", "add", "--", checkout.path, branch], command: command, timeout: 120)
            }
            try Self.validateManaged(workspace, managedRoot: managedRoot, requireCheckout: true, command: command)
            try Self.writeLifecycle(Lifecycle(), workspace: workspace)
            return workspace
        }
    }

    private static func validateManaged(_ workspace: ConversationWorkspace, managedRoot: URL,
                                        requireCheckout: Bool, command: CommandRun) throws {
        let reservation = managedRoot.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(workspace.id)
        // URL equality includes the directory hint/trailing slash. Ownership is
        // a filesystem identity check, including after cleanup removes checkout.
        guard UUID(uuidString: workspace.id) != nil, reservation.resolvingSymlinksInPath().path == reservation.path,
              workspace.state == .ready, let manifest = workspace.metadataURL,
              manifest.standardizedFileURL.path == reservation.appendingPathComponent("workspace.json").path,
              workspace.worktreeRoot?.standardizedFileURL.path == reservation.appendingPathComponent("checkout").path,
              try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: manifest)) == workspace else {
            throw WorkspaceGitError(message: "Only verified Memex-owned worktrees can be managed here.")
        }
        if requireCheckout {
            guard try WorkspaceGitCommand.root(reservation.appendingPathComponent("checkout"), command: command).path == reservation.appendingPathComponent("checkout").path else {
                throw WorkspaceGitError(message: "The managed checkout resolves to a different repository.")
            }
        }
    }

    private static func readLifecycle(_ workspace: ConversationWorkspace) throws -> Lifecycle {
        guard let manifest = workspace.metadataURL else { throw WorkspaceGitError(message: "The workspace has no ownership manifest.") }
        let url = manifest.deletingLastPathComponent().appendingPathComponent("lifecycle.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Lifecycle() }
        return try JSONDecoder().decode(Lifecycle.self, from: Data(contentsOf: url))
    }

    private static func writeLifecycle(_ value: Lifecycle, workspace: ConversationWorkspace) throws {
        guard let manifest = workspace.metadataURL else { throw WorkspaceGitError(message: "The workspace has no ownership manifest.") }
        let url = manifest.deletingLastPathComponent().appendingPathComponent("lifecycle.json")
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
