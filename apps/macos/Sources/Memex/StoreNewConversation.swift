import Foundation

extension Store {
    var conversationProjectNames: [String: String] {
        createdConversations.contexts.mapValues { context in
            localProjects.projects.first { $0.id == context.projectID }?.name ?? context.projectName
        }
    }

    func projectName(for session: Session) -> String {
        guard let context = createdConversations.contexts[session.id] else { return session.projectName }
        return localProjects.projects.first { $0.id == context.projectID }?.name ?? context.projectName
    }

    var newConversationProject: LocalProject? {
        localProjects.projects.first { $0.id == newConversationDraft.value.projectID }
    }

    var canStartConversation: Bool {
        !startingConversation && newConversationProject != nil
            && newConversationDraft.value.text.nilIfBlank != nil
            && newConversationDraft.value.createdSessionID == nil
            && newConversationDraft.value.preparedWorkspace?.state != .failed
            && newConversationDraft.error == nil && localProjects.error == nil
    }

    func startConversationFromHome() async {
        guard canStartConversation, let project = newConversationProject else { return }
        startingConversation = true
        newConversationError = nil
        defer { startingConversation = false }
        let draft = newConversationDraft.value
        do {
            await newConversationDraft.flush()
            if let error = newConversationDraft.error { throw ConversationRuntimeError(message: error) }
            if let error = createdConversations.error ?? liveConversations.drafts.error {
                throw ConversationRuntimeError(message: error)
            }

            let workspace: ConversationWorkspace
            if let prepared = draft.preparedWorkspace {
                workspace = prepared
            } else {
                workspace = try await workspaceClient.prepare(
                    directory: URL(fileURLWithPath: project.directoryPath, isDirectory: true),
                    mode: draft.workspaceMode, baseRef: draft.baseRef)
                newConversationDraft.value.preparedWorkspace = workspace
                await newConversationDraft.flush()
                if let error = newConversationDraft.error { throw ConversationRuntimeError(message: error) }
            }

            let context = CreatedConversationCatalog.Context(projectID: project.id, projectName: project.name, workspace: workspace)
            let conversation = try await createConversation(
                .init(provider: draft.provider, workingDirectory: workspace.workingDirectory),
                context: context, initialText: draft.text, navigate: false)
            // The native session and its draft must both survive relaunch before
            // retiring the Home draft or crossing the provider prompt boundary.
            if let error = createdConversations.error ?? newConversationDraft.error ?? liveConversations.drafts.error {
                throw ConversationRuntimeError(message: error)
            }
            try await newConversationDraft.finishTransfer()
            revealCreatedConversation(conversation.session)
            conversation.focus()
            await conversation.send()
        } catch {
            if let failed = (error as? ConversationWorkspacePreparationError)?.retainedWorkspace {
                newConversationDraft.value.preparedWorkspace = failed
                await newConversationDraft.flush()
            }
            newConversationError = error.localizedDescription
        }
    }

    /// Recover the already-created chat after a save failure or app exit. This
    /// never sends: its durable draft or uncertain delivery remains authoritative.
    func openCreatedConversationFromHome() async {
        guard !startingConversation, let id = newConversationDraft.value.createdSessionID else { return }
        guard let session = createdConversations.sessions.first(where: { $0.id == id }) else {
            newConversationError = "The created conversation is missing from the saved list. Your prompt and workspace have been retained."
            return
        }
        createdConversations.retrySave()
        if let error = createdConversations.error {
            newConversationError = error
            return
        }
        if liveConversations.drafts.drafts[id] == nil, !newConversationDraft.value.text.isEmpty {
            liveConversations.drafts.set(.init(text: newConversationDraft.value.text), for: id)
            await liveConversations.drafts.flush()
        }
        await liveConversations.drafts.retrySave()
        if let error = liveConversations.drafts.error {
            newConversationError = error
            return
        }
        do { try await newConversationDraft.finishTransfer() }
        catch {
            newConversationError = error.localizedDescription
            return
        }
        newConversationError = nil
        revealCreatedConversation(session)
    }
}
