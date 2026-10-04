import AppKit
import Foundation
import Testing
@testable import Memex

#if canImport(SQACPHost)
import SQACP
import SQACPHost
#endif

private func liveSession(source: String = "codex", root: URL = URL(fileURLWithPath: "/tmp/memex-resume-tests")) -> Session {
    let path = source == "codex" ? "sessions/2026/10/04/session.jsonl" : "projects/workspace/session.jsonl"
    return Session(source: source, sessionID: "native-session", sourcePath: root.appendingPathComponent(path).path,
                   project: "workspace", cwd: root.path, machine: "local")
}

private func fakeTarget(_ session: Session) -> InAppResumeTarget {
    InAppResumeTarget(session: session, sourceURL: URL(fileURLWithPath: session.sourcePath),
        workingDirectory: URL(fileURLWithPath: session.cwd!), providerHome: URL(fileURLWithPath: "/tmp/provider"),
        executableURL: URL(fileURLWithPath: "/bin/echo"), helperURL: nil, storageURL: URL(fileURLWithPath: "/tmp/runtime"))
}

private func liveMessage(_ text: String) -> Message {
    Message(role: "assistant", text: text, toolName: nil, toolInput: nil, toolOutput: nil)
}

private actor RecordingConversationRuntime: ConversationRuntime {
    var commands: [ConversationCommand] = []
    var failSend = false
    var stopped = false
    var connections = 0
    var readyOnConnect = true
    private var receive: (@Sendable (Result<ConversationSnapshot, ConversationRuntimeError>) -> Void)?

    func connect(_ target: InAppResumeTarget,
                 receive: @escaping @Sendable (Result<ConversationSnapshot, ConversationRuntimeError>) -> Void) {
        self.receive = receive
        connections += 1
        receive(.success(ConversationSnapshot(connected: true, ready: readyOnConnect, canCancel: true)))
    }
    func perform(_ command: ConversationCommand) throws {
        commands.append(command)
        if failSend { throw ConversationRuntimeError(message: "Acknowledgement lost") }
    }
    func disconnect() { stopped = true }
    func failNextSend() { failSend = true }
    func delayReadiness() { readyOnConnect = false }
    func emit(_ snapshot: ConversationSnapshot) { receive?(.success(snapshot)) }
    func rejectOwnership() {
        receive?(.failure(ConversationRuntimeError(message: "Open elsewhere", kind: .openElsewhere)))
    }
}

@MainActor private func waitFor(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(predicate(), "Timed out waiting for the conversation callback")
}

@Suite(.serialized) @MainActor struct LiveConversationTests {
    @Test func externalOwnerBlocksLaunchThenUnlocksWithoutSendingTheDraft() async {
        let driver = RecordingConversationRuntime()
        var locked = true
        let conversation = LiveConversation(session: liveSession(), makeRuntime: { driver },
            resolveTarget: fakeTarget, checkOwnership: { _ in locked })
        conversation.draft = "Keep this draft"
        #expect(conversation.isOpenElsewhere)
        #expect(!conversation.canSubmit)
        await conversation.send()
        #expect(await driver.connections == 0)
        locked = false
        conversation.refreshOwnership()
        #expect(conversation.canSubmit)
        #expect(conversation.draft == "Keep this draft")
        #expect(await driver.commands.isEmpty)
        await conversation.send()
        #expect(await driver.connections == 1)
        #expect(await driver.commands.map(\.text) == ["Keep this draft"])
        await conversation.disconnect()
    }

    @Test func sendRechecksOwnershipAfterSelection() async {
        let driver = RecordingConversationRuntime()
        var locked = false
        let conversation = LiveConversation(session: liveSession(), makeRuntime: { driver },
            resolveTarget: fakeTarget, checkOwnership: { _ in locked })
        conversation.draft = "Keep this draft"
        #expect(conversation.canSubmit)
        locked = true
        await conversation.send()
        #expect(conversation.isOpenElsewhere)
        #expect(await driver.connections == 0)
        #expect(await driver.commands.isEmpty)
        #expect(conversation.draft == "Keep this draft")
    }

    @Test func writerConflictDuringLoadBecomesLockedAndFinishesThePendingSend() async throws {
        let driver = RecordingConversationRuntime()
        await driver.delayReadiness()
        let conversation = LiveConversation(session: liveSession(), makeRuntime: { driver }, resolveTarget: fakeTarget)
        conversation.draft = "Keep this draft"
        let sending = Task { await conversation.send() }
        try await waitFor { conversation.snapshot.connected }
        await driver.rejectOwnership()
        try await waitFor { conversation.isOpenElsewhere }
        await sending.value
        #expect(!conversation.isWorking)
        #expect(conversation.error == nil)
        #expect(conversation.draft == "Keep this draft")
        #expect(await driver.stopped)
        #expect(await driver.commands.isEmpty)
        await driver.emit(ConversationSnapshot(connected: true, ready: true))
        try await Task.sleep(for: .milliseconds(20))
        #expect(!conversation.snapshot.connected)
        conversation.refreshOwnership()
        #expect(conversation.canSubmit)
        #expect(await driver.commands.isEmpty)
    }

    @Test func ourConnectedProviderIsNotTreatedAsAnExternalOwner() async {
        let driver = RecordingConversationRuntime()
        var locked = false
        let conversation = LiveConversation(session: liveSession(), makeRuntime: { driver },
            resolveTarget: fakeTarget, checkOwnership: { _ in locked })
        await conversation.connect()
        locked = true
        conversation.refreshOwnership()
        #expect(conversation.canSend)
        #expect(!conversation.isOpenElsewhere)
        await conversation.disconnect()
    }

    @Test func ownershipProbeFailureBlocksSendUntilItCanBeChecked() async {
        let driver = RecordingConversationRuntime()
        var fail = true
        let conversation = LiveConversation(session: liveSession(), makeRuntime: { driver },
            resolveTarget: fakeTarget, checkOwnership: { _ in
                if fail { throw POSIXError(.EACCES) }
                return false
            })
        conversation.draft = "Keep this draft"
        await conversation.send()
        #expect(conversation.ownershipError != nil)
        #expect(!conversation.canSubmit)
        #expect(await driver.connections == 0)
        fail = false
        conversation.refreshOwnership()
        #expect(conversation.canSubmit)
        #expect(conversation.ownershipError == nil)
        #expect(conversation.draft == "Keep this draft")
        #expect(await driver.commands.isEmpty)
    }

    @Test func firstSendLoadsSessionAndSendsOnceWithoutASeparateResumeAction() async throws {
        let driver = RecordingConversationRuntime()
        await driver.delayReadiness()
        let conversation = LiveConversation(session: liveSession(), makeRuntime: { driver }, resolveTarget: fakeTarget)
        #expect(conversation.canSubmit)
        #expect(await driver.connections == 0)
        conversation.draft = "Continue here"
        let sending = Task { await conversation.send() }
        try await waitFor { conversation.snapshot.connected }
        #expect(!conversation.canSubmit)
        await conversation.send()
        #expect(await driver.commands.isEmpty)
        await driver.emit(ConversationSnapshot(connected: true, ready: true, canCancel: true))
        await sending.value
        #expect(await driver.connections == 1)
        #expect(await driver.commands.map(\.text) == ["Continue here"])
        #expect(conversation.draft.isEmpty)
        await conversation.disconnect()
    }

    @Test func stopWhileLoadingRetainsDraftAndAllowsAnExplicitRetry() async throws {
        let driver = RecordingConversationRuntime()
        await driver.delayReadiness()
        let conversation = LiveConversation(session: liveSession(), makeRuntime: { driver }, resolveTarget: fakeTarget)
        conversation.draft = "Keep this draft"
        let sending = Task { await conversation.send() }
        try await waitFor { conversation.snapshot.connected }
        #expect(conversation.isWorking)
        await conversation.stop()
        await sending.value
        await driver.emit(ConversationSnapshot(connected: true, ready: true, canCancel: true))
        #expect(await driver.commands.isEmpty)
        #expect(conversation.draft == "Keep this draft")
        #expect(conversation.canSubmit)
        #expect(!conversation.isWorking)
    }

    @Test func failedInitialConnectionRetainsDraftWithoutAutomaticRetry() async {
        let driver = RecordingConversationRuntime()
        let conversation = LiveConversation(session: liveSession(), makeRuntime: { driver }, resolveTarget: { _ in
            throw ConversationRuntimeError(message: "Original workspace unavailable")
        })
        conversation.draft = "Keep this draft"
        await conversation.send()
        await conversation.send()
        #expect(conversation.draft == "Keep this draft")
        #expect(conversation.error == "Original workspace unavailable")
        #expect(!conversation.canSubmit)
        #expect(await driver.connections == 0)
        #expect(await driver.commands.isEmpty)
        conversation.refreshOwnership()
        #expect(!conversation.canSubmit)
        #expect(conversation.error == "Original workspace unavailable")
    }

    @Test func uncertainSendRetainsDraftAndDoesNotReplayOrAcceptStaleCallbacks() async throws {
        let driver = RecordingConversationRuntime()
        let conversation = LiveConversation(session: liveSession(), makeRuntime: { driver }, resolveTarget: fakeTarget)
        await conversation.connect()
        try await waitFor { conversation.canSend }
        await driver.failNextSend()
        conversation.draft = "Keep this prompt"
        await conversation.send()
        #expect(conversation.draft == "Keep this prompt")
        #expect(!conversation.canSend)
        #expect(conversation.error == "Acknowledgement lost")
        conversation.refreshOwnership()
        #expect(!conversation.canSubmit)
        #expect(conversation.error == "Acknowledgement lost")
        await conversation.send()
        #expect(await driver.commands.count == 1)
        await conversation.disconnect()
        await driver.emit(ConversationSnapshot(connected: true, ready: true))
        try await Task.sleep(for: .milliseconds(20))
        #expect(!conversation.snapshot.connected)
        #expect(await driver.stopped)
        #expect(await driver.commands.count == 1)
    }

    @Test func sendIsSingleFlightAndStopAndInteractionRepliesUseOriginalIDs() async throws {
        let driver = RecordingConversationRuntime()
        let conversation = LiveConversation(session: liveSession(), makeRuntime: { driver }, resolveTarget: fakeTarget)
        await conversation.connect()
        try await waitFor { conversation.canSend }
        conversation.draft = "One prompt"
        await conversation.send()
        #expect(conversation.draft.isEmpty)
        #expect(!conversation.canSend)
        #expect(conversation.canStop)
        conversation.draft = "Second prompt"
        await conversation.send()
        #expect(await driver.commands.count == 1)
        await conversation.stop()
        let approval = ConversationApproval(id: "approval:original", title: "Run command", detail: nil,
            options: [.init(id: "deny", title: "Deny", kind: "reject_once")])
        let question = ConversationQuestion(id: "request::question", title: nil, prompt: "Which?", placeholder: nil, choices: [])
        await driver.emit(ConversationSnapshot(connected: true, ready: true, running: true, canCancel: true,
                                              approvals: [approval], questions: [question]))
        try await waitFor { conversation.snapshot.questions.count == 1 }
        #expect(!conversation.canSend)
        await conversation.approve(approval, option: approval.options[0])
        await conversation.answer(question, text: "Choice")
        let commands = await driver.commands
        #expect(commands.map(\.action) == [.prompt, .cancel, .approval, .userInput])
        #expect(commands[2].requestID == "approval:original")
        #expect(commands[2].text == "deny")
        #expect(commands[3].requestID == "request::question")
        #expect(Set(commands.map(\.id)).count == 4)
        await conversation.disconnect()
    }

    @Test func liveFindIncludesEarlierPagesAndPreservesSelectedOccurrence() {
        let client = MemexClient()
        let find = ConversationFindState(client: client)
        find.isOpen = true
        find.query = "needle"
        var records = (0..<250).map { index in
            TranscriptRecord(recordID: "\(index)", record: liveMessage(index == 3 ? "needle needle" : "message"))
        }
        find.search(records: records)
        find.move(1)
        records.append(TranscriptRecord(recordID: "250", record: liveMessage("needle")))
        find.search(records: records)
        #expect(find.hits.count == 3)
        #expect(find.selectedHit?.recordID == "3")
        #expect(find.selectedHit?.occurrence == 1)
    }

    @Test func streamingFollowsBottomButPreservesAnEarlierReadingPosition() {
        let controller = TranscriptController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        controller.view.layoutSubtreeIfNeeded()
        var records = (0..<20).map { index in
            TranscriptRecord(recordID: "\(index)", record: liveMessage("Message \(index)"))
        }
        controller.update(sessionID: "live", records: records, provider: "codex", startsAtEnd: true, followLatest: true)
        let bottom = controller.scrollView.contentView.bounds.origin.y
        records.append(TranscriptRecord(recordID: "20", record: liveMessage("New message")))
        controller.update(sessionID: "live", records: records, provider: "codex", startsAtEnd: true, followLatest: true)
        #expect(controller.scrollView.contentView.bounds.origin.y > bottom)
        controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 70))
        let earlier = controller.scrollView.contentView.bounds.origin.y
        records[20] = TranscriptRecord(recordID: "20", record: liveMessage("New message growing\n\nMore content"))
        controller.update(sessionID: "live", records: records, provider: "codex", startsAtEnd: true, followLatest: true)
        #expect(abs(controller.scrollView.contentView.bounds.origin.y - earlier) < 1)
    }
}

@Test func inAppResumeUsesSourceInstallationAndRejectsUnavailableWorkspaces() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for provider in ["codex", "claude"] {
        let session = liveSession(source: provider, root: root.appendingPathComponent(provider))
        let source = URL(fileURLWithPath: session.sourcePath)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: source)
        let target = try InAppResumeTarget.resolve(session,
            environment: ["MEMEX_CODEX_EXECUTABLE": "/bin/echo", "MEMEX_CLAUDE_EXECUTABLE": "/bin/echo"],
            applicationSupport: root.appendingPathComponent("support"), helperURL: URL(fileURLWithPath: "/bin/echo"))
        #expect(target.providerHome.path == URL(fileURLWithPath: session.cwd!).resolvingSymlinksInPath().path)
        #expect(target.environment[provider == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] == target.providerHome.path)
        var missing = session
        missing.cwd = root.appendingPathComponent("missing").path
        #expect(throws: ConversationRuntimeError.self) { try InAppResumeTarget.resolve(missing) }
        var remote = session
        remote.machine = "nicbook-atm"
        #expect(InAppResumeTarget.unavailableReason(for: remote)?.contains("nicbook-atm") == true)
    }
}

@Test func conversationProjectionUsesPresentationAndOverlaysToolsByNativeIdentity() throws {
    let json = #"""
    {"presentation":[
      {"entity_id":"entry","body":{"kind":"entry","data":{"source_order":1,"payload":{"type":"entity","data":{"entity_id":"message"}}}}},
      {"entity_id":"message","body":{"kind":"message","data":{"role":"assistant","parts":[{"type":"text","data":"Hello"},{"type":"tool_call","data":{"invocation_id":"disk-call"}}]}}},
      {"entity_id":"disk-call","body":{"kind":"tool_invocation","data":{"native_call_id":"call-1","name":"exec_command","raw_arguments":"{}"}}}
    ],"persisted":[{"entity_id":"hidden","body":{"kind":"message","data":{"role":"assistant","parts":[{"type":"text","data":"MUST NOT DUPLICATE"}]}}}],
    "ephemeral":[{"item_id":"stream-call","source_order":2,"body":{"kind":"tool_invocation","data":{"native_call_id":"call-1","name":"exec_command","raw_arguments":"{\"cmd\":\"pwd\"}"}}}],
    "connected":true,"state":{"running":true,"pending_interactions":["approval-1","input-1"]}}
    """#
    let thread = #"""
    {"pendingRequests":[
      {"requestId":"approval-1","kind":"approval","payload":{"title":"Run command","options":[{"id":"deny","name":"Deny","kind":"reject_once"}]}},
      {"requestId":"input-1","kind":"user_input","payload":{"prompt":"Which?","choices":[{"id":"a","title":"A","value":"a"}]}},
      {"requestId":"stale","kind":"approval","payload":{"title":"Stale"}}
    ]}
    """#
    let snapshot = ConversationProjection.snapshot(try decodeJSON(json), thread: try decodeJSON(thread),
        operations: try decodeJSON(#"[{"command":{"type":"thread.turn.start"},"status":"dispatching"}]"#), ready: true, canCancel: true)
    #expect(snapshot.records.count == 2)
    #expect(snapshot.records[0].record.text == "Hello")
    #expect(snapshot.records[1].record.toolInput == #"{"cmd":"pwd"}"#)
    #expect(snapshot.approvals.map(\.id) == ["approval-1"])
    #expect(snapshot.questions.map(\.id) == ["input-1"])
    #expect(snapshot.pendingPrompt)
}

@Test func inAppResumeKeepsOwningHomeWhenSessionStorageIsSymlinked() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("provider")
    let storage = root.appendingPathComponent("external-volume")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("sessions"), withDestinationURL: storage)
    try Data("{}\n".utf8).write(to: storage.appendingPathComponent("session.jsonl"))
    let session = Session(source: "codex", sessionID: "native", sourcePath: home.appendingPathComponent("sessions/session.jsonl").path,
                          project: "test", cwd: root.path, machine: "local")
    let target = try InAppResumeTarget.resolve(session, environment: ["MEMEX_CODEX_EXECUTABLE": "/bin/echo"], applicationSupport: root)
    #expect(target.providerHome == home.resolvingSymlinksInPath())
    #expect(target.sourceURL == storage.appendingPathComponent("session.jsonl").resolvingSymlinksInPath())
}

private func decodeJSON(_ json: String) throws -> RawTranscriptJSON {
    try JSONDecoder().decode(RawTranscriptJSON.self, from: Data(json.utf8))
}

#if canImport(SQACPHost)
/// Resume-only diagnostic for a specified local session. Sends no prompt.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEMEX_LOAD_TEST_SESSION"] != nil))
@MainActor func nativeRuntimeLoadsSpecifiedSession() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["MEMEX_LOAD_TEST_SESSION"])
    let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let storage = FileManager.default.temporaryDirectory.appendingPathComponent("memex-load-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: storage) }
    let conversation = LiveConversation(session: session, resolveTarget: {
        try InAppResumeTarget.resolve($0, applicationSupport: storage)
    })
    await conversation.connect()
    if let error = conversation.error {
        await conversation.disconnect()
        throw ConversationRuntimeError(message: error)
    }
    #expect(conversation.snapshot.ready)
    await conversation.disconnect()
}

/// Opt-in only: point at explicitly created disposable native sessions, never a
/// user's working conversation. This exercises the same actor as the app.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEMEX_LIVE_TEST_SESSIONS"] != nil))
@MainActor func nativeRuntimeResumesDisposableProviderSessions() async throws {
    let environment = ProcessInfo.processInfo.environment
    let path = try #require(environment["MEMEX_LIVE_TEST_SESSIONS"])
    let sessions = try JSONDecoder().decode([Session].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let storage = FileManager.default.temporaryDirectory.appendingPathComponent("memex-live-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: storage) }
    for session in sessions {
        let conversation = LiveConversation(session: session, resolveTarget: {
            try InAppResumeTarget.resolve($0, applicationSupport: storage)
        })
        await conversation.connect()
        try await awaitLiveState(conversation) { $0.canSend }
        #expect(conversation.snapshot.records.contains { $0.record.role == "assistant" && $0.record.text.contains("MEMEX_SEED_OK") })
        conversation.draft = "This is a disposable Memex resume test. Reply exactly MEMEX_RESUMED_OK. Do not use tools."
        await conversation.send()
        try await awaitLiveState(conversation) {
            $0.canSend && $0.snapshot.records.contains { $0.record.role == "assistant" && $0.record.text.contains("MEMEX_RESUMED_OK") }
        }
        let source = try String(contentsOfFile: session.sourcePath, encoding: .utf8)
        #expect(source.contains("MEMEX_RESUMED_OK"))
        #expect(conversation.snapshot.records.filter { $0.record.role == "assistant" && $0.record.text.contains("MEMEX_RESUMED_OK") }.count == 1)
        await conversation.disconnect()
        await conversation.connect()
        try await awaitLiveState(conversation) { $0.canSend }
        #expect(conversation.snapshot.records.filter { $0.record.role == "assistant" && $0.record.text.contains("MEMEX_RESUMED_OK") }.count == 1)
        await conversation.disconnect()
    }
}

@MainActor private func awaitLiveState(_ conversation: LiveConversation, predicate: (LiveConversation) -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(100))
    while ContinuousClock.now < deadline {
        if let error = conversation.error {
            await conversation.disconnect()
            throw ConversationRuntimeError(message: "\(conversation.session.source): \(error)")
        }
        if predicate(conversation) { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    let status = conversation.status
    await conversation.disconnect()
    throw ConversationRuntimeError(message: "\(conversation.session.source): timed out in \(status)")
}

@Test func nativeRuntimeImportsAndProjectsRealProviderRecords() throws {
    for provider in ["codex", "claude"] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("session.jsonl")
        let json = provider == "codex" ? #"""
        {"type":"session_meta","payload":{"id":"native-session","cwd":"/tmp","originator":"codex_cli_rs","timestamp":"2026-10-04T10:00:00Z"}}
        {"type":"response_item","payload":{"id":"user-1","type":"message","role":"user","content":[{"type":"input_text","text":"Hello native runtime"}]}}
        {"type":"response_item","payload":{"id":"assistant-1","type":"message","role":"assistant","content":[{"type":"output_text","text":"A persisted answer"}]}}
        {"type":"response_item","payload":{"id":"reasoning-1","type":"reasoning","summary":[],"encrypted_content":"ENCRYPTED_PAYLOAD"}}
        {"type":"response_item","payload":{"id":"image-1","type":"message","role":"user","content":[{"type":"input_image","image_url":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0FYAAAAASUVORK5CYII="}]}}
        """# : #"""
        {"type":"user","sessionId":"native-session","uuid":"user-1","message":{"role":"user","content":"Hello native runtime"}}
        {"type":"assistant","sessionId":"native-session","uuid":"assistant-1","parentUuid":"user-1","message":{"id":"api-1","role":"assistant","content":[{"type":"text","text":"A persisted answer"}]}}
        {"type":"assistant","sessionId":"native-session","uuid":"reasoning-1","message":{"id":"api-2","role":"assistant","content":[{"type":"redacted_thinking","data":"ENCRYPTED_PAYLOAD"}]}}
        {"type":"user","sessionId":"native-session","uuid":"image-1","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0FYAAAAASUVORK5CYII="}}]}}
        """#
        try Data((json + "\n").utf8).write(to: source)
        let runtime = try AgentRuntimeClient(databaseURL: root.appendingPathComponent("runtime.sqlite"))
        let service = try AgentConversationService(runtime: runtime, archiveURL: root.appendingPathComponent("history"), executionHostID: "local")
        let imported = try service.addSource(agent: provider, format: "jsonl", url: source,
            nativeNamespace: "test-installation", nativeSessionID: "native-session", sessionID: "canonical-session")
        let conversation = try #require(try ConversationProjection.conversation(in: imported, sessionID: "canonical-session"))
        let snapshot = ConversationProjection.snapshot(conversation, ready: false, canCancel: false)
        let visible = TranscriptPresentation.project(snapshot.records)
        #expect(visible.map(\.record.text) == ["Hello native runtime", "A persisted answer", ""])
        #expect(snapshot.records.contains { $0.isRawOnly && $0.rawTranscriptBody.contains("ENCRYPTED_PAYLOAD") })
        let image = try #require(visible.last)
        #expect(SourceContent.blocks(image.record).count == 1)
        #expect(image.rawTranscriptBody.contains("iVBOR"))
        #expect(!visible.contains { $0.record.text.contains("ENCRYPTED_PAYLOAD") || $0.record.text.contains("iVBOR") })
        #expect(conversation["persisted"].array.contains { $0["body"]["kind"].string == "session" && !$0["body"]["data"]["source_ids"].array.isEmpty })
    }
}
#endif
