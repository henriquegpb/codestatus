import Foundation

/// What a model costs per million tokens, and what that makes a usage total worth.
///
/// **This is an estimate at list API rates, and the app says so wherever it shows
/// a number.** It is not an invoice. A subscription that overflows into
/// pay-as-you-go, a negotiated rate, batch discounts, and free-tier credits all
/// move the real figure, and none of them are observable from a transcript. The
/// number is still worth showing: it is the only local signal for "which day did
/// I burn through my limit", and it is exactly comparable day over day.
public struct ModelPricing: Sendable, Equatable {

    /// Dollars per million tokens.
    public let input: Double
    public let output: Double

    /// Cache reads bill at a tenth of input on every current model except
    /// Claude Fable 5.1, which reads at 0.025x.
    public let cacheReadMultiplier: Double
    /// A five-minute cache write bills at 1.25x input, a one-hour write at 2x.
    public static let cacheWrite5mMultiplier = 1.25
    public static let cacheWrite1hMultiplier = 2.0

    public init(input: Double, output: Double, cacheReadMultiplier: Double = 0.1) {
        self.input = input
        self.output = output
        self.cacheReadMultiplier = cacheReadMultiplier
    }

    public func cost(of usage: TokenUsage) -> Double {
        let perToken = 1_000_000.0
        return Double(usage.input) / perToken * input
            + Double(usage.output) / perToken * output
            + Double(usage.cacheRead) / perToken * input * cacheReadMultiplier
            + Double(usage.cacheWrite5m) / perToken * input * Self.cacheWrite5mMultiplier
            + Double(usage.cacheWrite1h) / perToken * input * Self.cacheWrite1hMultiplier
    }

    // MARK: - The table

    /// Rates as published for first-party API access.
    ///
    /// Keyed by prefix rather than by exact id: transcripts carry dated ids for
    /// some models (`claude-haiku-4-5-20251001`) and bare ids for others, and a
    /// model released after this build must fall back to something sane rather
    /// than silently price at zero.
    private static let table: [(prefix: String, pricing: ModelPricing)] = [
        ("claude-fable-5-1", ModelPricing(input: 10, output: 50, cacheReadMultiplier: 0.025)),
        ("claude-mythos-5-1", ModelPricing(input: 10, output: 50)),
        ("claude-fable-5", ModelPricing(input: 10, output: 50)),
        ("claude-opus-5", ModelPricing(input: 5, output: 25)),
        ("claude-opus-4-8", ModelPricing(input: 5, output: 25)),
        ("claude-opus-4-7", ModelPricing(input: 5, output: 25)),
        ("claude-opus-4-6", ModelPricing(input: 5, output: 25)),
        ("claude-sonnet-5", ModelPricing(input: 2, output: 10)),
        ("claude-sonnet-4-6", ModelPricing(input: 3, output: 15)),
        ("claude-haiku-4-5", ModelPricing(input: 1, output: 5)),
        // Codex models are deliberately absent. Their rates are not Anthropic's
        // to publish and were not verified against a source, and a made-up rate
        // in a table that looks authoritative is worse than a stated gap — the
        // caller reports Codex as unpriced instead. What Codex *does* give us,
        // and Claude Code does not, is how much of the plan's quota is spent;
        // that is reported directly and needs no rate at all.
    ]

    /// The rate for a model id, or `nil` when it is not one we know.
    ///
    /// Nil rather than a guessed default, so the caller can say "not priced"
    /// instead of quietly reporting a number that is wrong. A usage display that
    /// invents a rate is worse than one that admits a gap.
    public static func forModel(_ id: String) -> ModelPricing? {
        let lowered = id.lowercased()
        // Longest prefix first, so `claude-fable-5-1` is not matched by
        // `claude-fable-5`.
        return table
            .filter { lowered.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }?
            .pricing
    }

    /// Models that carry no cost at all, and should not be reported as unpriced.
    ///
    /// Claude Code writes `<synthetic>` for messages it generates locally — an
    /// interrupt notice, a hook result — which have a usage block of zeros.
    public static func isSynthetic(_ id: String) -> Bool {
        id.hasPrefix("<") || id.isEmpty || id == "unknown"
    }
}
