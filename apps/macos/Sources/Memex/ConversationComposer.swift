import AppKit
import SwiftUI

#if canImport(SQACPUI)
import SQACPUI
import SQACP

/// Use the same interaction surface as Sidequery's AgentInspectorView. Memex
/// supplies the session; SQACPUI owns the prompt, controls and request panels.
struct ConversationComposer: View {
    @Bindable var conversation: LiveConversation
    var contextSessions: [Session] = []
    @State private var catalog = ConversationComposerCatalog()
    @State private var contextError: String?
    @State private var loadingContext = false
    @State private var dropTargeted = false
    @State private var showingSettings = false
    @State private var showingDictation = false
    @State private var annotating: ConversationAttachment?
    @State private var recall = ConversationPromptRecall()
    @State private var library = ConversationPromptLibrary.shared
    @AppStorage("conversation.followUpBehavior") private var followUpBehavior = "queue"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConversationQueueView(conversation: conversation)
            ConversationQuestionsView(conversation: conversation)
            ForEach(conversation.snapshot.approvals.filter { $0.kind == "mcp_elicitation" }) { approval in
                ConversationElicitationView(approval: approval,
                    canRespond: conversation.snapshot.connected && !conversation.submitting,
                    onRespond: { response in Task { await conversation.respondToElicitation(approval, response: response) } })
            }
            if let error = contextError ?? library.error {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    Spacer()
                    Button { contextError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }
            if loadingContext { ProgressView("Capturing context…").controlSize(.small) }
            slashSuggestions
            if let error = conversation.draftSaveError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            if let error = conversation.attachmentError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            AcpComposerView(
                // Keep any saved draft intact while the ownership notice occupies the disabled field.
                text: conversation.isOpenElsewhere ? .constant("") : $conversation.draft,
                placeholder: conversation.isOpenElsewhere
                    ? "Close this conversation in the other Codex app or CLI to continue here."
                    : "Ask the agent…",
                isRunning: conversation.isWorking,
                canSend: (conversation.canSubmit || (conversation.isWorking && conversation.canQueue)) && conversation.hasPrompt && !loadingContext,
                focusRequestID: conversation.focusRequest,
                pendingApprovals: conversation.snapshot.approvals.filter { $0.kind != "mcp_elicitation" }.map { approval in
                    var item = AcpComposerPendingApprovalItem(
                        id: approval.id, title: approval.title, subtitle: nil,
                        diffPreview: approval.detail,
                        options: approval.options.map {
                            AcpComposerPendingApprovalOption(id: $0.id, name: $0.title, kind: $0.kind)
                        })
                    item.canRespond = conversation.snapshot.connected && !conversation.submitting
                    return item
                },
                onSelectApprovalOption: { requestID, optionID in
                    guard let approval = conversation.snapshot.approvals.first(where: { $0.id == requestID }),
                          let option = approval.options.first(where: { $0.id == optionID }) else { return }
                    Task { await conversation.approve(approval, option: option) }
                },
                onCancelApproval: { _ in Task { await conversation.stop() } },
                pendingUserInputs: [],
                onSubmitUserInput: { _, _ in },
                onCancelUserInput: { _ in },
                contextItems: conversation.attachments.map {
                    .init(id: $0.id, title: $0.title, subtitle: $0.path, kind: "attachment", systemImageName: "doc")
                },
                onRemoveContextItem: { conversation.removeAttachment($0) },
                composerFont: .system(size: 14),
                mentionConfiguration: .init(suggestions: mentionSuggestions, onSelect: selectMention),
                onSubmit: submit,
                onSteerSubmit: { Task { if !loadingContext { await conversation.steerDraft() } } },
                onCancel: { Task { await conversation.stop() } },
                leadingAccessory: { controls },
                sendButton: { AcpSendButton().accessibilityLabel("Send") },
                cancelButton: { AcpStopButton().accessibilityLabel("Stop") }
            )
            .disabled(conversation.isOpenElsewhere)
            .onPasteCommand(of: ConversationClipboard.supportedTypes) { providers in
                Task { await captureClipboard(providers) }
            }
            .onDrop(of: ConversationClipboard.supportedTypes, isTargeted: $dropTargeted) { providers in
                guard !loadingContext, !conversation.isOpenElsewhere else { return false }
                Task { await captureClipboard(providers) }
                return true
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(dropTargeted ? Color.accentColor : .clear, lineWidth: 2))
        }
        .frame(maxWidth: ConversationReadingLane.maximumWidth)
        .padding(.horizontal, ConversationReadingLane.minimumMargin).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .task(id: "\(conversation.session.id):\(conversation.isServerOwned)") { await loadCatalog() }
        .sheet(isPresented: $showingDictation) {
            ConversationDictationView { text in conversation.draft = joined(conversation.draft, text); conversation.focus() }
        }
        .sheet(item: $annotating) { item in
            ConversationAnnotationEditor(attachment: item, capturedSource: conversation.attachments.first {
                $0.id == (item.annotation?.attachmentID ?? item.id)
            }) { passage, comment in
                do {
                    let annotation = try item.annotated(passage: passage, comment: comment)
                    var items = conversation.attachments
                    guard items.contains(item) else { return false }
                    if item.annotation != nil { items.removeAll { $0.id == item.id } }
                    items.append(annotation)
                    try ConversationAttachment.validate(items, controls: conversation.snapshot.controls ?? ConversationControls())
                    return conversation.replaceDraft(text: conversation.draft, attachments: items)
                } catch { conversation.reportAttachmentError(error.localizedDescription); return false }
            }
        }
        .sheet(isPresented: $showingSettings) { settingsSheet }
    }

    @ViewBuilder private var controls: some View {
        if conversation.isOpenElsewhere {
            Label("Open elsewhere", systemImage: "lock")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .help("Close this conversation in the other Codex app or CLI to continue here.")
        } else {
            HStack(spacing: 2) {
                Button { Task { await chooseFiles() } } label: {
                    Image(systemName: "plus").font(.system(size: 14))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Attach files").accessibilityLabel("Attach files")
                .disabled(conversation.loadingAttachments || loadingContext || conversation.connecting)

                inputMenu

                if let settings = conversation.snapshot.controls {
                    AcpModelVariantSelectorMenu(
                        modelLabel: settings.modelTitle ?? "Model",
                        reasoningLabel: settings.reasoning?.selectedTitle ?? "Effort",
                        modelOptions: options(settings.models),
                        reasoningOptions: options(settings.reasoning?.choices ?? []),
                        selectedModelID: settings.selectedModelID,
                        selectedReasoningID: settings.reasoning?.selectedID,
                        foregroundColor: .primary.opacity(0.78), hoverFillColor: .primary.opacity(0.08),
                        onSelectModel: { id in Task { await chooseModel(id) } },
                        onSelectReasoning: { id in
                            guard let option = settings.reasoning else { return }
                            Task { await chooseConfiguration(option, value: id) }
                        })
                        .disabled(!conversation.canChangeSettings)
                        .help(settings.appliesToNextTurn ? "Model and effort for the next turn" : "Conversation model and effort")
                    ForEach(settings.configurations.filter { $0.id != settings.reasoning?.id && !$0.choices.isEmpty }) { option in
                        AcpPromptSelectorMenu(
                            label: option.selectedTitle ?? option.title,
                            options: options(option.choices),
                            foregroundColor: .primary.opacity(0.78), hoverFillColor: .primary.opacity(0.08),
                            usesHoverPill: true, selectedID: option.selectedID
                        ) { id in Task { await chooseConfiguration(option, value: id) } }
                        .disabled(!conversation.canChangeSettings)
                        .help(option.selectedID == nil
                              ? "The provider has not reported the inherited \(option.title.lowercased()). Choose a value to change it."
                              : option.title)
                    }
                } else {
                    AcpPromptSelectorMenu(
                        label: ConversationProviderCatalog.name(for: conversation.session.source),
                        options: [.init(id: "load", title: "Load conversation settings", isEnabled: true)],
                        foregroundColor: .primary.opacity(0.78), usesHoverPill: true
                    ) { _ in Task { await conversation.connect() } }
                    .disabled(conversation.isWorking)
                }
            }
        }
    }

    private func options(_ choices: [ConversationControls.Choice]) -> [AcpProviderOption] {
        choices.map { .init(id: $0.id, title: $0.title, isEnabled: true) }
    }

    private var inputMenu: some View {
        Menu {
            Button("Dictate a prompt…") { showingDictation = true }
            Divider()
            if conversation.isWorking {
                Picker("While working", selection: $followUpBehavior) {
                    Text("Queue after this turn").tag("queue")
                    if conversation.canSteer { Text("Steer current turn").tag("steer") }
                }
                Button("Queue message") { Task { await conversation.enqueueDraft() } }
                    .disabled(!conversation.canQueue || !conversation.hasPrompt || loadingContext)
                if conversation.canSteer {
                    Button("Steer current turn") { Task { await conversation.steerDraft() } }
                        .disabled(!conversation.hasPrompt || loadingContext)
                }
                if conversation.canInterruptAndRestart {
                    Button("Stop and send draft as a new turn") { Task { await conversation.interruptAndRestartDraft() } }
                        .disabled(!conversation.hasPrompt || loadingContext)
                }
                Divider()
            }
            if !conversation.attachments.isEmpty {
                Menu("Annotate captured context") {
                    ForEach(conversation.attachments) { item in
                        Button(item.title) { annotating = item }
                    }
                }
                Divider()
            }
            Button("Stash current prompt") { Task { await stashPrompt() } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!conversation.hasPrompt || library.saving || loadingContext)
            Menu("Saved prompts (\(library.entries.count))") {
                ForEach(library.entries) { entry in
                    Menu(entry.title) {
                        Button("Insert into draft") { restoreStash(entry) }
                        Button("Delete saved prompt", role: .destructive) { Task { await library.remove(entry.id) } }
                    }
                }
            }.disabled(library.entries.isEmpty || library.saving)
            Divider()
            Button("Previous prompt") { recallPrompt(-1) }.keyboardShortcut(.upArrow, modifiers: [.command])
                .disabled(promptHistory.isEmpty)
            Button("Next prompt / original draft") { recallPrompt(1) }.keyboardShortcut(.downArrow, modifiers: [.command])
                .disabled(recall.position == nil)
            Menu("Recent prompts") {
                ForEach(Array(promptHistory.suffix(12).enumerated()), id: \.offset) { _, text in
                    Button(String(text.prefix(100))) { conversation.draft = joined(conversation.draft, text) }
                }
            }.disabled(promptHistory.isEmpty)
            Divider()
            Button("Insert file or conversation mention") {
                conversation.draft = joined(conversation.draft, "@", separator: " ")
                conversation.focus()
            }
            Button("Commands and skills") {
                conversation.draft = "/ " + conversation.draft
                conversation.focus()
            }
            Button("Reload commands and file list") { Task { await loadCatalog() } }
        } label: { Image(systemName: "text.badge.plus").frame(width: 28, height: 28) }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Prompt history, stash, mentions and commands")
        .disabled(conversation.isOpenElsewhere)
    }

    private var promptHistory: [String] {
        conversation.snapshot.records.compactMap {
            $0.record.role == "user" && !$0.record.isInstruction ? $0.record.text.nilIfBlank : nil
        }
    }

    private func recallPrompt(_ direction: Int) {
        if let text = recall.move(direction, current: conversation.draft, history: promptHistory) {
            conversation.draft = text
            conversation.focus()
        }
    }

    private func joined(_ left: String, _ right: String, separator: String = "\n\n") -> String {
        [left, right].filter { !$0.isEmpty }.joined(separator: separator)
    }

    private func stashPrompt() async {
        let text = conversation.draft
        let attachments = conversation.attachments
        guard !loadingContext, await library.stash(text: text, attachments: attachments) else { return }
        // Saving may suspend while the user continues typing. Never clear newer input.
        if conversation.draft == text, conversation.attachments == attachments {
            _ = conversation.replaceDraft(text: "", attachments: [])
        }
    }

    private func restoreStash(_ entry: ConversationPromptEntry) {
        let attachments = conversation.attachments + entry.attachments.filter { saved in
            !conversation.attachments.contains { $0.id == saved.id }
        }
        do {
            try ConversationAttachment.validate(attachments, controls: conversation.snapshot.controls ?? ConversationControls())
            guard conversation.replaceDraft(text: joined(conversation.draft, entry.text), attachments: attachments) else {
                throw ConversationRuntimeError(message: "Wait for the current draft operation before restoring this prompt.")
            }
            contextError = nil
            conversation.focus()
        } catch { contextError = error.localizedDescription }
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Conversation settings").font(.title2)
            if let settings = conversation.snapshot.controls {
                Form {
                    if !settings.models.isEmpty {
                        Picker("Model", selection: Binding(get: { settings.selectedModelID ?? "" }, set: { id in Task { await chooseModel(id) } })) {
                            if settings.selectedModelID == nil { Text("Provider default").tag("") }
                            ForEach(settings.models) { Text($0.title).tag($0.id) }
                        }
                    }
                    ForEach(settings.configurations.filter { !$0.choices.isEmpty }) { option in
                        Picker(option.title, selection: Binding(get: { option.selectedID ?? "" }, set: { id in Task { await chooseConfiguration(option, value: id) } })) {
                            if option.selectedID == nil { Text("Inherited default").tag("") }
                            ForEach(option.choices) { Text($0.title).tag($0.id) }
                        }
                    }
                }.disabled(!conversation.canChangeSettings)
            } else {
                Text("Load this conversation to discover the provider's available settings.").foregroundStyle(.secondary)
                Button("Load settings") { Task { await conversation.connect() } }.disabled(conversation.isWorking)
            }
            Text("Explicit selections are remembered for new conversations. Existing conversations keep their own settings.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { showingSettings = false }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 460)
    }

    private func chooseModel(_ id: String) async {
        if await conversation.applySettings(modelID: id, configurationValues: [:]) {
            ConversationComposerPreferences.saveModel(id, provider: conversation.session.source)
        }
    }

    private func chooseConfiguration(_ option: ConversationControls.Configuration, value: String) async {
        if await conversation.applySettings(modelID: nil, configurationValues: [option.id: value]) {
            ConversationComposerPreferences.saveConfiguration(option.id, value: value, provider: conversation.session.source)
        }
    }

    private var slashQuery: String? {
        guard conversation.draft.hasPrefix("/") else { return nil }
        return String(conversation.draft.dropFirst().prefix { !$0.isWhitespace })
    }

    private var planConfiguration: ConversationControls.Configuration? {
        conversation.snapshot.controls?.configurations.first { $0.choices.contains(where: { $0.id == "plan" }) }
    }

    @ViewBuilder private var slashSuggestions: some View {
        if let query = slashQuery {
            VStack(alignment: .leading, spacing: 5) {
                if "model".hasPrefix(query) {
                    Button("/model — Choose model, effort and permissions") { consumeSlashToken(); showingSettings = true }
                }
                if let option = planConfiguration, "plan".hasPrefix(query) {
                    Button("/plan — Plan this work") {
                        consumeSlashToken()
                        Task { await chooseConfiguration(option, value: "plan") }
                    }.disabled(!conversation.canChangeSettings)
                }
                if let option = planConfiguration,
                   let value = option.choices.first(where: { ["default", "build", "code"].contains($0.id) })?.id,
                   "default".hasPrefix(query) {
                    Button("/default — Return to build mode") {
                        consumeSlashToken()
                        Task { await chooseConfiguration(option, value: value) }
                    }.disabled(!conversation.canChangeSettings)
                }
                ForEach((conversation.snapshot.controls?.slashCommands ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.prefix(8)) { command in
                    Button("/\(command.name) — \(command.description)") {
                        conversation.draft = "/\(command.name) " + slashRemainder
                        conversation.focus()
                    }.help(command.hint ?? command.description)
                }
                ForEach(catalog.matchingPrompts(query.replacingOccurrences(of: "skill:", with: "").replacingOccurrences(of: "command:", with: ""))) { prompt in
                    Button("/\(prompt.kind.rawValue):\(prompt.name) — \(prompt.description)") { Task { await capturePrompt(prompt) } }
                        .help(prompt.url.path)
                }
                if catalog.truncated { Text("Showing a bounded workspace catalog. Use Attach files for other paths.").foregroundStyle(.secondary) }
            }
            .font(.caption).buttonStyle(.plain)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .disabled(loadingContext || conversation.isOpenElsewhere)
        }
    }

    private var slashRemainder: String {
        guard let query = slashQuery else { return conversation.draft }
        return String(conversation.draft.dropFirst(query.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func consumeSlashToken() { conversation.draft = slashRemainder }

    private func submit() {
        guard !loadingContext else { return }
        if slashQuery == "model" { consumeSlashToken(); showingSettings = true; return }
        if slashQuery == "plan", let option = planConfiguration {
            consumeSlashToken()
            Task { await chooseConfiguration(option, value: "plan") }
            return
        }
        if slashQuery == "default", let option = planConfiguration,
           let value = option.choices.first(where: { ["default", "build", "code"].contains($0.id) })?.id {
            consumeSlashToken()
            Task { await chooseConfiguration(option, value: value) }
            return
        }
        if let query = slashQuery,
           let prompt = catalog.prompts.first(where: { "\($0.kind.rawValue):\($0.name)" == query }) {
            Task { await capturePrompt(prompt) }
            return
        }
        recall.reset()
        Task {
            if conversation.isWorking {
                if followUpBehavior == "steer", conversation.canSteer { await conversation.steerDraft() }
                else { await conversation.enqueueDraft() }
            } else { await conversation.send() }
        }
    }

    private func capturePrompt(_ prompt: ConversationComposerCatalog.Prompt) async {
        guard !loadingContext, locallyAccessible else { return }
        let originalDraft = conversation.draft
        let remainder = slashRemainder
        loadingContext = true
        defer { loadingContext = false }
        do {
            let text = try await Task.detached {
                guard (try prompt.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 20 * 1024 * 1024 else {
                    throw ConversationRuntimeError(message: "This prompt file exceeds the context size limit.")
                }
                return try String(contentsOf: prompt.url, encoding: .utf8)
            }.value
            guard conversation.draft == originalDraft else {
                throw ConversationRuntimeError(message: "Your draft changed while the command loaded. Select it again to apply it to the current draft.")
            }
            let contents = prompt.kind == .command ? text.replacingOccurrences(of: "$ARGUMENTS", with: remainder) : text
            let item = try ConversationAttachment.text(title: "\(prompt.kind.rawValue.capitalized): \(prompt.name)", text: contents, source: prompt.url.path)
            let combined = conversation.attachments + [item]
            try ConversationAttachment.validate(combined, controls: conversation.snapshot.controls ?? ConversationControls())
            let invocation = "Use the attached \(prompt.kind.rawValue) \(prompt.name) for this request."
            guard conversation.replaceDraft(text: joined(invocation, remainder), attachments: combined) else {
                throw ConversationRuntimeError(message: "The draft is busy. Select the command again when it finishes.")
            }
            contextError = nil
            conversation.focus()
        } catch { contextError = error.localizedDescription }
    }

    private func mentionSuggestions(_ query: String) -> [AcpComposerMentionSuggestion] {
        let chats = contextSessions.reduce(into: [String: Session]()) { $0[$1.id] = $1 }.values
            .filter { $0.id != conversation.session.id && !query.isEmpty && ($0.title.localizedCaseInsensitiveContains(query) || $0.sessionID.hasPrefix(query)) }
            .sorted { ($0.lastAt ?? "") > ($1.lastAt ?? "") }.prefix(5)
            .map { AcpComposerMentionSuggestion(id: "chat:" + $0.id, title: $0.title,
                subtitle: "\($0.source) · \($0.machineID)", systemImageName: "bubble.left.and.bubble.right") }
        return chats + catalog.matchingFiles(query).map {
            .init(id: "file:" + $0.id, title: $0.url.lastPathComponent, subtitle: $0.relativePath, systemImageName: "doc")
        }
    }

    private func selectMention(_ suggestion: AcpComposerMentionSuggestion) {
        if suggestion.id.hasPrefix("file:"), let file = catalog.files.first(where: { "file:" + $0.id == suggestion.id }) {
            guard locallyAccessible else { return }
            Task { await conversation.attachFiles([file.url]) }
        } else if let session = contextSessions.first(where: { "chat:" + $0.id == suggestion.id }) {
            Task {
                guard !loadingContext else { return }
                loadingContext = true
                defer { loadingContext = false }
                do {
                    let attachment = try await ConversationMentionContext.capture(session)
                    guard conversation.appendCapturedContext([attachment]) else {
                        throw ConversationRuntimeError(message: "The conversation excerpt could not be attached. Remove an attachment or wait for the draft operation to finish.")
                    }
                    contextError = nil
                } catch { contextError = error.localizedDescription }
            }
        }
    }

    private var locallyAccessible: Bool {
        ConversationComposerCatalog.locallyAccessible(
            machineID: conversation.session.machineID, isServerOwned: conversation.isServerOwned)
    }

    private func loadCatalog() async {
        let session = conversation.session
        let locallyAccessible = locallyAccessible
        guard locallyAccessible else {
            catalog = ConversationComposerCatalog()
            return
        }
        do {
            let catalog = try await Task.detached {
                let providerHome = (try? InAppResumeTarget.providerHome(for: URL(fileURLWithPath: session.sourcePath), provider: session.source))
                    ?? (try? ConfiguredConversationManifest.read(for: session)).map { URL(fileURLWithPath: $0.provider.homePath) }
                return try ConversationComposerCatalog.load(workspace: session.cwd.map { URL(fileURLWithPath: $0) },
                    providerHome: providerHome, locallyAccessible: locallyAccessible)
            }.value
            guard !Task.isCancelled else { return }
            self.catalog = catalog
        } catch is CancellationError {} catch { contextError = error.localizedDescription }
    }

    private func captureClipboard(_ providers: [NSItemProvider]) async {
        guard !loadingContext, !conversation.isOpenElsewhere else { return }
        loadingContext = true
        defer { loadingContext = false }
        if !conversation.snapshot.connected {
            guard !conversation.isWorking, await conversation.connect() else { return }
        }
        guard conversation.snapshot.ready, let controls = conversation.snapshot.controls else {
            contextError = "The provider has not reported its attachment capabilities yet."
            return
        }
        do {
            let items = try await ConversationClipboard.capture(providers, controls: controls)
            guard !items.isEmpty, conversation.appendCapturedContext(items) else {
                throw ConversationRuntimeError(message: "These attachments could not be added. Check the message's attachment limits and try again.")
            }
            contextError = nil
        } catch { contextError = error.localizedDescription }
    }

    @MainActor private func chooseFiles() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.directoryURL = conversation.session.cwd.map { URL(fileURLWithPath: $0) }
        guard await panel.begin() == .OK else { return }
        await conversation.attachFiles(panel.urls)
    }
}
#else
struct ConversationComposer: View {
    let conversation: LiveConversation
    var contextSessions: [Session] = []
    var body: some View { EmptyView() }
}
#endif
