import Foundation

/// Tokens billed for one assistant message, split the way pricing splits them.
///
/// The four categories are priced very differently — a cache read costs a tenth
/// of fresh input, a one-hour cache write twice as much — so they are never
/// collapsed into a single "tokens" number. Collapsing them is how a usage
/// display ends up off by an order of magnitude.
public struct TokenUsage: Sendable, Equatable, Codable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    /// Written with the default five-minute TTL, billed at 1.25x input.
    public var cacheWrite5m = 0
    /// Written with the one-hour TTL, billed at 2x input.
    public var cacheWrite1h = 0

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    /// Every token the request was billed for.
    ///
    /// `input` is the uncached remainder only, so the prompt's real size is this
    /// sum rather than `input` alone — a session that ran for hours can show a
    /// four-figure `input` and hundreds of millions of cache reads.
    public var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    public var isEmpty: Bool { total == 0 }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h
        )
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs = lhs + rhs
    }

    /// Everything that was in the prompt, cached or not.
    ///
    /// For a single assistant message this is the size of the context the model
    /// was handed — which is what makes it, and not ``total``, the figure a
    /// context gauge is built from. `output` is excluded deliberately: it was
    /// produced by the turn rather than fed into it.
    public var promptTokens: Int { input + cacheRead + cacheWrite5m + cacheWrite1h }

    /// Share of prompt tokens that were served from cache.
    ///
    /// `nil` rather than zero when nothing was read or written, so "no data yet"
    /// is never displayed as "a 0% hit rate", which reads as a problem.
    public var cacheHitRate: Double? {
        guard promptTokens > 0 else { return nil }
        return Double(cacheRead) / Double(promptTokens)
    }
}

/// One assistant message's usage, with what is needed to price and de-duplicate it.
public struct UsageRecord: Sendable, Equatable {
    /// The API's message id. Together with ``requestID`` this is what makes a
    /// record unique — see ``UsageLedger``.
    public let messageID: String?
    public let requestID: String?
    public let model: String
    public let timestamp: Date
    public let usage: TokenUsage

    public init(
        messageID: String?,
        requestID: String?,
        model: String,
        timestamp: Date,
        usage: TokenUsage
    ) {
        self.messageID = messageID
        self.requestID = requestID
        self.model = model
        self.timestamp = timestamp
        self.usage = usage
    }
}
