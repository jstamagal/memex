import AppKit
import SwiftUI

#if canImport(SQACPUI)
import SQACPUI

/// Use the same interaction surface as Sidequery's AgentInspectorView. Memex
/// supplies the session; SQACPUI owns the prompt, controls and request panels.
struct ConversationComposer: View {
    @Bindable var conversation: LiveConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if conversation.isOpenElsewhere {
                Label("Close this conversation in the other Codex app or CLI to continue here.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = conversation.draftSaveError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let error = conversation.attachmentError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            AcpComposerView(
                text: $conversation.draft,
                placeholder: "Ask the agent…",
                isRunning: conversation.isWorking,
                canSend: conversation.canSubmit && conversation.hasPrompt,
                focusRequestID: conversation.focusRequest,
                pendingApprovals: conversation.snapshot.approvals.map { approval in
                    AcpComposerPendingApprovalItem(
                        id: approval.id, title: approval.title, subtitle: nil,
                        diffPreview: approval.detail,
                        options: approval.options.map {
                            AcpComposerPendingApprovalOption(id: $0.id, name: $0.title, kind: $0.kind)
                        })
                },
                onSelectApprovalOption: { requestID, optionID in
                    guard let approval = conversation.snapshot.approvals.first(where: { $0.id == requestID }),
                          let option = approval.options.first(where: { $0.id == optionID }) else { return }
                    Task { await conversation.approve(approval, option: option) }
                },
                onCancelApproval: { _ in Task { await conversation.stop() } },
                pendingUserInputs: conversation.snapshot.questions.map { question in
                    AcpComposerPendingUserInputItem(
                        id: question.id, title: question.title, prompt: question.prompt,
                        placeholder: question.placeholder,
                        choices: question.choices.map {
                            AcpComposerPendingUserInputChoice(id: $0.id, title: $0.title, value: $0.value)
                        })
                },
                onSubmitUserInput: { requestID, text in
                    guard let question = conversation.snapshot.questions.first(where: { $0.id == requestID }) else { return }
                    Task { await conversation.answer(question, text: text) }
                },
                onCancelUserInput: { _ in Task { await conversation.stop() } },
                contextItems: conversation.attachments.map {
                    .init(id: $0.id, title: $0.title, subtitle: $0.path, kind: "attachment", systemImageName: "doc")
                },
                onRemoveContextItem: { conversation.removeAttachment($0) },
                composerFont: .system(size: 14),
                onSubmit: { Task { await conversation.send() } },
                onCancel: { Task { await conversation.stop() } },
                leadingAccessory: { controls },
                sendButton: { AcpSendButton().accessibilityLabel("Send") },
                cancelButton: { AcpStopButton().accessibilityLabel("Stop") }
            )
        }
        .frame(maxWidth: ConversationReadingLane.maximumWidth)
        .padding(.horizontal, ConversationReadingLane.minimumMargin).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
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
                .disabled(conversation.loadingAttachments || conversation.isWorking)

                if let settings = conversation.snapshot.controls {
                    AcpModelVariantSelectorMenu(
                        modelLabel: settings.modelTitle ?? "Model",
                        reasoningLabel: settings.reasoning?.selectedTitle ?? "Effort",
                        modelOptions: options(settings.models),
                        reasoningOptions: options(settings.reasoning?.choices ?? []),
                        selectedModelID: settings.selectedModelID,
                        selectedReasoningID: settings.reasoning?.selectedID,
                        foregroundColor: .primary.opacity(0.78), hoverFillColor: .primary.opacity(0.08),
                        onSelectModel: { id in Task { await conversation.setModel(id) } },
                        onSelectReasoning: { id in
                            guard let option = settings.reasoning else { return }
                            Task { await conversation.configure(option, value: id) }
                        })
                        .disabled(!conversation.canChangeSettings)
                        .help(settings.appliesToNextTurn ? "Model and effort for the next turn" : "Conversation model and effort")
                    ForEach(settings.configurations.filter { $0.id != settings.reasoning?.id && !$0.choices.isEmpty }) { option in
                        AcpPromptSelectorMenu(
                            label: option.selectedTitle ?? option.title,
                            options: options(option.choices),
                            foregroundColor: .primary.opacity(0.78), hoverFillColor: .primary.opacity(0.08),
                            usesHoverPill: true, selectedID: option.selectedID
                        ) { id in Task { await conversation.configure(option, value: id) } }
                        .disabled(!conversation.canChangeSettings)
                        .help(option.selectedID == nil
                              ? "The provider has not reported the inherited \(option.title.lowercased()). Choose a value to change it."
                              : option.title)
                    }
                } else {
                    AcpPromptSelectorMenu(
                        label: conversation.session.source == "codex" ? "Codex" : "Claude Code",
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
    var body: some View { EmptyView() }
}
#endif
