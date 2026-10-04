import Foundation
import Testing
@testable import Memex

@Test func conversationRecoveryDistinguishesAuthenticationArchiveAndUncertainDelivery() {
    let session = Session(source: "codex", sessionID: "native", sourcePath: "/provider/sessions/native.jsonl",
                          project: "test", cwd: "/workspace", machine: "local")
    #expect(ConversationRecoveryKind.resolve(session: session, error: "OAuth token expired", deliveryUncertain: true) == .signIn)
    #expect(ConversationRecoveryKind.resolve(session: session, error: "Acknowledgement lost", deliveryUncertain: true) == .uncertain)
    #expect(ConversationRecoveryKind.resolve(session: session, error: "Process exited", deliveryUncertain: false) == .reconnect)
    let archived = Session(source: "codex", sessionID: "native", sourcePath: "/provider/archived_sessions/native.jsonl",
                           project: "test", cwd: "/workspace", machine: "local")
    #expect(InAppResumeTarget.unavailableReason(for: archived)?.contains("Unarchive") == true)
    #expect(ConversationRecoveryKind.resolve(session: archived, error: nil, deliveryUncertain: false) == .archived)
}

@MainActor @Test func signInUsesTheOriginalProviderInstallation() {
    for provider in ["codex", "claude"] {
        let session = Session(source: provider, sessionID: "native", sourcePath: "/provider/sessions/native.jsonl", project: "test")
        let target = InAppResumeTarget(session: session, sourceURL: URL(fileURLWithPath: session.sourcePath),
            workingDirectory: URL(fileURLWithPath: "/workspace"), providerHome: URL(fileURLWithPath: "/custom provider's home"),
            executableURL: URL(fileURLWithPath: "/custom bin/\(provider)"), helperURL: nil, storageURL: URL(fileURLWithPath: "/runtime"))
        let command = ConversationRecoveryView.signInCommand(target)
        let variable = provider == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
        let arguments = provider == "codex" ? "login" : "auth login"
        #expect(command == "\(variable)='/custom provider'\\''s home' '/custom bin/\(provider)' \(arguments)")
    }
}
