import AppKit
import Testing
@testable import Memex

@MainActor @Suite struct DesktopAutomationTests {
    @Test func ungrantedChatsCannotDiscoverOrControlApps() {
        let host = DesktopAutomationHost()
        #expect(throws: (any Error).self) { try host.descriptor(conversationID: "ungranted") }
        #expect(throws: (any Error).self) {
            try host.dispatch(.init(conversationID: "ungranted", grantID: UUID(), action: .snapshot))
        }
        #expect(host.grants.isEmpty)
    }

    @Test func cannotGrantTheMemexProcessOrPersistAuthority() {
        let host = DesktopAutomationHost()
        #expect(throws: (any Error).self) {
            try host.allow(conversationID: "chat", application: .current, capabilities: [.snapshot])
        }
        #expect(host.grants.isEmpty)
        #expect(DesktopAutomationHost().grants.isEmpty)
    }
}
