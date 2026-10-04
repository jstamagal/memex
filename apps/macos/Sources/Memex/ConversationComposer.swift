import SwiftUI

#if canImport(SQACPUI)
import SQACPUI

/// Use the same interaction surface as Sidequery's AgentInspectorView. Memex
/// supplies the session; SQACPUI owns the prompt, controls and request panels.
struct ConversationComposer: View {
    @Bindable var conversation: LiveConversation
    @State private var inspectedApproval: ConversationApproval?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if conversation.isOpenElsewhere {
                Label("Close this conversation in the other Codex app or CLI to continue here.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = conversation.draftSaveError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            ForEach(conversation.snapshot.approvals.filter { $0.detail?.nilIfBlank != nil }) { approval in
                Button { inspectedApproval = approval } label: {
                    Label("Inspect full request: \(approval.title)", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless).font(.caption)
            }
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
                },
                sendButton: { AcpSendButton().accessibilityLabel("Send") },
                cancelButton: { AcpStopButton().accessibilityLabel("Stop") }
            )
        }
        .frame(maxWidth: ConversationReadingLane.maximumWidth)
        .padding(.horizontal, ConversationReadingLane.minimumMargin).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .sheet(item: $inspectedApproval) { approval in
            VStack(alignment: .leading, spacing: 12) {
                Text(approval.title).font(.headline)
                ScrollView([.horizontal, .vertical]) {
                    Text(approval.detail ?? "").font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("Done") { inspectedApproval = nil }.keyboardShortcut(.cancelAction) }
            }
            .padding(20).frame(minWidth: 520, idealWidth: 720, minHeight: 320, idealHeight: 520)
        }
    }

}
#else
struct ConversationComposer: View {
    let conversation: LiveConversation
    var body: some View { EmptyView() }
}
#endif
