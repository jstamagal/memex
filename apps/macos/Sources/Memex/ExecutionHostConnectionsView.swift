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
                    Section("Schedules") {
                        Text("Schedules run through this host's durable queue. Stopped or recovered queues stay held until explicitly resumed.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(schedules, id: \.identity) { schedule in
                            VStack(alignment: .leading) {
                                Text(schedule["prompt"].string ?? "Scheduled prompt").lineLimit(2)
                                Text("Every \(Int(schedule["intervalSeconds"].number ?? 0)) seconds · \(schedule["paused"].bool == true ? "Paused" : "Active")")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Edit") {
                                        scheduleID = schedule["id"].string ?? UUID().uuidString
                                        scheduleConversation = schedule["conversationID"].string ?? ""
                                        scheduleText = schedule["prompt"].string ?? ""
                                        interval = Int(schedule["intervalSeconds"].number ?? 3600)
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
                        TextField("Interval in seconds", value: $interval, format: .number)
                        Button("Save schedule") {
                            run {
                                _ = try await connections.client(selected).call("schedule.upsert", params: ["scheduleId": .string(scheduleID),
                                    "conversationId": .string(scheduleConversation), "text": .string(scheduleText), "intervalSeconds": .number(Double(interval))], mutation: true)
                                scheduleID = UUID().uuidString; scheduleText = ""
                                try await load(selected)
                            }
                        }.disabled(busy || scheduleConversation.isEmpty || scheduleText.isEmpty || interval < 60)
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
    }

    private func load(_ host: ExecutionHostConnection) async throws {
        let client = try connections.client(host)
        let info = try await client.call("host.info")
        guard info["hostId"].string == host.id else { throw HostFailure("wrong_host", "The endpoint's execution identity changed. Pair it explicitly again.") }
        let nextConversations = try await client.call("conversation.list").array
        let nextWorkspaces = try await client.call("workspace.list").array
        let nextSchedules = try await client.call("schedule.list").array
        let nextPending = try await client.pending()
        selected = host; conversations = nextConversations; workspaces = nextWorkspaces; schedules = nextSchedules; pending = nextPending
        providers = info["providers"].array.compactMap(\.string)
        if !providers.contains(provider) { provider = providers.first ?? "" }
        if !workspaces.contains(where: { $0["id"].string == workspace }) { workspace = workspaces.first?["id"].string ?? "" }
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
