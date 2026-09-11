import Foundation

/// How full a session's context was on its most recent turn, derived from the
/// transcript rather than reported by the agent.
///
/// This exists because the agent's own reading — `context_window.used_percentage`
/// — arrives only on the status line, and the status line is only ever rendered
/// by the terminal TUI. A session driven by the VS Code extension, the JetBrains
/// plugin, the SDK, or `claude -p` runs with `--output-format stream-json` and
/// never renders one, so for those sessions the agent's reading does not exist at
/// any point. The transcript, however, is written identically by every client,
/// and each assistant message records the tokens its prompt was billed for.
///
/// **A count, not a percentage, and that is deliberate.** The denominator is not
/// knowable here: transcripts record the model as `claude-opus-5` whether the
/// session was opened with the 200K window or the 1M one, and nothing else in the
/// record distinguishes them. Dividing by a guessed window would misreport a full
/// context as a fifth of one, or the reverse — the same failure mode
/// ``ModelPricing`` refuses when it returns `nil` for a model it has no rate for.
/// A number the reader can interpret beats a percentage they cannot trust.
public struct ContextEstimate: Sendable, Equatable {

    /// Tokens in the last prompt: fresh input plus every cached token replayed
    /// into it. This is the context the model was handed on that turn.
    public let tokens: Int
    public let model: String
    /// When the turn this was read from happened — not when it was scanned.
    public let observedAt: Date

    public init(tokens: Int, model: String, observedAt: Date) {
        self.tokens = tokens
        self.model = model
        self.observedAt = observedAt
    }

    /// Whether the session must have been opened with a long-context window.
    ///
    /// Inferred from evidence rather than configuration: a prompt larger than the
    /// standard window could not have fitted in it. Reported so a surface can say
    /// "long context" where it is certain, and stay quiet where it is not — the
    /// absence of this flag means unknown, never "standard".
    public var exceedsStandardWindow: Bool { tokens > Self.standardWindow }

    /// The window every current Claude model offers before a long-context request
    /// is opted into.
    public static let standardWindow = 200_000

    public func age(at now: Date) -> TimeInterval { now.timeIntervalSince(observedAt) }
}
