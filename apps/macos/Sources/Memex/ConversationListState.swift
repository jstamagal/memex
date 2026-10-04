import SwiftUI

enum ConversationActivity: String, Equatable, Sendable {
    case starting, working, stopping, approval, question, failed, completed, stopped, openElsewhere

    var label: String {
        switch self {
        case .starting: "Starting"
        case .working: "Working"
        case .stopping: "Stopping"
        case .approval: "Approval needed"
        case .question: "Answer needed"
        case .failed: "Needs attention"
        case .completed: "Completed"
        case .stopped: "Stopped"
        case .openElsewhere: "Open elsewhere"
        }
    }

    var symbol: String {
        switch self {
        case .starting, .working: "circle.dotted"
        case .stopping, .stopped: "stop.circle"
        case .approval: "hand.raised"
        case .question: "questionmark.bubble"
        case .failed: "exclamationmark.circle"
        case .completed: "checkmark.circle"
        case .openElsewhere: "lock"
        }
    }

    var color: Color {
        switch self {
        case .approval, .question: .orange
        case .failed: .red
        case .starting, .working, .stopping: .accentColor
        case .completed, .stopped, .openElsewhere: .secondary
        }
    }
}

struct ConversationListState: Equatable, Sendable {
    var activity: ConversationActivity?
    var hasDraft = false

    var label: String? {
        [activity?.label, hasDraft ? "Draft" : nil].compactMap { $0 }.joined(separator: " · ").nilIfBlank
    }
    var symbol: String { activity?.symbol ?? "square.and.pencil" }
}

struct ConversationStateLabel: View {
    let state: ConversationListState

    var body: some View {
        if let label = state.label {
            Label(label, systemImage: state.symbol)
                .font(.caption).foregroundStyle(state.activity?.color ?? .secondary)
                .lineLimit(1)
        }
    }
}
