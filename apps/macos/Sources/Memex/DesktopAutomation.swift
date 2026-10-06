import AppKit
import ApplicationServices
import Combine
import Foundation
import SwiftUI

enum DesktopAutomationCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case snapshot, press, setValue
}

struct DesktopAutomationGrant: Codable, Sendable {
    let id: UUID
    let conversationID: String
    let bundleID: String
    let processID: Int32
    let capabilities: Set<DesktopAutomationCapability>
}

struct DesktopAutomationRequest: Codable, Sendable {
    let conversationID: String
    let grantID: UUID
    let action: DesktopAutomationCapability
    var elementID: UUID?
    var text: String?
}

struct DesktopAutomationSnapshot: Codable, Sendable {
    struct Element: Codable, Sendable {
        let id: UUID
        let parentID: UUID?
        let role: String
        let label: String
        let value: String?
        let actions: [String]
    }
    let grant: DesktopAutomationGrant
    let elements: [Element]
    let truncated: Bool
}

/// Session-only authority for one exact running process, never an app-name or
/// bundle wildcard. macOS Accessibility consent is an independent prerequisite.
@MainActor final class DesktopAutomationHost: ObservableObject {
    @Published private(set) var grants: [String: DesktopAutomationGrant] = [:]
    private var applications: [UUID: NSRunningApplication] = [:]
    private var elements: [UUID: [UUID: AXUIElement]] = [:]

    var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    func requestAccessibilityPermission() {
        // This SDK imports the exported CFString as a mutable, non-Sendable
        // global. Its stable value avoids reading shared mutable imported state.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func allow(conversationID: String, application: NSRunningApplication,
               capabilities: Set<DesktopAutomationCapability>) throws {
        guard accessibilityTrusted else { throw failure("Enable Memex in macOS Privacy & Security > Accessibility, then grant access again.") }
        guard !application.isTerminated, application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = application.bundleIdentifier, !capabilities.isEmpty else { throw failure("Select another running application and at least one capability.") }
        revoke(conversationID: conversationID)
        let grant = DesktopAutomationGrant(id: UUID(), conversationID: conversationID, bundleID: bundleID,
                                          processID: application.processIdentifier, capabilities: capabilities)
        applications[grant.id] = application
        grants[conversationID] = grant
    }

    func revoke(conversationID: String) {
        guard let grant = grants.removeValue(forKey: conversationID) else { return }
        applications.removeValue(forKey: grant.id)
        elements.removeValue(forKey: grant.id)
    }

    func descriptor(conversationID: String) throws -> DesktopAutomationGrant {
        guard let grant = grants[conversationID] else { throw failure("Explicitly grant this conversation access to an exact running app in Memex first.") }
        try validate(grant)
        return grant
    }

    func dispatch(_ request: DesktopAutomationRequest) throws -> DesktopAutomationSnapshot {
        let grant = try descriptor(conversationID: request.conversationID)
        guard grant.id == request.grantID, grant.capabilities.contains(request.action) else { throw failure("This app action is not granted.") }
        if request.action != .snapshot {
            guard let id = request.elementID, let element = elements[grant.id]?[id] else { throw failure("Read a fresh snapshot and use its exact element ID.") }
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == grant.processID else { throw failure("Element no longer belongs to the granted app.") }
            let status: AXError
            switch request.action {
            case .press:
                status = AXUIElementPerformAction(element, kAXPressAction as CFString)
            case .setValue:
                guard attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
                      let text = request.text, text.utf8.count <= 65536 else { throw failure("Provide at most 64 KiB for a non-secure editable element.") }
                status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
            case .snapshot: status = .success
            }
            guard status == .success else { throw failure("The target app rejected this Accessibility action (\(status.rawValue)). Inspect before retrying.") }
        }
        try validate(grant)
        // Reading is separately granted: interaction-only callers receive no UI data.
        guard grant.capabilities.contains(.snapshot) else { return .init(grant: grant, elements: [], truncated: false) }
        return snapshot(grant)
    }

    private func validate(_ grant: DesktopAutomationGrant) throws {
        guard accessibilityTrusted, let app = applications[grant.id], !app.isTerminated,
              app.processIdentifier == grant.processID, app.bundleIdentifier == grant.bundleID else {
            revoke(conversationID: grant.conversationID)
            throw failure("App access expired or macOS Accessibility access was revoked. Grant access again.")
        }
    }

    private func snapshot(_ grant: DesktopAutomationGrant) -> DesktopAutomationSnapshot {
        let root = AXUIElementCreateApplication(grant.processID)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var pending: [(AXUIElement, UUID?, Int)] = [(root, nil, 0)]
        var result: [DesktopAutomationSnapshot.Element] = []
        var handles: [UUID: AXUIElement] = [:]
        let deadline = Date().addingTimeInterval(2)
        var truncated = false
        while !pending.isEmpty, result.count < 200, Date() < deadline {
            let (element, parent, depth) = pending.removeFirst()
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == grant.processID else { continue }
            AXUIElementSetMessagingTimeout(element, 0.2)
            let id = UUID()
            handles[id] = element
            let secure = attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
            var rawActions: CFArray?
            AXUIElementCopyActionNames(element, &rawActions)
            result.append(.init(id: id, parentID: parent,
                role: attribute(element, kAXRoleAttribute) as? String ?? "unknown",
                label: String((attribute(element, kAXTitleAttribute) as? String ?? attribute(element, kAXDescriptionAttribute) as? String ?? "").prefix(4096)),
                value: secure ? nil : (attribute(element, kAXValueAttribute) as? String).map { String($0.prefix(4096)) },
                actions: rawActions as? [String] ?? []))
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            if depth < 12 {
                let capacity = max(0, 200 - result.count - pending.count)
                truncated = truncated || children.count > capacity
                pending.append(contentsOf: children.prefix(capacity).map { ($0, id, depth + 1) })
            } else if !children.isEmpty { truncated = true }
        }
        elements[grant.id] = handles
        return .init(grant: grant, elements: result, truncated: truncated || !pending.isEmpty)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func failure(_ message: String) -> WorkspaceBrowserAutomationError { .init(message: message) }
}

struct DesktopAutomationPermissionView: View {
    let conversationID: String
    @ObservedObject var host: DesktopAutomationHost
    @State private var apps: [NSRunningApplication] = []
    @State private var selectedPID: Int32 = 0
    @State private var interaction = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App access").font(.headline)
            Text("Grant this chat access to one running app. This includes that app’s windows and signed-in content. Grants expire when revoked, the target quits, or Memex quits.").font(.caption)
            if let grant = host.grants[conversationID] {
                Text("Allowed: \(grant.bundleID) (process \(grant.processID))").font(.caption)
                Button("Revoke app access") { host.revoke(conversationID: conversationID) }
            } else {
                Picker("Running app", selection: $selectedPID) {
                    Text("Choose an app").tag(Int32(0))
                    ForEach(apps, id: \.processIdentifier) { app in
                        Text("\(app.localizedName ?? "App") — \(app.bundleIdentifier ?? "") (\(app.processIdentifier))").tag(app.processIdentifier)
                    }
                }
                Toggle("Allow pressing controls and editing values", isOn: $interaction)
                Button("Grant selected app access") {
                    guard let app = apps.first(where: { $0.processIdentifier == selectedPID }) else { return }
                    do { try host.allow(conversationID: conversationID, application: app, capabilities: interaction ? [.snapshot, .press, .setValue] : [.snapshot]); error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(selectedPID == 0)
                Button("Enable macOS Accessibility permission") { host.requestAccessibilityPermission() }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }.padding().frame(width: 420)
        .onAppear {
            apps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        }
    }
}
