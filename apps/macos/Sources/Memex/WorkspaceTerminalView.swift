import AppKit
import SwiftUI

struct WorkspaceTerminalView: View {
    enum Placement { case rightPane, drawer }
    @Bindable var store: Store
    let placement: Placement
    @State private var session: WorkspaceTerminalSession?
    @State private var loadedDirectory: URL?
    @State private var error: String?
    @State private var retry = 0

    private struct Request: Equatable {
        let directory: URL?
        let retry: Int
    }

    var body: some View {
        Group {
            if let directory = store.selectedWorkspace {
                if directory == loadedDirectory, let session {
                    WorkspaceTerminalContent(session: session, store: store, placement: placement)
                } else if directory == loadedDirectory, let error {
                    ContentUnavailableView {
                        Label("Couldn’t open terminal", systemImage: "terminal")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { retry += 1 }
                    }
                } else {
                    ProgressView("Opening workspace terminal…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("Local workspace unavailable", systemImage: "terminal",
                    description: Text("A terminal requires a conversation with a local working folder."))
            }
        }
        .task(id: Request(directory: store.selectedWorkspace, retry: retry)) {
            let directory = store.selectedWorkspace
            error = nil
            guard let directory else { session = nil; loadedDirectory = nil; return }
            do {
                let next = try await store.workspaceTerminals.session(for: directory)
                guard !Task.isCancelled, store.selectedWorkspace == directory else { return }
                session = next
                loadedDirectory = directory
            } catch {
                guard !Task.isCancelled, store.selectedWorkspace == directory else { return }
                session = nil
                self.error = error.localizedDescription
                loadedDirectory = directory
            }
        }
    }
}

private struct WorkspaceTerminalContent: View {
    @Bindable var session: WorkspaceTerminalSession
    @Bindable var store: Store
    let placement: WorkspaceTerminalView.Placement

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(session.directory.lastPathComponent, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                    .help(session.directory.path)
                Text(session.isExited ? "Exited" : session.title)
                    .foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 4)
                if session.isExited {
                    Button("Restart") { session.restart() }
                        .help("Start a new shell in this workspace")
                }
                Button {
                    if placement == .drawer { store.showWorkspaceTerminal() }
                    else { store.toggleTerminalDrawer() }
                } label: {
                    Image(systemName: placement == .drawer ? "sidebar.right" : "rectangle.bottomthird.inset.filled")
                        .frame(width: 28, height: 28)
                }
                .help(placement == .drawer ? "Move terminal to right pane" : "Move terminal to bottom (⌘J)")
                .accessibilityLabel(placement == .drawer ? "Move terminal to right pane" : "Move terminal to bottom")
                Menu {
                    Button("End Terminal", role: .destructive) {
                        if session.needsCloseConfirmation { session.closeRequested = true }
                        else { session.close() }
                    }.disabled(session.isExited)
                } label: { Image(systemName: "ellipsis").frame(width: 22, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Terminal actions").accessibilityLabel("Terminal actions")
                if placement == .drawer {
                    Button { store.toggleTerminalDrawer() } label: {
                        Image(systemName: "chevron.down").frame(width: 28, height: 28)
                    }
                    .help("Hide terminal (⌘J)").accessibilityLabel("Hide terminal")
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 4).background(.bar)
            Divider()
            WorkspaceTerminalSurface(session: session, isActive: true, focusRequest: store.terminalFocusRequest)
                .id(session.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
            }
        }
        .alert("End this terminal?", isPresented: $session.closeRequested) {
            Button("End Terminal", role: .destructive) { session.close() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This ends the shell and any processes running in \(session.directory.lastPathComponent).")
        }
    }
}

/// The reader keeps its identity when the drawer opens. Its height changes,
/// while the terminal's session is owned separately by the workspace registry.
struct WorkspaceTerminalDrawer<Content: View>: View {
    @Bindable var store: Store
    @ViewBuilder let content: () -> Content
    @AppStorage("workspace-terminal-drawer-height") private var preferredHeight = 280.0
    @State private var dragStart: CGFloat?
    @State private var hoveringDivider = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
                if store.showingTerminalDrawer {
                    VStack(spacing: 0) {
                        resizeHandle(totalHeight: geometry.size.height)
                        WorkspaceTerminalView(store: store, placement: .drawer)
                    }
                    .frame(height: drawerHeight(in: geometry.size.height))
                }
            }
        }
    }

    private func drawerHeight(in totalHeight: CGFloat) -> CGFloat {
        min(max(140, preferredHeight), max(140, totalHeight - 180))
    }

    private func resizeHandle(totalHeight: CGFloat) -> some View {
        Color.clear.frame(height: 5)
            .overlay { Divider() }
            .contentShape(Rectangle())
            .onHover { hovering in
                guard hovering != hoveringDivider else { return }
                hoveringDivider = hovering
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if hoveringDivider { NSCursor.pop(); hoveringDivider = false }
                dragStart = nil
            }
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                if dragStart == nil { dragStart = drawerHeight(in: totalHeight) }
                preferredHeight = min(max(140, (dragStart ?? preferredHeight) - value.translation.height),
                                      max(140, totalHeight - 180))
            }.onEnded { _ in dragStart = nil })
            .accessibilityLabel("Terminal drawer height")
            .accessibilityAdjustableAction { direction in
                preferredHeight = drawerHeight(in: totalHeight) + (direction == .increment ? 40 : -40)
            }
    }
}
