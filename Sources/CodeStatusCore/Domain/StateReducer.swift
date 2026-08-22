import Foundation

/// A recorded state change, carrying everything needed to explain and
/// de-duplicate it.
public struct Transition: Sendable, Equatable {
    public let sessionID: SessionID
    public let from: AgentState
    public let to: AgentState
    /// Idempotency key, inherited from the event that caused the change.
    /// Notifications key off this so one event can never notify twice.
    public let eventID: EventID
    public let source: EventSource
    public let confidence: StateConfidence
    public let occurredAt: Date
    /// Human-readable cause, for the diagnostics screen. Never contains content.
    public let reason: String
}

/// The result of offering one event to one session.
public struct Reduction: Sendable {
    /// The session after the event; unchanged when the event was ignored.
    public let session: AgentSession
    public let outcome: Outcome

    public enum Outcome: Sendable, Equatable {
        /// State moved. Notifications and HUD updates key off this.
        case stateChanged(Transition)
        /// Event accepted and timestamps refreshed, but the state is the same.
        case refreshed
        /// Arrived after a newer event for the same session; dropped.
        case ignoredOutOfOrder
        /// An event we have no mapping for — e.g. a `Notification` subtype that
        /// did not exist when this was written. Deliberately a no-op.
        case ignoredUnmapped
        /// The session already ended; nothing can revive it.
        case ignoredEnded
    }
}

/// The canonical state machine.
///
/// Pure and total: no IO, no clock reads, no shared state. Every transition is
/// a function of the current session and one event, which is what makes the
/// duplicate/out-of-order/replay behaviour testable against fixtures.
public enum StateReducer {

    /// The state an event implies, or `nil` if the event carries no state meaning.
    ///
    /// Returning `nil` rather than throwing is what keeps us forward compatible:
    /// when an agent adds a new event or notification type, we ignore it instead
    /// of misclassifying the session.
    public static func targetState(for event: AgentEvent) -> AgentState? {
        switch event.kind {
        case .sessionStart:
            // A fresh or resumed session is open and idle, waiting for a prompt.
            return .free

        case .userPromptSubmit:
            return .busy

        case .preToolUse, .postToolUse:
            return .busy

        case .permissionRequest:
            return .waitingForApproval

        case .permissionDenied:
            // Auto-deny already happened; the agent carries on.
            return .busy

        case .notification:
            switch event.notificationType {
            case .permissionPrompt: return .waitingForApproval
            case .idlePrompt: return .waitingForInput
            case .agentCompleted: return .free
            case nil: return nil
            }

        case .stop:
            // The *turn* finished. The session stays open and countable.
            return .free

        case .stopFailure:
            return .failed

        case .subagentStop:
            // A subagent finished; the main turn is still running.
            return .busy

        case .sessionEnd, .processExited:
            return .ended
        }
    }

    /// How much to trust a state derived from this event.
    public static func confidence(for event: AgentEvent) -> StateConfidence {
        switch event.source {
        case .hook:
            return .high
        case .process:
            // Process exit is a fact, not an inference — it is the one thing
            // process observation may assert about state.
            return event.kind == .processExited ? .high : .low
        case .reconciliation:
            return .medium
        }
    }

    private static func reason(for event: AgentEvent) -> String {
        switch event.kind {
        case .notification:
            let type = event.notificationType?.rawValue ?? "unknown"
            return "Notification(\(type)) via \(event.source.rawValue)"
        case .processExited:
            return "Process exited without SessionEnd"
        case .stopFailure:
            let type = event.errorType ?? "unknown"
            return "Turn failed (\(type))"
        default:
            return "\(event.kind.rawValue) via \(event.source.rawValue)"
        }
    }

    /// Apply one event to one session.
    public static func reduce(_ session: AgentSession, applying event: AgentEvent) -> Reduction {
        // Nothing revives an ended session — not even a straggler from before it
        // ended, and not a recycled pid landing on the same identity.
        guard session.state != .ended else {
            return Reduction(session: session, outcome: .ignoredEnded)
        }

        guard let target = targetState(for: event) else {
            return Reduction(session: session, outcome: .ignoredUnmapped)
        }

        guard session.clock.accepts(event) else {
            return Reduction(session: session, outcome: .ignoredOutOfOrder)
        }

        var updated = session
        updated.clock.advance(with: event)
        updated.lastEventAt = event.timestamp
        updated.stateConfidence = confidence(for: event)
        if event.source == .hook { updated.hasHookEvidence = true }
        applyEnrichment(from: event, to: &updated)

        guard target != session.state else {
            return Reduction(session: updated, outcome: .refreshed)
        }

        updated.previousState = session.state
        updated.state = target
        updated.stateChangedAt = event.timestamp
        if target != .failed { updated.lastError = nil }
        if target == .failed { updated.lastError = event.errorType }

        let transition = Transition(
            sessionID: session.id,
            from: session.state,
            to: target,
            eventID: event.id,
            source: event.source,
            confidence: updated.stateConfidence,
            occurredAt: event.timestamp,
            reason: reason(for: event)
        )
        return Reduction(session: updated, outcome: .stateChanged(transition))
    }

    /// Copies metadata an event carries onto the session, without ever
    /// overwriting a known value with a missing one.
    private static func applyEnrichment(from event: AgentEvent, to session: inout AgentSession) {
        if let value = event.providerSessionID { session.providerSessionID = value }
        if let value = event.providerTurnID { session.providerTurnID = value }
        if let value = event.cwd, !value.isEmpty { session.cwd = value }
        if let value = event.pid { session.pid = value }

        let host = event.hostApplication
        if host != .unknown {
            session.hostApplication = host
            session.hostBundleIdentifier = host.bundleIdentifier
            session.controlTarget.hostApplication = host
        }
        if let value = event.termSessionID, !value.isEmpty {
            session.controlTarget.termSessionID = value
        }
        if session.controlTarget.workspacePath == nil, let cwd = event.cwd, !cwd.isEmpty {
            session.controlTarget.workspacePath = cwd
        }
    }
}
