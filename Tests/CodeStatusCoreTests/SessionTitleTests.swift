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

/// Writes one record where the Claude Code desktop app keeps its session list.
///
/// Verbatim field names from a real store, trimmed to what the reader reads —
/// the real record also carries the session's whole MCP tool roster, which is
/// what makes these files about 90 KB each and worth not re-parsing.
@discardableResult
private func writeDesktopSession(
    home: URL,
    workspace: String = "ws-1",
    project: String = "proj-1",
    file: String,
    cliSessionID: String?,
    title: String?,
    titleSource: String = "user",
    archived: Bool = false,
    lastActivityAt: Double = 1_788_890_634_095
) throws -> URL {
    let directory = home.appendingPathComponent(
        "Library/Application Support/Claude/claude-code-sessions/\(workspace)/\(project)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var record: [String: Any] = [
        "titleSource": titleSource,
        "isArchived": archived,
        "lastActivityAt": lastActivityAt,
    ]
    if let cliSessionID { record["cliSessionId"] = cliSessionID }
    if let title { record["title"] = title }

    let url = directory.appendingPathComponent(file)
    try JSONSerialization.data(withJSONObject: record).write(to: url)
    return url
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

/// The two title records Claude Code writes, in the verbatim shape they have
/// on a real machine: same key order, same field names, same spelling of the
/// type. Captured from live transcripts, with only the title text replaced —
/// a real one is a model's description of somebody's work and does not belong
/// in a repository.
///
/// Both are here because the first version of this reader knew about one of
/// them, and both suites built their fixtures from that same assumption, so
/// 375 tests agreed with each other and none of them agreed with a CLI-only
/// machine. Fixtures that invent their own shape cannot catch that; these are
/// the shapes the agent actually appends.
private func customTitleRecord(_ title: String, session: String) -> String {
    "{\"type\":\"custom-title\",\"customTitle\":\"\(title)\",\"sessionId\":\"\(session)\"}"
}

private func aiTitleRecord(_ title: String, session: String) -> String {
    "{\"type\":\"ai-title\",\"aiTitle\":\"\(title)\",\"sessionId\":\"\(session)\"}"
}

/// Kept as the name the older tests used, so what they assert is unchanged.
private func titleRecord(_ title: String, session: String) -> String {
    customTitleRecord(title, session: session)
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

    @Test("A session renamed in the desktop app takes the new name, not the transcript's")
    func desktopRenameWins() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = "21922c07-c5d7-4bf3-ab35-4e0fd639c5d5"

        // The transcript keeps the title that was appended to it earlier. A
        // rename typed in the session list never reaches it, so a reader that
        // consults only the transcript shows a name the user already changed.
        try writeTranscript(home: home, slug: "-Users-x-backend", sessionID: session, lines: [
            customTitleRecord("Situação da infraestrutura WAHA", session: session),
            aiTitleRecord("Explicar a situação da infraestrutura", session: session),
        ])
        try writeDesktopSession(
            home: home, file: "local_a.json", cliSessionID: session, title: "WAHA Infra"
        )

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .claudeCode, sessionID: session) == "WAHA Infra")
    }

    @Test("A rename after the title was already read is picked up")
    func desktopRenameInvalidatesTheCache() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = "aaaa1111-bbbb-2222-cccc-333333333333"
        let url = try writeDesktopSession(
            home: home, file: "local_b.json", cliSessionID: session, title: "Before the rename"
        )

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .claudeCode, sessionID: session) == "Before the rename")

        // A rename rewrites that one file, which is the only signal there is:
        // no directory above it changes, and nothing is appended anywhere.
        try writeDesktopSession(
            home: home, file: "local_b.json", cliSessionID: session, title: "After the rename"
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path
        )
        #expect(reader.title(for: .claudeCode, sessionID: session) == "After the rename")
    }

    @Test("With no desktop store the transcript is still read")
    func withoutDesktopStore() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = "cccc4444-dddd-5555-eeee-666666666666"
        // A CLI-only machine has no such directory at all.
        try writeTranscript(home: home, slug: "-Users-x-cli", sessionID: session, lines: [
            aiTitleRecord("Next.js CVE upgrade", session: session),
        ])

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .claudeCode, sessionID: session) == "Next.js CVE upgrade")
    }

    @Test("A desktop record with no title falls through to the transcript")
    func desktopWithoutTitleFallsThrough() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = "eeee7777-ffff-8888-9999-000000000000"
        try writeTranscript(home: home, slug: "-Users-x-untitled", sessionID: session, lines: [
            customTitleRecord("From the transcript", session: session),
        ])
        try writeDesktopSession(
            home: home, file: "local_c.json", cliSessionID: session, title: nil
        )

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .claudeCode, sessionID: session) == "From the transcript")
    }

    @Test("A live desktop record outranks an archived one for the same session")
    func liveRecordOutranksArchived() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = "12341234-5678-5678-9012-901290129012"
        try writeDesktopSession(
            home: home, file: "local_archived.json", cliSessionID: session,
            title: "The archived one", archived: true, lastActivityAt: 9_000_000_000_000
        )
        try writeDesktopSession(
            home: home, file: "local_live.json", cliSessionID: session,
            title: "The live one", archived: false, lastActivityAt: 1_000
        )

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .claudeCode, sessionID: session) == "The live one")
    }

    @Test("An ai-title names a session that has no custom-title")
    func aiTitleIsRead() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = "5a5a5a5a-6b6b-7c7c-8d8d-9e9e9e9e9e9e"
        // A CLI-only machine looks exactly like this: 126 transcripts of it,
        // and not one `custom-title` among them.
        try writeTranscript(home: home, slug: "-Users-x-cli", sessionID: session, lines: [
            "{\"type\":\"user\",\"text\":\"hello\"}",
            aiTitleRecord("Next.js CVE upgrade", session: session),
        ])

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .claudeCode, sessionID: session) == "Next.js CVE upgrade")
    }

    @Test("A custom-title outranks an ai-title appended after it")
    func customTitleWinsOverAiTitle() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = "7f7f7f7f-8080-8181-8282-838383838383"
        // The desktop app writes both, with different wording, and keeps
        // appending both. The renamed one is what its session list shows, so
        // position in the file must not decide this.
        try writeTranscript(home: home, slug: "-Users-x-desktop", sessionID: session, lines: [
            aiTitleRecord("Explicar fluxo de chat atual", session: session),
            customTitleRecord("Fluxo de chat atual (fork)", session: session),
            aiTitleRecord("Explicar fluxo de chat atual", session: session),
        ])

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .claudeCode, sessionID: session) == "Fluxo de chat atual (fork)")
    }

    @Test("An ai-title is used when the custom-title record carries nothing")
    func emptyCustomTitleFallsThroughToAi() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = "0a0a0a0a-0b0b-0c0c-0d0d-0e0e0e0e0e0e"
        try writeTranscript(home: home, slug: "-Users-x-blank", sessionID: session, lines: [
            aiTitleRecord("Upgrade the release pipeline", session: session),
            customTitleRecord("   ", session: session),
        ])

        let reader = SessionTitleReader(home: home)
        #expect(reader.title(for: .claudeCode, sessionID: session) == "Upgrade the release pipeline")
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
        // An `ai-title`, because that is the record a machine with no manual
        // renames has, and it is the one whose distance from EOF was measured
        // at worst 15.7 KB on a 49 MB transcript.
        lines.append(aiTitleRecord("Near the end", session: session))
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

        // A title qualifies the row; it does not take it over. The location
        // keeps the lead so that a column of rows stays scannable by place.
        session.sessionTitle = "Calendar fix"
        #expect(session.primaryLabel == "backend")
        #expect(session.secondaryLabel == "Calendar fix")
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
            == "Situação da infraestrutura WAHA: Open the session to answer.")
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
