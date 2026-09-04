import Testing
import Foundation
@testable import CodeStatusCore

/// A throwaway home directory laid out the way the agents lay theirs out, so
/// the reader is exercised against the real shape rather than a stand-in.
private func makeTestHome() throws -> URL {
    let home = URL(fileURLWithPath: "/tmp/cs-titles-\(getuid())-\(UInt32.random(in: 0..<0xFFFFFF))")
    try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".claude/projects"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".codex"),
        withIntermediateDirectories: true
    )
    return home
}

/// Writes a transcript where Claude Code writes one, slug and all.
@discardableResult
private func writeTranscript(
    home: URL,
    slug: String,
    sessionID: String,
    lines: [String]
) throws -> URL {
    let directory = home.appendingPathComponent(".claude/projects/\(slug)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(sessionID).jsonl")
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func titleRecord(_ title: String, session: String) -> String {
    "{\"type\":\"custom-title\",\"customTitle\":\"\(title)\",\"sessionId\":\"\(session)\"}"
}

/// A user record big enough to push earlier lines out of a tail read.
private func filler(_ bytes: Int) -> String {
    "{\"type\":\"user\",\"text\":\"\(String(repeating: "x", count: bytes))\"}"
}

@Suite("Session titles")
struct SessionTitleTests {

    @Test("The last custom-title in a transcript wins")
    func lastTitleWins() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = "11111111-2222-3333-4444-555555555555"
        try writeTranscript(home: home, slug: "-Users-x-repo", sessionID: session, lines: [
            "{\"type\":\"user\",\"text\":\"hello\"}",
            titleRecord("First guess", session: session),
            "{\"type\":\"assistant\",\"text\":\"working\"}",
            titleRecord("Renamed by hand", session: session),
        ])

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .claudeCode, sessionID: session) == "Renamed by hand")
    }

    @Test("A title is found without reading more than the tail of a huge transcript")
    func titleFoundInTail() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

        // Two megabytes of conversation, with the title near the end where
        // Claude Code actually keeps rewriting it.
        var lines = [titleRecord("Buried and stale", session: session)]
        for _ in 0..<32 { lines.append(filler(64 * 1024)) }
        lines.append(titleRecord("Near the end", session: session))
        lines.append(filler(8 * 1024))
        let url = try writeTranscript(home: home, slug: "-Users-x-big", sessionID: session, lines: lines)

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        #expect((size?.intValue ?? 0) > 2_000_000)

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .claudeCode, sessionID: session) == "Near the end")
    }

    @Test("A title older than the tail window is not found rather than guessed at")
    func titleOutsideTailIsNotInvented() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = "99999999-8888-7777-6666-555555555555"

        var lines = [titleRecord("Long gone", session: session)]
        for _ in 0..<4 { lines.append(filler(64 * 1024)) }
        try writeTranscript(home: home, slug: "-Users-x-old", sessionID: session, lines: lines)

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .claudeCode, sessionID: session) == nil)
    }

    @Test("A transcript that grows is re-read, and one that does not is not")
    func growthInvalidatesTheCache() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = "12121212-3434-5656-7878-909090909090"
        let url = try writeTranscript(home: home, slug: "-Users-x-grow", sessionID: session, lines: [
            titleRecord("Before", session: session),
        ])

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .claudeCode, sessionID: session) == "Before")

        // Deleting the file behind the reader's back proves the second answer
        // came from the cache and not from disk.
        try FileManager.default.removeItem(at: url)
        #expect(reader.title(for: .claudeCode, sessionID: session) == nil)

        try writeTranscript(home: home, slug: "-Users-x-grow", sessionID: session, lines: [
            titleRecord("Before", session: session),
            titleRecord("After", session: session),
        ])
        #expect(reader.title(for: .claudeCode, sessionID: session) == "After")
    }

    @Test("A session with no title anywhere reads as nil rather than as an error")
    func missingTitleIsNil() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeTranscript(home: home, slug: "-Users-x-quiet", sessionID: "known", lines: [
            "{\"type\":\"user\",\"text\":\"hello\"}",
        ])

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .claudeCode, sessionID: "known") == nil)
        #expect(reader.title(for: .claudeCode, sessionID: "never-existed") == nil)
        #expect(reader.title(for: .generic, sessionID: "known") == nil)
    }

    @Test("A truncated or malformed transcript yields no title instead of throwing")
    func malformedTranscriptIsSurvivable() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        try writeTranscript(home: home, slug: "-Users-x-broken", sessionID: session, lines: [
            "not json at all",
            "{\"type\":\"custom-title\",\"customTitle\":\"unterminated",
            "{\"type\":\"custom-title\"}",
        ])

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .claudeCode, sessionID: session) == nil)
    }

    @Test("Codex names come from the session index, last entry winning")
    func codexIndexIsRead() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let index = home.appendingPathComponent(".codex/session_index.jsonl")
        try """
        {"id":"01a0-first","thread_name":"Corrigir salvamento","updated_at":"2026-03-12T22:19:47Z"}
        {"id":"01a0-second","thread_name":"Explique DDL e DML","updated_at":"2026-03-15T20:27:59Z"}
        {"id":"01a0-first","thread_name":"Renamed later","updated_at":"2026-03-16T09:00:00Z"}
        """.write(to: index, atomically: true, encoding: .utf8)

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .codex, sessionID: "01a0-first") == "Renamed later")
        #expect(reader.title(for: .codex, sessionID: "01a0-second") == "Explique DDL e DML")
        // A `codex exec` run never reaches the index.
        #expect(reader.title(for: .codex, sessionID: "01a0-unindexed") == nil)
    }

    @Test("A missing Codex index is not an error")
    func missingCodexIndex() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .codex, sessionID: "anything") == nil)
    }

    @Test("A session with no title keeps the repository name it has today")
    func fallbackIsUnchanged() {
        var session = AgentSession(
            id: .provider(.claudeCode, "s1"),
            provider: .claudeCode,
            now: Date(),
            sourceAdapter: "test"
        )
        session.cwd = "/Users/x/repositories/backend/packages/api"
        session.repositoryName = "backend"

        #expect(session.primaryLabel == "backend")
        #expect(session.secondaryLabel == nil)

        session.sessionTitle = "Calendar fix"
        #expect(session.primaryLabel == "Calendar fix")
        #expect(session.secondaryLabel == "backend")
        // The name every export path still uses must not have moved.
        #expect(session.displayName == "backend")
    }

    @Test("A notification names the repository first and the session second")
    func announcementLeadsWithTheTitle() {
        var session = AgentSession(
            id: .provider(.claudeCode, "s4"),
            provider: .claudeCode,
            now: Date(),
            sourceAdapter: "test"
        )
        session.repositoryName = "backend"

        // Untitled, the banner reads exactly as it did before this existed.
        #expect(session.announcement("Open the session to answer.")
            == "Open the session to answer.")

        session.sessionTitle = "Situação da infraestrutura WAHA"
        #expect(session.announcement("Open the session to answer.")
            == "Situação da infraestrutura WAHA — Open the session to answer.")
        // The line the banner leads with stays locative, and stays the repo.
        #expect(session.displayName == "backend")
    }

    @Test("An empty title is treated as no title")
    func emptyTitleIsIgnored() {
        var session = AgentSession(
            id: .provider(.claudeCode, "s2"),
            provider: .claudeCode,
            now: Date(),
            sourceAdapter: "test"
        )
        session.repositoryName = "backend"
        session.sessionTitle = ""

        #expect(session.agentTitle == nil)
        #expect(session.primaryLabel == "backend")
        #expect(session.secondaryLabel == nil)
        #expect(session.announcement("Finished.") == "Finished.")
    }

    @Test("A snapshot written before titles existed still restores")
    func oldSnapshotsDecode() throws {
        // Exactly the shape `sessions.json` had before this field: no
        // `sessionTitle` key anywhere in the session object.
        let json = """
        {
          "id": {"rawValue": "claudeCode:s3"},
          "provider": "claudeCode",
          "state": "free",
          "stateConfidence": 0,
          "stateChangedAt": 810246572.77,
          "startedAt": 810237966.51,
          "lastEventAt": 810237995.29,
          "hostApplication": "unknown",
          "sourceAdapter": "claudeCodeHook",
          "capabilities": 17,
          "controlTarget": {"hostApplication": "unknown"},
          "hasHookEvidence": true,
          "repositoryName": "backend",
          "clock": {"turnSequence": 1, "lastAppliedRank": 8}
        }
        """
        let session = try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8))

        #expect(session.sessionTitle == nil)
        #expect(session.primaryLabel == "backend")
        #expect(session.secondaryLabel == nil)
    }

    @Test("Pruning drops the cache for sessions that have ended")
    func pruningForgetsDeadSessions() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        let url = try writeTranscript(home: home, slug: "-Users-x-prune", sessionID: session, lines: [
            titleRecord("Cached", session: session),
        ])

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .claudeCode, sessionID: session) == "Cached")

        reader.prune(keeping: [])
        try FileManager.default.removeItem(at: url)
        // With the entry pruned there is nothing left to serve the old answer.
        #expect(reader.title(for: .claudeCode, sessionID: session) == nil)
    }
}
