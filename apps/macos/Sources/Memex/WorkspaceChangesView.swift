import AppKit
import SwiftUI

struct WorkspaceChangesView: View {
    let directory: URL
    var isWorking = false
    var initialSelectedPath: String? = nil
    var reviewRequest: UUID? = nil
    var close: (() -> Void)? = nil
    @State private var state = WorkspaceChangesState()
    @State private var refreshID = UUID()
    private let client = WorkspaceChangesClient()

    private var displayedRoot: String {
        (state.directory == directory ? state.snapshot?.root.path : nil) ?? directory.path
    }

    private struct PatchTask: Equatable {
        let directory: URL
        let path: String?
        let revision: UUID
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Uncommitted changes").font(.headline)
                    Text(displayedRoot)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(displayedRoot)
                }
                Spacer()
                if state.loading { ProgressView().controlSize(.small).help("Refreshing workspace changes") }
                if let close {
                    Button(action: close) { Image(systemName: "xmark") }
                        .help("Close workspace changes").accessibilityLabel("Close workspace changes")
                }
                Button { refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh workspace changes").accessibilityLabel("Refresh workspace changes")
                    .disabled(state.loading)
            }.padding(12)
            Divider()
            if state.directory != directory {
                ProgressView("Reading workspace changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let error = state.error {
                    errorBanner(error, retained: state.snapshot != nil) { refreshID = UUID() }
                }
                if let snapshot = state.snapshot {
                    if snapshot.files.isEmpty {
                        ContentUnavailableView("No uncommitted changes", systemImage: "checkmark.circle",
                            description: Text("This Git working tree has no staged, unstaged, or untracked files."))
                    } else {
                        HSplitView {
                            List(snapshot.files, selection: Binding(get: { state.selectedPath }, set: { state.select($0) })) { file in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.label).lineLimit(2).truncationMode(.middle)
                                    Text(file.status).font(.caption).foregroundStyle(.secondary)
                                }.tag(file.id).help(file.label)
                            }.listStyle(.sidebar).frame(minWidth: 150, idealWidth: 230, maxWidth: 340)
                            VStack(spacing: 0) {
                                if let error = state.patchError {
                                    errorBanner(error, retained: state.patch != nil) { state.retryPatch() }
                                }
                                WorkspaceDiffText(text: state.patch, identity: directory.path + "/" + (state.selectedPath ?? ""))
                                    .overlay {
                                        if state.patch == nil {
                                            if state.loadingPatch { ProgressView("Reading diff…") }
                                            else {
                                                Text(state.patchError != nil ? "Could not read this diff." : "Select a file to see its changes.")
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if state.loadingPatch && state.patch != nil {
                                            ProgressView().controlSize(.small).padding(8).help("Refreshing diff")
                                        }
                                    }
                            }.frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else if state.loading {
                    ProgressView("Reading workspace changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if state.error != nil {
                    ContentUnavailableView("Could not read changes", systemImage: "exclamationmark.triangle",
                        description: Text("Try refreshing the workspace changes."))
                } else {
                    ContentUnavailableView("Not a Git working tree", systemImage: "folder",
                        description: Text("The selected workspace is not inside a Git repository."))
                }
            }
            Divider()
            Text("Current working tree · Staged, unstaged, and untracked files")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .task(id: directory.path + refreshID.uuidString + String(isWorking)) { await refresh() }
        .task(id: PatchTask(directory: directory, path: state.selectedPath, revision: state.patchRevision)) { await loadPatch() }
        .onChange(of: reviewRequest) { _, _ in
            if let path = initialSelectedPath {
                state.select(path)
                refreshID = UUID()
            }
        }
    }

    private func errorBanner(_ message: String, retained: Bool, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text((retained ? "Showing the last successful read. " : "") + message)
                .font(.caption).textSelection(.enabled)
            Spacer()
            Button("Retry", action: retry).controlSize(.small)
        }.padding(10).background(.quaternary)
    }

    @MainActor private func refresh() async {
        let request = state.beginRefresh(directory: directory, initialSelectedPath: initialSelectedPath)
        do {
            let next = try await client.snapshot(directory: directory)
            guard !Task.isCancelled else { return }
            state.finishRefresh(next, request: request)
        } catch {
            guard !Task.isCancelled else { return }
            state.failRefresh(error.localizedDescription, request: request)
        }
    }

    @MainActor private func loadPatch() async {
        guard state.directory == directory, let read = state.beginPatch() else { return }
        do {
            let next = try await client.diff(file: read.file, root: read.root)
            guard !Task.isCancelled else { return }
            state.finishPatch(next, request: read.request)
        } catch {
            guard !Task.isCancelled else { return }
            state.failPatch(error.localizedDescription, request: read.request)
        }
    }
}

struct WorkspaceDiffText: NSViewRepresentable {
    let text: String?
    let identity: String

    func makeCoordinator() -> WorkspaceDiffViewport { WorkspaceDiffViewport() }
    func makeNSView(context: Context) -> NSScrollView { Self.makeScrollView() }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(scroll, text: text, identity: identity)
    }

    static func makeScrollView() -> NSScrollView {
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
}

/// Lives with the native view, so reading position and text selection survive both
/// changed patches and file switches without publishing scroll events into SwiftUI.
@MainActor final class WorkspaceDiffViewport {
    private struct Position {
        let origin: NSPoint
        let selection: NSRange
    }
    private var positions: [String: Position] = [:]
    private var identity: String?
    private var hasText = false

    func update(_ scroll: NSScrollView, text: String?, identity nextIdentity: String) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if let identity, hasText {
            positions[identity] = Position(origin: scroll.contentView.bounds.origin, selection: view.selectedRange())
        }
        let changedFile = identity != nextIdentity
        identity = nextIdentity
        let position = positions[nextIdentity]
        let next = text ?? ""
        let changedText = view.string != next
        hasText = text != nil
        guard changedFile || changedText else { return }
        if changedText {
            view.textStorage?.setAttributedString(CodeSyntax.render(next, language: "diff", font: .systemFont(ofSize: 13)))
        }
        if let container = view.textContainer, let manager = view.layoutManager {
            manager.ensureLayout(for: container)
            let size = manager.usedRect(for: container).size
            view.setFrameSize(NSSize(width: max(scroll.contentSize.width, ceil(size.width) + 24),
                                     height: max(scroll.contentSize.height, ceil(size.height) + 24)))
        }
        let length = (next as NSString).length
        let selection = position?.selection ?? NSRange(location: 0, length: 0)
        let start = min(selection.location, length)
        view.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
        let origin = position?.origin ?? .zero
        scroll.contentView.scroll(to: NSPoint(
            x: min(max(0, origin.x), max(0, view.frame.width - scroll.contentSize.width)),
            y: min(max(0, origin.y), max(0, view.frame.height - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
