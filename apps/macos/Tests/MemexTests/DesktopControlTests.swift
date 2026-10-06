import Foundation
import MemexExecutionHostCore
import Testing
@testable import Memex

@Suite @MainActor struct DesktopControlTests {
    private func session(_ id: String) -> Session {
        Session(source: "codex", sessionID: id, sourcePath: "/provider/\(id).jsonl", project: "project", label: id)
    }
    private func request(_ family: String, action: String, grant: DesktopControlAuthority.Grant? = nil,
                         caller: String = "execution-one", fields: [String: HostValue] = [:]) -> HostRequest {
        var payload = fields
        payload["action"] = .string(action)
        if let grant { payload["grantId"] = .string(grant.id.uuidString) }
        return HostRequest(method: "desktop.\(family)", params: ["conversationId": .string(caller), "request": .object(payload)])
    }

    @Test func nativeGrantIsRequiredCannotBeSelfIssuedAndRevocationTakesEffect() async throws {
        let suite = "DesktopControlTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let authority = DesktopControlAuthority(preferences: AppPreferences(defaults: defaults))
        let store = Store(desktopControls: authority)
        let row = session("one")
        store.sessions = [row]
        let schema = try await store.handleDesktopControl(request("organization", action: "describe"))
        #expect(schema["grant"] == .null)
        #expect(schema["schema"]["actions"].array.contains(.string("markRead")))
        await #expect(throws: HostFailure.self) {
            try await store.handleDesktopControl(request("organization", action: "list"))
        }
        await #expect(throws: HostFailure.self) {
            try await store.handleDesktopControl(request("organization", action: "allow"))
        }
        #expect(authority.grants.isEmpty)
        authority.allow(conversationID: "execution-one", sessionID: row.id, families: [.organization])
        let grant = try #require(authority.grants["execution-one"])
        let list = try await store.handleDesktopControl(request("organization", action: "list", grant: grant))
        #expect(list["sessions"].array.first?["id"].string == row.id)
        await #expect(throws: HostFailure.self) {
            try await store.handleDesktopControl(request("organization", action: "list", grant: grant, caller: "execution-two"))
        }
        await #expect(throws: HostFailure.self) {
            try await store.handleDesktopControl(request("preferences", action: "get", grant: grant))
        }
        authority.revoke(conversationID: "execution-one")
        await #expect(throws: HostFailure.self) {
            try await store.handleDesktopControl(request("organization", action: "markRead", grant: grant,
                fields: ["sessionIds": .array([.string(row.id)]), "read": .bool(false)]))
        }
        #expect(!store.conversationLibrary.isUnread(row))
        authority.allow(conversationID: "execution-one", sessionID: row.id, families: [.organization])
        await #expect(throws: HostFailure.self) {
            try await store.handleDesktopControl(request("organization", action: "list", grant: grant))
        }
    }

    @Test func grantedOperationsUseRealOrganizationAndPreferenceModels() async throws {
        let suite = "DesktopControlTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let authority = DesktopControlAuthority(preferences: preferences)
        let library = ConversationLibrary()
        let store = Store(conversationLibrary: library, desktopControls: authority)
        let row = session("one")
        store.sessions = [row]
        authority.allow(conversationID: "execution-one", sessionID: row.id, families: [.organization, .preferences])
        let grant = try #require(authority.grants["execution-one"])
        let created = try await store.handleDesktopControl(request("organization", action: "createSection", grant: grant,
                                                                  fields: ["name": .string("Research")]))
        let sectionID = try #require(created["sections"].array.first?["id"].string)
        _ = try await store.handleDesktopControl(request("organization", action: "move", grant: grant,
            fields: ["sessionIds": .array([.string(row.id)]), "sectionId": .string(sectionID)]))
        _ = try await store.handleDesktopControl(request("organization", action: "pin", grant: grant,
            fields: ["sessionIds": .array([.string(row.id)]), "value": .bool(true)]))
        _ = try await store.handleDesktopControl(request("organization", action: "markRead", grant: grant,
            fields: ["sessionIds": .array([.string(row.id)]), "read": .bool(false)]))
        #expect(library.sectionID(for: row) == sectionID)
        #expect(library.isPinned(row) && library.isUnread(row))
        _ = try await store.handleDesktopControl(request("organization", action: "deleteSection", grant: grant,
                                                          fields: ["sectionId": .string(sectionID)]))
        #expect(library.sectionID(for: row) == nil)
        #expect(library.isPinned(row) && library.isUnread(row))
        #expect(store.sessions == [row])
        _ = try await store.handleDesktopControl(request("preferences", action: "set", grant: grant,
                                                          fields: ["key": .string("codeSize"), "value": .number(18)]))
        #expect(preferences.codeNSFont.pointSize == 18)
        #expect(AppPreferences(defaults: defaults).codeSize == 18)
        await #expect(throws: HostFailure.self) {
            try await store.handleDesktopControl(request("preferences", action: "set", grant: grant,
                fields: ["key": .string("codeSize"), "value": .number(1000)]))
        }
        let conflicting = try HostValue.encoded(AppPreferences.Binding(key: "f"))
        await #expect(throws: HostFailure.self) {
            try await store.handleDesktopControl(request("preferences", action: "setShortcut", grant: grant,
                fields: ["command": .string("refresh"), "binding": conflicting]))
        }
        #expect(preferences.binding(for: .refresh)?.key == "r")
    }

    @Test func panelControlIsBoundToTheGrantedNativeConversation() async throws {
        let suite = "DesktopControlTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let authority = DesktopControlAuthority(preferences: AppPreferences(defaults: defaults))
        let store = Store(desktopControls: authority)
        let first = session("one"), second = session("two")
        store.sessions = [first, second]
        store.scope = .all
        store.selectedID = first.id
        authority.allow(conversationID: "execution-one", sessionID: first.id, families: [.panel])
        let grant = try #require(authority.grants["execution-one"])
        let opened = try await store.handleDesktopControl(request("panel", action: "open", grant: grant,
                                                                 fields: ["panel": .string("browser")]))
        #expect(opened["sessionId"].string == first.id)
        #expect(store.workspacePanel == .browser && store.showingWorkspaceChanges)
        store.selectedID = second.id
        await #expect(throws: HostFailure.self) {
            try await store.handleDesktopControl(request("panel", action: "close", grant: grant))
        }
        #expect(store.showingWorkspaceChanges)
        store.selectedID = first.id
        _ = try await store.handleDesktopControl(request("panel", action: "close", grant: grant))
        #expect(!store.showingWorkspaceChanges)
    }
}
