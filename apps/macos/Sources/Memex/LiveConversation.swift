import CryptoKit
import Foundation
import Observation

struct ConversationRuntimeError: LocalizedError, Sendable {
    enum Kind: Sendable { case other, openElsewhere }
    let message: String
    var kind: Kind = .other
    var errorDescription: String? { message }
}

/// The transcript's owning installation, not the GUI process's default agent home.
struct InAppResumeTarget: Sendable, Equatable {
    let session: Session
    let sourceURL: URL
    let workingDirectory: URL
    let providerHome: URL
    let executableURL: URL
    let helperURL: URL?
    let storageURL: URL

    var environment: [String: String] {
        [session.source == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR": providerHome.path]
    }
    var providerInstanceID: String { "\(session.source):\(Self.digest(providerHome.path))" }
    var workspaceID: String { Self.digest(workingDirectory.path) }

    static func unavailableReason(for session: Session) -> String? {
        guard session.machineID == "local" else { return "Resume this conversation on \(session.machineID)." }
        guard ["codex", "claude"].contains(session.source) else { return "In-app resume supports Codex and Claude conversations." }
        guard !session.isSubagent, session.conversationKind != "guardian_review" else {
            return "Resume the parent conversation to continue this agent's work."
        }
        guard session.cwd?.nilIfBlank != nil else { return "The original working directory is unavailable." }
        return nil
    }

    static func resolve(_ session: Session, environment: [String: String] = ProcessInfo.processInfo.environment,
                        applicationSupport: URL? = nil, helperURL: URL? = nil,
                        requiresTranscript: Bool = true) throws -> Self {
        if let reason = unavailableReason(for: session) { throw ConversationRuntimeError(message: reason) }
        guard session.sessionID.nilIfBlank != nil, !session.sessionID.contains("\0"),
              session.sourcePath.hasPrefix("/"), !session.sourcePath.contains("\0"),
              let cwd = session.cwd, cwd.hasPrefix("/"), !cwd.contains("\0") else {
            throw ConversationRuntimeError(message: "This conversation has invalid resume metadata.")
        }
        let manager = FileManager.default
        let nativeSourceURL = URL(fileURLWithPath: session.sourcePath).standardizedFileURL
        let sourceURL = nativeSourceURL.resolvingSymlinksInPath()
        let workingDirectory = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: workingDirectory.path, isDirectory: &directory), directory.boolValue else {
            throw ConversationRuntimeError(message: "The original working directory no longer exists: \(cwd)")
        }
        guard !requiresTranscript || (manager.fileExists(atPath: sourceURL.path, isDirectory: &directory) && !directory.boolValue) else {
            throw ConversationRuntimeError(message: "The original agent session file is unavailable: \(session.sourcePath)")
        }
        // A session directory can be a symlink onto another volume. Its parent
        // installation still owns configuration and auth, not the storage volume.
        let providerHome = try providerHome(for: nativeSourceURL, provider: session.source).resolvingSymlinksInPath()
        let override = environment[session.source == "codex" ? "MEMEX_CODEX_EXECUTABLE" : "MEMEX_CLAUDE_EXECUTABLE"]
        let home = manager.homeDirectoryForCurrentUser
        let searchDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".cargo/bin").path,
               "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let executable = override.map { [$0] } ?? searchDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent(session.source).path }
        guard let executablePath = executable.first(where: { $0.hasPrefix("/") && manager.isExecutableFile(atPath: $0) }) else {
            throw ConversationRuntimeError(message: "\(session.source == "codex" ? "Codex" : "Claude Code") is not installed. Install its CLI or set the corresponding MEMEX executable override.")
        }
        let helper: URL?
        if session.source == "claude" {
            helper = helperURL ?? environment["MEMEX_CLAUDE_HELPER"].map { URL(fileURLWithPath: $0) }
                ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/claude-agent-sdk-host")
            guard let helper, manager.isExecutableFile(atPath: helper.path) else {
                throw ConversationRuntimeError(message: "The Claude session helper is missing from this build. Rebuild Memex with its local agent runtime.")
            }
        } else { helper = nil }
        let support = try applicationSupport ?? manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                             appropriateFor: nil, create: true)
            .appendingPathComponent("dev.memex.app/Resume", isDirectory: true)
        return Self(session: session, sourceURL: sourceURL, workingDirectory: workingDirectory,
                    providerHome: providerHome, executableURL: URL(fileURLWithPath: executablePath), helperURL: helper,
                    storageURL: support.appendingPathComponent(digest(session.id), isDirectory: true))
    }

    static func providerHome(for sourceURL: URL, provider: String) throws -> URL {
        var directory = sourceURL.deletingLastPathComponent()
        if provider == "claude" {
            // Claude stores <config>/projects/<encoded workspace>/<session>.jsonl.
            directory.deleteLastPathComponent()
            if directory.lastPathComponent == "projects" { return directory.deletingLastPathComponent() }
        } else if provider == "codex" {
            while directory.path != "/" {
                if ["sessions", "archived_sessions"].contains(directory.lastPathComponent) {
                    return directory.deletingLastPathComponent()
                }
                directory.deleteLastPathComponent()
            }
        }
        throw ConversationRuntimeError(message: "This transcript is outside its agent's native session store. Resume requires the original installation and session data.")
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ConversationApproval: Identifiable, Equatable, Sendable {
    struct Option: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let kind: String
    }
    let id: String
    let title: String
    let detail: String?
    let options: [Option]
}

struct ConversationQuestion: Identifiable, Equatable, Sendable {
    struct Choice: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let value: String
    }
    let id: String
    let title: String?
    let prompt: String
    let placeholder: String?
    let choices: [Choice]
}

struct ConversationSnapshot: Equatable, Sendable {
    var records: [TranscriptRecord] = []
    var connected = false
    var ready = false
    var running = false
    var pendingPrompt = false
    var canCancel = false
    var approvals: [ConversationApproval] = []
    var questions: [ConversationQuestion] = []
    var warning: String?
}

struct ConversationCommand: Sendable, Equatable {
    enum Action: Sendable, Equatable { case prompt, cancel, approval, userInput }
    let id: String
    let issuedAt: String
    let action: Action
    let text: String
    let requestID: String?

    init(_ action: Action, text: String = "", requestID: String? = nil) {
        id = UUID().uuidString
        issuedAt = Date().ISO8601Format()
        self.action = action
        self.text = text
        self.requestID = requestID
    }
}

protocol ConversationRuntime: Sendable {
    func connect(_ target: InAppResumeTarget,
                 receive: @escaping @Sendable (Result<ConversationSnapshot, ConversationRuntimeError>) -> Void) async throws
    func perform(_ command: ConversationCommand) async throws
    func disconnect() async
}

@MainActor @Observable
final class LiveConversation {
    enum Ownership: Equatable {
        case available, openElsewhere, unavailable(String)
    }

    let session: Session
    var draft = "" { didSet { persistDraft() } }
    private(set) var snapshot = ConversationSnapshot()
    private(set) var hasSnapshot = false
    private(set) var connecting = false
    private(set) var submitting = false
    private(set) var connectionAttempted = false
    private var preparingPrompt = false
    private(set) var error: String?
    private(set) var ownership: Ownership = .available
    private(set) var revision = 0
    private(set) var focusRequest = 0
    private(set) var visibleLimit = 120
    private(set) var completion: ConversationActivity?
    private var deliveryUncertain = false
    private var stopping = false
    private var adoptingCreatedSession: Bool
    @ObservationIgnored private let drafts: ConversationDraftStore?
    @ObservationIgnored private var runtime: (any ConversationRuntime)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var connectionWaiter: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let makeRuntime: @Sendable () -> any ConversationRuntime
    @ObservationIgnored private let resolveTarget: @Sendable (Session) throws -> InAppResumeTarget
    @ObservationIgnored private let checkOwnership: (Session) throws -> Bool

    init(session: Session, makeRuntime: @escaping @Sendable () -> any ConversationRuntime = { InAppAgentRuntime.make() },
         resolveTarget: @escaping @Sendable (Session) throws -> InAppResumeTarget = { try InAppResumeTarget.resolve($0) },
         checkOwnership: @escaping (Session) throws -> Bool = ConversationOwnership.isOpenElsewhere,
         drafts: ConversationDraftStore? = nil, adoptingCreatedSession: Bool = false) {
        self.session = session
        self.makeRuntime = makeRuntime
        self.resolveTarget = resolveTarget
        self.checkOwnership = checkOwnership
        self.drafts = drafts
        self.adoptingCreatedSession = adoptingCreatedSession
        if let saved = drafts?.drafts[session.id] {
            draft = saved.text
            deliveryUncertain = saved.deliveryUncertain
            if saved.deliveryUncertain {
                error = "The previous send could not be confirmed. Reload and review the conversation before sending again."
                connectionAttempted = true
            }
        }
        refreshOwnership()
    }

    private func persistDraft() {
        drafts?.set(.init(text: draft, deliveryUncertain: deliveryUncertain), for: session.id)
    }

    var draftSaveError: String? { drafts?.error }

    var listState: ConversationListState {
        let activity: ConversationActivity?
        if error != nil || ownershipError != nil { activity = .failed }
        else if !snapshot.approvals.isEmpty { activity = .approval }
        else if !snapshot.questions.isEmpty { activity = .question }
        else if connecting { activity = .starting }
        else if isWorking { activity = stopping ? .stopping : .working }
        else if isOpenElsewhere { activity = .openElsewhere }
        else { activity = completion }
        return ConversationListState(activity: activity, hasDraft: draft.nilIfBlank != nil)
    }

    var isOpenElsewhere: Bool { ownership == .openElsewhere }
    var ownershipError: String? {
        if case .unavailable(let message) = ownership { return message }
        return nil
    }

    func refreshOwnership() {
        // Once our provider is loading or connected, its own writer lock is
        // expected. Only inspect ownership before opening a native session.
        guard !adoptingCreatedSession, !connecting, !snapshot.connected else { return }
        do {
            ownership = try checkOwnership(session) ? .openElsewhere : .available
        } catch {
            ownership = .unavailable("Could not check whether this conversation is open elsewhere: \(error.localizedDescription)")
        }
    }

    var canSend: Bool {
        ownership == .available && snapshot.connected && snapshot.ready && !snapshot.running && !snapshot.pendingPrompt
            && snapshot.approvals.isEmpty && snapshot.questions.isEmpty && !connecting && !submitting && error == nil
    }
    var canSubmit: Bool {
        ownership == .available && !preparingPrompt
            && (canSend || (!connectionAttempted && !connecting && !submitting && error == nil))
    }
    var isWorking: Bool { connecting || preparingPrompt || submitting || snapshot.running || snapshot.pendingPrompt }
    var canStop: Bool { connecting || (snapshot.connected && snapshot.canCancel && (snapshot.running || snapshot.pendingPrompt) && !submitting) }
    var visibleRecords: [TranscriptRecord] { Array(snapshot.records.suffix(visibleLimit)) }
    var hasEarlierRecords: Bool { snapshot.records.count > visibleLimit }
    func loadEarlierRecords() { visibleLimit += MemexClient.pageSize }
    func revealRecord(_ id: String) {
        if let index = snapshot.records.firstIndex(where: { $0.id == id }) {
            visibleLimit = max(visibleLimit, snapshot.records.count - index + MemexClient.pageSize / 2)
        }
    }
    var status: String {
        if isOpenElsewhere { return "Open elsewhere" }
        if connecting { return "Connecting…" }
        if error != nil { return "Connection needs attention" }
        if !snapshot.connected { return "Disconnected" }
        if !snapshot.approvals.isEmpty { return "Waiting for approval" }
        if !snapshot.questions.isEmpty { return "Waiting for your answer" }
        if stopping { return "Stopping…" }
        if snapshot.running { return "Working…" }
        if submitting || snapshot.pendingPrompt { return "Sending…" }
        if !snapshot.ready { return "Loading session…" }
        return "Ready"
    }

    func focus() { focusRequest += 1 }

    func showHistory(_ records: [TranscriptRecord]) {
        guard !connecting, !snapshot.connected else { return }
        snapshot.records = records
        hasSnapshot = true
        revision += 1
    }

    @discardableResult
    func connect() async -> Bool {
        refreshOwnership()
        guard ownership == .available, !connecting else { return false }
        adoptingCreatedSession = false
        finishConnecting(false)
        let token = UUID()
        generation = token
        connectionAttempted = true
        connecting = true
        submitting = false
        error = nil
        snapshot.connected = false
        snapshot.ready = false
        snapshot.approvals = []
        snapshot.questions = []
        let previous = runtime
        runtime = nil
        await previous?.disconnect()
        guard generation == token else { return false }
        do {
            let session = session
            let resolver = resolveTarget
            let target = try await Task.detached { try resolver(session) }.value
            guard generation == token, !Task.isCancelled else { return false }
            let driver = makeRuntime()
            runtime = driver
            try await driver.connect(target) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    switch result {
                    case .success(let snapshot):
                        guard self.snapshot != snapshot || !self.hasSnapshot else { return }
                        let wasConnecting = self.connecting
                        let wasWorking = self.snapshot.running || self.snapshot.pendingPrompt
                        if snapshot.running || snapshot.pendingPrompt {
                            if !self.stopping { self.completion = nil }
                        }
                        else if wasWorking, snapshot.ready, snapshot.approvals.isEmpty, snapshot.questions.isEmpty,
                                self.completion == nil { self.completion = self.stopping ? .stopped : .completed }
                        self.snapshot = snapshot
                        self.hasSnapshot = true
                        self.revision += 1
                        if snapshot.ready {
                            self.connecting = false
                            self.finishConnecting(true)
                            if wasConnecting, self.deliveryUncertain {
                                self.deliveryUncertain = false
                                self.persistDraft()
                            }
                        }
                    case .failure(let failure):
                        await self.connectionFailed(failure)
                    }
                }
            }
            guard generation == token else { await driver.disconnect(); return false }
            let ready: Bool
            if snapshot.ready { ready = true }
            else if error != nil { ready = false }
            else { ready = await withCheckedContinuation { connectionWaiter = $0 } }
            guard ready, generation == token else { return false }
            focus()
            return true
        } catch {
            guard generation == token else { return false }
            await connectionFailed(error as? ConversationRuntimeError
                ?? ConversationRuntimeError(message: error.localizedDescription))
            return false
        }
    }

    private func connectionFailed(_ failure: ConversationRuntimeError) async {
        generation = UUID()
        connecting = false
        submitting = false
        snapshot.connected = false
        snapshot.ready = false
        if failure.kind == .openElsewhere {
            ownership = .openElsewhere
            // Resume was rejected before a prompt could be delivered. Unlocking
            // permits a new explicit Send, never a replay of the retained draft.
            connectionAttempted = false
            error = nil
            hasSnapshot = false
        } else {
            error = failure.message
        }
        finishConnecting(false)
        let previous = runtime
        runtime = nil
        await previous?.disconnect()
    }

    private func finishConnecting(_ ready: Bool) {
        let waiter = connectionWaiter
        connectionWaiter = nil
        waiter?.resume(returning: ready)
    }

    func send() async {
        refreshOwnership()
        guard canSubmit, let text = draft.nilIfBlank else { return }
        preparingPrompt = true
        defer { preparingPrompt = false }
        // Browsing history does not launch a provider. The first explicit send
        // loads its original session, then sends exactly once when it is ready.
        if !connectionAttempted, !(await connect()) { return }
        guard canSend else { return }
        completion = nil
        stopping = false
        _ = await perform(ConversationCommand(.prompt, text: text))
    }

    func stop() async {
        if connecting {
            await disconnect()
            connectionAttempted = false
            completion = .stopped
            return
        }
        guard canStop else { return }
        stopping = true
        if await perform(ConversationCommand(.cancel)) { completion = .stopped }
        else { stopping = false }
    }

    func approve(_ approval: ConversationApproval, option: ConversationApproval.Option) async {
        guard snapshot.connected, !submitting, snapshot.approvals.contains(approval), approval.options.contains(option) else { return }
        _ = await perform(ConversationCommand(.approval, text: option.id, requestID: approval.id))
    }

    func answer(_ question: ConversationQuestion, text: String) async {
        guard snapshot.connected, !submitting, snapshot.questions.contains(question), let answer = text.nilIfBlank else { return }
        _ = await perform(ConversationCommand(.userInput, text: answer, requestID: question.id))
    }

    private func perform(_ command: ConversationCommand) async -> Bool {
        guard let runtime, !submitting else { return false }
        let token = generation
        submitting = true
        if command.action == .prompt {
            snapshot.pendingPrompt = true
            // Persist before crossing the provider boundary. A process exit while
            // awaiting acknowledgement must restore a draft that requires review.
            deliveryUncertain = true
            persistDraft()
            await drafts?.flush()
            guard generation == token else { return false }
        }
        defer { if generation == token { submitting = false } }
        do {
            try await runtime.perform(command)
            if command.action == .prompt, generation == token {
                deliveryUncertain = false
                if draft == command.text { draft = "" }
                else { persistDraft() }
            }
            return generation == token
        } catch {
            guard generation == token else { return false }
            self.error = error.localizedDescription
            if command.action == .prompt {
                deliveryUncertain = true
                persistDraft()
            }
            // A provider can accept a command before its acknowledgement is lost.
            // Reconnect explicitly; never turn an uncertain result into another send.
            snapshot.ready = false
            return false
        }
    }

    func disconnect() async {
        generation = UUID()
        connectionAttempted = true
        finishConnecting(false)
        connecting = false
        submitting = false
        snapshot.connected = false
        snapshot.ready = false
        snapshot.approvals = []
        snapshot.questions = []
        let previous = runtime
        runtime = nil
        await previous?.disconnect()
    }
}

@MainActor @Observable
final class LiveConversations {
    private(set) var sessions: [String: LiveConversation] = [:]
    let drafts: ConversationDraftStore
    @ObservationIgnored private let makeConversation: (Session, ConversationDraftStore) -> LiveConversation

    init(drafts: ConversationDraftStore = ConversationDraftStore(),
         makeConversation: @escaping (Session, ConversationDraftStore) -> LiveConversation = { LiveConversation(session: $0, drafts: $1) }) {
        self.drafts = drafts
        self.makeConversation = makeConversation
    }

    func prepare(_ session: Session) {
        guard InAppAgentRuntime.isAvailable, InAppResumeTarget.unavailableReason(for: session) == nil,
              sessions[session.id] == nil else { return }
        sessions[session.id] = makeConversation(session, drafts)
    }

    @discardableResult
    func adopt(_ created: CreatedConversation) async -> LiveConversation {
        let conversation = LiveConversation(session: created.session,
            makeRuntime: { created.runtime }, resolveTarget: { _ in created.target },
            drafts: drafts, adoptingCreatedSession: true)
        sessions[created.session.id] = conversation
        _ = await conversation.connect()
        return conversation
    }

    func listState(for session: Session) -> ConversationListState {
        if let conversation = sessions[session.id] { return conversation.listState }
        let draft = drafts.drafts[session.id]
        return ConversationListState(activity: draft?.deliveryUncertain == true ? .failed : nil,
                                     hasDraft: draft?.text.nilIfBlank != nil)
    }

    func disconnectAll() async {
        for conversation in sessions.values { await conversation.disconnect() }
        await drafts.flush()
    }
}
