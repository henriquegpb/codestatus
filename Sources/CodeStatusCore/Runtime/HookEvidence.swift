import Foundation

/// When a provider's hooks were last observed actually running.
///
/// The install path can prove that we wrote the right bytes to the right file.
/// It cannot prove the agent read them, and for Codex it provably cannot: the
/// user has to trust the file through `/hooks` afterwards, and Codex's refusal
/// to run an untrusted hook is silent. So "connected" and "working" are two
/// different claims, and only an event arriving over the socket settles the
/// second one.
public struct HookEvidence: Codable, Sendable, Equatable {
    /// The first hook event we ever received from this provider.
    public var firstSeen: Date
    public var lastSeen: Date

    public init(firstSeen: Date, lastSeen: Date) {
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// The evidence table plus the bookkeeping that keeps it off the hot path.
///
/// This is touched on every hook event, and a hook event is a tool call, so the
/// interesting question is not what to record but when to write. Both live here
/// because they cannot be answered separately: staleness is measured from the
/// last *write*, not from the last event, and a caller holding only the table
/// has no way to know when that was. Getting this backwards means a busy agent —
/// an event every few seconds, forever — never crosses the threshold and never
/// persists at all, leaving the file frozen at its first event.
public struct HookEvidenceLedger: Sendable {

    /// How stale the file may get before we write again.
    public static let writeInterval: TimeInterval = 300

    public private(set) var table: [AgentProvider: HookEvidence]
    private var persistedAt: [AgentProvider: Date]

    public init(_ table: [AgentProvider: HookEvidence] = [:]) {
        self.table = table
        // Whatever we loaded came off disk, so by definition it is persisted.
        persistedAt = table.mapValues(\.lastSeen)
    }

    public struct Outcome: Sendable, Equatable {
        /// The first event ever seen from this provider — what a setup screen
        /// waiting to be proven right is waiting for.
        public var isFirstEver: Bool
        public var shouldPersist: Bool
    }

    @discardableResult
    public mutating func record(_ provider: AgentProvider, at now: Date = Date()) -> Outcome {
        guard var existing = table[provider] else {
            table[provider] = HookEvidence(firstSeen: now, lastSeen: now)
            persistedAt[provider] = now
            // A first sighting is always worth a write: it is the one fact
            // anything else in the app asks this store for.
            return Outcome(isFirstEver: true, shouldPersist: true)
        }
        existing.lastSeen = now
        table[provider] = existing

        let since = persistedAt[provider] ?? .distantPast
        guard now.timeIntervalSince(since) >= Self.writeInterval else {
            return Outcome(isFirstEver: false, shouldPersist: false)
        }
        persistedAt[provider] = now
        return Outcome(isFirstEver: false, shouldPersist: true)
    }
}

/// Loads and saves ``HookEvidence``.
///
/// Ours, so it is written 0600 like everything else we own, and losing it is
/// harmless: the setup screen simply falls back to waiting for the next event.
public struct HookEvidenceStore: Sendable {

    public let paths: RuntimePaths

    public init(paths: RuntimePaths) {
        self.paths = paths
    }

    public var url: URL { paths.state.appendingPathComponent("hook-evidence.json") }

    public func load(fileManager: FileManager = .default) -> [AgentProvider: HookEvidence] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = fileManager.contents(atPath: url.path),
              let raw = try? decoder.decode([String: HookEvidence].self, from: data)
        else { return [:] }
        // An unrecognised key is a provider a newer build knew about. Dropping
        // it is right: this file is a cache of something observable, so being
        // wrong about it costs one more event's wait.
        return raw.reduce(into: [:]) { result, entry in
            guard let provider = AgentProvider(rawValue: entry.key) else { return }
            result[provider] = entry.value
        }
    }

    public func save(
        _ table: [AgentProvider: HookEvidence],
        fileManager: FileManager = .default
    ) throws {
        try paths.createDirectories(fileManager: fileManager)
        let raw = table.reduce(into: [String: HookEvidence]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // ISO 8601 so the file reads as a timeline to anyone looking at it. It
        // truncates below the second, which nothing here is sensitive to.
        encoder.dateEncodingStrategy = .iso8601
        try FileSurgery.atomicallyWrite(
            try encoder.encode(raw), to: url, mode: 0o600, fileManager: fileManager
        )
    }
}
