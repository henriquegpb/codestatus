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

    /// The events added for 2.1.247 bring keys the older ones never had, and
    /// three of them carry content: an MCP server's question text, the schema it
    /// asked against, and the answer the user typed into it.
    static let elicitationPayload = """
    {"session_id":"abc-123",\
    "hook_event_name":"ElicitationResult",\
    "mcp_server_name":"elicitprobe",\
    "mode":"form",\
    "message":"CONTENT_QUESTION",\
    "requested_schema":{"properties":{"confirm":{"title":"CONTENT_SCHEMA"}}},\
    "action":"accept",\
    "content":{"confirm":"CONTENT_ANSWER"},\
    "cwd":"/Users/x/proj"}
    """

    /// A failing tool's payload. `error` is the tool's own output.
    static let failurePayload = """
    {"session_id":"abc-123",\
    "hook_event_name":"PostToolUseFailure",\
    "tool_name":"Read",\
    "tool_use_id":"toolu_2",\
    "is_interrupt":false,\
    "duration_ms":12,\
    "error":"CONTENT_ERROR",\
    "tool_input":{"file_path":"CONTENT_PATH"},\
    "cwd":"/Users/x/proj"}
    """

    /// `PostToolBatch` summarises the batch in `tool_calls`, which nests inputs.
    static let batchPayload = """
    {"session_id":"abc-123",\
    "hook_event_name":"PostToolBatch",\
    "tool_calls":[{"tool_name":"Bash","tool_input":{"command":"CONTENT_BATCH"}}],\
    "cwd":"/Users/x/proj"}
    """

    @Test("Conversation and tool content never reach the wire", arguments: [
        stopPayload, toolPayload, elicitationPayload, failurePayload, batchPayload,
    ])
    func contentIsDropped(payload: String) {
        let emitted = line(for: payload)
        for secret in ["CONTENT_ASSISTANT", "CONTENT_COMMAND", "CONTENT_NESTED",
                       "CONTENT_ARRAY", "CONTENT_DEEP", "CONTENT_QUESTION", "CONTENT_SCHEMA",
                       "CONTENT_ANSWER", "CONTENT_ERROR", "CONTENT_PATH", "CONTENT_BATCH"] {
            #expect(!emitted.contains(secret), "leaked \(secret)")
        }
        // Whole keys we never want, content or not.
        for key in ["transcript_path", "last_assistant_message", "tool_input", "stop_reason",
                    "requested_schema", "tool_calls", "error", "message"] {
            #expect(!emitted.contains(key), "leaked key \(key)")
        }
    }

    /// The new events are acted on by name alone. Nothing they carry beyond the
    /// identifiers we already read is needed, so nothing else is allowlisted —
    /// which is what keeps `message`, `content`, and `error` structurally
    /// incapable of reaching the socket rather than merely unused.
    @Test("The new events add no new keys to the allowlist")
    func newEventsCarryNothingExtra() {
        let emitted = line(for: Self.elicitationPayload)
        for key in ["mcp_server_name", "mode", "action", "content"] {
            #expect(!emitted.contains(key), "leaked key \(key)")
        }
        #expect(emitted.contains("\"hook_event_name\":\"ElicitationResult\""))
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

    /// The payloads below are transcribed from a live 2.1.247 session driven in
    /// the same mode the VS Code extension uses, with a logging hook on every
    /// event — see docs/spikes/07-blocking-questions.md. Note what
    /// `PermissionRequest` does and does not carry: `tool_name` but no
    /// `tool_use_id`, which is why steps fall back to matching on the name.
    @Test("A real turn that ends in a question reaches the user, tools and all")
    func realTurnEndingInAQuestion() throws {
        let prompt = "ff4aaace-7b9f-45bb-b8fb-8e469712dc52"
        let session = "2f4e9635-986a-4113-95ce-1538c9c2c491"
        func wire(_ id: String, _ event: String, _ extra: String = "") -> String {
            #"{"v":1,"id":"\#(id)","provider":"claudeCode","hook_event_name":"\#(event)","#
                + #""session_id":"\#(session)","prompt_id":"\#(prompt)","ppid":4242\#(extra)}"#
        }

        let captured = [
            wire("1", "UserPromptSubmit"),
            wire("2", "PreToolUse", #","tool_name":"Bash","tool_use_id":"toolu_01W3XTBwdQ2kzDvy7AcoHbGg""#),
            wire("3", "PostToolUse", #","tool_name":"Bash","tool_use_id":"toolu_01W3XTBwdQ2kzDvy7AcoHbGg""#),
            wire("4", "PreToolUse", #","tool_name":"AskUserQuestion","tool_use_id":"toolu_01SxTntvBmV24XFyYSy3tR7r""#),
            wire("5", "PermissionRequest", #","tool_name":"AskUserQuestion""#),
            wire("6", "Notification", #","notification_type":"permission_prompt""#),
        ]

        var registry = SessionRegistry()
        for json in captured {
            _ = registry.ingest(try decode(json))
        }

        let result = try #require(registry.all.first)
        #expect(result.state == .waitingForInput)
        #expect(result.state.bucket == .needsYou)
    }

    @Test("Every event we ask Claude Code to send is one we can decode")
    func installedEventsAllDecode() {
        for event in ClaudeHookInstaller.events {
            #expect(HookEventKind(rawValue: event) != nil,
                    "registered \(event) but the decoder would reject it")
        }
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
