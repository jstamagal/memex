import AppKit
import Testing
@testable import Memex

@Suite(.serialized) @MainActor struct TranscriptSelectionTests {
    private func record(_ text: String) -> TranscriptRecord {
        TranscriptRecord(recordID: "selected-record", record: Message(role: "assistant", text: text,
            toolName: nil, toolInput: nil, toolOutput: nil))
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    private func window(_ controller: TranscriptController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        window.contentViewController = controller
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func showActions(in text: NSTextView) throws {
        var ancestor = text.superview
        while let view = ancestor {
            if let target = view as? any TranscriptSelectionTarget {
                target.showSelectionActions(in: text)
                return
            }
            ancestor = view.superview
        }
        Issue.record("No transcript selection target")
    }

    private func addButton(_ actions: TranscriptSelectionActions) throws -> NSButton {
        try #require(actions.popover?.contentViewController?.view.subviews.compactMap { $0 as? NSButton }.first)
    }

    @Test(arguments: ["Before **selected café 👋** after.", "Before\n\n```swift\nlet selected = 42\n```\n\nAfter"])
    func selectedTextIsCapturedFromProseAndCode(_ markdown: String) throws {
        let controller = TranscriptController()
        let window = window(controller)
        defer { controller.selectionActions.dismiss(); window.close() }
        let source = record(markdown)
        controller.update(sessionID: "one", records: [source], provider: "codex")
        var received: TranscriptSelection?
        controller.onAddSelection = { received = $0; return nil }
        let cell = try #require(controller.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let text = try #require(textViews(in: cell).first { !$0.isHidden && $0.string.contains("selected") })
        let expected = markdown.contains("café") ? "selected café 👋" : "selected = 42"
        text.setSelectedRange((text.string as NSString).range(of: expected))
        #expect(controller.selectionActions.popover == nil) // Find also sets a range programmatically.
        try showActions(in: text)
        #expect(controller.selectionActions.popover?.isShown == true)
        #expect(text is TranscriptSelectionTextView)
        try expectActionsAboveSelection(controller.selectionActions, text: text)
        try addButton(controller.selectionActions).performClick(nil)
        #expect(received == TranscriptSelection(text: expected, sourceIDs: [source.sourceID]))
        #expect(controller.selectionActions.popover == nil)
    }

    private func expectActionsAboveSelection(_ actions: TranscriptSelectionActions, text: NSTextView) throws {
        let window = try #require(text.window)
        let manager = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        let glyphs = manager.glyphRange(forCharacterRange: text.selectedRange(), actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
        let selectedOnScreen = window.convertToScreen(text.convert(rect, to: nil))
        let popup = try #require(actions.popover?.contentViewController?.view.window)
        #expect(popup.frame.minY >= selectedOnScreen.maxY + 5)
        #expect(!popup.frame.intersects(selectedOnScreen))
    }

    @Test func wrappedSelectionKeepsActionsAboveAllHighlightedLines() throws {
        let controller = TranscriptController()
        let window = window(controller)
        defer { controller.selectionActions.dismiss(); window.close() }
        controller.update(sessionID: "wrapped", records: [record(String(repeating: "selected words ", count: 30))], provider: "codex")
        controller.onAddSelection = { _ in nil }
        let cell = try #require(controller.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let text = try #require(textViews(in: cell).first { !$0.isHidden })
        text.setSelectedRange(NSRange(location: 10, length: 180))
        try showActions(in: text)
        try expectActionsAboveSelection(controller.selectionActions, text: text)
    }

    @Test func emptyAndWhitespaceSelectionsHaveNoAction() {
        let text = TranscriptSelectionTextView()
        text.string = "one   two"
        text.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(TranscriptSelectionActions.selectedText(in: text) == nil)
        text.setSelectedRange(NSRange(location: 3, length: 3))
        #expect(TranscriptSelectionActions.selectedText(in: text) == nil)
        text.setSelectedRange(NSRange(location: 0, length: 6))
        #expect(TranscriptSelectionActions.selectedText(in: text) == "one   ")
    }

    @Test func keyboardSelectionOpensActionsButFindDoesNot() throws {
        let controller = TranscriptController()
        let window = window(controller)
        defer { controller.selectionActions.dismiss(); window.close() }
        let records = [record("Choose this text")]
        controller.update(sessionID: "one", records: records, provider: "codex")
        controller.onAddSelection = { _ in nil }
        let cell = try #require(controller.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let text = try #require(textViews(in: cell).first { !$0.isHidden })
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{f703}",
            charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124))
        text.keyDown(with: key)
        #expect(TranscriptSelectionActions.selectedText(in: text) == "C")
        #expect(controller.selectionActions.popover?.isShown == true)
        let hit = try #require(ConversationMatcher.matches(records, query: "text").first)
        controller.update(sessionID: "one", records: records, provider: "codex", findQuery: "text", findHit: hit, findGeneration: 1)
        #expect(controller.selectionActions.popover == nil)
        #expect(controller.selectedFindRange != nil)
    }

    @Test func sessionSwitchDismissesActionsAndCannotCaptureIntoAnotherChat() throws {
        let controller = TranscriptController()
        let window = window(controller)
        defer { controller.selectionActions.dismiss(); window.close() }
        controller.update(sessionID: "one", records: [record("First chat")], provider: "codex")
        var count = 0
        controller.onAddSelection = { _ in count += 1; return nil }
        let cell = try #require(controller.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let text = try #require(textViews(in: cell).first { !$0.isHidden })
        text.setSelectedRange(NSRange(location: 0, length: 5))
        try showActions(in: text)
        let oldButton = try addButton(controller.selectionActions)
        controller.update(sessionID: "two", records: [record("Second chat")], provider: "codex")
        #expect(controller.selectionActions.popover == nil)
        oldButton.performClick(nil)
        #expect(count == 0)
    }

    @Test func changedSelectionCannotAttachOldTextAndShowsReason() throws {
        let controller = TranscriptController()
        let window = window(controller)
        defer { controller.selectionActions.dismiss(); window.close() }
        controller.update(sessionID: "one", records: [record("First second")], provider: "codex")
        var count = 0
        controller.onAddSelection = { _ in count += 1; return nil }
        let cell = try #require(controller.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let text = try #require(textViews(in: cell).first { !$0.isHidden })
        text.setSelectedRange(NSRange(location: 0, length: 5))
        try showActions(in: text)
        text.setSelectedRange(NSRange(location: 6, length: 6))
        try addButton(controller.selectionActions).performClick(nil)
        #expect(count == 0)
        let error = controller.selectionActions.popover?.contentViewController?.view.subviews.compactMap { $0 as? NSTextField }.first
        #expect(error?.stringValue == "The selection changed. Select the text again.")
    }

    #if canImport(SQACPHost)
    @Test func addToChatPreservesDraftAndAttachmentsWithoutSending() throws {
        let session = Session(source: "codex", sessionID: "selection", sourcePath: "/tmp/selection.jsonl",
                              project: "selection", cwd: "/tmp", machine: "local")
        let live = LiveConversation(session: session, checkOwnership: { _ in false })
        live.draft = "Existing unsent question"
        #expect(live.appendContext(title: "Earlier", text: "existing bytes", source: "earlier"))
        let first = try #require(live.attachments.first)
        #expect(live.appendTranscriptSelection(.init(text: "  exact café 👋\n", sourceIDs: ["record-42"])) == nil)
        #expect(live.draft == "Existing unsent question")
        #expect(live.attachments.first == first)
        let captured = try #require(live.attachments.last)
        let content = try #require(JSONSerialization.jsonObject(with: captured.content) as? [String: Any])
        #expect(content["text"] as? String == "Attached context: Selected text\nSource: \(session.id)#record-42\n\n  exact café 👋\n")
        #expect(!live.connectionAttempted)
        #expect(live.pendingPrompt == nil)
    }

    @Test func unavailableConversationReportsOwnershipAndPreservesDraft() {
        let session = Session(source: "codex", sessionID: "selection", sourcePath: "/tmp/selection.jsonl",
                              project: "selection", cwd: "/tmp", machine: "local")
        let live = LiveConversation(session: session, checkOwnership: { _ in true })
        live.draft = "Keep me"
        let error = live.appendTranscriptSelection(.init(text: "selected", sourceIDs: ["record"]))
        #expect(error == "This conversation is open in another app. Close it there before adding context here.")
        #expect(live.draft == "Keep me")
        #expect(live.attachments.isEmpty)
    }
    #endif
}
