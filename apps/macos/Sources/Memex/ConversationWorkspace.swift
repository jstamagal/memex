import Foundation
import Darwin

struct ConversationWorkspaceRepository: Sendable, Equatable {
    let root: URL
    let defaultBaseRef: String?
    let localBranches: [String]
}

struct ConversationWorkspace: Identifiable, Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case existing, preparing, ready, failed }
    let id: String
    let workingDirectory: URL
    let sourceDirectory: URL
    let repositoryRoot: URL?
    let baseRef: String?
    let baseCommit: String?
    let branch: String?
    let worktreeRoot: URL?
    let metadataURL: URL?
    var state: State
    var failure: String?
}

struct ConversationWorkspacePreparationError: LocalizedError, Sendable {
    let message: String
    /// A failed Git command can have created a branch or part of a checkout.
    /// Retain the reservation and manifest so neither is silently orphaned.
    var retainedWorkspace: ConversationWorkspace? = nil
    var errorDescription: String? {
        guard let location = retainedWorkspace?.metadataURL?.deletingLastPathComponent().path else { return message }
        return message + "\nWorkspace resources were retained at \(location)."
    }
}

struct ConversationWorkspaceClient: Sendable {
    let managedRoot: URL
    let temporaryRoot: URL
    private let makeID: @Sendable () -> UUID

    init(managedRoot: URL? = nil, temporaryRoot: URL? = nil, makeID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.managedRoot = managedRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dev.memex.app/Worktrees", isDirectory: true)
        self.temporaryRoot = temporaryRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dev.memex.app/ProjectlessChats", isDirectory: true)
        self.makeID = makeID
    }

    /// A chat without a saved project still owns a durable working folder.
    /// Keep it after completion or failure: provider history can resume here and
    /// generated files must not disappear through OS temporary-directory cleanup.
    func prepareTemporaryDirectory() async throws -> ConversationWorkspace {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            guard temporaryRoot.isFileURL, temporaryRoot.path.hasPrefix("/"), !temporaryRoot.path.contains("\0") else {
                throw ConversationWorkspacePreparationError(message: "The chat workspace folder must be a local absolute path.")
            }
            let manager = FileManager.default
            try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let id = makeID().uuidString.lowercased()
            let reservation = temporaryRoot.appendingPathComponent(id, isDirectory: true)
            guard reservation.path.withCString({ mkdir($0, 0o700) }) == 0 else {
                throw ConversationWorkspacePreparationError(message: "Could not reserve a chat folder at \(reservation.path): \(String(cString: strerror(errno)))")
            }
            let directory = reservation.appendingPathComponent("files", isDirectory: true)
            var workspace = ConversationWorkspace(id: id, workingDirectory: directory,
                sourceDirectory: directory, repositoryRoot: nil, baseRef: nil, baseCommit: nil,
                branch: nil, worktreeRoot: nil, metadataURL: reservation.appendingPathComponent("workspace.json"), state: .preparing)
            do {
                try Self.persist(workspace)
                try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
                workspace.state = .ready
                try Self.persist(workspace)
                return workspace
            } catch {
                workspace.state = .failed
                workspace.failure = error.localizedDescription
                var message = "The chat folder could not be prepared: \(error.localizedDescription)"
                do { try Self.persist(workspace) }
                catch { message += " The recovery record could not be saved: \(error.localizedDescription)" }
                throw ConversationWorkspacePreparationError(message: message, retainedWorkspace: workspace)
            }
        }.value
    }

    func inspect(directory: URL) async throws -> ConversationWorkspaceRepository? {
        try await Self.run { command in
            try Self.repository(try LocalProjects.validatedDirectory(directory), command: command)
        }
    }

    func prepare(directory: URL, mode: ConversationWorkspaceMode, baseRef: String? = nil) async throws -> ConversationWorkspace {
        try await Self.run { command in
            let directory = try LocalProjects.validatedDirectory(directory)
            let repository = try Self.repository(directory, command: command)
            if mode == .existingDirectory {
                return ConversationWorkspace(id: UUID().uuidString, workingDirectory: directory,
                    sourceDirectory: directory,
                    repositoryRoot: repository?.root, baseRef: nil, baseCommit: nil,
                    branch: nil, worktreeRoot: nil, metadataURL: nil, state: .existing)
            }
            guard let repository else {
                throw ConversationWorkspacePreparationError(message: "This project is not a Git repository. Use its existing folder.")
            }
            guard let selectedRef = baseRef?.nilIfBlank ?? repository.defaultBaseRef else {
                throw ConversationWorkspacePreparationError(message: "Git has no unambiguous default branch recorded locally. Choose a base branch for the new worktree.")
            }
            guard !selectedRef.contains("\0"), !selectedRef.contains("\n") else {
                throw ConversationWorkspacePreparationError(message: "Choose a valid Git base ref.")
            }
            let commit = try Self.git(repository.root, ["rev-parse", "--verify", "--end-of-options", selectedRef + "^{commit}"], command: command)
            let relativePath: String
            if directory.path == repository.root.path { relativePath = "" }
            else if directory.path.hasPrefix(repository.root.path + "/") {
                relativePath = String(directory.path.dropFirst(repository.root.path.count + 1))
            } else { throw ConversationWorkspacePreparationError(message: "The project folder is outside its Git repository.") }
            if !relativePath.isEmpty {
                let type = try Self.git(repository.root, ["cat-file", "-t", commit + ":" + relativePath], command: command)
                guard type == "tree" else {
                    throw ConversationWorkspacePreparationError(message: "The project folder does not exist in the selected base ref.")
                }
            }
            let id = makeID().uuidString.lowercased()
            guard managedRoot.isFileURL, managedRoot.path.hasPrefix("/"), !managedRoot.path.contains("\0") else {
                throw ConversationWorkspacePreparationError(message: "The managed worktree folder must be a local absolute path.")
            }
            let reservation = managedRoot.appendingPathComponent(id, isDirectory: true)
            let checkout = reservation.appendingPathComponent("checkout", isDirectory: true)
            let branch = "memex-chat-" + id
            let manager = FileManager.default
            try manager.createDirectory(at: managedRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // An exclusive reservation makes even an ID collision non-destructive.
            guard reservation.path.withCString({ mkdir($0, 0o700) }) == 0 else {
                throw ConversationWorkspacePreparationError(message: "Could not reserve a new worktree folder at \(reservation.path): \(String(cString: strerror(errno)))")
            }
            var workspace = ConversationWorkspace(id: id,
                workingDirectory: relativePath.isEmpty ? checkout : checkout.appendingPathComponent(relativePath, isDirectory: true),
                sourceDirectory: directory,
                repositoryRoot: repository.root, baseRef: selectedRef, baseCommit: commit,
                branch: branch, worktreeRoot: checkout, metadataURL: reservation.appendingPathComponent("workspace.json"), state: .preparing)
            do {
                try Self.persist(workspace)
                // Resolve the commit first so an advancing ref cannot change this
                // checkout's base. Never copy, commit or stash the source checkout.
                _ = try Self.git(repository.root, ["worktree", "add", "--no-track", "-b", branch, "--", checkout.path, commit],
                                 command: command, timeout: 120)
                _ = try LocalProjects.validatedDirectory(workspace.workingDirectory)
                workspace.state = .ready
                try Self.persist(workspace)
                return workspace
            } catch {
                workspace.state = .failed
                workspace.failure = error.localizedDescription
                var message = "The new worktree could not be prepared: \(error.localizedDescription)"
                do { try Self.persist(workspace) }
                catch { message += " The recovery record could not be saved: \(error.localizedDescription)" }
                throw ConversationWorkspacePreparationError(message: message, retainedWorkspace: workspace)
            }
        }
    }

    private static func persist(_ workspace: ConversationWorkspace) throws {
        guard let url = workspace.metadataURL else { return }
        try JSONEncoder().encode(workspace).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func repository(_ directory: URL, command: CommandRun) throws -> ConversationWorkspaceRepository? {
        let root: URL
        do {
            root = URL(fileURLWithPath: try git(directory, ["rev-parse", "--show-toplevel"], command: command), isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
        } catch {
            if error.localizedDescription.contains("not a git repository") { return nil }
            throw error
        }
        let branches = try git(root, ["for-each-ref", "--format=%(refname:short)", "refs/heads"], command: command)
            .split(separator: "\n").map(String.init)
        let remoteRefs = try git(root, ["for-each-ref", "--format=%(refname)%00%(symref)", "refs/remotes"], command: command)
        let defaults = remoteRefs.split(separator: "\n").compactMap { row -> (String, String)? in
            let fields = row.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0].hasSuffix("/HEAD"), !fields[1].isEmpty else { return nil }
            return (String(fields[0]), String(fields[1]))
        }
        let defaultRef = defaults.first(where: { $0.0 == "refs/remotes/origin/HEAD" })?.1
            ?? (defaults.count == 1 ? defaults[0].1 : nil)
        return ConversationWorkspaceRepository(root: root, defaultBaseRef: defaultRef, localBranches: branches)
    }

    private static func run<T: Sendable>(_ body: @escaping @Sendable (CommandRun) throws -> T) async throws -> T {
        let command = CommandRun()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) { try body(command) }.value
        } onCancel: { command.cancel() }
    }

    private static func git(_ directory: URL, _ arguments: [String], command: CommandRun,
                            timeout: TimeInterval = 15) throws -> String {
        // Keep the established process watchdog/cancellation implementation, while
        // removing inherited Git selectors and disabling checkout hooks/fsmonitor.
        let unset = ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("GIT_") }.sorted()
            .flatMap { ["-u", $0] }
        let data = try command.execute(executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: unset + ["LC_ALL=C", "GIT_TERMINAL_PROMPT=0", "/usr/bin/git", "--no-optional-locks",
                "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "submodule.recurse=false", "-C", directory.path] + arguments,
            timeout: timeout)
        let text = String(decoding: data, as: UTF8.self)
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}
