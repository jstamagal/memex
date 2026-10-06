import AppKit
import Foundation
import Testing
@testable import Memex

@Suite(.serialized) @MainActor struct ConversationMediaTests {
    private func bitmap() throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<16 { for y in 0..<16 { bitmap.setColor(.red, atX: x, y: y) } }
        return bitmap
    }

    @Test func smallSupportedImagesRetainExactBytesAndTiffIsNormalized() throws {
        let bitmap = try bitmap()
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(try ConversationImageNormalization.normalize(png).data == png)
        let tiff = try #require(bitmap.representation(using: .tiff, properties: [:]))
        let normalized = try ConversationImageNormalization.normalize(tiff)
        #expect(normalized.mimeType == "image/png")
        #expect(normalized.data.count <= ConversationImageNormalization.maximumOutputBytes)
        let decoded = try #require(NSBitmapImageRep(data: normalized.data))
        #expect(decoded.pixelsWide == 16)
        #expect(decoded.pixelsHigh == 16)
    }

    @Test func invalidImageFailsInsteadOfBecomingAnOpaqueAttachment() {
        #expect(throws: (any Error).self) { try ConversationImageNormalization.normalize(Data("not an image".utf8)) }
    }

    @Test func dictationRecoversLatestAudioWithoutRecordingOrSending() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let older = directory.appendingPathComponent("100-first.m4a")
        let latest = directory.appendingPathComponent("200-second.m4a")
        try Data([1]).write(to: older)
        try Data([2]).write(to: latest)
        let dictation = ConversationDictation(directory: directory)
        let recovered = try #require(dictation.recordingURL)
        #expect(recovered.resolvingSymlinksInPath().path == latest.resolvingSymlinksInPath().path)
        #expect(try Data(contentsOf: recovered) == Data([2]))
        #expect(dictation.phase == .idle)
        #expect(dictation.transcript.isEmpty)
        dictation.cancel()
        #expect(try Data(contentsOf: latest) == Data([2]))
    }

    #if canImport(SQACPHost)
    @Test func editingAnnotationKeepsIdentityLocationAndOriginalCapture() throws {
        let original = try ConversationAttachment.text(title: "Selected response", text: "Captured text", source: "session-id#record-id")
        let first = try original.annotated(passage: "line 2", comment: "Explain this")
        let edited = try first.annotated(passage: "line 2", comment: "Explain more")
        #expect(edited.id == first.id)
        #expect(edited.annotation?.attachmentID == original.id)
        #expect(edited.annotation?.source == "session-id#record-id")
        #expect(edited.annotation?.comment == "Explain more")
        #expect(edited.content != first.content)
        let restored = try JSONDecoder().decode([ConversationAttachment].self,
            from: JSONEncoder().encode([original, edited]))
        #expect(restored[0].content == original.content)
        #expect(restored[1] == edited)
    }
    #endif
}
