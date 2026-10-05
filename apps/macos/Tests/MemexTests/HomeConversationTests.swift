import Foundation
import Testing
@testable import Memex

private actor HomeConversationRuntime: ConversationRuntime {
    var creations: [URL] = []
    var prompts: [String] = []
    var failCreation = false

    func failNextCreation() { failCreation = true }
    func create(_ request: NewConversationRequest) throws -> CreatedConversation {
        creations.append(request.workingDirectory)
        if failCreation {
            failCreation = false
            throw ConversationRuntimeError(message: "Creation failed before native session allocation")
        }
        let session = Session(source: request.provider, sessionID: "home-native-\(creations.count)",
            sourcePath: "/tmp/home-native/sessions/new.jsonl", project: request.workingDirectory.lastPathComponent,
            cwd: request.workingDirectory.path)
        let target = InAppResumeTarget(session: session, sourceURL: URL(fileURLWithPath: session.sourcePath),
            workingDirectory: request.workingDirectory, providerHome: URL(fileURLWithPath: "/tmp/home-native"),
            executableURL: URL(fileURLWithPath: "/bin/echo"), helperURL: nil,
            storageURL: URL(fileURLWithPath: "/tmp/home-native-runtime"))
        return CreatedConversation(session: session, runtime: self, target: target)
    }
    func connect(_ target: InAppResumeTarget,
                 receive: @escaping @Sendable (Result<ConversationSnapshot, ConversationRuntimeError>) -> Void) {
        receive(.success(ConversationSnapshot(connected: true, ready: true, canCancel: true)))
    }
    func perform(_ command: ConversationCommand) { if command.action == .prompt { prompts.append(command.text) } }
    func disconnect() {}
}

@Suite(.serialized) @MainActor struct HomeConversationTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func homeSubmitCreatesOnceTransfersDurableDraftAndRecordsProject() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = LocalProjects(directory: root.appendingPathComponent("projects"))
        let project = try projects.save(name: "My project", directory: root)
        let home = NewConversationDraft(directory: root.appendingPathComponent("home"))
        home.selectProject(project)
        home.value.text = "Build the requested feature"
        let runtime = HomeConversationRuntime()
        let drafts = ConversationDraftStore(directory: root.appendingPathComponent("drafts"))
        let catalogRoot = root.appendingPathComponent("catalog")
        let store = Store(draftStore: drafts, createdConversations: CreatedConversationCatalog(directory: catalogRoot),
            localProjects: projects, newConversationDraft: home, makeConversation: { try await runtime.create($0) })
        async let first: Void = store.startConversationFromHome()
        async let duplicate: Void = store.startConversationFromHome()
        _ = await (first, duplicate)
        #expect(await runtime.creations.count == 1)
        #expect(await runtime.prompts == ["Build the requested feature"])
        let session = try #require(store.selected)
        #expect(store.scope == .all)
        #expect(home.value.text.isEmpty)
        #expect(home.value.createdSessionID == nil)
        #expect(home.value.projectID == project.id)
        #expect(NewConversationDraft(directory: root.appendingPathComponent("home")).value.text.isEmpty)
        let reopened = CreatedConversationCatalog(directory: catalogRoot)
        #expect(reopened.contexts[session.id]?.projectName == "My project")
        #expect(reopened.contexts[session.id]?.workspace.workingDirectory == root.resolvingSymlinksInPath())
        #expect(drafts.drafts[session.id]?.pendingPrompt?.text == "Build the requested feature")
        let list = ConversationListController()
        list.update(sessions: [session], selectedID: session.id, projectNames: store.conversationProjectNames,
                    select: { _ in }, loadMore: { _ in })
        #expect(list.rows[0].metadata == "My project · codex")
        #expect(list.rows[0].session == session)
        var renamed = project
        renamed.name = "Renamed project"
        try projects.update(renamed)
        list.update(sessions: [session], selectedID: session.id, projectNames: store.conversationProjectNames,
                    select: { _ in }, loadMore: { _ in })
        #expect(list.rows[0].metadata == "Renamed project · codex")
        #expect(store.projectName(for: session) == "Renamed project")
        try projects.remove(id: project.id)
        #expect(store.projectName(for: session) == "My project")
        #expect(store.createdConversations.contexts[session.id]?.workspace.workingDirectory == root.resolvingSymlinksInPath())
        await store.liveConversations.disconnectAll()
    }

    @Test func providerFailureReusesPreparedWorktreeAndKeepsPrompt() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let run = CommandRun()
        func git(_ arguments: [String]) throws {
            _ = try run.execute(executable: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", projectRoot.path] + arguments, timeout: 10)
        }
        try git(["init", "-b", "main"])
        try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Initial"])
        let projects = LocalProjects()
        let project = try projects.save(name: "Project", directory: projectRoot, defaultWorkspace: .newWorktree, defaultBaseRef: "main")
        let home = NewConversationDraft(directory: root.appendingPathComponent("home"))
        home.selectProject(project)
        home.value.text = "Retain this request"
        let runtime = HomeConversationRuntime()
        await runtime.failNextCreation()
        let store = Store(localProjects: projects, newConversationDraft: home,
            workspaceClient: ConversationWorkspaceClient(managedRoot: root.appendingPathComponent("worktrees")),
            makeConversation: { try await runtime.create($0) })
        await store.startConversationFromHome()
        #expect(store.newConversationError != nil)
        let prepared = try #require(home.value.preparedWorkspace)
        #expect(prepared.state == .ready)
        #expect(home.value.text == "Retain this request")
        #expect(NewConversationDraft(directory: root.appendingPathComponent("home")).value.preparedWorkspace == prepared)
        await store.startConversationFromHome()
        #expect(await runtime.creations == [prepared.workingDirectory, prepared.workingDirectory])
        #expect(await runtime.prompts == ["Retain this request"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("worktrees").path).count == 1)
        await store.liveConversations.disconnectAll()
    }

    @Test func failedDraftSaveKeepsCreatedIdentityAndRecoveryNeverResends() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = LocalProjects()
        let project = try projects.save(name: "Project", directory: root)
        let homeRoot = root.appendingPathComponent("home")
        let home = NewConversationDraft(directory: homeRoot)
        home.selectProject(project)
        home.value.text = "Saved in Home"
        let draftsRoot = root.appendingPathComponent("drafts")
        let drafts = ConversationDraftStore(directory: draftsRoot)
        // A storage failure after initialization is recoverable without recreating the chat.
        try Data("blocking file".utf8).write(to: draftsRoot)
        let runtime = HomeConversationRuntime()
        let store = Store(draftStore: drafts, localProjects: projects, newConversationDraft: home,
            makeConversation: { try await runtime.create($0) })
        await store.startConversationFromHome()
        #expect(await runtime.creations.count == 1)
        #expect(await runtime.prompts.isEmpty)
        #expect(home.value.createdSessionID != nil)
        #expect(NewConversationDraft(directory: homeRoot).value.createdSessionID == home.value.createdSessionID)
        #expect(!store.canStartConversation)
        await store.startConversationFromHome()
        #expect(await runtime.creations.count == 1)
        try FileManager.default.removeItem(at: draftsRoot)
        await store.openCreatedConversationFromHome()
        #expect(store.newConversationError == nil)
        #expect(store.selectedLiveConversation?.draft == "Saved in Home")
        #expect(home.value.createdSessionID == nil)
        #expect(await runtime.prompts.isEmpty)
        await store.liveConversations.disconnectAll()
    }

    @Test func failedHomeClearPreservesRecoveryMarkerAndUnreadableDraftIsNotReplaced() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeRoot = root.appendingPathComponent("home")
        let home = NewConversationDraft(directory: homeRoot)
        home.value.text = "Pending transfer"
        home.value.createdSessionID = "exact-native-identity"
        await home.flush()
        try FileManager.default.removeItem(at: homeRoot)
        try Data("blocking file".utf8).write(to: homeRoot)
        await #expect(throws: ConversationRuntimeError.self) { try await home.finishTransfer() }
        #expect(home.value.createdSessionID == "exact-native-identity")
        #expect(home.value.text == "Pending transfer")
        await home.flush()
        let corrupt = NewConversationDraft(directory: homeRoot)
        corrupt.value.text = "New draft"
        await corrupt.flush()
        #expect(corrupt.error != nil)
        #expect(try Data(contentsOf: homeRoot) == Data("blocking file".utf8))
    }
}
