import Foundation

/// Reads the name an agent gave a session, from that agent's own transcript
/// store.
///
/// The one place in CodeStatus that reads an agent's private files rather than
/// what a hook handed us, so the boundaries are worth stating.
///
/// The hook is not involved and does not change: `transcript_path` stays off
/// its allowlist, and nothing here crosses the socket. This runs in the app,
/// which already reads the filesystem to find a session's git root. What it
/// reads is undocumented and unversioned, so every failure — a moved
/// directory, a renamed key, a format that stops being NDJSON — has to return
/// `nil` and leave the session with the name it already had.
///
/// Only the title is ever retained. Transcript bytes are read into a buffer to
/// be searched and then dropped; nothing else from them is copied out.
public final class SessionTitleReader {

    /// How much of the end of a transcript to search.
    ///
    /// Claude Code appends a fresh `custom-title` record throughout a session,
    /// so the newest one is near the end. Measured against the three largest
    /// transcripts on a real machine — 9.3 MB, 8.1 MB and 7.2 MB — where the
    /// last record sat 4 KB, 0 KB and 15 KB from the end. 64 KB is four times
    /// the worst of those, and it bounds the read for a file that has no
    /// bound of its own.
    private static let tailBytes: UInt64 = 64 * 1024

    /// Cheap filter applied before any JSON parsing, so a multi-megabyte
    /// transcript costs one substring search per line instead of a parse.
    private static let marker = Data("\"custom-title\"".utf8)

    private let home: URL
    private let fileManager: FileManager

    /// What we know about one Claude Code session's transcript.
    ///
    /// The resolved URL is cached because finding it means listing the projects
    /// directory, and a transcript never moves. `size` is the invalidation
    /// stamp: the file is append-only, so an unchanged size means an unchanged
    /// answer and no read at all.
    private struct ClaudeEntry {
        var url: URL
        var size: UInt64
        var title: String?
    }

    private var claudeCache: [String: ClaudeEntry] = [:]

    private var codexIndex: [String: String] = [:]
    private var codexStamp: Stamp?

    private struct Stamp: Equatable {
        var size: UInt64
        var modified: Date
    }

    public init(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        fileManager: FileManager = .default
    ) {
        self.home = home
        self.fileManager = fileManager
    }

    // MARK: - Entry point

    /// The agent's own name for a session, or `nil` when it has not named one.
    public func title(for provider: AgentProvider, sessionID: String) -> String? {
        switch provider {
        case .claudeCode: return claudeTitle(sessionID: sessionID)
        case .codex: return codexTitle(sessionID: sessionID)
        case .generic: return nil
        }
    }

    /// Drops everything we are caching for sessions that no longer exist.
    ///
    /// Without this the caches are a leak with a slow fuse: one entry per
    /// session the machine has ever run, held for as long as the app is up.
    public func prune(keeping live: Set<String>) {
        claudeCache = claudeCache.filter { live.contains($0.key) }
    }

    // MARK: - Claude Code

    private var claudeProjects: URL {
        home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    private func claudeTitle(sessionID: String) -> String? {
        if let cached = claudeCache[sessionID], let size = fileSize(of: cached.url) {
            if size == cached.size { return cached.title }
            // A transcript that outgrows the tail window carries its title out
            // of reach. Keeping the last one we saw is right: the session was
            // named, and nothing has told us it was renamed.
            let title = lastCustomTitle(in: cached.url, size: size) ?? cached.title
            claudeCache[sessionID] = ClaudeEntry(url: cached.url, size: size, title: title)
            return title
        }

        // Either we have never resolved this session, or the file we resolved
        // is gone. Both mean the cached entry is worthless.
        claudeCache[sessionID] = nil

        // Deliberately no negative cache. A miss costs one directory listing
        // and a handful of `stat` calls every ten seconds, and the alternative
        // was worse: a transcript that did not exist at first lookup stayed
        // invisible for the life of the process, because creating a file in an
        // existing project directory does not change the directory we watched.
        guard let url = locateTranscript(sessionID: sessionID),
              let size = fileSize(of: url)
        else { return nil }

        let title = lastCustomTitle(in: url, size: size)
        claudeCache[sessionID] = ClaudeEntry(url: url, size: size, title: title)
        return title
    }

    /// Finds `<projects>/<slug>/<session id>.jsonl` by listing rather than by
    /// rebuilding the slug.
    ///
    /// Claude Code derives that directory name from the working directory with
    /// a substitution it has never documented, and a session started in a path
    /// we transform even slightly differently would silently never be found.
    /// Listing is a handful of `stat` calls once per session and cannot drift.
    private func locateTranscript(sessionID: String) -> URL? {
        let file = "\(sessionID).jsonl"
        guard let directories = try? fileManager.contentsOfDirectory(
            at: claudeProjects,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for directory in directories {
            let candidate = directory.appendingPathComponent(file)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Scans the last ``tailBytes`` of a transcript backwards for the newest
    /// `custom-title` record.
    private func lastCustomTitle(in url: URL, size: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let offset = size > Self.tailBytes ? size - Self.tailBytes : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              !data.isEmpty
        else { return nil }

        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // Seeking to a byte offset lands mid-record unless we started at zero,
        // and half a JSON object is not something to hand to a parser.
        if offset > 0, !lines.isEmpty { lines.removeFirst() }

        for line in lines.reversed() {
            guard line.range(of: Self.marker) != nil else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "custom-title",
                  let title = object["customTitle"] as? String
            else { continue }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    // MARK: - Codex

    /// Codex keeps names in one small index rather than in the session file.
    ///
    /// Its rollout transcript carries no name at all — verified across a full
    /// file, which holds only `session_meta`, `event_msg` and `response_item`
    /// records — so this index is the only source, and it is a lagging one.
    /// A session it has not reached yet, and any `codex exec` run, has no name
    /// here and correctly falls back to the working directory.
    private var codexSessionIndex: URL {
        home.appendingPathComponent(".codex/session_index.jsonl")
    }

    private func codexTitle(sessionID: String) -> String? {
        let stamp = stamp(of: codexSessionIndex)
        if stamp != codexStamp {
            codexStamp = stamp
            codexIndex = loadCodexIndex()
        }
        return codexIndex[sessionID]
    }

    private func loadCodexIndex() -> [String: String] {
        guard let data = try? Data(contentsOf: codexSessionIndex) else { return [:] }

        var index: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = object["thread_name"] as? String
            else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // The file is append-only and a rename appends again, so the last
            // entry for an id is the current name.
            if trimmed.isEmpty { index[id] = nil } else { index[id] = trimmed }
        }
        return index
    }

    // MARK: - Filesystem

    private func stamp(of url: URL) -> Stamp? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        return Stamp(size: size, modified: modified)
    }

    private func fileSize(of url: URL) -> UInt64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.uint64Value
    }
}
