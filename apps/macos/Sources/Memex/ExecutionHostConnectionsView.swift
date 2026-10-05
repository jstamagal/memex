import SwiftUI
import MemexExecutionHostCore

@MainActor
struct ExecutionHostConnectionsView: View {
    var onOpen: (Session, ExecutionHostConnection, String) -> Void
    @State private var connections = ExecutionHostConnections.shared
    @State private var selected: ExecutionHostConnection?
    @State private var endpoint = "http://127.0.0.1:6363"
    @State private var name = ""
    @State private var machine = "local"
    @State private var token = ""
    @State private var error: String?
    @State private var busy = false
    @State private var conversations: [HostValue] = []
    @State private var workspaces: [HostValue] = []
    @State private var providers: [String] = []
    @State private var workspace = ""
    @State private var provider = "codex"
    @State private var title = ""
    @State private var schedules: [HostValue] = []
    @State private var scheduleID = UUID().uuidString
    @State private var scheduleConversation = ""
    @State private var scheduleText = ""
    @State private var interval = 3600
    @State private var fixedLocalTime = false
    @State private var scheduleTime = "09:00"
    @State private var scheduleDays: Set<Int> = [1, 2, 3, 4, 5]
    @State private var scheduleTimeZone = TimeZone.current.identifier
    @State private var worktrees: [HostValue] = []
    @State private var supportsWorktrees = false
    @State private var repository = ""
    @State private var baseRef = ""
    @State private var cleanupWorktree: HostValue?
    @State private var pending: [HostRequest] = []
    @State private var receipt: String?
    @State private var reconciling: HostRequest?

    var body: some View {
        ScrollView {
            Form {
                Section("Execution hosts") {
                    Text("Agents run on the paired host and continue when this window closes. Register permitted folders when starting MemexExecutionHost.")
                        .foregroundStyle(.secondary)
                    ForEach(connections.hosts) { host in
                        HStack {
                            Button { run { try await load(host) } } label: {
                                VStack(alignment: .leading) {
                                    Text(host.name)
                                    Text("\(host.machineID) · \(host.endpoint.host ?? "")").font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                            Spacer()
                            if selected?.id == host.id { Image(systemName: "checkmark") }
                            Button("Remove pairing") {
                                do {
                                    try connections.remove(host)
                                    if selected?.id == host.id { selected = nil; conversations = []; schedules = []; pending = [] }
                                } catch { self.error = error.localizedDescription }
                            }.buttonStyle(.borderless)
                        }
                    }
                    TextField("Display name", text: $name)
                    TextField("Exact Memex machine identifier", text: $machine)
                    TextField("HTTPS server or loopback tunnel URL", text: $endpoint)
                    SecureField("Execution pairing token", text: $token)
                    Text("Use the host's private state/execution/control-token. History login tokens do not grant execution. Credentials are stored in Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Pair host") {
                        run {
                            guard let url = URL(string: endpoint) else { throw HostFailure("endpoint", "Enter a valid host URL") }
                            let host = try await connections.pair(name: name, machineID: machine, endpoint: url,
                                                                  token: token.trimmingCharacters(in: .whitespacesAndNewlines))
                            token = ""
                            try await load(host)
                        }
                    }.disabled(busy || token.isEmpty)
                }
                if let selected {
                    Section("Conversations on \(selected.name)") {
                        ForEach(conversations, id: \.identity) { conversation in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(conversation["title"].string ?? "Conversation")
                                    Text("\(conversation["provider"].string ?? "") · \(conversation["cwd"].string ?? "")").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Open") {
                                    do {
                                        let session = try RemoteConversationRuntime.session(conversation, connection: selected)
                                        onOpen(session, selected, conversation["id"].string ?? "")
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                        Picker("Workspace", selection: $workspace) {
                            Text("Choose a registered folder").tag("")
                            ForEach(workspaces, id: \.identity) { item in Text(item["path"].string ?? "").tag(item["id"].string ?? "") }
                        }
                        Picker("Provider", selection: $provider) { ForEach(providers, id: \.self) { Text($0).tag($0) } }
                        TextField("New conversation title", text: $title)
                        Button("Create conversation") {
                            run {
                                let client = try connections.client(selected)
                                let result = try await client.call("conversation.create", params: ["provider": .string(provider),
                                    "workspaceId": .string(workspace), "title": .string(title.isEmpty ? "New conversation" : title)], mutation: true)
                                try await load(selected)
                                let value = result["conversation"]
                                onOpen(try RemoteConversationRuntime.session(value, connection: selected), selected, value["id"].string ?? "")
                            }
                        }.disabled(busy || workspace.isEmpty || !providers.contains(provider))
                    }
                    if supportsWorktrees { worktreeSection(selected) }
                    Section("Schedules") {
                        Text("Schedules run through this host's durable queue. Stopped or recovered queues stay held until explicitly resumed.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(schedules, id: \.identity) { schedule in
                            VStack(alignment: .leading) {
                                Text(schedule["prompt"].string ?? "Scheduled prompt").lineLimit(2)
                                Text("\(scheduleDescription(schedule)) · \(schedule["paused"].bool == true ? "Paused" : "Active")")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Edit") {
                                        scheduleID = schedule["id"].string ?? UUID().uuidString
                                        scheduleConversation = schedule["conversationID"].string ?? ""
                                        scheduleText = schedule["prompt"].string ?? ""
                                        interval = Int(schedule["intervalSeconds"].number ?? 3600)
                                        fixedLocalTime = schedule["wallClock"] != .null
                                        if fixedLocalTime {
                                            scheduleTime = schedule["wallClock"]["localTime"].string ?? "09:00"
                                            scheduleDays = Set(schedule["wallClock"]["weekdays"].array.compactMap { $0.number.map(Int.init) })
                                            scheduleTimeZone = schedule["wallClock"]["timeZone"].string ?? TimeZone.current.identifier
                                        }
                                    }
                                    Button(schedule["paused"].bool == true ? "Resume" : "Pause") {
                                        scheduleAction("pause", schedule, ["paused": .bool(schedule["paused"].bool != true)])
                                    }
                                    Button("Run now") { scheduleAction("run", schedule) }
                                    Button("Delete", role: .destructive) { scheduleAction("delete", schedule) }
                                }.buttonStyle(.borderless)
                            }
                        }
                        Picker("Conversation", selection: $scheduleConversation) {
                            Text("Choose a conversation").tag("")
                            ForEach(conversations, id: \.identity) { Text($0["title"].string ?? "Conversation").tag($0["id"].string ?? "") }
                        }
                        TextField("Prompt", text: $scheduleText, axis: .vertical).lineLimit(3...6)
                        Toggle("Fixed local time and weekdays", isOn: $fixedLocalTime)
                        if fixedLocalTime {
                            TextField("Local time (HH:mm)", text: $scheduleTime)
                            TextField("Time zone", text: $scheduleTimeZone)
                            HStack {
                                ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { index, day in
                                    Toggle(day, isOn: Binding(get: { scheduleDays.contains(index + 1) }, set: { selected in
                                        if selected { scheduleDays.insert(index + 1) } else { scheduleDays.remove(index + 1) }
                                    }))
                                }
                            }
                            Text("Daylight saving gaps and occurrences missed by more than a minute are skipped. Repeated local times run once.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else { TextField("Interval in seconds", value: $interval, format: .number) }
                        Button("Save schedule") {
                            run {
                                var parameters: [String: HostValue] = ["scheduleId": .string(scheduleID),
                                    "conversationId": .string(scheduleConversation), "text": .string(scheduleText)]
                                if fixedLocalTime {
                                    parameters["wallClock"] = .object(["localTime": .string(scheduleTime),
                                        "weekdays": .array(scheduleDays.sorted().map { .number(Double($0)) }), "timeZone": .string(scheduleTimeZone)])
                                } else { parameters["intervalSeconds"] = .number(Double(interval)) }
                                _ = try await connections.client(selected).call("schedule.upsert", params: parameters, mutation: true)
                                scheduleID = UUID().uuidString; scheduleText = ""
                                try await load(selected)
                            }
                        }.disabled(busy || scheduleConversation.isEmpty || scheduleText.isEmpty || (fixedLocalTime ? scheduleDays.isEmpty || scheduleTime.isEmpty || scheduleTimeZone.isEmpty : interval < 60))
                    }
                    if !pending.isEmpty {
                        Section("Outgoing commands awaiting a receipt") {
                            Text("Keep the original command identity when checking or retrying. An uncertain host receipt requires inspecting the native conversation.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(pending.enumerated()), id: \.offset) { _, request in
                                VStack(alignment: .leading) {
                                    Text(request.method)
                                    Text(request.params["commandId"]?.string ?? "").font(.caption.monospaced())
                                    HStack {
                                        Button("Inspect receipt") {
                                            run {
                                                let result = try await connections.client(selected).call("command.read", params: ["commandId": request.params["commandId"] ?? .null])
                                                receipt = "\(result["status"].string ?? "Unknown"): \(result["error"].string ?? "Recorded by host")"
                                            }
                                        }
                                        Button("Retry exact command") {
                                            run {
                                                _ = try await connections.client(selected).call(request.method, params: request.params, mutation: true)
                                                try await load(selected)
                                            }
                                        }
                                        Button("Reconcile after inspection") { reconciling = request }
                                    }
                                }
                            }
                            if let receipt { Text(receipt).textSelection(.enabled) }
                        }
                    }
                    Button("Refresh host") { run { try await load(selected) } }.disabled(busy)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if busy { ProgressView() }
            }.formStyle(.grouped)
        }.frame(minWidth: 560, idealWidth: 680, minHeight: 560)
        .confirmationDialog("Mark this outgoing command reconciled?", isPresented: Binding(
            get: { reconciling != nil }, set: { if !$0 { reconciling = nil } }
        )) {
            Button("Mark reconciled") {
                guard let selected, let request = reconciling else { return }
                reconciling = nil
                run {
                    try await connections.client(selected).reconcile(request)
                    try await load(selected)
                }
            }
        } message: {
            Text("Confirm that you inspected the host receipt and native conversation. This archives the saved request without sending it again.")
        }
        .confirmationDialog("Remove this unused, clean checkout?", isPresented: Binding(
            get: { cleanupWorktree != nil }, set: { if !$0 { cleanupWorktree = nil } }
        )) {
            Button("Remove clean checkout", role: .destructive) {
                guard let tree = cleanupWorktree else { return }
                cleanupWorktree = nil
                worktreeAction("cleanup", tree)
            }
        } message: { Text("Removal refuses dirty or ignored files and retained chat references. Its branch and commits remain for reattachment.") }
    }

    private func load(_ host: ExecutionHostConnection) async throws {
        let client = try connections.client(host)
        let info = try await client.call("host.info")
        guard info["hostId"].string == host.id else { throw HostFailure("wrong_host", "The endpoint's execution identity changed. Pair it explicitly again.") }
        let nextConversations = try await client.call("conversation.list").array
        let nextWorkspaces = try await client.call("workspace.list").array
        let nextSchedules = try await client.call("schedule.list").array
        let nextPending = try await client.pending()
        let nextWorktrees = info["capabilities"].array.contains(.string("worktree.lifecycle")) ? try await client.call("worktree.list").array : []
        selected = host; conversations = nextConversations; workspaces = nextWorkspaces; schedules = nextSchedules; pending = nextPending
        worktrees = nextWorktrees
        supportsWorktrees = info["capabilities"].array.contains(.string("worktree.lifecycle"))
        providers = info["providers"].array.compactMap(\.string)
        if !providers.contains(provider) { provider = providers.first ?? "" }
        if !workspaces.contains(where: { $0["id"].string == workspace }) { workspace = workspaces.first?["id"].string ?? "" }
        if !workspaces.contains(where: { $0["id"].string == repository && $0["worktreeID"] == .null }) {
            repository = workspaces.first(where: { $0["worktreeID"] == .null })?["id"].string ?? ""
        }
    }
    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private func scheduleDescription(_ schedule: HostValue) -> String {
        let clock = schedule["wallClock"]
        guard clock != .null else { return "Every \(Int(schedule["intervalSeconds"].number ?? 0)) seconds" }
        let days = clock["weekdays"].array.compactMap { value -> String? in
            guard let value = value.number, (1...7).contains(value) else { return nil }
            return Self.weekdays[Int(value) - 1]
        }.joined(separator: ", ")
        return "\(days) at \(clock["localTime"].string ?? "") · \(clock["timeZone"].string ?? "")"
    }

    @ViewBuilder private func worktreeSection(_ host: ExecutionHostConnection) -> some View {
        Section("Managed worktrees") {
            Text("Create from an explicitly registered repository root. Archive keeps every file. Cleanup refuses dirty or ignored files and retained chat references.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Repository", selection: $repository) {
                Text("Choose a registered repository").tag("")
                ForEach(workspaces.filter { $0["worktreeID"] == .null }, id: \.identity) { item in
                    Text(item["path"].string ?? "").tag(item["id"].string ?? "")
                }
            }
            TextField("Base ref (blank uses recorded default)", text: $baseRef)
            Button("Create worktree") {
                run {
                    var parameters: [String: HostValue] = ["workspaceId": .string(repository)]
                    if !baseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parameters["baseRef"] = .string(baseRef) }
                    let created = try await connections.client(host).call("worktree.create", params: parameters, mutation: true)
                    try await load(host)
                    workspace = created["workspaceId"].string ?? workspace
                }
            }.disabled(busy || repository.isEmpty)
            ForEach(worktrees, id: \.identity) { tree in
                VStack(alignment: .leading) {
                    Text(tree["branch"].string ?? tree["id"].string ?? "Worktree")
                    Text(tree["path"].string ?? "").font(.caption).textSelection(.enabled)
                    if let failure = tree["failure"].string { Text(failure).font(.caption).foregroundStyle(.red) }
                    Text(tree["removed"].bool == true ? "Checkout removed" : tree["archived"].bool == true ? "Archived · files retained" : tree["state"].string ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                    if !tree["referencedBy"].array.isEmpty { Text("Retained chat references: \(tree["referencedBy"].array.count)").font(.caption) }
                    HStack {
                        if tree["removed"].bool == true { Button("Reattach") { worktreeAction("reattach", tree) } }
                        else {
                            Button(tree["archived"].bool == true ? "Unarchive" : "Archive") {
                                worktreeAction("archive", tree, ["archived": .bool(tree["archived"].bool != true)])
                            }
                            Button("Remove clean checkout…", role: .destructive) { cleanupWorktree = tree }
                                .disabled(!tree["referencedBy"].array.isEmpty)
                        }
                    }.buttonStyle(.borderless).disabled(busy || tree["state"].string != "ready")
                }
            }
        }
    }

    private func worktreeAction(_ action: String, _ tree: HostValue, _ fields: [String: HostValue] = [:]) {
        guard let selected else { return }
        run {
            var parameters = fields; parameters["worktreeId"] = tree["id"]
            _ = try await connections.client(selected).call("worktree." + action, params: parameters, mutation: true)
            try await load(selected)
        }
    }
    private func scheduleAction(_ action: String, _ schedule: HostValue, _ fields: [String: HostValue] = [:]) {
        guard let selected else { return }
        run {
            var params = fields; params["scheduleId"] = schedule["id"]
            _ = try await connections.client(selected).call("schedule." + action, params: params, mutation: true)
            try await load(selected)
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }
}

private extension HostValue { var identity: String { self["id"].string ?? "" } }
