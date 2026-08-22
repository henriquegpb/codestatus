import Foundation

/// Persists the session table across daemon restarts and sleep.
///
/// PRIVACY: the only thing written here is ``AgentSession``, which is metadata by
/// construction — identity, state, timing, pid, and paths. Paths (`cwd`,
/// `gitRoot`, `repositoryName`) are permitted metadata; a prompt, a response, a
/// tool argument, or a file's contents never reach ``AgentSession`` in the first
/// place, because the hook drops those keys before they cross the socket.
/// `PersistenceTests` asserts the stored property set of ``AgentSession`` against
/// a reviewed allowlist, so adding a field to it fails the build until someone
/// has looked at this decision again.
public struct StatePersistence: Sendable {

    /// Bumped only when the on-disk shape changes in a way an older build cannot
    /// read. A snapshot from a *newer* build is discarded rather than guessed at.
    public static let schemaVersion = 1

    public struct Snapshot: Sendable, Codable, Equatable {
        public let version: Int
        /// Wall clock at save time. The wake path needs this to reason about how
        /// long the machine was away, which is the whole reason the field exists.
        public let savedAt: Date
        public let sessions: [AgentSession]

        public init(
            version: Int = StatePersistence.schemaVersion,
            savedAt: Date,
            sessions: [AgentSession]
        ) {
            self.version = version
            self.savedAt = savedAt
            self.sessions = sessions
        }

        public func age(at now: Date) -> TimeInterval {
            now.timeIntervalSince(savedAt)
        }
    }

    /// Loading never throws: the daemon must start regardless, and a missing or
    /// unusable snapshot is a normal condition, not a failure.
    public enum LoadOutcome: Sendable, Equatable {
        case none
        case restored(Snapshot)
        /// The file existed, was unusable, and has been deleted.
        case discarded(DiscardReason)

        public enum DiscardReason: String, Sendable, Equatable {
            /// Written by a newer build. Reading it would mean guessing at a shape
            /// we do not know, so we drop it and rediscover instead.
            case futureSchema
            case corrupt
        }
    }

    public enum SaveError: Error, Equatable {
        case createFailed(Int32)
        case writeFailed(Int32)
        case publishFailed(Int32)
    }

    private let paths: RuntimePaths

    public init(paths: RuntimePaths = RuntimePaths()) {
        self.paths = paths
    }

    public func save(_ sessions: [AgentSession], now: Date = Date()) throws {
        try paths.createDirectories()
        let snapshot = Snapshot(savedAt: now, sessions: sessions)
        // Deliberately the default date strategy: dates round-trip through a
        // Double exactly, whereas ISO-8601 would quantise `stateChangedAt` and
        // make a restored session's duration drift. This file is ours alone and
        // is never an interchange format.
        try write(JSONEncoder().encode(snapshot))
    }

    public func load() -> LoadOutcome {
        guard let data = try? Data(contentsOf: paths.sessionsSnapshot) else { return .none }

        let decoder = JSONDecoder()
        // The envelope version is read before the payload on purpose: if a future
        // build changes the session shape, decoding the whole file first would
        // report "corrupt" for something that is merely newer.
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            discard()
            return .discarded(.corrupt)
        }
        guard probe.version <= Self.schemaVersion else {
            discard()
            return .discarded(.futureSchema)
        }
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else {
            discard()
            return .discarded(.corrupt)
        }
        return .restored(snapshot)
    }

    public func discard() {
        unlink(paths.sessionsSnapshot.path)
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    /// Publishes the snapshot atomically, owner-only for its whole life.
    ///
    /// Foundation's `.atomic` write would create the temporary file under the
    /// process umask and only apply permissions after the rename, briefly
    /// exposing every session's repository paths as 0644. Creating the descriptor
    /// at 0600 ourselves closes that window.
    private func write(_ data: Data) throws {
        let destination = paths.sessionsSnapshot.path
        // Pid-suffixed so two daemons — one shutting down, one starting — cannot
        // interleave into the same temporary file.
        let temporary = destination + ".tmp-\(getpid())"

        unlink(temporary)
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SaveError.createFailed(errno) }
        // umask can strip bits from the mode requested above.
        fchmod(fd, 0o600)

        var failure: Int32 = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n <= 0 {
                    failure = errno == 0 ? EIO : errno
                    return
                }
                offset += n
            }
        }
        // The snapshot that matters most is the one taken as the Mac goes to
        // sleep; without this, an unclean wake can leave a truncated file that
        // the next launch would have to throw away.
        if failure == 0 { fsync(fd) }
        close(fd)

        guard failure == 0 else {
            unlink(temporary)
            throw SaveError.writeFailed(failure)
        }
        guard rename(temporary, destination) == 0 else {
            let code = errno
            unlink(temporary)
            throw SaveError.publishFailed(code)
        }
    }
}
