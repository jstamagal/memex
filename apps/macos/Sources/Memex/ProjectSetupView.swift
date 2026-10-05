import AppKit
import SwiftUI

struct ProjectSetupView: View {
    @Bindable var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var name = ""
    @State private var directory: URL?
    @State private var mode = ConversationWorkspaceMode.existingDirectory
    @State private var baseRef: String?
    @State private var repository: ConversationWorkspaceRepository?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Projects").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Save local folders for new conversations. Each chat can use the existing folder or its own Git worktree.")
                .font(.callout).foregroundStyle(.secondary)
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    List(selection: $selectedID) {
                        ForEach(store.localProjects.projects) { project in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name).font(.headline)
                                Text(project.directoryPath).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2).truncationMode(.middle)
                            }.tag(project.id)
                        }
                    }.frame(minWidth: 180, idealWidth: 230)
                    Button("Add folder…", systemImage: "plus") { Task { await chooseFolder(adding: true) } }
                }
                VStack(alignment: .leading, spacing: 12) {
                    if let directory {
                        TextField("Project name", text: $name)
                        HStack {
                            Text(directory.path).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button("Change…") { Task { await chooseFolder(adding: false) } }
                        }
                        Picker("New chats use", selection: $mode) {
                            Text("Existing folder").tag(ConversationWorkspaceMode.existingDirectory)
                            Text("New worktree").tag(ConversationWorkspaceMode.newWorktree).disabled(repository == nil)
                        }.pickerStyle(.menu)
                        if mode == .newWorktree {
                            Picker("Base branch", selection: $baseRef) {
                                Text("Choose a branch").tag(String?.none)
                                ForEach(baseRefs, id: \.self) { ref in Text(ref).tag(Optional(ref)) }
                            }.pickerStyle(.menu)
                            Text("Starts from the selected Git ref. Your original checkout stays in place.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if repository == nil {
                            Text("This folder does not have a Git worktree available.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack {
                            if selectedID != nil {
                                Button("Remove from list") { remove() }
                                    .help("Removes the saved project entry. Files, chats and worktrees stay in place.")
                            }
                            Spacer()
                            Button("Save project") { save() }
                                .buttonStyle(.borderedProminent)
                                .disabled(name.nilIfBlank == nil || (mode == .newWorktree && (repository == nil || baseRef == nil)))
                        }
                    } else {
                        ContentUnavailableView("Add a project", systemImage: "folder.badge.plus",
                            description: Text("Choose an existing folder, or create one in the folder picker."))
                    }
                }
                .padding(.leading, 12).frame(minWidth: 320, maxWidth: .infinity)
            }.frame(height: 280).disabled(store.startingConversation)
            if let error = error ?? store.localProjects.error {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .padding(24).frame(width: 680)
        .onAppear { selectedID = store.newConversationProject?.id ?? store.localProjects.projects.first?.id; loadSelection() }
        .onChange(of: selectedID) { _, _ in loadSelection() }
        .task(id: directory?.path) { await inspectDirectory() }
    }

    private var baseRefs: [String] {
        Array(Set((repository?.localBranches ?? []) + [repository?.defaultBaseRef, baseRef].compactMap { $0 })).sorted()
    }

    private func loadSelection() {
        guard let project = store.localProjects.projects.first(where: { $0.id == selectedID }) else { return }
        name = project.name
        directory = project.directory
        mode = project.defaultWorkspace
        baseRef = project.defaultBaseRef
        error = nil
    }

    @MainActor private func chooseFolder(adding: Bool) async {
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        guard await panel.begin() == .OK, let url = panel.url else { return }
        if adding {
            selectedID = nil
            name = url.lastPathComponent
            mode = .existingDirectory
            baseRef = nil
        }
        directory = url
        error = nil
    }

    @MainActor private func inspectDirectory() async {
        repository = nil
        guard let directory else { return }
        do {
            let repository = try await store.workspaceClient.inspect(directory: directory)
            guard !Task.isCancelled, self.directory == directory else { return }
            self.repository = repository
            if baseRef == nil { baseRef = repository?.defaultBaseRef }
        } catch is CancellationError {} catch {
            if self.directory == directory { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard let directory else { return }
        do {
            let project: LocalProject
            if let selectedID {
                project = LocalProject(id: selectedID, name: name, directoryPath: directory.path,
                                       defaultWorkspace: mode, defaultBaseRef: baseRef)
                try store.localProjects.update(project)
            } else {
                project = try store.localProjects.save(name: name, directory: directory, defaultWorkspace: mode, defaultBaseRef: baseRef)
            }
            store.newConversationDraft.selectProject(project, resetWorkspace: true)
            selectedID = project.id
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func remove() {
        guard let selectedID else { return }
        do {
            try store.localProjects.remove(id: selectedID)
            if store.newConversationDraft.value.projectID == selectedID,
               store.newConversationDraft.value.createdSessionID == nil {
                store.newConversationDraft.value.projectID = nil
                store.newConversationDraft.value.preparedWorkspace = nil
            }
            self.selectedID = nil
            directory = nil
            name = ""
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
