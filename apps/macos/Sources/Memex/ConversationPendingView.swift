import SwiftUI

#if canImport(SQACPUI)
import SQACPUI
#endif

/// Local send state stays outside the source transcript and its search results.
struct ConversationPendingView: View {
    let conversation: LiveConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pending = conversation.pendingPrompt {
                HStack {
                    Spacer(minLength: 30)
                    VStack(alignment: .trailing, spacing: 6) {
                        if !pending.text.isEmpty {
                            Text(pending.text).font(.system(size: 14)).lineLimit(4)
                                .textSelection(.enabled)
                        }
                        if !pending.attachments.isEmpty {
                            Label(pending.attachments.map(\.title).joined(separator: ", "), systemImage: "paperclip")
                                .font(.caption).lineLimit(2)
                        }
                        HStack(spacing: 8) {
                            Text(label(pending.phase)).font(.caption).foregroundStyle(.secondary)
                            if pending.phase == .notSent || pending.phase == .uncertain {
                                Button("Restore draft") { conversation.restorePendingDraft() }
                                    .buttonStyle(.borderless).font(.caption)
                                    .disabled(conversation.isWorking || (pending.phase == .uncertain && !conversation.snapshot.ready))
                                    .help("Review the conversation first. This restores the message without sending it.")
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            #if canImport(SQACPUI)
            if conversation.snapshot.running && conversation.snapshot.approvals.isEmpty && conversation.snapshot.questions.isEmpty {
                AcpShimmerText("Thinking…", font: .system(size: 12))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Agent is working")
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
            }
            #endif
        }
        .frame(maxWidth: ConversationReadingLane.maximumWidth, alignment: .leading)
        .padding(.horizontal, ConversationReadingLane.minimumMargin)
        .frame(maxWidth: .infinity)
    }

    private func label(_ phase: ConversationPendingPrompt.Phase) -> String {
        switch phase {
        case .preparing: "Preparing to send…"
        case .awaitingConfirmation: "Sending…"
        case .uncertain: "Delivery unconfirmed — review before retrying"
        case .notSent: "Not sent"
        }
    }
}
