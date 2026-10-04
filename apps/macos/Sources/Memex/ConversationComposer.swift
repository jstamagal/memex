import SwiftUI

#if canImport(SQACPUI)
import SQACPUI

/// Use the same interaction surface as Sidequery's AgentInspectorView. Memex
/// supplies the session; SQACPUI owns the prompt, controls and request panels.
struct ConversationComposer: View {
    @Bindable var conversation: LiveConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AcpComposerView(
                text: $conversation.draft,
                placeholder: "Ask the agent…",
                isRunning: conversation.isWorking,
                canSend: conversation.canSubmit && conversation.draft.nilIfBlank != nil,
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
                composerFont: .system(size: 14),
                onSubmit: { Task { await conversation.send() } },
                onCancel: { Task { await conversation.stop() } },
                leadingAccessory: {
                    Group {
                        if conversation.isOpenElsewhere {
                            Label("Open elsewhere", systemImage: "lock")
                                .help("This conversation is open in another Codex app or CLI. Close it there to continue here.")
                        } else {
                            Text(conversation.session.source == "codex" ? "Codex" : "Claude Code")
                        }
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                },
                sendButton: { AcpSendButton().accessibilityLabel("Send") },
                cancelButton: { AcpStopButton().accessibilityLabel("Stop") }
            )
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

}
#else
struct ConversationComposer: View {
    let conversation: LiveConversation
    var body: some View { EmptyView() }
}
#endif
