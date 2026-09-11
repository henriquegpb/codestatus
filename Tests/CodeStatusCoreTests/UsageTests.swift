import Testing
import Foundation
@testable import CodeStatusCore

private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

private func line(_ json: String) -> Data { Data(json.utf8) }

// MARK: - The privacy guarantee

@Suite("The scanner reads only what it is asked for")
struct PathScannerPrivacyTests {

    /// The reason this scanner exists. Transcripts hold entire conversations,
    /// and the guarantee has to be structural rather than a promise not to look.
    @Test("Conversation content is never captured, at any depth")
    func skipsContent() {
        let record = """
        {"type":"assistant","requestId":"req_1","timestamp":"2026-01-01T00:00:00.000Z",
        "message":{"id":"msg_1","model":"claude-opus-5",
        "content":[{"type":"text","text":"MY SECRET PROMPT"},
        {"type":"tool_use","input":{"command":"cat ~/.ssh/id_rsa","nested":{"deep":"SECRET"}}}],
        "usage":{"input_tokens":10,"output_tokens":20}}}
        """
        let found = PathScanner.scan(line(record), paths: [
            "message.id", "message.model", "message.usage.output_tokens",
        ])
        #expect(found["message.id"]?.stringValue == "msg_1")
        #expect(found["message.usage.output_tokens"]?.intValue == 20)

        // Nothing that was not asked for came back, under any key.
        let values = found.values.compactMap(\.stringValue).joined()
        #expect(!values.contains("SECRET"))
        #expect(!values.contains("id_rsa"))
        #expect(found.count == 3)
    }

    /// A transcript is appended to while we read it, so the last line is
    /// routinely half-written. That must cost nothing, not throw.
    @Test("A truncated line yields what was read, not a crash")
    func toleratesTruncation() {
        let found = PathScanner.scan(
            line(#"{"requestId":"req_1","message":{"id":"msg_1","usage":{"output_tokens":"#),
            paths: ["requestId", "message.id", "message.usage.output_tokens"]
        )
        #expect(found["requestId"]?.stringValue == "req_1")
        #expect(found["message.usage.output_tokens"] == nil)
    }

    @Test("Arrays and nested objects on the way past do not derail the walk")
    func skipsStructures() {
        let record = """
        {"a":[1,2,{"b":[{"c":"x"}]}],"escaped":"a \\" brace } here","wanted":42}
        """
        let found = PathScanner.scan(line(record), paths: ["wanted"])
        #expect(found["wanted"]?.intValue == 42)
    }

    /// A wanted path landing on an object must not be descended into blindly —
    /// that would copy whatever it contains.
    @Test("A wanted path that lands on an object captures nothing")
    func objectAtLeafIsNotCaptured() {
        let found = PathScanner.scan(
            line(#"{"leaf":{"secret":"NO"},"after":7}"#),
            paths: ["leaf", "after"]
        )
        #expect(found["leaf"] == nil)
        #expect(found["after"]?.intValue == 7)
    }
}

// MARK: - Claude Code

@Suite("Reading Claude Code transcripts")
struct ClaudeUsageParserTests {

    @Test("A full usage block is read, split by cache TTL")
    func readsUsage() {
        let record = """
        {"type":"assistant","requestId":"req_1","timestamp":"2026-01-01T12:00:00.000Z",
        "message":{"id":"msg_1","model":"claude-opus-5","usage":{
        "input_tokens":10,"output_tokens":238,"cache_read_input_tokens":26566,
        "cache_creation_input_tokens":8231,
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":8231}}}}
        """
        let parsed = ClaudeUsageParser.record(from: line(record))
        #expect(parsed?.model == "claude-opus-5")
        #expect(parsed?.usage.output == 238)
        #expect(parsed?.usage.cacheRead == 26566)
        #expect(parsed?.usage.cacheWrite1h == 8231)
        // Not double-counted from the flat field, which repeats the same tokens.
        #expect(parsed?.usage.cacheWrite5m == 0)
    }

    /// Older records carry only the flat field. Attributed to the 5-minute TTL
    /// because that is what a request gets when it does not ask for the other.
    @Test("Without the per-TTL breakdown, the flat field is used once")
    func flatCacheCreationFallback() {
        let record = """
        {"requestId":"r","timestamp":"2026-01-01T12:00:00.000Z","message":{"id":"m",
        "model":"claude-opus-5","usage":{"output_tokens":5,"cache_creation_input_tokens":900}}}
        """
        let parsed = ClaudeUsageParser.record(from: line(record))
        #expect(parsed?.usage.cacheWrite5m == 900)
        #expect(parsed?.usage.cacheWrite1h == 0)
    }

    @Test("Lines without a usage block are ignored")
    func ignoresNonAssistantLines() {
        #expect(ClaudeUsageParser.record(from: line(#"{"type":"user","message":"hi"}"#)) == nil)
        #expect(ClaudeUsageParser.record(from: line(#"{"type":"file-history-snapshot"}"#)) == nil)
    }

    @Test("An all-zero usage block is not a record")
    func ignoresEmptyUsage() {
        let record = """
        {"requestId":"r","message":{"id":"m","model":"<synthetic>",
        "usage":{"input_tokens":0,"output_tokens":0}}}
        """
        #expect(ClaudeUsageParser.record(from: line(record)) == nil)
    }
}

// MARK: - Codex

@Suite("Reading Codex rollout files")
struct CodexUsageParserTests {

    private static let tokenCount = """
    {"timestamp":"2026-09-10T20:17:31.137Z","type":"event_msg","payload":{"type":"token_count",
    "info":{"total_token_usage":{"input_tokens":792866,"cached_input_tokens":741376,
    "cache_write_input_tokens":0,"output_tokens":7358,"total_tokens":800224},
    "model_context_window":258400},
    "rate_limits":{"limit_id":"codex","primary":{"used_percent":7.5,"window_minutes":300,
    "resets_at":1789088436},"secondary":{"used_percent":13.0,"window_minutes":10080,
    "resets_at":1789508725},"credits":{"has_credits":false,"balance":"0"},"plan_type":"plus"}}}
    """

    /// Codex counts cached tokens inside `input_tokens` where Claude Code
    /// reports the uncached remainder. Without subtracting, the same tokens are
    /// counted twice and priced at ten times their rate.
    @Test("Cached tokens are taken out of the input total")
    func separatesCachedInput() {
        let reading = CodexUsageParser.reading(from: line(Self.tokenCount))
        #expect(reading?.usage.cacheRead == 741_376)
        #expect(reading?.usage.input == 792_866 - 741_376)
        #expect(reading?.usage.output == 7358)
    }

    /// The signal Claude Code has no equivalent of.
    @Test("Rate limit windows are read, fractions intact")
    func readsRateLimits() {
        let limits = CodexUsageParser.reading(from: line(Self.tokenCount))?.limits
        #expect(limits?.primary.usedPercent == 7.5)
        #expect(limits?.primary.windowLabel == "5h")
        #expect(limits?.secondary?.usedPercent == 13.0)
        #expect(limits?.secondary?.windowLabel == "weekly")
        #expect(limits?.planType == "plus")
        // The weekly window is further along, so it is the one worth showing.
        #expect(limits?.tightest.windowMinutes == 10080)
    }

    @Test("Other event types are ignored")
    func ignoresOtherEvents() {
        let other = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        #expect(CodexUsageParser.reading(from: line(other)) == nil)
    }
}

// MARK: - Pricing

@Suite("Pricing")
struct ModelPricingTests {

    @Test("Each token class is billed at its own rate")
    func pricesEachClass() {
        let pricing = ModelPricing(input: 5, output: 25)
        let usage = TokenUsage(
            input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
            cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000
        )
        // 5 + 25 + 0.5 + 6.25 + 10
        #expect(abs(pricing.cost(of: usage) - 46.75) < 0.0001)
    }

    /// The longest matching prefix has to win, or every Fable 5.1 token is
    /// priced as Fable 5 and its cheaper cache reads are lost.
    @Test("Model ids resolve by longest prefix")
    func longestPrefixWins() {
        #expect(ModelPricing.forModel("claude-fable-5-1")?.cacheReadMultiplier == 0.025)
        #expect(ModelPricing.forModel("claude-fable-5")?.cacheReadMultiplier == 0.1)
        // Transcripts carry dated ids for some models.
        #expect(ModelPricing.forModel("claude-haiku-4-5-20251001")?.input == 1)
    }

    @Test("An unknown model is nil, never a guessed rate")
    func unknownIsNil() {
        #expect(ModelPricing.forModel("some-future-model") == nil)
    }

    @Test("Locally generated messages are not reported as unpriced")
    func syntheticRecognised() {
        #expect(ModelPricing.isSynthetic("<synthetic>"))
        #expect(!ModelPricing.isSynthetic("claude-opus-5"))
    }
}

// MARK: - The ledger

@Suite("Aggregating usage")
struct UsageLedgerTests {

    private func record(
        _ id: String,
        request: String? = "req",
        model: String = "claude-opus-5",
        at offset: TimeInterval = 0,
        output: Int = 1000
    ) -> UsageRecord {
        UsageRecord(
            messageID: id, requestID: request, model: model,
            timestamp: t0.addingTimeInterval(offset),
            usage: TokenUsage(output: output)
        )
    }

    /// The failure this type exists to prevent. Resuming a session copies the
    /// prior history into a new transcript, so the same message is read twice.
    @Test("The same message counted twice lands once")
    func dedupes() {
        var ledger = UsageLedger()
        let first = ledger.add(record("msg_1"))
        let second = ledger.add(record("msg_1"))
        #expect(first)
        #expect(!second)
        #expect(ledger.recordCount == 1)
        #expect(ledger.totalUsage.output == 1000)
    }

    /// One message id can span several requests when a turn is retried, so the
    /// id alone is not identity.
    @Test("The same message id under a different request is counted again")
    func requestIDIsPartOfIdentity() {
        var ledger = UsageLedger()
        ledger.add(record("msg_1", request: "req_a"))
        ledger.add(record("msg_1", request: "req_b"))
        #expect(ledger.totalUsage.output == 2000)
    }

    /// Losing real usage is the worse error, so unidentifiable records count.
    @Test("Records with no identity at all are still counted")
    func anonymousRecordsCount() {
        var ledger = UsageLedger()
        ledger.add(record("x", request: nil).withoutIDs())
        ledger.add(record("y", request: nil).withoutIDs())
        #expect(ledger.totalUsage.output == 2000)
    }

    @Test("Totals are grouped by local day")
    func groupsByDay() {
        var ledger = UsageLedger(timeZone: TimeZone(identifier: "UTC")!)
        ledger.add(record("a", at: 0))
        ledger.add(record("b", at: 3600))
        ledger.add(record("c", at: 86_400 * 2))
        #expect(ledger.usage(on: t0).output == 2000)
        #expect(ledger.days().count == 2)
    }

    /// A model we cannot price must show up as a gap rather than quietly
    /// dragging the total down.
    @Test("Unknown models are recorded as unpriced")
    func flagsUnpriced() {
        var ledger = UsageLedger()
        ledger.add(record("a", model: "some-future-model"))
        ledger.add(record("b", model: "<synthetic>"))
        #expect(ledger.unpricedModels == ["some-future-model"])
    }

    @Test("Per-model totals come back with the biggest spend first")
    func ordersByModel() {
        var ledger = UsageLedger()
        ledger.add(record("a", model: "claude-haiku-4-5", output: 1_000_000))
        ledger.add(record("b", model: "claude-opus-5", output: 1_000_000))
        #expect(ledger.byModel().first?.model == "claude-opus-5")
    }
}

private extension UsageRecord {
    func withoutIDs() -> UsageRecord {
        UsageRecord(
            messageID: nil, requestID: nil, model: model,
            timestamp: timestamp, usage: usage
        )
    }
}

// MARK: - Context, for sessions that never render a status line

@Suite("Context read from the transcript")
struct ContextEstimateTests {

    /// The whole point of the derived reading: it is the prompt, so the tokens
    /// the turn produced must not be in it. Counting `output` would inflate the
    /// gauge by the length of the answer.
    @Test("The prompt is every cached and uncached input token, and no output")
    func promptExcludesOutput() {
        let usage = TokenUsage(
            input: 2, output: 900, cacheRead: 95_355, cacheWrite5m: 100, cacheWrite1h: 1_551
        )
        #expect(usage.promptTokens == 97_008)
        #expect(usage.total == usage.promptTokens + 900)
    }

    /// A long session shows a tiny `input` and enormous cache reads, so anything
    /// reading `input` alone would report a full context as nearly empty.
    @Test("A cache-heavy turn is measured by the whole prompt, not by input alone")
    func countsFromRealShape() {
        let record = """
        {"type":"assistant","requestId":"req_1","timestamp":"2026-09-10T12:00:00.000Z",
        "message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":2,
        "output_tokens":917,"cache_read_input_tokens":95355,
        "cache_creation_input_tokens":1551,
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1551}}}}
        """
        let parsed = ClaudeUsageParser.record(from: line(record))
        #expect(parsed?.usage.promptTokens == 96_908)
        #expect(parsed?.usage.input == 2)
    }

    /// Reported only where the evidence is conclusive. A prompt that fits inside
    /// the standard window says nothing about which window was opened, and must
    /// not be read as a claim that it was the small one.
    @Test("A long window is claimed only when the prompt could not have fitted the small one")
    func inferesWindowOnlyFromEvidence() {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let small = ContextEstimate(tokens: 96_908, model: "claude-opus-5", observedAt: now)
        let large = ContextEstimate(tokens: 350_000, model: "claude-opus-5", observedAt: now)
        #expect(small.exceedsStandardWindow == false)
        #expect(large.exceedsStandardWindow)
        // Exactly at the boundary still fits, so it proves nothing either.
        let boundary = ContextEstimate(
            tokens: ContextEstimate.standardWindow, model: "claude-opus-5", observedAt: now
        )
        #expect(boundary.exceedsStandardWindow == false)
    }

    /// Transcripts record `claude-opus-5` for both the 200K and the 1M window, so
    /// there is no percentage to derive. This test exists to fail loudly if
    /// someone later adds one — the denominator is not in the data.
    @Test("No percentage is offered, because the window size is not in the record")
    func offersNoPercentage() {
        let estimate = ContextEstimate(
            tokens: 96_908, model: "claude-opus-5",
            observedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        #expect(estimate.tokens == 96_908)
        #expect(estimate.model == "claude-opus-5")
    }
}
