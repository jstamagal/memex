import AppKit
import SwiftUI

struct ReaderView: View {
    @Bindable var store: Store
    @State private var navigation = TranscriptNavigationState()
    @State private var find: ConversationFindState?
    @State private var rawTranscript = false
    @FocusState private var findFocused: Bool

    var body: some View {
        Group {
            if let session = store.selected {
                VStack(spacing: 0) {
                    header(session)
                        .contextMenu { Toggle("Raw transcript", isOn: $rawTranscript) }
                    Divider().opacity(0.5)
                    if let error = store.createdConversations.error {
                        HStack {
                            Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                            Button("Retry saving") { store.createdConversations.retrySave() }
                        }.padding(8)
                    }
                    if let live = store.selectedLiveConversation {
                        if let error = live.ownershipError ?? live.error {
                            HStack {
                                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                Button("Reload") { Task { await live.connect() } }
                            }.padding(8)
                        } else if let warning = live.snapshot.warning {
                            Text(warning).font(.caption).foregroundStyle(.secondary).padding(8)
                        }
                    }
                    if let find, find.isOpen { findBar(find) }
                    if let live = store.selectedLiveConversation, store.readerUsesLiveSnapshot {
                        NativeTranscript(sessionID: session.id + ":live", records: live.visibleRecords,
                                         provider: session.source, hasMore: false, isLoading: false, onLoadMore: {},
                                         hasEarlier: live.hasEarlierRecords, startsAtEnd: true, navigation: navigation,
                                         onLoadEarlier: { live.loadEarlierRecords() },
                                         findQuery: find?.isOpen == true ? find?.query ?? "" : "",
                                         findHit: find?.selectedHit, findGeneration: find?.generation ?? 0,
                                         rawTranscript: rawTranscript, isLocalHost: true, sourcePath: session.sourcePath,
                                         followLatest: true)
                    } else {
                        NativeTranscript(sessionID: store.readerPositionKey,
                                     records: store.loadedReaderKey == store.readerPositionKey ? store.records : [],
                                     provider: session.source, hasMore: store.hasMoreRecords,
                                     isLoading: store.loadingRecords,
                                     onLoadMore: { Task { await store.loadMoreRecords() } },
                                     hasEarlier: store.hasEarlierRecords, startsAtEnd: store.readerStartsAtEnd,
                                     anchorID: store.readerAnchorID, navigation: navigation,
                                     onLoadEarlier: { Task { await store.loadEarlierRecords() } },
                                     findQuery: find?.isOpen == true ? find?.query ?? "" : "",
                                     findHit: find?.selectedHit, findGeneration: find?.generation ?? 0,
                                     rawTranscript: rawTranscript, isLocalHost: session.machineID == "local",
                                     sourcePath: session.sourcePath)
                        if let error = store.readerError {
                            ErrorBanner(message: error) {
                                Task { await store.retryRecords() }
                            }
                        }
                        if store.loadingRecords {
                            ProgressView("Loading conversation…").controlSize(.small).padding(12)
                        } else if store.records.isEmpty && store.readerError == nil {
                            Text("No messages in this transcript.").foregroundStyle(.secondary).padding(12)
                        }
                    }
                    if let live = store.selectedLiveConversation {
                        ConversationComposer(conversation: live)
                    } else {
                        Label(InAppResumeTarget.unavailableReason(for: session)
                              ?? "This build supports continuing conversations through Open in.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: ConversationReadingLane.maximumWidth, alignment: .leading)
                            .padding(.horizontal, ConversationReadingLane.minimumMargin).padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                ContentUnavailableView("Your conversations, together", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Select a conversation or search your history."))
            }
        }
        .onAppear { if find == nil { find = ConversationFindState(client: store.client) } }
        .onChange(of: store.selected, initial: true) { _, session in
            if let session { store.liveConversations.prepare(session) }
        }
        .task(id: store.selectedLiveConversation?.session.id) {
            guard let live = store.selectedLiveConversation else { return }
            while !Task.isCancelled {
                live.refreshOwnership()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onChange(of: store.findConversationRequest) { _, _ in
            find?.isOpen = true
            findFocused = true
        }
        .onChange(of: store.readerTranscriptKey) { _, _ in
            search()
        }
        .onChange(of: find?.query) { _, _ in search() }
        .onChange(of: store.selectedLiveConversation?.revision) { _, _ in
            if store.readerUsesLiveSnapshot { search() }
            store.updateCreatedConversationTitle()
        }
        .task(id: find?.generation) {
            guard let hit = find?.selectedHit else { return }
            if let live = store.selectedLiveConversation, store.readerUsesLiveSnapshot { live.revealRecord(hit.recordID) }
            else { await store.revealRecord(hit.recordID, offset: hit.recordOffset) }
        }
        .onDisappear { find?.reset() }
    }

    private func search() {
        if let live = store.selectedLiveConversation, store.readerUsesLiveSnapshot { find?.search(records: live.snapshot.records) }
        else { find?.search(in: store.selected) }
    }

    private func findBar(_ state: ConversationFindState) -> some View {
        @Bindable var state = state
        return HStack(spacing: 8) {
            TextField("Find in conversation", text: $state.query)
                .textFieldStyle(.roundedBorder).focused($findFocused)
                .onAppear { findFocused = true }
                .onSubmit { state.move(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                .onExitCommand { state.close() }
                .accessibilityLabel("Find in conversation")
                .frame(minWidth: 100).layoutPriority(1)
            if state.isScanning { ProgressView().controlSize(.small) }
            Text(state.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: 90).help(state.statusDetail)
                .accessibilityLabel(state.statusDetail)
            Button { state.move(-1) } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Previous match (⇧⌘G)").disabled(state.hits.isEmpty)
            Button { state.move(1) } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut("g", modifiers: .command)
                .help("Next match (⌘G)").disabled(state.hits.isEmpty)
            Button { state.close() } label: { Image(systemName: "xmark") }
                .help("Close find").keyboardShortcut(.escape, modifiers: [])
        }
        .buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 8)
    }

    private func header(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.title).font(.title2.weight(.semibold)).lineLimit(2)
            HStack(spacing: 8) {
                Text(session.source)
                Text("·")
                Text(session.projectName)
                if session.machineID != "local" {
                    Text("·")
                    Label(session.machineID, systemImage: "desktopcomputer")
                }
                Spacer()
                if let date = session.date { Text(date, format: .dateTime.month().day().hour().minute()) }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: ConversationReadingLane.maximumWidth, alignment: .leading)
        .padding(.horizontal, ConversationReadingLane.minimumMargin).padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }
}
