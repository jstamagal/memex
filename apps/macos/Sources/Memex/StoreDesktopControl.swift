import Foundation
import MemexExecutionHostCore

extension Store {
    /// Called only by the desktop bridge after execution-host conversation
    /// authorization. This second boundary requires native, revocable app consent.
    func handleDesktopControl(_ request: HostRequest) async throws -> HostValue {
        guard let conversationID = request.params["conversationId"]?.string, !conversationID.isEmpty,
              let suffix = request.method.split(separator: ".").last,
              request.method == "desktop.\(suffix)",
              let family = DesktopControlFamily(rawValue: String(suffix)) else {
            throw HostFailure("invalid_params", "Expected desktop.panel, desktop.preferences or desktop.organization with an exact conversationId")
        }
        let payload = request.params["request"]?.object ?? request.params
        let action = payload["action"]?.string ?? "describe"
        if action == "describe" {
            return .object([
                "method": .string(request.method),
                "conversationId": .string(conversationID),
                "grant": try desktopControls.grants[conversationID].map { try HostValue.encoded($0) } ?? .null,
                "schema": desktopControlSchema(family),
                "permission": .string("Grant operation families through native workspace controls. Pass the returned grant.id as grantId. Grants cannot be created by API and expire on revocation or app exit.")
            ])
        }
        let grant = try desktopControls.authorize(conversationID: conversationID,
                                                  grantID: payload["grantId"]?.string,
                                                  family: family)
        switch family {
        case .panel: return try controlPanel(action: action, payload: payload, grant: grant)
        case .preferences: return try controlPreferences(action: action, payload: payload)
        case .organization: return try controlOrganization(action: action, payload: payload)
        }
    }

    private func desktopControlSchema(_ family: DesktopControlFamily) -> HostValue {
        switch family {
        case .panel:
            return .object([
                "actions": .array(["get", "open", "close"].map(HostValue.string)),
                "panel": .array(WorkspacePanel.allCases.map { .string($0.rawValue) }),
                "scope": .string("The grant's exact native session must be selected. open requires panel; close closes workspace inspector and terminal drawer.")
            ])
        case .preferences:
            return .object([
                "actions": .array(["get", "set", "setShortcut", "resetShortcuts", "resetAppearance"].map(HostValue.string)),
                "set": .object([
                    "appearance": .string("system | light | dark"), "fontDesign": .string("system | serif | rounded | monospaced"),
                    "interfaceSize": .string("number 10...24"), "codeSize": .string("number 10...24"),
                    "reduceMotion": .string("boolean"), "increasedContrast": .string("boolean")
                ]),
                "setFormat": .string("key and value; changes one named preference"),
                "setShortcut": .string("command and binding (null to remove, or {key: lowercase letter/number, command: bool, shift: bool, option: bool, control: bool}); conflicts are rejected"),
                "commands": .array(AppPreferences.Command.allCases.map { .string($0.rawValue) })
            ])
        case .organization:
            return .object([
                "actions": .array(["list", "rename", "pin", "archive", "restore", "remove", "markRead", "move", "createSection", "renameSection", "deleteSection", "moveSection"].map(HostValue.string)),
                "chatActions": .string("sessionIds: exact IDs returned by list; rename requires one ID and title; pin/ archive require value: boolean; markRead requires read: boolean; move requires sectionId: exact ID or null"),
                "sectionActions": .string("createSection: name; renameSection: sectionId and name; deleteSection: sectionId; moveSection: sectionId and offset (-1 or 1)"),
                "scope": .string("Memex presentation metadata only. remove is reversible local removal; restore clears archive/removal. No provider history deletion or messaging.")
            ])
        }
    }

    private func controlPanel(action: String, payload: [String: HostValue], grant: DesktopControlAuthority.Grant) throws -> HostValue {
        guard selectedID == grant.sessionID, selected != nil, scope != .home else {
            throw HostFailure("desktop_control_scope", "Select the granted conversation in Memex before controlling its panels")
        }
        switch action {
        case "get": break
        case "open":
            guard let raw = payload["panel"]?.string, let panel = WorkspacePanel(rawValue: raw) else {
                throw HostFailure("invalid_params", "Use a panel ID returned by describe")
            }
            guard panel == .browser || hasSelectedWorkspace else {
                throw HostFailure("capability_unavailable", "This conversation has no accessible workspace")
            }
            selectWorkspacePanel(panel)
            showingWorkspaceChanges = true
        case "close":
            showingWorkspaceChanges = false
            showingTerminalDrawer = false
        default: throw HostFailure("invalid_params", "Unknown panel action")
        }
        return .object(["sessionId": .string(grant.sessionID), "panel": .string(workspacePanel.rawValue),
                        "visible": .bool(showingWorkspaceChanges), "terminalDrawerVisible": .bool(showingTerminalDrawer)])
    }

    private func controlPreferences(action: String, payload: [String: HostValue]) throws -> HostValue {
        let preferences = desktopControls.preferences
        switch action {
        case "get": break
        case "set":
            let key = try controlString(payload, "key")
            let value = payload["value"] ?? .null
            switch key {
            case "appearance":
                guard let raw = value.string, let mode = AppPreferences.Appearance(rawValue: raw) else { throw invalidControlValue(key) }
                preferences.appearance = mode
            case "fontDesign":
                guard let raw = value.string, let font = AppPreferences.FontDesign(rawValue: raw) else { throw invalidControlValue(key) }
                preferences.fontDesign = font
            case "interfaceSize", "codeSize":
                guard let size = value.number, size.isFinite, (10...24).contains(size) else { throw invalidControlValue(key) }
                if key == "interfaceSize" { preferences.interfaceSize = size } else { preferences.codeSize = size }
            case "reduceMotion", "increasedContrast":
                guard let enabled = value.bool else { throw invalidControlValue(key) }
                if key == "reduceMotion" { preferences.reduceMotion = enabled } else { preferences.increasedContrast = enabled }
            default: throw invalidControlValue(key)
            }
        case "setShortcut":
            guard let command = AppPreferences.Command(rawValue: try controlString(payload, "command")),
                  let value = payload["binding"] else { throw invalidControlValue("command/binding") }
            let binding: AppPreferences.Binding?
            if value == .null { binding = nil }
            else { binding = try JSONDecoder().decode(AppPreferences.Binding.self, from: JSONEncoder().encode(value)) }
            if let error = preferences.setBinding(binding, for: command) { throw HostFailure("shortcut_conflict", error) }
        case "resetShortcuts": preferences.resetShortcuts()
        case "resetAppearance": preferences.resetAppearance()
        default: throw HostFailure("invalid_params", "Unknown preferences action")
        }
        var shortcuts: [String: HostValue] = [:]
        for command in AppPreferences.Command.allCases {
            shortcuts[command.rawValue] = try preferences.binding(for: command).map { try HostValue.encoded($0) } ?? .null
        }
        return .object(["appearance": .string(preferences.appearance.rawValue),
                        "fontDesign": .string(preferences.fontDesign.rawValue),
                        "interfaceSize": .number(preferences.interfaceSize), "codeSize": .number(preferences.codeSize),
                        "reduceMotion": .bool(preferences.reduceMotion), "increasedContrast": .bool(preferences.increasedContrast),
                        "shortcuts": .object(shortcuts)])
    }

    private var controlLibrarySessions: [Session] {
        var rows: [String: Session] = [:]
        for entry in conversationLibrary.entries.values { rows[entry.session.id] = entry.session }
        for session in createdConversations.sessions + catalog + sessions { rows[session.id] = nativeLibrarySession(session) }
        return rows.values.sorted { $0.id < $1.id }
    }

    private func controlOrganization(action: String, payload: [String: HostValue]) throws -> HostValue {
        let library = conversationLibrary
        var succeeded = true
        switch action {
        case "list": break
        case "createSection": succeeded = library.createSection(named: try controlString(payload, "name"))
        case "renameSection", "deleteSection", "moveSection":
            let id = try controlString(payload, "sectionId")
            guard library.sections.contains(where: { $0.id == id }) else { throw invalidControlValue("sectionId") }
            if action == "renameSection" { succeeded = library.renameSection(id, to: try controlString(payload, "name")) }
            else if action == "deleteSection" { succeeded = library.deleteSection(id) }
            else {
                guard let offset = payload["offset"]?.number, offset == -1 || offset == 1 else { throw invalidControlValue("offset") }
                succeeded = library.moveSection(id, by: Int(offset))
            }
        case "rename", "pin", "archive", "restore", "remove", "markRead", "move":
            guard let rawIDs = payload["sessionIds"], case .array(let values) = rawIDs, !values.isEmpty, values.count <= 200 else {
                throw invalidControlValue("sessionIds")
            }
            let rows = controlLibrarySessions
            let selected = try values.map { value -> Session in
                guard let id = value.string, let row = rows.first(where: { $0.id == id }) else { throw invalidControlValue("sessionIds") }
                return row
            }
            switch action {
            case "rename":
                guard selected.count == 1 else { throw invalidControlValue("sessionIds") }
                // Empty title intentionally restores the provider's original title.
                guard let title = payload["title"]?.string else { throw invalidControlValue("title") }
                succeeded = library.rename(selected[0], to: title)
            case "pin", "archive":
                guard let value = payload["value"]?.bool else { throw invalidControlValue("value") }
                succeeded = action == "pin" ? library.pin(selected, pinned: value) : library.archive(selected, archived: value)
            case "restore": succeeded = library.restore(selected)
            case "remove": succeeded = library.remove(selected)
            case "markRead":
                guard let read = payload["read"]?.bool else { throw invalidControlValue("read") }
                succeeded = library.markRead(selected, read: read)
            case "move":
                guard let value = payload["sectionId"], value == .null || library.sections.contains(where: { $0.id == value.string }) else {
                    throw invalidControlValue("sectionId")
                }
                succeeded = library.move(selected, toSection: value.string)
            default: break
            }
        default: throw HostFailure("invalid_params", "Unknown organization action")
        }
        guard succeeded else { throw HostFailure("organization_not_saved", library.error ?? "Organization metadata was not changed") }
        if action != "list" { finishLibraryAction(true) }
        return .object([
            "sections": try .encoded(library.sections),
            "sessions": .array(controlLibrarySessions.map { session in
                .object(["id": .string(session.id), "title": .string(library.title(for: session)),
                         "provider": .string(session.source), "machineId": .string(session.machineID),
                         "sectionId": library.sectionID(for: session).map(HostValue.string) ?? .null,
                         "pinned": .bool(library.isPinned(session)), "read": .bool(!library.isUnread(session)),
                         "archived": .bool(library.entries[session.id]?.archived == true),
                         "removed": .bool(library.entries[session.id]?.removed == true)])
            })
        ])
    }

    private func controlString(_ payload: [String: HostValue], _ key: String) throws -> String {
        guard let value = payload[key]?.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalidControlValue(key) }
        return value
    }
    private func invalidControlValue(_ key: String) -> HostFailure {
        HostFailure("invalid_params", "Invalid \(key); inspect this operation's describe schema")
    }
}
