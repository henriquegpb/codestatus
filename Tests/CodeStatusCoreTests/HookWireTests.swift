import Testing
import Foundation
@testable import CodeStatusCore
@testable import HookCore

// MARK: - Helpers

private func scanFields(_ json: String) -> [(key: [UInt8], value: ScannedValue)] {
    var scanner = JSONScanner(Array(json.utf8))
    return scanner.scan()
}

private func line(for json: String, provider: String = "claudeCode") -> String {
    let out = buildEventLine(
        envelope: EventEnvelope(
            provider: provider,
            eventID: Array("1-2-0".utf8),
            timestampSeconds: 1_770_000_000,
            timestampMicroseconds: 123_456,
            parentPID: 4242,
            termProgram: Array("Apple_Terminal".utf8),
            termSessionID: Array("tsid-1".utf8)
        ),
        fields: scanFields(json)
    )
    return String(decoding: out, as: UTF8.self)
}

// MARK: - Privacy

@Suite("Hook scanner — only allowlisted metadata survives")
struct HookPrivacyTests {

    /// A realistic Claude Code `Stop` payload, including the fields that carry
    /// conversation content.
    static let stopPayload = """
    {"session_id":"abc-123",\
    "transcript_path":"/Users/x/.claude/projects/p/t.jsonl",\
    "cwd":"/Users/x/proj",\
    "permission_mode":"default",\
    "hook_event_name":"Stop",\
    "last_assistant_message":"CONTENT_ASSISTANT",\
    "stop_reason":"end_turn",\
    "prompt_id":"pid-9"}
    """

    /// A `PreToolUse` payload whose `tool_input` nests objects and arrays — the
    /// shape most likely to defeat a naive scanner.
    static let toolPayload = """
    {"session_id":"abc-123",\
    "hook_event_name":"PreToolUse",\
    "tool_name":"Bash",\
    "tool_input":{"command":"CONTENT_COMMAND","env":{"KEY":"CONTENT_NESTED"},\
    "args":[1,"CONTENT_ARRAY",{"deep":"CONTENT_DEEP"}]},\
    "tool_use_id":"toolu_1",\
    "cwd":"/Users/x/proj"}
    """

    @Test("Conversation and tool content never reach the wire", arguments: [
        stopPayload, toolPayload,
    ])
    func contentIsDropped(payload: String) {
        let emitted = line(for: payload)
        for secret in ["CONTENT_ASSISTANT", "CONTENT_COMMAND", "CONTENT_NESTED",
                       "CONTENT_ARRAY", "CONTENT_DEEP"] {
            #expect(!emitted.contains(secret), "leaked \(secret)")
        }
        // Whole keys we never want, content or not.
        for key in ["transcript_path", "last_assistant_message", "tool_input", "stop_reason"] {
            #expect(!emitted.contains(key), "leaked key \(key)")
        }
    }

    @Test("The metadata we do need is preserved")
    func metadataIsKept() {
        let emitted = line(for: Self.toolPayload)
        for expected in ["\"session_id\":\"abc-123\"", "\"hook_event_name\":\"PreToolUse\"",
                         "\"tool_name\":\"Bash\"", "\"tool_use_id\":\"toolu_1\"",
                         "\"cwd\":\"/Users/x/proj\"", "\"ppid\":4242",
                         "\"term_program\":\"Apple_Terminal\""] {
            #expect(emitted.contains(expected), "missing \(expected)")
        }
    }

    @Test("A content value that mimics JSON structure cannot break out")
    func adversarialContent() {
        // Braces, quotes, and escapes inside a skipped string must not confuse
        // the skipper into treating following content as allowlisted keys.
        let payload = """
        {"tool_input":{"command":"\\"},\\"session_id\\":\\"INJECTED\\",\\"x\\":\\"CONTENT_X"},\
        "session_id":"real-id","hook_event_name":"PreToolUse"}
        """
        let emitted = line(for: payload)
        #expect(!emitted.contains("INJECTED"))
        #expect(!emitted.contains("CONTENT_X"))
        #expect(emitted.contains("\"session_id\":\"real-id\""))
    }

    @Test("Truncated input yields a partial event rather than a failure")
    func truncationIsTolerated() {
        let payload = #"{"session_id":"abc","hook_event_name":"Stop","cwd":"/tmp"#
        let emitted = line(for: payload)
        #expect(emitted.contains("\"session_id\":\"abc\""))
        #expect(emitted.hasSuffix("}\n"))
    }

    @Test("Emitted lines are valid JSON and exactly one line")
    func emitsWellFormedNDJSON() throws {
        let emitted = line(for: Self.stopPayload)
        #expect(emitted.hasSuffix("\n"))
        #expect(emitted.dropLast().contains("\n") == false)
        let parsed = try JSONSerialization.jsonObject(with: Data(emitted.utf8)) as? [String: Any]
        #expect(parsed?["session_id"] as? String == "abc-123")
    }
}

// MARK: - Wire decoding

@Suite("Wire decoder")
struct WireDecoderTests {

    private func decode(_ json: String) throws -> AgentEvent {
        try EventWireDecoder.decode(line: Data(json.utf8))
    }

    @Test("Round-trips a line the hook actually produces")
    func roundTrip() throws {
        let emitted = line(for: HookPrivacyTests.stopPayload)
        let event = try decode(emitted)

        #expect(event.kind == .stop)
        #expect(event.provider == .claudeCode)
        #expect(event.providerSessionID == "abc-123")
        #expect(event.source == .hook)
        #expect(event.pid == 4242)
        #expect(event.termProgram == "Apple_Terminal")
        #expect(event.hostApplication == .terminal)
        #expect(event.timestamp.timeIntervalSince1970 == 1_770_000_000.123456)
    }

    @Test("Claude's prompt_id and Codex's turn_id both resolve to the turn")
    func turnIdentifierAliases() throws {
        let claude = try decode(#"{"v":1,"id":"a","provider":"claudeCode","hook_event_name":"Stop","prompt_id":"p1"}"#)
        #expect(claude.providerTurnID == "p1")

        let codex = try decode(#"{"v":1,"id":"b","provider":"codex","hook_event_name":"Stop","turn_id":"t1"}"#)
        #expect(codex.providerTurnID == "t1")
        #expect(codex.provider == .codex)
    }

    @Test("An unknown event is rejected rather than guessed at")
    func unknownEventRejected() {
        #expect(throws: EventWireDecoder.DecodeError.unknownEvent("FutureEvent")) {
            try decode(#"{"v":1,"id":"a","provider":"codex","hook_event_name":"FutureEvent"}"#)
        }
    }

    @Test("A future wire version is rejected rather than misread")
    func versionGuard() {
        #expect(throws: EventWireDecoder.DecodeError.unsupportedVersion(2)) {
            try decode(#"{"v":2,"id":"a","provider":"codex","hook_event_name":"Stop"}"#)
        }
    }

    @Test("Garbage on the socket is an error, not a crash")
    func rejectsGarbage() {
        #expect(throws: EventWireDecoder.DecodeError.notJSON) {
            try decode("not json at all")
        }
    }

    @Test("Stream splitting keeps a partial trailing line buffered")
    func splitsLines() {
        var buffer = Data(#"{"a":1}"# .utf8) + Data("\n".utf8) + Data(#"{"b":2}"#.utf8)
        let lines = EventWireDecoder.splitLines(&buffer)
        #expect(lines.count == 1)
        #expect(String(decoding: buffer, as: UTF8.self) == #"{"b":2}"#)
    }
}
