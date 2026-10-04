import Darwin
import Foundation

enum ConversationOwnership {
    /// Codex holds an exclusive flock for each native writer. Probe the existing
    /// file read-only: a stale lock file is not evidence of a running owner.
    static func isOpenElsewhere(_ session: Session) throws -> Bool {
        guard session.source == "codex", session.machineID == "local",
              let id = UUID(uuidString: session.sessionID) else { return false }
        let home = try InAppResumeTarget.providerHome(
            for: URL(fileURLWithPath: session.sourcePath).standardizedFileURL, provider: "codex")
            .resolvingSymlinksInPath()
        let lock = home.appendingPathComponent("thread-writer-locks")
            .appendingPathComponent(id.uuidString.lowercased() + ".lock")
        let descriptor = open(lock.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return false
        }
        if errno == EWOULDBLOCK { return true }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
