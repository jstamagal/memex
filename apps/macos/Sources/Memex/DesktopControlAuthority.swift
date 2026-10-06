import Foundation
import MemexExecutionHostCore
import Observation
import SwiftUI

enum DesktopControlFamily: String, CaseIterable, Codable, Hashable, Identifiable {
    case panel, preferences, organization
    var id: Self { self }
    var title: String {
        switch self {
        case .panel: "Open or close this chat’s workspace panels"
        case .preferences: "Read and change app appearance and keyboard shortcuts"
        case .organization: "Read and organize the conversation library and custom sections"
        }
    }
}

/// Native user actions are the only grant authority. Grants are never persisted
/// and no control request can create, expand or renew one.
@MainActor @Observable final class DesktopControlAuthority {
    struct Grant: Codable {
        let id: UUID
        let conversationID: String
        let sessionID: String
        let families: Set<DesktopControlFamily>
    }
    private(set) var grants: [String: Grant] = [:]
    let preferences: AppPreferences

    init(preferences: AppPreferences = .shared) { self.preferences = preferences }

    func allow(conversationID: String, sessionID: String, families: Set<DesktopControlFamily>) {
        guard !conversationID.isEmpty, !sessionID.isEmpty, !families.isEmpty else { return }
        grants[conversationID] = Grant(id: UUID(), conversationID: conversationID, sessionID: sessionID, families: families)
    }
    func revoke(conversationID: String) { grants.removeValue(forKey: conversationID) }

    func authorize(conversationID: String, grantID: String?, family: DesktopControlFamily) throws -> Grant {
        guard let grant = grants[conversationID], grant.id.uuidString == grantID,
              grant.families.contains(family) else {
            throw HostFailure("desktop_control_denied", "Explicit native Memex permission for this conversation and operation family is required. Open workspace controls to grant or revoke access.")
        }
        return grant
    }
}

struct DesktopControlPermissionView: View {
    let conversationID: String
    let sessionID: String
    @Bindable var authority: DesktopControlAuthority
    @State private var selected: Set<DesktopControlFamily> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Memex controls").font(.headline)
            Text("Allow this chat to use the selected Memex controls. Preferences affect the whole app; organization access includes titles and metadata for other chats. No messages are sent and provider history is not deleted. Permission expires when Memex quits.")
                .font(.caption)
            if let grant = authority.grants[conversationID] {
                ForEach(DesktopControlFamily.allCases.filter { grant.families.contains($0) }) { family in
                    Label(family.title, systemImage: "checkmark").font(.caption)
                }
                Button("Revoke Memex controls") { authority.revoke(conversationID: conversationID) }
            } else {
                ForEach(DesktopControlFamily.allCases) { family in
                    Toggle(family.title, isOn: Binding(get: { selected.contains(family) }, set: {
                        if $0 { selected.insert(family) } else { selected.remove(family) }
                    }))
                }
                Button("Grant selected Memex controls") {
                    authority.allow(conversationID: conversationID, sessionID: sessionID, families: selected)
                }.disabled(selected.isEmpty)
            }
        }.padding().frame(width: 430)
    }
}
