import Foundation

#if canImport(SQACPHost)
import SQACP
import SQACPHost
#endif

enum InAppAgentRuntime {
    static var isAvailable: Bool {
        #if canImport(SQACPHost)
        AgentRuntimeClient.schemaVersion > 0
        #else
        false
        #endif
    }

    static func make() -> any ConversationRuntime {
        #if canImport(SQACPHost)
        NativeConversationRuntime()
        #else
        UnavailableConversationRuntime()
        #endif
    }
}

private actor UnavailableConversationRuntime: ConversationRuntime {
    func connect(_ target: InAppResumeTarget,
                 receive: @escaping @Sendable (Result<ConversationSnapshot, ConversationRuntimeError>) -> Void) throws {
        throw ConversationRuntimeError(message: "This build does not include the local agent runtime.")
    }
    func perform(_ command: ConversationCommand) throws {
        throw ConversationRuntimeError(message: "The local agent runtime is unavailable.")
    }
    func disconnect() {}
}

#if canImport(SQACPHost)
func conversationProviderError(_ error: Error) -> ConversationRuntimeError {
    let message: String
    if case AgentConversationServiceError.runtime(let detail) = error { message = detail }
    else { message = error.localizedDescription }
    if message.contains("already has an active writer") {
        return ConversationRuntimeError(message: "Open elsewhere", kind: .openElsewhere)
    }
    return ConversationRuntimeError(message: message)
}

/// Owns blocking runtime calls off the main actor. One private archive tracks only
/// the explicitly resumed source; the native provider continues to own its file.
actor NativeConversationRuntime: ConversationRuntime {
    private var creation: AgentConversationCreation?
    private var runtime: AgentRuntimeClient?
    private var service: AgentConversationService?
    private var sessionID: String?
    private var subscription: UUID?
    private var poll: Task<Void, Never>?
    private var drain: Task<Void, Never>?
    private var receive: (@Sendable (Result<ConversationSnapshot, ConversationRuntimeError>) -> Void)?
    private var target: InAppResumeTarget?
    private var fileVersion: FileVersion?
    private var connectedAt = Date()
    private var wasReady = false
    private var warning: String?
    private var sentPromptIDs: Set<String> = []

    init(creation: AgentConversationCreation? = nil) { self.creation = creation }

    private struct FileVersion: Equatable {
        let size: Int
        let modified: Date?
        init(_ url: URL) throws {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            size = values.fileSize ?? 0
            modified = values.contentModificationDate
        }
    }

    func connect(_ target: InAppResumeTarget,
                 receive: @escaping @Sendable (Result<ConversationSnapshot, ConversationRuntimeError>) -> Void) throws {
        let created = creation
        creation = nil
        disconnect()
        self.target = target
        self.receive = receive
        connectedAt = Date()
        wasReady = false
        warning = nil
        try FileManager.default.createDirectory(at: target.storageURL, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let runtime = try AgentRuntimeClient(databaseURL: target.storageURL.appendingPathComponent("runtime.sqlite"))
        let service = try AgentConversationService(runtime: runtime,
            archiveURL: target.storageURL.appendingPathComponent("history"), executionHostID: "local")
        self.runtime = runtime
        self.service = service
        let id = "memex-" + InAppResumeTarget.digest(target.session.id)
        let source: String?
        if created == nil {
            let imported = try service.addSource(agent: target.session.source, format: "jsonl", url: target.sourceURL,
                nativeNamespace: target.providerInstanceID, nativeSessionID: target.session.sessionID, sessionID: id)
            guard let conversation = try ConversationProjection.conversation(in: imported, sessionID: id),
              let sessionEntity = conversation["persisted"].array.first(where: { $0["body"]["kind"].string == "session" }),
              let sourceID = sessionEntity["body"]["data"]["source_ids"].array.first?.string else {
                throw ConversationRuntimeError(message: "The native session could not be identified in its transcript.")
            }
            source = sourceID
        } else {
            source = nil
            warning = "The provider has not saved its transcript yet. Send a message before closing to make this conversation resumable."
        }
        sessionID = id
        let binding = AgentConversationBinding(sessionID: id, sourceID: source,
            nativeSessionID: target.session.sessionID, providerInstanceID: target.providerInstanceID,
            executionHostID: "local", workspaceID: target.workspaceID, cwd: target.workingDirectory.path)
        subscription = service.subscribe(on: DispatchQueue(label: "memex.conversation.events")) { [weak self] result in
            // Never carry Foundation Any across actors or project stale event payloads.
            let error: ConversationRuntimeError?
            if case .failure(let failure) = result { error = conversationProviderError(failure) } else { error = nil }
            Task { await self?.changed(error: error) }
        }
        do {
            if let created {
                try service.connectCreated(binding, creation: created)
            } else if target.session.source == "codex" {
                try service.connectCodex(binding, executablePath: target.executableURL.path, environment: target.environment)
            } else if let helper = target.helperURL {
                try service.connectClaude(binding, hostExecutablePath: helper.path,
                    claudeExecutablePath: target.executableURL.path, environment: target.environment)
            }
        } catch {
            throw conversationProviderError(error)
        }
        fileVersion = created == nil ? try? FileVersion(target.sourceURL) : nil
        try publish()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await self?.tick()
            }
        }
    }

    private func changed(error: ConversationRuntimeError?) {
        if let error { fail(error); return }
        guard drain == nil, service != nil else { return }
        drain = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            await self?.flush()
        }
    }

    private func flush() {
        drain = nil
        do { try publish() } catch { fail(conversationProviderError(error)) }
    }

    private func tick() {
        guard let target, let service, let sessionID else { return }
        do {
            let version = try FileVersion(target.sourceURL)
            if version != fileVersion {
                if fileVersion == nil {
                    _ = try service.addSource(agent: target.session.source, format: "jsonl", url: target.sourceURL,
                        nativeNamespace: target.providerInstanceID, nativeSessionID: target.session.sessionID, sessionID: sessionID)
                } else {
                    _ = try service.refresh(sessionID: sessionID)
                }
                fileVersion = version
                warning = nil
            }
        } catch {
            if fileVersion != nil || FileManager.default.fileExists(atPath: target.sourceURL.path) {
                warning = "Transcript refresh failed: \(error.localizedDescription). Live output is retained."
            }
        }
        if !wasReady && Date().timeIntervalSince(connectedAt) > 45 {
            fail(ConversationRuntimeError(message: "The agent did not finish loading this session. Check its CLI and sign-in, then reconnect."))
            return
        }
        do { try publish() } catch { fail(conversationProviderError(error)) }
    }

    private func publish() throws {
        guard let service, let sessionID,
              let conversation = try ConversationProjection.conversation(in: service.read(sessionID: sessionID), sessionID: sessionID) else { return }
        let actions = service.supportedActions(sessionID: sessionID)
        let thread = try request("thread.snapshot", params: ["threadId": .string(sessionID)])
        let operations = try request("provider_operation.list", params: ["threadId": .string(sessionID), "includeTerminal": .bool(false)])
        var snapshot = ConversationProjection.snapshot(conversation, thread: thread, operations: operations,
            ready: actions.contains(.prompt), canCancel: actions.contains(.cancel), sentPromptIDs: sentPromptIDs)
        snapshot.warning = snapshot.warning ?? warning
        if snapshot.ready { wasReady = true }
        receive?(.success(snapshot))
        if wasReady && !snapshot.connected {
            fail(ConversationRuntimeError(message: "The agent process disconnected. Reconnect to reload the native session."))
        }
    }

    private func request(_ method: String, params: [String: RawTranscriptJSON]) throws -> RawTranscriptJSON {
        guard let runtime else { throw ConversationRuntimeError(message: "The agent is disconnected.") }
        let encoded = try RawTranscriptJSON.object(["id": .string(UUID().uuidString), "method": .string(method), "params": .object(params)]).prettyPrinted()
        let response = try runtime.requestJSON(encoded)
        let value = try JSONDecoder().decode(RawTranscriptJSON.self, from: Data(response.utf8))
        if let error = value["error"]["message"].string { throw ConversationRuntimeError(message: error) }
        return value["result"]
    }

    func perform(_ command: ConversationCommand) throws {
        guard let service, let sessionID else { throw ConversationRuntimeError(message: "The agent is disconnected.") }
        let action: AgentConversationAction
        switch command.action {
        case .prompt: action = .prompt
        case .cancel: action = .cancel
        case .approval: action = .approval
        case .userInput: action = .userInput
        }
        if command.action == .prompt { sentPromptIDs.insert(command.id) }
        _ = try service.perform(action, sessionID: sessionID, commandID: command.id,
            issuedAt: command.issuedAt, text: command.text, requestID: command.requestID)
        try publish()
    }

    private func fail(_ error: ConversationRuntimeError) {
        let callback = receive
        disconnect()
        callback?(.failure(error))
    }

    func disconnect() {
        creation = nil
        sentPromptIDs.removeAll()
        poll?.cancel(); poll = nil
        drain?.cancel(); drain = nil
        if let subscription { service?.unsubscribe(subscription) }
        subscription = nil
        if let sessionID { try? service?.disconnect(sessionID: sessionID) }
        service = nil
        runtime = nil
        sessionID = nil
        receive = nil
        target = nil
    }
}
#endif
