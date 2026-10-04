import AppKit
import SwiftUI

struct NewConversationView: View {
    @Bindable var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var provider = "codex"
    @State private var directory: URL?
    @State private var creating = false
    @State private var error: String?

    private var recentDirectories: [URL] {
        var seen = Set<String>()
        return (store.createdConversations.sessions + store.sessions + store.catalog).compactMap { session in
            guard session.machineID == "local", let cwd = session.cwd, cwd.hasPrefix("/"), seen.insert(cwd).inserted else { return nil }
            return URL(fileURLWithPath: cwd, isDirectory: true)
        }.prefix(12).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New conversation").font(.title2.weight(.semibold))
            Picker("Provider", selection: $provider) {
                Text("Codex").tag("codex")
                Text("Claude").tag("claude")
            }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 8) {
                Text("Local project").font(.headline)
                HStack {
                    if let directory {
                        Label(directory.lastPathComponent, systemImage: "folder")
                        Spacer()
                        Button("Choose folder…", action: chooseDirectory)
                    } else {
                        Text("Choose the folder this conversation will work in.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose folder…", action: chooseDirectory)
                    }
                }
                if let directory {
                    Text(directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(3).accessibilityLabel("Project path: \(directory.path)")
                }
                if !recentDirectories.isEmpty {
                    Menu("Recent projects") {
                        ForEach(recentDirectories, id: \.path) { url in
                            Button(url.path) { directory = url }
                        }
                    }.fixedSize()
                }
            }
            Text("Uses your local \(provider == "codex" ? "Codex" : "Claude Code") installation and its configured defaults.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if creating { ProgressView().controlSize(.small); Text("Creating conversation…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                Button("Create conversation") { Task { await create() } }
                    .keyboardShortcut(.defaultAction).disabled(directory == nil || creating)
            }
        }
        .padding(24).frame(width: 520)
        .disabled(creating)
        .interactiveDismissDisabled(creating)
        .onAppear { directory = store.selectedWorkspace ?? recentDirectories.first }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK { directory = panel.url }
            }
        } else if panel.runModal() == .OK { directory = panel.url }
    }

    @MainActor private func create() async {
        guard let directory, !creating else { return }
        creating = true
        error = nil
        defer { creating = false }
        do {
            try await store.createConversation(NewConversationRequest(provider: provider, workingDirectory: directory))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
