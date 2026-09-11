import Foundation

/// Reads one line of a Claude Code transcript.
///
/// The transcript is JSONL, one record per line, of which only assistant
/// messages carry a `usage` block. Every other line — the user's prompts, tool
/// results, file snapshots, attachments — is walked past by ``PathScanner``
/// without its bytes being copied.
public enum ClaudeUsageParser {

    private static let paths = [
        "timestamp",
        "requestId",
        "message.id",
        "message.model",
        "message.usage.input_tokens",
        "message.usage.output_tokens",
        "message.usage.cache_read_input_tokens",
        "message.usage.cache_creation_input_tokens",
        "message.usage.cache_creation.ephemeral_5m_input_tokens",
        "message.usage.cache_creation.ephemeral_1h_input_tokens",
    ]

    public static func record(from line: Data, now: Date = Date()) -> UsageRecord? {
        // Cheap gate before the scan. Most lines in a transcript are not
        // assistant messages, and this skips them without parsing at all.
        guard line.count > 2, containsUsageKey(line) else { return nil }

        let found = PathScanner.scan(line, paths: paths)
        guard !found.isEmpty else { return nil }

        let output = found["message.usage.output_tokens"]?.intValue ?? 0
        let input = found["message.usage.input_tokens"]?.intValue ?? 0
        let cacheRead = found["message.usage.cache_read_input_tokens"]?.intValue ?? 0

        // The per-TTL breakdown is authoritative when present. The flat
        // `cache_creation_input_tokens` is the fallback for older records, and
        // is attributed to the five-minute TTL because that is the default a
        // request gets when it does not ask for the one-hour one.
        let write5m = found["message.usage.cache_creation.ephemeral_5m_input_tokens"]?.intValue
        let write1h = found["message.usage.cache_creation.ephemeral_1h_input_tokens"]?.intValue
        let flatWrite = found["message.usage.cache_creation_input_tokens"]?.intValue ?? 0
        let resolved5m = (write5m == nil && write1h == nil) ? flatWrite : (write5m ?? 0)

        let usage = TokenUsage(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite5m: resolved5m,
            cacheWrite1h: write1h ?? 0
        )
        guard !usage.isEmpty else { return nil }

        return UsageRecord(
            messageID: found["message.id"]?.stringValue,
            requestID: found["requestId"]?.stringValue,
            model: found["message.model"]?.stringValue ?? "unknown",
            timestamp: found["timestamp"]?.stringValue.flatMap(ISO8601.date(from:)) ?? now,
            usage: usage
        )
    }

    /// Whether the line mentions a usage block at all, by byte search.
    private static func containsUsageKey(_ line: Data) -> Bool {
        line.range(of: Data("\"usage\"".utf8)) != nil
    }
}

/// Reads one line of a Codex rollout file.
///
/// Codex reports usage differently and, unlike Claude Code, also reports what is
/// left of the plan's quota — see ``RateLimitSnapshot``. Its `token_count`
/// events carry a running total for the session rather than a per-message
/// delta, so the last one seen wins instead of accumulating.
public enum CodexUsageParser {

    private static let paths = [
        "timestamp",
        "payload.type",
        "payload.info.total_token_usage.input_tokens",
        "payload.info.total_token_usage.cached_input_tokens",
        "payload.info.total_token_usage.cache_write_input_tokens",
        "payload.info.total_token_usage.output_tokens",
        "payload.rate_limits.primary.used_percent",
        "payload.rate_limits.primary.window_minutes",
        "payload.rate_limits.primary.resets_at",
        "payload.rate_limits.secondary.used_percent",
        "payload.rate_limits.secondary.window_minutes",
        "payload.rate_limits.secondary.resets_at",
        "payload.rate_limits.plan_type",
        "payload.rate_limits.credits.balance",
    ]

    public struct Reading: Sendable, Equatable {
        /// The session's running total, not a delta.
        public var usage: TokenUsage
        public var limits: RateLimitSnapshot?
        public var timestamp: Date
    }

    public static func reading(from line: Data, now: Date = Date()) -> Reading? {
        guard line.range(of: Data("\"token_count\"".utf8)) != nil else { return nil }
        let found = PathScanner.scan(line, paths: paths)
        guard found["payload.type"]?.stringValue == "token_count" else { return nil }

        let cached = found["payload.info.total_token_usage.cached_input_tokens"]?.intValue ?? 0
        let rawInput = found["payload.info.total_token_usage.input_tokens"]?.intValue ?? 0
        // Codex counts cached tokens inside `input_tokens`, where Claude Code
        // reports the uncached remainder. Subtracted so the two providers mean
        // the same thing by "input" and can be added together honestly.
        let usage = TokenUsage(
            input: max(0, rawInput - cached),
            output: found["payload.info.total_token_usage.output_tokens"]?.intValue ?? 0,
            cacheRead: cached,
            cacheWrite5m: found["payload.info.total_token_usage.cache_write_input_tokens"]?
                .intValue ?? 0
        )

        func window(_ prefix: String) -> RateLimitSnapshot.Window? {
            guard let used = found["\(prefix).used_percent"]?.doubleValue else { return nil }
            return RateLimitSnapshot.Window(
                usedPercent: used,
                windowMinutes: found["\(prefix).window_minutes"]?.intValue ?? 0,
                resetsAt: found["\(prefix).resets_at"]?.doubleValue
                    .map { Date(timeIntervalSince1970: $0) }
            )
        }

        let limits = window("payload.rate_limits.primary").map { primary in
            RateLimitSnapshot(
                primary: primary,
                secondary: window("payload.rate_limits.secondary"),
                planType: found["payload.rate_limits.plan_type"]?.stringValue,
                creditBalance: found["payload.rate_limits.credits.balance"]?.stringValue
            )
        }

        return Reading(
            usage: usage,
            limits: limits,
            timestamp: found["timestamp"]?.stringValue.flatMap(ISO8601.date(from:)) ?? now
        )
    }
}

/// How much of a plan's quota is gone, and when the window resets.
///
/// Only Codex reports this. Claude Code publishes nothing equivalent anywhere on
/// disk — searched for across transcripts and configuration — so any surface
/// showing this must be able to say "not available" for a provider rather than
/// implying a full quota.
public struct RateLimitSnapshot: Sendable, Equatable {

    public struct Window: Sendable, Equatable {
        public let usedPercent: Double
        public let windowMinutes: Int
        public let resetsAt: Date?

        public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date?) {
            self.usedPercent = usedPercent
            self.windowMinutes = windowMinutes
            self.resetsAt = resetsAt
        }

        /// "5h" / "weekly", the way the plan describes itself.
        public var windowLabel: String {
            switch windowMinutes {
            case ..<60: return "\(windowMinutes)m"
            case 10080: return "weekly"
            case let minutes where minutes % 1440 == 0: return "\(minutes / 1440)d"
            default: return "\(windowMinutes / 60)h"
            }
        }
    }

    public let primary: Window
    public let secondary: Window?
    public let planType: String?
    public let creditBalance: String?

    public init(
        primary: Window,
        secondary: Window? = nil,
        planType: String? = nil,
        creditBalance: String? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.creditBalance = creditBalance
    }

    /// The window closest to being exhausted, which is the one worth showing.
    public var tightest: Window {
        guard let secondary else { return primary }
        return secondary.usedPercent > primary.usedPercent ? secondary : primary
    }
}

/// Timestamp parsing shared by both parsers.
///
/// Both providers write ISO 8601 with fractional seconds, but a record written
/// on a second boundary omits them, so both shapes are tried.
enum ISO8601 {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func date(from string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }
}
