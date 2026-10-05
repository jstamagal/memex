import Foundation
import XCTest
@testable import MemexExecutionHostCore

#if canImport(SQACPHost)
import SQACPHost

/// These checks use the real archive and Rust runtime. The only executable in
/// PATH is a disposable sentinel, so a validation failure cannot launch a user agent.
final class NativeExecutionProviderTests: XCTestCase {
    private func fixture() throws -> (NativeExecutionProvider, URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memex-native-host-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let home = root.appendingPathComponent("provider-home")
        let workspace = root.appendingPathComponent("workspace")
        let binary = root.appendingPathComponent("bin")
        let runtime = root.appendingPathComponent("runtime")
        for directory in [home.appendingPathComponent("sessions"), workspace, binary, runtime] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sentinel = binary.appendingPathComponent("codex")
        try "#!/bin/sh\n/usr/bin/touch \"$CODEX_HOME/provider-was-launched\"\nexit 1\n".write(to: sentinel, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sentinel.path)
        let provider = try NativeExecutionProvider(directory: runtime, hostID: "fixture-host",
            environment: ["PATH": binary.path, "CODEX_HOME": home.path])
        return (provider, home, workspace, root)
    }

    private func transcript(home: URL, nativeID: String, cwd: URL) throws -> URL {
        let file = home.appendingPathComponent("sessions/rollout-" + UUID().uuidString + ".jsonl")
        let metadata: [String: Any] = ["type": "session_meta", "timestamp": "2026-10-05T12:00:00Z",
            "payload": ["id": nativeID, "cwd": cwd.path, "originator": "codex_cli_rs", "timestamp": "2026-10-05T12:00:00Z"]]
        var data = try JSONSerialization.data(withJSONObject: metadata)
        data.append(10)
        try data.write(to: file)
        return file
    }

    func testNativeImportConfirmsOriginalIdentityWithoutStartingProvider() throws {
        let (provider, home, workspace, _) = try fixture()
        let source = try transcript(home: home, nativeID: "native-original", cwd: workspace)
        let conversation = try provider.importConversation(id: "hosted-original", provider: "codex",
            nativeSessionID: "native-original", sourcePath: source.path, workspaceID: workspace.path,
            cwd: workspace.path, title: "Imported")
        XCTAssertEqual(conversation.nativeSessionID, "native-original")
        XCTAssertEqual(conversation.providerInstanceID, "codex:" + home.path)
        XCTAssertEqual(conversation.transcriptPath, source.path)
        XCTAssertEqual(conversation.cwd, workspace.path)
        XCTAssertFalse(provider.isConnected(conversation.id))
        let state = try provider.read(conversation)
        XCTAssertFalse(state["ready"].bool ?? true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("provider-was-launched").path))
    }

    func testNativeImportRejectsMismatchedSessionWorkspaceAndOutsideHome() throws {
        let (provider, home, workspace, root) = try fixture()
        let source = try transcript(home: home, nativeID: "native-original", cwd: workspace)
        XCTAssertThrowsError(try provider.importConversation(id: "wrong-session", provider: "codex",
            nativeSessionID: "wrong-native", sourcePath: source.path, workspaceID: workspace.path,
            cwd: workspace.path, title: "Wrong session")) { error in
            guard case AgentConversationServiceError.runtime(let message) = error else {
                return XCTFail("Expected native parser identity rejection, got \(String(reflecting: error))")
            }
            XCTAssertEqual(message, "invalid conversation request: Codex session metadata identity mismatch")
        }
        XCTAssertThrowsError(try provider.importConversation(id: "wrong-workspace", provider: "codex",
            nativeSessionID: "native-original", sourcePath: source.path, workspaceID: root.path,
            cwd: root.path, title: "Wrong workspace")) { error in
            XCTAssertEqual((error as? HostFailure)?.code, "identity_conflict")
        }
        let outside = root.appendingPathComponent("outside.jsonl")
        try FileManager.default.copyItem(at: source, to: outside)
        XCTAssertThrowsError(try provider.importConversation(id: "outside", provider: "codex",
            nativeSessionID: "native-original", sourcePath: outside.path, workspaceID: workspace.path,
            cwd: workspace.path, title: "Outside provider home")) { error in
            XCTAssertEqual((error as? HostFailure)?.code, "source_denied")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("provider-was-launched").path))
    }

    func testResumeRejectsChangedProviderHomeBeforeLaunchingProcess() throws {
        let (provider, home, workspace, _) = try fixture()
        let source = try transcript(home: home, nativeID: "native-original", cwd: workspace)
        var conversation = try provider.importConversation(id: "original", provider: "codex",
            nativeSessionID: "native-original", sourcePath: source.path, workspaceID: workspace.path,
            cwd: workspace.path, title: "Imported")
        conversation.providerInstanceID = "codex:/different-provider-home"
        XCTAssertThrowsError(try provider.resume(conversation)) { error in
            XCTAssertEqual((error as? HostFailure)?.code, "provider_identity")
        }
        XCTAssertFalse(provider.isConnected(conversation.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("provider-was-launched").path))
    }
}
#endif
