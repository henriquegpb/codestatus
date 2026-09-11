import Testing
@testable import HookCore

/// A payload shaped like the one Claude Code documents for `statusLine`,
/// including the parts we must walk past.
private let payload = """
{
  "session_id": "sess-abc",
  "session_name": "a name we must not read",
  "transcript_path": "/Users/x/.claude/projects/p/sess-abc.jsonl",
  "cwd": "/Users/x/secret-project",
  "model": { "id": "claude-opus-5", "display_name": "Opus 5" },
  "workspace": { "current_dir": "/Users/x/secret-project", "repo": { "owner": "acme" } },
  "version": "2.1.267",
  "context_window": {
    "total_input_tokens": 420000,
    "total_output_tokens": 900,
    "context_window_size": 1000000,
    "current_usage": { "input_tokens": 10, "cache_read_input_tokens": 419990 },
    "used_percentage": 42.5,
    "remaining_percentage": 57.5
  },
  "effort": { "level": "xhigh" },
  "rate_limits": {
    "five_hour": { "used_percentage": 7.5, "resets_at": 1789088436 },
    "seven_day": { "used_percentage": 13, "resets_at": 1789508725 }
  }
}
"""

private func scan(_ json: String) -> StatusMetrics {
    StatusScanner.scan(Array(json.utf8))
}

private func text(_ bytes: [UInt8]?) -> String? {
    bytes.map { String(decoding: $0, as: UTF8.self) }
}

@Suite("Reading the Claude Code status line payload")
struct StatusScanTests {

    /// The disambiguation this scanner exists for: `used_percentage` appears
    /// three times under three different parents, and confusing them would
    /// report a full plan as an empty one.
    @Test("Each used_percentage lands in its own window")
    func separatesWindows() {
        let metrics = scan(payload)
        #expect(metrics.fiveHourPercent == 7.5)
        #expect(metrics.sevenDayPercent == 13)
        #expect(metrics.contextPercent == 42.5)
    }

    @Test("Reset times and context size are read")
    func readsRest() {
        let metrics = scan(payload)
        #expect(metrics.fiveHourResetsAt == 1_789_088_436)
        #expect(metrics.sevenDayResetsAt == 1_789_508_725)
        #expect(metrics.contextSize == 1_000_000)
        #expect(metrics.contextInputTokens == 420_000)
        #expect(text(metrics.sessionID) == "sess-abc")
        #expect(text(metrics.modelID) == "claude-opus-5")
        #expect(text(metrics.effortLevel) == "xhigh")
    }

    /// The quota is not a reason to start collecting where someone works.
    @Test("Paths that are not asked for are never captured")
    func readsNothingElse() {
        let metrics = scan(payload)
        let captured = [
            text(metrics.sessionID), text(metrics.modelID), text(metrics.effortLevel),
        ].compactMap { $0 }.joined()
        #expect(!captured.contains("secret-project"))
        #expect(!captured.contains("transcript"))
        #expect(!captured.contains("acme"))
        #expect(!captured.contains("a name we must not read"))
    }

    /// Documented as present only for subscribers, and only after the first API
    /// response. An absent quota is an ordinary state and must not read as 0%.
    @Test("A payload without rate_limits reports nothing rather than zero")
    func absentQuotaIsNotZero() {
        let metrics = scan("""
        {"session_id":"s","model":{"id":"m"},
         "context_window":{"used_percentage":12}}
        """)
        #expect(metrics.fiveHourPercent == nil)
        #expect(metrics.sevenDayPercent == nil)
        #expect(metrics.contextPercent == 12)
        #expect(!metrics.isEmpty)
    }

    @Test("An empty payload is empty, not a plan at zero")
    func emptyIsEmpty() {
        #expect(scan("{}").isEmpty)
        #expect(scan("").isEmpty)
        #expect(scan("not json").isEmpty)
    }

    /// The status line runs on every render, so a truncated read must cost
    /// nothing rather than throw.
    @Test("A truncated payload yields what was read")
    func toleratesTruncation() {
        let metrics = scan("""
        {"session_id":"s","rate_limits":{"five_hour":{"used_percentage":9,"resets
        """)
        #expect(metrics.fiveHourPercent == 9)
        #expect(metrics.fiveHourResetsAt == nil)
    }

    /// A window can be absent on its own — the schema marks both as optional.
    @Test("One window present and the other absent")
    func partialWindows() {
        let metrics = scan("""
        {"rate_limits":{"five_hour":{"used_percentage":88,"resets_at":1789088436}}}
        """)
        #expect(metrics.fiveHourPercent == 88)
        #expect(metrics.sevenDayPercent == nil)
    }

    /// Percentages arrive fractional, and truncating one reports a plan as less
    /// spent than it is — the direction that matters.
    @Test("Fractions survive")
    func keepsFractions() {
        let metrics = scan(#"{"rate_limits":{"seven_day":{"used_percentage":99.9}}}"#)
        #expect(metrics.sevenDayPercent == 99.9)
    }
}
