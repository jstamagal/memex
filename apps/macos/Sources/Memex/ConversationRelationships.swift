import Darwin
import Foundation
import Observation

@MainActor @Observable
final class ConversationRelationships {
    struct Link: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case nativeFork, contextBranch, providerTransition, rewind }
        let parent: Session
        let child: Session
        let kind: Kind
        let sourceRecordID: String?
        let createdAt: Date
        var id: String { child.id }
    }
    struct Pending: Codable, Equatable, Identifiable {
        let id: String
        let source: Session
        let operation: String
        let boundary: ConversationHistoryBoundary?
        let issuedAt: Date
        var result: Session?
    }
    private struct Saved: Codable {
        var version = 1
        var links: [Link] = []
        var pending: [Pending] = []
    }
    private(set) var links: [Link] = []
    private(set) var pending: [Pending] = []
    private(set) var error: String?
    @ObservationIgnored private let directory: URL?

    init(directory: URL? = nil) {
        self.directory = directory
        do { if let directory { install(try read(directory)) } }
        catch { self.error = "Saved conversation relationships could not be read. Their file was preserved: \(error.localizedDescription)" }
    }
    static func persistent() -> Self {
        Self(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dev.memex.app/Conversations"))
    }
    func parent(of id: String) -> Link? { links.first { $0.child.id == id } }
    func children(of id: String) -> [Link] { links.filter { $0.parent.id == id } }

    func begin(source: Session, operation: String, boundary: ConversationHistoryBoundary? = nil) throws -> Pending {
        let operation = Pending(id: UUID().uuidString, source: source, operation: operation, boundary: boundary, issuedAt: Date())
        try mutate { saved in
            guard !saved.pending.contains(where: { $0.source.id == source.id }) else {
                throw ConversationRuntimeError(message: "A previous history change needs inspection before another can start.")
            }
            saved.pending.append(operation)
        }
        return operation
    }
    func recordResult(_ session: Session, for operation: Pending) throws {
        try mutate { saved in
            guard let index = saved.pending.firstIndex(where: { $0.id == operation.id }) else {
                throw ConversationRuntimeError(message: "The saved history operation is unavailable.")
            }
            saved.pending[index].result = session
        }
    }
    func finish(_ operation: Pending, link: Link?) throws {
        try mutate { saved in
            if let link, !saved.links.contains(where: { $0.id == link.id }) { saved.links.append(link) }
            saved.pending.removeAll { $0.id == operation.id }
        }
    }
    func acknowledge(_ operation: Pending) throws { try finish(operation, link: nil) }

    private func read(_ directory: URL) throws -> Saved {
        let file = directory.appendingPathComponent("relationships.json")
        do {
            let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
            guard saved.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            return saved
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Saved() }
    }
    private func install(_ saved: Saved) { links = saved.links; pending = saved.pending; error = nil }
    private func mutate(_ body: (inout Saved) throws -> Void) throws {
        do {
            if let directory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let descriptor = Darwin.open(directory.appendingPathComponent("relationships.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
                guard descriptor >= 0 else { throw POSIXError(.EIO) }
                defer { Darwin.close(descriptor) }
                guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
                defer { _ = flock(descriptor, LOCK_UN) }
                var saved = try read(directory)
                try body(&saved)
                let file = directory.appendingPathComponent("relationships.json")
                try JSONEncoder().encode(saved).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                install(saved)
            } else {
                var saved = Saved(links: links, pending: pending)
                try body(&saved)
                install(saved)
            }
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }
}
