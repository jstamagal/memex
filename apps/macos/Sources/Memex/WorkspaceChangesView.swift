import AppKit
import SwiftUI

struct WorkspaceChangesView: View {
    let directory: URL
    var isWorking = false
    var close: (() -> Void)? = nil
    @State private var snapshot: WorkspaceChangesSnapshot?
    @State private var selectedPath: String?
    @State private var loading = true
    @State private var error: String?
    @State private var patch = ""
    @State private var loadingPatch = false
    @State private var refreshID = UUID()
    @State private var snapshotID = UUID()
    private let client = WorkspaceChangesClient()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Uncommitted changes").font(.headline)
                    Text(snapshot?.root.path ?? directory.path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(snapshot?.root.path ?? directory.path)
                }
                Spacer()
                if let close {
                    Button(action: close) { Image(systemName: "xmark") }
                        .help("Close workspace changes").accessibilityLabel("Close workspace changes")
                }
                Button { refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh workspace changes").accessibilityLabel("Refresh workspace changes")
                    .disabled(loading)
            }.padding(12)
            Divider()
            if loading {
                ProgressView("Reading workspace changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Could not read changes", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let snapshot {
                if snapshot.files.isEmpty {
                    ContentUnavailableView("No uncommitted changes", systemImage: "checkmark.circle",
                        description: Text("This Git working tree has no staged, unstaged, or untracked files."))
                } else {
                    HSplitView {
                        List(snapshot.files, selection: $selectedPath) { file in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.label).lineLimit(2).truncationMode(.middle)
                                Text(file.status).font(.caption).foregroundStyle(.secondary)
                            }.tag(file.id).help(file.label)
                        }.listStyle(.sidebar).frame(minWidth: 150, idealWidth: 230, maxWidth: 340)
                        Group {
                            if loadingPatch { ProgressView("Reading diff…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                            else if selectedPath != nil { WorkspaceDiffText(text: patch) }
                            else { Text("Select a file to see its changes.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        }.frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                ContentUnavailableView("Not a Git working tree", systemImage: "folder",
                    description: Text("The selected workspace is not inside a Git repository."))
            }
            Divider()
            Text("Current working tree · Staged, unstaged, and untracked files")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .task(id: directory.path + refreshID.uuidString + String(isWorking)) { await refresh() }
        .task(id: (selectedPath ?? "") + snapshotID.uuidString) { await loadPatch() }
    }

    @MainActor private func refresh() async {
        loading = true
        error = nil
        snapshot = nil
        do {
            let next = try await client.snapshot(directory: directory)
            guard !Task.isCancelled else { return }
            snapshot = next
            snapshotID = UUID()
            if !((next?.files.contains { $0.path == selectedPath }) ?? false) { selectedPath = next?.files.first?.path }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }

    @MainActor private func loadPatch() async {
        guard let snapshot, let file = snapshot.files.first(where: { $0.path == selectedPath }) else { return }
        loadingPatch = true
        patch = ""
        do {
            let next = try await client.diff(file: file, root: snapshot.root)
            guard !Task.isCancelled else { return }
            patch = next
        } catch {
            guard !Task.isCancelled else { return }
            patch = "Could not read this diff.\n\n" + error.localizedDescription
        }
        loadingPatch = false
    }
}

private struct WorkspaceDiffText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let view = RichContentView.textView()
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = view.maxSize
        view.textContainer?.heightTracksTextView = false
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.textStorage?.setAttributedString(CodeSyntax.render(text, language: "diff", font: .systemFont(ofSize: 13)))
        if let container = view.textContainer, let manager = view.layoutManager {
            manager.ensureLayout(for: container)
            let size = manager.usedRect(for: container).size
            view.setFrameSize(NSSize(width: max(scroll.contentSize.width, ceil(size.width) + 24),
                                     height: max(scroll.contentSize.height, ceil(size.height) + 24)))
        }
        scroll.contentView.scroll(to: .zero)
    }
}
