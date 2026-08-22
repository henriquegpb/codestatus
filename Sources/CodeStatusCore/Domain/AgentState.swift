import Foundation

/// The canonical lifecycle state of an agent session.
///
/// This is the single vocabulary the whole app speaks. There are deliberately no
/// `isBusy` / `isDone` / `needsApproval` booleans anywhere else: every surface
/// (HUD, menu bar, notifications, diagnostics) derives what it shows from this.
///
/// Absence of evidence is represented explicitly (`unknown`, `reconnecting`)
/// rather than guessed at. We never infer completion from quiet CPU, missing
/// output, or a backgrounded window.
public enum AgentState: String, Codable, Sendable, CaseIterable {
    /// Found, but not yet identified well enough to classify.
    case discovering

    /// Prompt received: thinking, generating, running tools, or handling results.
    case busy

    /// The turn finished and the session is still open, ready for another prompt.
    ///
    /// Note this is *not* the end of the session — see ``ended``.
    case free

    /// Blocked waiting for the user to approve or deny a tool.
    case waitingForApproval

    /// Blocked waiting for the user to answer a question or supply information.
    case waitingForInput

    /// The turn ended in error, or execution could not continue.
    case failed

    /// The Mac woke, the daemon restarted, or events were missed; state is being
    /// reconciled and is not yet trustworthy.
    case reconnecting

    /// A session exists but there is not enough evidence to classify it.
    case unknown

    /// The session is over and should leave the counters after a short transition.
    case ended
}

public extension AgentState {
    /// Whether this state requires the user to come back and do something.
    ///
    /// `failed` counts here — a failure must never be presented as "free".
    var needsAttention: Bool {
        switch self {
        case .waitingForApproval, .waitingForInput, .failed:
            return true
        case .discovering, .busy, .free, .reconnecting, .unknown, .ended:
            return false
        }
    }

    /// Whether the session still occupies a slot in the counters.
    var isActive: Bool {
        self != .ended
    }

    /// Whether no further transition can move the session out of this state.
    var isTerminal: Bool {
        self == .ended
    }

    /// The bucket this state is counted under in the HUD.
    var bucket: StateBucket {
        switch self {
        case .free: return .free
        case .busy: return .busy
        case .waitingForApproval, .waitingForInput, .failed: return .needsYou
        case .discovering, .reconnecting, .unknown: return .indeterminate
        case .ended: return .gone
        }
    }
}

/// The coarse grouping the HUD counts by.
public enum StateBucket: String, Sendable, CaseIterable {
    case free
    case busy
    case needsYou
    case indeterminate
    /// Not counted.
    case gone
}

/// How much we trust the current state.
///
/// Confidence decays with silence; state does not. A session quiet for ten
/// minutes mid-tool-call is still `busy` — only our confidence in that drops.
public enum StateConfidence: Int, Codable, Sendable, Comparable {
    /// Derived from process observation alone.
    case low = 0
    /// Derived from a hook, but stale or partially reconciled.
    case medium = 1
    /// Derived from a recent official hook event.
    case high = 2

    public static func < (lhs: StateConfidence, rhs: StateConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
