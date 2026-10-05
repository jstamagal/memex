import Foundation
import Darwin

public final class ExecutionHost: @unchecked Sendable {
    struct Workspace: Codable { var id: String; var path: String; var worktreeID: String?; var repositoryWorkspaceID: String? }
    struct Receipt: Codable {
        var request: HostValue
        var status: String
        var result: HostValue?
        var error: String?
    }
    struct Queued: Codable {
        var command: HostedCommand
        var status: String
        var error: String?
    }
    struct Schedule: Codable {
        var id: String
        var conversationID: String
        var prompt: String
        var intervalSeconds: Double?
        var wallClock: HostWallClockSchedule?
        var nextRunAt: Date
        var paused: Bool
        var lastCommandID: String?
        var lastError: String?
        var lastSkippedAt: Date?
    }
    struct Catalog: Codable {
        var schemaVersion = 1
        var hostID: String
        var workspaces: [Workspace] = []
        var conversations: [HostedConversation] = []
        var receipts: [String: Receipt] = [:]
        var queue: [Queued] = []
        var heldConversations: Set<String> = []
        var schedules: [Schedule] = []
    }

    public let directory: URL
    public var hostID: String { lock.withLock { catalog.hostID } }
    private let lock = NSRecursiveLock()
    private let provider: any ExecutionProvider
    private let worktrees: ManagedWorkspaceStore
    private var catalog: Catalog
    private let now: () -> Date

    public init(directory: URL, workspaceRoots: [URL], providerFactory: (String) throws -> any ExecutionProvider,
                now: @escaping () -> Date = Date.init) throws {
        self.directory = directory
        self.now = now
        worktrees = ManagedWorkspaceStore(managedRoot: directory.appendingPathComponent("worktrees"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.requirePrivateDirectory(directory)
        let file = directory.appendingPathComponent("catalog.json")
        if FileManager.default.fileExists(atPath: file.path) {
            catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: file))
            guard catalog.schemaVersion == 1 else { throw HostFailure("version", "Unsupported execution catalog version") }
        } else { catalog = Catalog(hostID: UUID().uuidString) }
        let roots = try workspaceRoots.map { url -> Workspace in
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw HostFailure("workspace", "Registered workspace does not exist: \(canonical.path)")
            }
            return Workspace(id: canonical.path, path: canonical.path)
        }
        // Startup arguments are the authority. Removing a grant never leaves a stale root authorized.
        catalog.workspaces = roots
        for key in catalog.receipts.keys where catalog.receipts[key]?.status == "executing" {
            catalog.receipts[key]?.status = "uncertain"
            catalog.receipts[key]?.error = "Host restarted before command outcome was recorded; inspect native history before retrying."
        }
        for index in catalog.queue.indices where ["queued", "dispatching"].contains(catalog.queue[index].status) {
            catalog.queue[index].status = catalog.queue[index].status == "dispatching" ? "uncertain" : "held"
            catalog.heldConversations.insert(catalog.queue[index].command.conversationID)
        }
        provider = try providerFactory(catalog.hostID)
        try save()
    }

    public func handle(_ request: HostRequest) -> HostResponse {
        do {
            if request.method == "conversation.wait" { return HostResponse(id: request.id, result: try wait(request)) }
            return try lock.withLock { HostResponse(id: request.id, result: try route(request)) }
        } catch let error as HostFailure { return HostResponse(id: request.id, error: error) }
        catch { return HostResponse(id: request.id, error: HostFailure("host_error", error.localizedDescription)) }
    }

    private func authorize(_ request: HostRequest) throws {
        guard request.method == "host.info" || request.params["hostId"]?.string == catalog.hostID else {
            throw HostFailure("wrong_host", "This command does not identify the paired execution host.")
        }
    }

    private func route(_ request: HostRequest) throws -> HostValue {
        try authorize(request)
        let p = request.params
        switch request.method {
        case "host.info": return .object([
            "hostId": .string(catalog.hostID), "schemaVersion": .number(1),
            "providers": .array(provider.providers.map(HostValue.string)),
            "capabilities": .array(["conversation", "queue", "schedules", "schedules.wall_clock", "workspace.read", "worktree.lifecycle", "context_fork"].map(HostValue.string)),
            "browserAvailable": .bool(FileManager.default.fileExists(atPath: directory.appendingPathComponent("desktop.sock").path)),
            "executionPersistsWithoutClients": .bool(true)
        ])
        case "workspace.list": return try .encoded(availableWorkspaces())
        case "worktree.list":
            let repository = p["workspaceId"]?.string
            if let repository { _ = try registeredWorkspace(repository) }
            return .array(try managedEntries().filter { repository == nil || $0.workspace.sourceDirectory.path == repository }.map(worktreeValue))
        case "conversation.list":
            return .array(try catalog.conversations.map { conversation in
                var value = try HostValue.encoded(conversation).object
                value["connected"] = .bool(provider.isConnected(conversation.id))
                value["queueHeld"] = .bool(catalog.heldConversations.contains(conversation.id))
                return .object(value)
            })
        case "conversation.read": return try read(try required(p, "conversationId"))
        case "command.read":
            guard let receipt = catalog.receipts[try required(p, "commandId")] else { throw HostFailure("not_found", "Command receipt not found") }
            return try .encoded(receipt)
        case "schedule.list": return try .encoded(catalog.schedules)
        case "conversation.queue.list":
            let id = try required(p, "conversationId")
            _ = try conversation(id)
            return try .encoded(catalog.queue.filter { $0.command.conversationID == id })
        case "browser.describe": return try browser(request)
        default: return try mutate(request)
        }
    }

    /// Save the exact operation before any process boundary. Reusing a command ID with
    /// changed parameters is an error; a crash never turns an uncertain operation into a new send.
    private func mutate(_ request: HostRequest) throws -> HostValue {
        let allowed: Set<String> = ["conversation.create", "conversation.import", "conversation.resume", "conversation.send", "conversation.steer",
            "conversation.interrupt", "conversation.approval", "conversation.userInput", "conversation.model", "conversation.configuration",
            "conversation.queue.add", "conversation.queue.edit", "conversation.queue.cancel", "conversation.queue.reorder", "conversation.queue.resume",
            "conversation.queue.promote", "conversation.fork", "conversation.delegate", "schedule.upsert", "schedule.pause", "schedule.delete", "schedule.run", "browser.dispatch",
            "worktree.create", "worktree.archive", "worktree.reattach", "worktree.cleanup"]
        guard allowed.contains(request.method) else { throw HostFailure("method_not_found", "Unknown execution operation: \(request.method)") }
        let id = try required(request.params, "commandId")
        let identity: HostValue = .object(["method": .string(request.method), "params": .object(request.params)])
        if let existing = catalog.receipts[id] {
            guard existing.request == identity else { throw HostFailure("id_conflict", "Command ID was already used with different parameters") }
            if existing.status == "completed", let result = existing.result { return result }
            throw HostFailure(existing.status, existing.error ?? "Command delivery is still in progress; inspect its receipt.")
        }
        catalog.receipts[id] = Receipt(request: identity, status: "executing")
        try save()
        do {
            let result = try execute(request)
            catalog.receipts[id]?.status = "completed"
            catalog.receipts[id]?.result = result
            try save()
            return result
        } catch {
            // The provider may already have accepted a command. Keep the original ID and
            // explicit uncertainty even when an acknowledgement or persistence write fails.
            let rejectedCodes: Set<String> = ["invalid_params", "workspace_denied", "unsupported_provider", "not_found", "queue_state"]
            catalog.receipts[id]?.status = (error as? HostFailure).map { rejectedCodes.contains($0.code) } == true ? "rejected" : "uncertain"
            catalog.receipts[id]?.error = error.localizedDescription
            try save()
            throw error
        }
    }

    private func execute(_ request: HostRequest) throws -> HostValue {
        let p = request.params
        switch request.method {
        case "worktree.create":
            let root = URL(fileURLWithPath: try registeredWorkspace(required(p, "workspaceId")))
            let command = CommandRun()
            guard let repository = try worktrees.inspect(directory: root, command: command), repository.root.path == root.path else {
                throw HostFailure("workspace_denied", "Worktree creation requires an explicitly registered repository root")
            }
            try FileManager.default.createDirectory(at: worktrees.managedRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Self.requirePrivateDirectory(worktrees.managedRoot)
            let workspace = try worktrees.prepare(directory: root, newWorktree: true, baseRef: p["baseRef"]?.string, command: command)
            return try worktreeValue(ManagedWorkspaceEntry(workspace: workspace, archived: false, removed: false))
        case "worktree.archive", "worktree.reattach", "worktree.cleanup":
            let id = try required(p, "worktreeId")
            guard let entry = try managedEntries().first(where: { $0.id == id }) else { throw HostFailure("not_found", "Managed worktree is not registered under a currently granted repository") }
            _ = try registeredWorkspace(entry.workspace.sourceDirectory.path)
            let command = CommandRun()
            switch request.method {
            case "worktree.archive": try worktrees.setArchived(entry.workspace, archived: p["archived"]?.bool ?? true, command: command)
            case "worktree.reattach": _ = try worktrees.reattach(entry.workspace, command: command)
            default:
                // Every retained native conversation is a reference, including a
                // disconnected one with schedules or queued work. Removing the
                // checkout must never silently break its future resume location.
                let references = catalog.conversations.map { URL(fileURLWithPath: $0.cwd) }
                try worktrees.removeCleanCheckout(entry.workspace, otherWorkspaceDirectories: references, isBusy: false, command: command)
            }
            guard let updated = try managedEntries().first(where: { $0.id == id }) else { throw HostFailure("not_found", "Worktree recovery record is unavailable") }
            return try worktreeValue(updated)
        case "browser.dispatch": return try browser(request)
        case "conversation.import":
            let workspace = try required(p, "workspaceId")
            let cwd = try authorizedWorkspace(workspace)
            let chosen = try required(p, "provider")
            let native = try required(p, "nativeSessionId")
            let sourcePath = try required(p, "sourcePath")
            if let existing = catalog.conversations.first(where: { $0.provider == chosen && $0.nativeSessionID == native && $0.transcriptPath == sourcePath }) {
                guard existing.workspaceID == workspace else { throw HostFailure("identity_conflict", "Native session is already bound to another workspace") }
                return .object(["conversation": try .encoded(existing)])
            }
            guard !catalog.conversations.contains(where: { $0.provider == chosen && $0.nativeSessionID == native }) else {
                throw HostFailure("identity_conflict", "A different native transcript already uses this provider session ID; its original binding is preserved")
            }
            let imported = try provider.importConversation(id: "host-" + required(p, "commandId"), provider: chosen,
                nativeSessionID: native, sourcePath: sourcePath, workspaceID: workspace, cwd: cwd,
                title: p["title"]?.string ?? native)
            catalog.conversations.append(imported)
            return .object(["conversation": try .encoded(imported)])
        case "conversation.create", "conversation.fork", "conversation.delegate":
            let parent = try p["conversationId"]?.string.map(conversation)
            guard request.method == "conversation.create" || parent != nil else {
                throw HostFailure("invalid_params", "conversationId is required for a fork or delegation")
            }
            let workspace = p["workspaceId"]?.string ?? parent?.workspaceID
            guard let workspace else { throw HostFailure("invalid_params", "workspaceId is required") }
            let cwd = try authorizedWorkspace(workspace)
            let chosen = p["provider"]?.string ?? parent?.provider ?? "codex"
            guard provider.providers.contains(chosen) else { throw HostFailure("unsupported_provider", "Provider is not configured on this host") }
            let id = "host-" + (try required(p, "commandId"))
            var created = try provider.create(id: id, provider: chosen, workspaceID: workspace, cwd: cwd,
                                              title: p["title"]?.string ?? "New conversation")
            created.parentID = parent?.id
            catalog.conversations.append(created)
            try save()
            if request.method != "conversation.create" {
                guard let parent else { throw HostFailure("invalid_params", "conversationId is required for a fork or delegation") }
                // Context handoff is explicit, not a fabricated native fork. The original
                // provider session remains untouched and both identities are recorded.
                let snapshot = try provider.read(parent)
                let messages = snapshot["thread"]["messages"].array
                let context = messages.suffix(100).compactMap { message -> String? in
                    guard let text = message["content"].string else { return nil }
                    return "\(message["role"].string ?? "message"): \(text)"
                }.joined(separator: "\n\n")
                guard context.utf8.count <= 512_000 else { throw HostFailure("context_too_large", "Select a smaller context before forking") }
                let text = "Context handed off from conversation \(parent.id):\n\n\(context)\n\n\(p["text"]?.string ?? "Continue from this context.")"
                let command = HostedCommand(id: "handoff-" + (try required(p, "commandId")), issuedAt: timestamp(),
                    conversationID: created.id, action: "prompt", text: text)
                catalog.queue.append(Queued(command: command, status: "queued"))
            }
            return .object(["conversation": try .encoded(created), "forkKind": parent == nil ? .null : .string("context_handoff")])
        case "conversation.resume":
            let c = try conversation(required(p, "conversationId"))
            _ = try authorizedWorkspace(c.workspaceID)
            if !provider.isConnected(c.id) { try provider.resume(c) }
            return try read(c.id)
        case "conversation.send", "conversation.steer", "conversation.interrupt", "conversation.approval", "conversation.userInput", "conversation.model", "conversation.configuration":
            let actions = ["conversation.send": "prompt", "conversation.steer": "steer", "conversation.interrupt": "cancel",
                           "conversation.approval": "approval", "conversation.userInput": "userInput", "conversation.model": "model", "conversation.configuration": "configuration"]
            let command = try command(p, action: actions[request.method]!)
            _ = try authorizedWorkspace(conversation(command.conversationID).workspaceID)
            if command.action == "cancel" {
                catalog.heldConversations.insert(command.conversationID)
                try save() // Stop holds the queue even when native interruption is rejected.
            }
            return try provider.perform(command)
        case "conversation.queue.add":
            let command = try command(p, action: "prompt")
            _ = try conversation(command.conversationID)
            catalog.queue.append(Queued(command: command, status: "queued"))
            return try .encoded(catalog.queue.last!)
        case "conversation.queue.resume":
            let id = try required(p, "conversationId")
            _ = try conversation(id)
            // Only held, never dispatching/uncertain, entries may be rearmed automatically.
            for i in catalog.queue.indices where catalog.queue[i].command.conversationID == id && catalog.queue[i].status == "held" {
                catalog.queue[i].status = "queued"
            }
            catalog.heldConversations.remove(id)
            return .bool(true)
        case "conversation.queue.edit", "conversation.queue.cancel", "conversation.queue.promote":
            let id = try required(p, "queuedCommandId")
            guard let index = catalog.queue.firstIndex(where: { $0.command.id == id }),
                  catalog.queue[index].command.conversationID == (try required(p, "conversationId")),
                  ["queued", "held"].contains(catalog.queue[index].status) else {
                throw HostFailure("queue_state", "Only an undispatched queue entry can be edited, cancelled, or promoted")
            }
            if request.method == "conversation.queue.cancel" { catalog.queue[index].status = "cancelled" }
            else if request.method == "conversation.queue.edit" {
                let text = try required(p, "text")
                catalog.queue[index].command.text = text
                if let replacement = p["promptContent"] {
                    catalog.queue[index].command.promptContent = replacement
                } else if let content = catalog.queue[index].command.promptContent {
                    var blocks = content.array
                    let primary: HostValue = .object(["type": .string("text"), "text": .string(text)])
                    if blocks.first?["type"].string == "text" { blocks[0] = primary }
                    else { blocks.insert(primary, at: 0) }
                    catalog.queue[index].command.promptContent = .array(blocks)
                }
            }
            else {
                _ = try authorizedWorkspace(conversation(catalog.queue[index].command.conversationID).workspaceID)
                catalog.queue[index].command.action = "steer"
                catalog.queue[index].status = "dispatching"
                try save()
                do { _ = try provider.perform(catalog.queue[index].command); catalog.queue[index].status = "dispatched" }
                catch {
                    catalog.queue[index].status = "uncertain"
                    catalog.queue[index].error = error.localizedDescription
                    catalog.heldConversations.insert(catalog.queue[index].command.conversationID)
                    throw error
                }
            }
            return try .encoded(catalog.queue[index])
        case "conversation.queue.reorder":
            let conversationID = try required(p, "conversationId")
            let ids = p["commandIds"]?.array.compactMap(\.string) ?? []
            let entries = catalog.queue.filter { $0.command.conversationID == conversationID && ["queued", "held"].contains($0.status) }
            guard Set(ids).count == ids.count, Set(ids) == Set(entries.map { $0.command.id }) else {
                throw HostFailure("invalid_params", "Supply every undispatched queue ID exactly once")
            }
            let ordered = ids.compactMap { id in entries.first { $0.command.id == id } }
            var next = 0
            for index in catalog.queue.indices where catalog.queue[index].command.conversationID == conversationID && ["queued", "held"].contains(catalog.queue[index].status) {
                catalog.queue[index] = ordered[next]; next += 1
            }
            return try .encoded(ordered)
        case "schedule.upsert":
            let id = try required(p, "scheduleId")
            let c = try required(p, "conversationId")
            _ = try conversation(c)
            let interval: Double?
            let wallClock: HostWallClockSchedule?
            if let value = p["wallClock"] {
                guard p["intervalSeconds"] == nil, p["nextRunAt"] == nil,
                      let localTime = value["localTime"].string, let zone = value["timeZone"].string else {
                    throw HostFailure("invalid_params", "A wallClock schedule requires localTime, weekdays and timeZone; omit intervalSeconds and nextRunAt")
                }
                let numbers = value["weekdays"].array.compactMap(\.number)
                guard numbers.count == value["weekdays"].array.count, numbers.allSatisfy({ $0.isFinite && $0.rounded() == $0 && (1...7).contains($0) }) else {
                    throw HostFailure("invalid_params", "weekdays must contain ISO weekday integers 1 through 7")
                }
                wallClock = try HostWallClockSchedule(localTime: localTime, weekdays: numbers.map(Int.init), timeZone: zone)
                interval = nil
            } else {
                let seconds = p["intervalSeconds"]?.number ?? 0
                guard seconds.isFinite, seconds >= 60, seconds <= 31_536_000 else {
                    throw HostFailure("invalid_params", "Schedule interval must be between 60 seconds and one year")
                }
                interval = seconds
                wallClock = nil
            }
            let previous = catalog.schedules.first { $0.id == id }
            let next: Date
            if let value = p["nextRunAt"] {
                guard let text = value.string,
                      let parsed = ISO8601DateFormatter().date(from: text) ?? Self.fractionalDate(text) else {
                    throw HostFailure("invalid_params", "nextRunAt must be an RFC3339 timestamp")
                }
                next = parsed
            } else if let previous, previous.intervalSeconds == interval, previous.wallClock == wallClock {
                next = previous.nextRunAt
            } else if let wallClock { next = try wallClock.next(after: now()) }
            else { next = now().addingTimeInterval(interval!) }
            let schedule = Schedule(id: id, conversationID: c, prompt: try required(p, "text"), intervalSeconds: interval,
                                    wallClock: wallClock, nextRunAt: next, paused: p["paused"]?.bool ?? previous?.paused ?? false,
                                    lastCommandID: previous?.lastCommandID, lastError: previous?.lastError, lastSkippedAt: previous?.lastSkippedAt)
            catalog.schedules.removeAll { $0.id == id }; catalog.schedules.append(schedule)
            return try .encoded(schedule)
        case "schedule.pause", "schedule.delete", "schedule.run":
            let id = try required(p, "scheduleId")
            guard let index = catalog.schedules.firstIndex(where: { $0.id == id }) else { throw HostFailure("not_found", "Schedule not found") }
            if request.method == "schedule.delete" { catalog.schedules.remove(at: index); return .bool(true) }
            if request.method == "schedule.pause" { catalog.schedules[index].paused = p["paused"]?.bool ?? true }
            else { enqueueSchedule(index, commandID: "schedule-manual-" + (try required(p, "commandId"))) }
            return try .encoded(catalog.schedules[index])
        default: throw HostFailure("method_not_found", request.method)
        }
    }

    public func tick() throws {
        try lock.withLock {
            for index in catalog.schedules.indices where !catalog.schedules[index].paused && catalog.schedules[index].nextRunAt <= now() {
                let schedule = catalog.schedules[index]
                let id = "schedule-\(schedule.id)-\(Int64(schedule.nextRunAt.timeIntervalSince1970))"
                if let wallClock = schedule.wallClock {
                    // A late fixed-time run is skipped, not replayed later in a burst.
                    // The one-minute grace allows normal scheduler latency.
                    if now().timeIntervalSince(schedule.nextRunAt) < 60 { enqueueSchedule(index, commandID: id) }
                    else { catalog.schedules[index].lastSkippedAt = schedule.nextRunAt }
                    catalog.schedules[index].nextRunAt = try wallClock.next(after: now())
                } else if let interval = schedule.intervalSeconds {
                    enqueueSchedule(index, commandID: id)
                    // Preserve legacy interval coalescing. Advancing and enqueueing
                    // share one durable write, so restart cannot duplicate an occurrence.
                    catalog.schedules[index].nextRunAt = now().addingTimeInterval(interval)
                } else { throw HostFailure("schedule_time", "Schedule has no recurrence") }
                try save()
            }
            for index in catalog.queue.indices where catalog.queue[index].status == "queued" {
                let command = catalog.queue[index].command
                guard !catalog.heldConversations.contains(command.conversationID), provider.isConnected(command.conversationID) else { continue }
                let c = try conversation(command.conversationID)
                _ = try authorizedWorkspace(c.workspaceID)
                let snapshot = try provider.read(c)
                guard snapshot["ready"].bool == true, snapshot["running"].bool != true else { continue }
                catalog.queue[index].status = "dispatching"
                try save()
                do {
                    _ = try provider.perform(command)
                    catalog.queue[index].status = "dispatched"
                } catch {
                    catalog.queue[index].status = "uncertain"
                    catalog.queue[index].error = error.localizedDescription
                    catalog.heldConversations.insert(command.conversationID)
                }
                try save()
            }
        }
    }

    private func enqueueSchedule(_ index: Int, commandID: String) {
        let schedule = catalog.schedules[index]
        if !catalog.queue.contains(where: { $0.command.id == commandID }) {
            let command = HostedCommand(id: commandID, issuedAt: timestamp(), conversationID: schedule.conversationID,
                                        action: "prompt", text: schedule.prompt)
            catalog.queue.append(Queued(command: command, status: "queued"))
        }
        catalog.schedules[index].lastCommandID = commandID
    }

    private func browser(_ request: HostRequest) throws -> HostValue {
        let c = try conversation(required(request.params, "conversationId"))
        _ = try authorizedWorkspace(c.workspaceID)
        guard let source = c.transcriptPath else { throw HostFailure("capability_unavailable", "The provider has not established a native transcript identity for desktop attachment") }
        let desktopID = ["local", c.provider, c.nativeSessionID, source].joined(separator: "\u{1f}")
        var params: [String: HostValue] = ["conversationId": .string(desktopID)]
        if request.method == "browser.dispatch" {
            guard let payload = request.params["request"], payload["conversationID"].string == desktopID else {
                throw HostFailure("browser_scope", "Browser request does not match this hosted conversation's exact native identity")
            }
            params["request"] = payload
        }
        let response = try HostSocketClient.request(HostRequest(id: request.id, method: request.method, params: params), directory: directory)
        if let error = response.error { throw error }
        return response.result ?? .null
    }

    private func read(_ id: String) throws -> HostValue {
        let c = try conversation(id)
        var result = try provider.read(c).object
        result["conversation"] = try .encoded(c)
        result["queueHeld"] = .bool(catalog.heldConversations.contains(id))
        result["queue"] = try .encoded(catalog.queue.filter { $0.command.conversationID == id })
        return .object(result)
    }

    private func wait(_ request: HostRequest) throws -> HostValue {
        let timeout = min(30, max(0, request.params["timeoutSeconds"]?.number ?? 20))
        let deadline = Date().addingTimeInterval(timeout)
        let after = request.params["afterSequence"]?.number
        repeat {
            let value = try lock.withLock { () throws -> HostValue in
                try authorize(request)
                return try read(required(request.params, "conversationId"))
            }
            if value["thread"]["snapshotSequence"].number != after || value["running"].bool != true || Date() >= deadline { return value }
            Thread.sleep(forTimeInterval: 0.1)
        } while true
    }

    private func command(_ p: [String: HostValue], action: String) throws -> HostedCommand {
        let issuedAt = try required(p, "issuedAt")
        guard ISO8601DateFormatter().date(from: issuedAt) != nil || Self.fractionalDate(issuedAt) != nil else { throw HostFailure("invalid_params", "issuedAt must be an RFC3339 timestamp") }
        return HostedCommand(id: try required(p, "commandId"), issuedAt: issuedAt, conversationID: try required(p, "conversationId"),
            action: action, text: p["text"]?.string ?? "", optionID: p["optionId"]?.string,
            requestID: p["requestId"]?.string, promptContent: p["promptContent"])
    }
    private func conversation(_ id: String) throws -> HostedConversation {
        guard let value = catalog.conversations.first(where: { $0.id == id }) else { throw HostFailure("not_found", "Conversation not found on this host") }
        return value
    }
    private func authorizedWorkspace(_ id: String) throws -> String {
        if catalog.workspaces.contains(where: { $0.id == id }) { return try registeredWorkspace(id) }
        guard let entry = try managedEntries().first(where: { $0.workspace.workingDirectory.path == id && !$0.removed && $0.workspace.state == .ready }) else {
            throw HostFailure("workspace_denied", "Workspace is not registered on this execution host")
        }
        _ = try registeredWorkspace(entry.workspace.sourceDirectory.path)
        try ManagedWorkspaceStore.validateManaged(entry.workspace, managedRoot: worktrees.managedRoot, requireCheckout: true, command: CommandRun())
        return entry.workspace.workingDirectory.path
    }
    private func registeredWorkspace(_ id: String) throws -> String {
        guard let workspace = catalog.workspaces.first(where: { $0.id == id }),
              URL(fileURLWithPath: workspace.path).resolvingSymlinksInPath().path == workspace.path else {
            throw HostFailure("workspace_denied", "Workspace is not registered on this execution host")
        }
        return workspace.path
    }
    private func managedEntries() throws -> [ManagedWorkspaceEntry] {
        if FileManager.default.fileExists(atPath: worktrees.managedRoot.path) {
            try Self.requirePrivateDirectory(worktrees.managedRoot)
        }
        return try worktrees.managedWorkspaces().filter { entry in
            let workspace = entry.workspace
            if workspace.state == .ready {
                try ManagedWorkspaceStore.validateManaged(workspace, managedRoot: worktrees.managedRoot, requireCheckout: false, command: CommandRun())
            }
            return workspace.repositoryRoot?.path == workspace.sourceDirectory.path
                && catalog.workspaces.contains(where: { $0.id == workspace.sourceDirectory.path })
        }
    }
    private func availableWorkspaces() throws -> [Workspace] {
        catalog.workspaces + (try managedEntries().filter { !$0.archived && !$0.removed && $0.workspace.state == .ready }.map { entry in
            Workspace(id: entry.workspace.workingDirectory.path, path: entry.workspace.workingDirectory.path,
                worktreeID: entry.id, repositoryWorkspaceID: entry.workspace.sourceDirectory.path)
        })
    }
    private func worktreeValue(_ entry: ManagedWorkspaceEntry) throws -> HostValue {
        let workspace = entry.workspace
        return .object(["id": .string(entry.id), "workspaceId": .string(workspace.workingDirectory.path),
            "repositoryWorkspaceId": .string(workspace.sourceDirectory.path), "path": .string(workspace.workingDirectory.path),
            "branch": workspace.branch.map(HostValue.string) ?? .null, "baseRef": workspace.baseRef.map(HostValue.string) ?? .null,
            "state": .string(workspace.state.rawValue), "failure": workspace.failure.map(HostValue.string) ?? .null,
            "archived": .bool(entry.archived), "removed": .bool(entry.removed),
            "referencedBy": .array(catalog.conversations.filter { $0.cwd == workspace.workingDirectory.path || $0.cwd.hasPrefix(workspace.workingDirectory.path + "/") }.map { .string($0.id) })])
    }
    private func required(_ p: [String: HostValue], _ key: String) throws -> String {
        let limit = key == "text" ? 1_048_576 : (["commandId", "scheduleId"].contains(key) ? 128 : 512)
        guard let value = p[key]?.string, !value.isEmpty, value.utf8.count <= limit,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && key != "text" }) else {
            throw HostFailure("invalid_params", "Missing or invalid \(key)")
        }
        return value
    }
    private func timestamp() -> String { now().ISO8601Format() }
    private static func fractionalDate(_ value: String) -> Date? {
        let format = ISO8601DateFormatter(); format.formatOptions.insert(.withFractionalSeconds); return format.date(from: value)
    }
    private func save() throws {
        let file = directory.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(catalog).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw HostFailure("persistence", "Cannot open execution catalog for synchronization") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw HostFailure("persistence", "Cannot synchronize execution catalog") }
        let directoryFD = Darwin.open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw HostFailure("persistence", "Cannot synchronize execution directory") }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw HostFailure("persistence", "Cannot synchronize execution directory") }
    }
    public static func requirePrivateDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw HostFailure("permissions", "Execution directory must be owned by this user, mode 0700, and not a symlink")
        }
    }
}
