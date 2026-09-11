import Foundation

/// What an agent reports about the plan it is spending and the context it is
/// filling.
///
/// This is the answer to the two questions a usage display actually gets asked —
/// *how much can I still spend* and *how full is this session* — and neither is
/// derivable from tokens. A cost estimate at list rates cannot tell you what is
/// left of a subscription, because the subscription's size is not published; the
/// agent, which is told by the API, is the only thing that knows.
///
/// Claude Code delivers it to the status line command on every render and never
/// writes it to disk, so ``HookCore`` captures it there and leaves it in the run
/// directory for the app. Codex publishes the same shape in its rollout files.
public struct PlanMetrics: Sendable, Equatable, Codable {

    /// One rolling quota window.
    public struct Window: Sendable, Equatable, Codable {
        public let usedPercent: Double
        public let resetsAt: Date?
        public let label: String

        public init(usedPercent: Double, resetsAt: Date?, label: String) {
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
            self.label = label
        }

        /// Rounded down, always. A plan reported as less spent than it is is the
        /// one error here that costs the user something.
        public var displayPercent: Int { Int(max(0, min(100, usedPercent))) }
    }

    public let sessionID: String
    public let provider: AgentProvider
    public let observedAt: Date
    public let model: String?

    public let fiveHour: Window?
    public let sevenDay: Window?

    /// How much of this session's context window is in use.
    public let contextPercent: Double?
    public let contextSize: Int?

    public init(
        sessionID: String,
        provider: AgentProvider,
        observedAt: Date,
        model: String? = nil,
        fiveHour: Window? = nil,
        sevenDay: Window? = nil,
        contextPercent: Double? = nil,
        contextSize: Int? = nil
    ) {
        self.sessionID = sessionID
        self.provider = provider
        self.observedAt = observedAt
        self.model = model
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.contextPercent = contextPercent
        self.contextSize = contextSize
    }

    /// Whether there is any quota reading at all.
    ///
    /// Claude Code documents `rate_limits` as present only for subscribers, and
    /// only after the first API response, so absence is an ordinary state — and
    /// must never be rendered as a plan at 0%.
    public var hasQuota: Bool { fiveHour != nil || sevenDay != nil }

    /// The window closest to being exhausted, which is the one worth showing.
    public var tightest: Window? {
        switch (fiveHour, sevenDay) {
        case let (five?, seven?): return five.usedPercent >= seven.usedPercent ? five : seven
        case let (five?, nil): return five
        case let (nil, seven?): return seven
        default: return nil
        }
    }

    /// How stale this reading is.
    ///
    /// The status line only fires while a session is open and rendering, so a
    /// reading is a last-known value rather than a live one. Surfaced so the app
    /// can say "6 min ago" instead of implying it is current.
    public func age(at now: Date) -> TimeInterval { now.timeIntervalSince(observedAt) }
}

/// Decodes what ``HookCore`` wrote for one session.
public enum PlanMetricsFile {

    /// The shape the hook writes. Flat and snake-cased because it is built by
    /// hand in a Foundation-free target.
    private struct Wire: Decodable {
        var session_id: String?
        var model: String?
        var five_hour_percent: Double?
        var five_hour_resets_at: Double?
        var seven_day_percent: Double?
        var seven_day_resets_at: Double?
        var context_percent: Double?
        var context_size: Double?
        var observed_at: Double?
    }

    public static func decode(_ data: Data, provider: AgentProvider = .claudeCode) -> PlanMetrics? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
              let sessionID = wire.session_id, !sessionID.isEmpty
        else { return nil }

        func window(_ percent: Double?, _ resets: Double?, _ label: String) -> PlanMetrics.Window? {
            guard let percent else { return nil }
            return PlanMetrics.Window(
                usedPercent: percent,
                resetsAt: resets.map { Date(timeIntervalSince1970: $0) },
                label: label
            )
        }

        return PlanMetrics(
            sessionID: sessionID,
            provider: provider,
            observedAt: Date(timeIntervalSince1970: wire.observed_at ?? 0),
            model: wire.model,
            fiveHour: window(wire.five_hour_percent, wire.five_hour_resets_at, "5h"),
            sevenDay: window(wire.seven_day_percent, wire.seven_day_resets_at, "weekly"),
            contextPercent: wire.context_percent,
            contextSize: wire.context_size.map(Int.init)
        )
    }
}

public extension RateLimitSnapshot.Window {
    /// Codex's own window, in the shared shape the UI draws.
    ///
    /// The two providers report the same thing through different files, and one
    /// rendering for both is what keeps them from looking like separate features.
    var asPlanWindow: PlanMetrics.Window {
        PlanMetrics.Window(usedPercent: usedPercent, resetsAt: resetsAt, label: windowLabel)
    }
}
