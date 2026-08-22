import Testing
import Foundation
@testable import CodeStatusCore

// MARK: - Fixtures

private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

private struct EventFactory {
    var provider: AgentProvider = .claudeCode
    var turn: String? = "turn-1"
    private var counter = 0

    mutating func make(
        _ kind: HookEventKind,
        notification: NotificationType? = nil,
        turn overrideTurn: String?? = nil,
        source: EventSource = .hook,
        at offset: TimeInterval = 0,
        id explicitID: String? = nil,
        cwd: String? = nil,
        termProgram: String? = nil,
        errorType: String? = nil
    ) -> AgentEvent {
        counter += 1
        let resolvedTurn = overrideTurn ?? turn
        return AgentEvent(
            id: EventID(explicitID ?? "e\(counter)"),
            provider: provider,
            kind: kind,
            source: source,
            timestamp: t0.addingTimeInterval(offset),
            providerSessionID: "sess-abc",
            providerTurnID: resolvedTurn,
            notificationType: notification,
            errorType: errorType,
            cwd: cwd,
            termProgram: termProgram
        )
    }
}

private func newSession(state: AgentState = .discovering) -> AgentSession {
    var s = AgentSession(id: SessionID("claudeCode:sess-abc"), provider: .claudeCode, now: t0, sourceAdapter: "test")
    s.state = state
    return s
}

/// Applies events in sequence, returning the final session and every outcome.
@discardableResult
private func run(_ session: AgentSession, _ events: [AgentEvent]) -> (AgentSession, [Reduction.Outcome]) {
    var current = session
    var outcomes: [Reduction.Outcome] = []
    for event in events {
        let result = StateReducer.reduce(current, applying: event)
        current = result.session
        outcomes.append(result.outcome)
    }
    return (current, outcomes)
}

private func isStateChange(_ outcome: Reduction.Outcome) -> Bool {
    if case .stateChanged = outcome { return true }
    return false
}

// MARK: - Happy path

@Suite("State machine — normal lifecycle")
struct NormalLifecycleTests {

    @Test("A full turn walks discovering → free → busy → free")
    func fullTurn() {
        var f = EventFactory()
        let (session, outcomes) = run(newSession(), [
            f.make(.sessionStart, turn: .some(nil)),
            f.make(.userPromptSubmit, at: 1),
            f.make(.preToolUse, at: 2),
            f.make(.postToolUse, at: 3),
            f.make(.stop, at: 4),
        ])

        #expect(session.state == .free)
        #expect(session.previousState == .busy)
        // start→free, prompt→busy, stop→free are changes; the tool events refresh.
        #expect(outcomes.map(isStateChange) == [true, true, false, false, true])
        #expect(outcomes[2] == .refreshed)
        #expect(session.stateChangedAt == t0.addingTimeInterval(4))
    }

    @Test("Stop means the turn ended, not the session — it stays countable")
    func stopKeepsSessionActive() {
        var f = EventFactory()
        let (session, _) = run(newSession(state: .busy), [f.make(.stop)])
        #expect(session.state == .free)
        #expect(session.state.isActive)
        #expect(session.state.bucket == .free)
    }

    @Test("A second turn is ordered after the first")
    func secondTurn() {
        var f = EventFactory()
        let (session, outcomes) = run(newSession(), [
            f.make(.userPromptSubmit, turn: .some("turn-1")),
            f.make(.stop, turn: .some("turn-1"), at: 1),
            f.make(.userPromptSubmit, turn: .some("turn-2"), at: 2),
        ])
        #expect(session.state == .busy)
        #expect(outcomes.allSatisfy(isStateChange))
    }
}

// MARK: - Attention states

@Suite("State machine — states that need the user")
struct AttentionTests {

    @Test("PermissionRequest blocks on approval")
    func permissionRequest() {
        var f = EventFactory()
        let (session, _) = run(newSession(state: .busy), [f.make(.permissionRequest)])
        #expect(session.state == .waitingForApproval)
        #expect(session.state.needsAttention)
        #expect(session.state.bucket == .needsYou)
    }

    @Test("Approving lets the tool run, returning the session to busy")
    func approvalThenToolRuns() {
        var f = EventFactory()
        let (session, _) = run(newSession(state: .busy), [
            f.make(.permissionRequest),
            f.make(.postToolUse, at: 1),
        ])
        #expect(session.state == .busy)
    }

    @Test("Notification subtypes map to distinct states", arguments: [
        (NotificationType.permissionPrompt, AgentState.waitingForApproval),
        (NotificationType.idlePrompt, AgentState.waitingForInput),
        (NotificationType.agentCompleted, AgentState.free),
    ])
    func notificationSubtypes(type: NotificationType, expected: AgentState) {
        var f = EventFactory()
        let (session, _) = run(newSession(state: .busy), [f.make(.notification, notification: type)])
        #expect(session.state == expected)
    }

    @Test("A failed turn is never counted as free")
    func failureIsNotFree() {
        var f = EventFactory()
        let (session, _) = run(newSession(state: .busy), [
            f.make(.stopFailure, errorType: "rate_limit"),
        ])
        #expect(session.state == .failed)
        #expect(session.state.bucket == .needsYou)
        #expect(session.state.bucket != .free)
        #expect(session.lastError == "rate_limit")
    }

    @Test("Recovering from failure clears the recorded error")
    func failureCleared() {
        var f = EventFactory()
        let (session, _) = run(newSession(state: .busy), [
            f.make(.stopFailure, errorType: "overloaded"),
            f.make(.userPromptSubmit, turn: .some("turn-2"), at: 1),
        ])
        #expect(session.state == .busy)
        #expect(session.lastError == nil)
    }
}

// MARK: - Idempotency and ordering

@Suite("State machine — duplicates, ordering, and terminal events")
struct OrderingTests {

    @Test("A late PreToolUse cannot knock a session out of waitingForApproval")
    func lateToolEventDoesNotClobberApproval() {
        var f = EventFactory()
        let (session, outcomes) = run(newSession(state: .busy), [
            f.make(.permissionRequest, at: 2),
            f.make(.preToolUse, at: 1), // arrives late, belongs before the request
        ])
        #expect(session.state == .waitingForApproval)
        #expect(outcomes.last == .ignoredOutOfOrder)
    }

    @Test("A late PostToolUse cannot resurrect busy after Stop")
    func lateToolEventDoesNotClobberStop() {
        var f = EventFactory()
        let (session, outcomes) = run(newSession(state: .busy), [
            f.make(.stop, at: 5),
            f.make(.postToolUse, at: 4),
        ])
        #expect(session.state == .free)
        #expect(outcomes.last == .ignoredOutOfOrder)
    }

    @Test("Replaying an identical event stream is a no-op after the first pass")
    func replayIsIdempotent() {
        var f = EventFactory()
        let events = [
            f.make(.userPromptSubmit),
            f.make(.preToolUse, at: 1),
            f.make(.stop, at: 2),
        ]
        let (once, _) = run(newSession(), events)
        let (twice, outcomes) = run(once, events)

        #expect(once.state == twice.state)
        #expect(once.stateChangedAt == twice.stateChangedAt)
        // Every replayed event is either stale or a no-op; none change state.
        #expect(!outcomes.contains(where: isStateChange))
    }

    @Test("SessionEnd wins even when it arrives out of order")
    func terminalEventAlwaysWins() {
        var f = EventFactory()
        let (session, _) = run(newSession(state: .busy), [
            f.make(.stop, at: 10),
            f.make(.sessionEnd, turn: .some(nil), at: 0),
        ])
        #expect(session.state == .ended)
    }

    @Test("Process exit ends a session that never sent SessionEnd")
    func processExitEndsSession() {
        var f = EventFactory()
        let (session, outcomes) = run(newSession(state: .busy), [
            f.make(.processExited, turn: .some(nil), source: .process, at: 3),
        ])
        #expect(session.state == .ended)
        #expect(isStateChange(outcomes[0]))
        // Exit is observed fact, not inference.
        #expect(session.stateConfidence == .high)
    }

    @Test("Nothing revives an ended session")
    func endedIsFinal() {
        var f = EventFactory()
        let (session, outcomes) = run(newSession(state: .ended), [
            f.make(.userPromptSubmit),
            f.make(.stop, at: 1),
        ])
        #expect(session.state == .ended)
        #expect(outcomes.allSatisfy { $0 == .ignoredEnded })
    }
}

// MARK: - Forward compatibility

@Suite("State machine — unknown input")
struct ForwardCompatibilityTests {

    @Test("An unrecognised Notification subtype is ignored, not guessed at")
    func unknownNotificationIsNoOp() {
        var f = EventFactory()
        // `nil` here stands for a subtype that did not exist when this shipped,
        // such as the `agent_needs_input` the spec expected but Claude Code
        // does not actually emit.
        let (session, outcomes) = run(newSession(state: .busy), [
            f.make(.notification, notification: nil),
        ])
        #expect(session.state == .busy)
        #expect(outcomes == [.ignoredUnmapped])
    }

    @Test("Quiet time never changes state on its own")
    func silenceDoesNotChangeState() {
        var f = EventFactory()
        // A single long-running tool call: busy at t0, still busy an hour later
        // with no intervening events.
        let (session, _) = run(newSession(), [f.make(.userPromptSubmit)])
        #expect(session.state == .busy)

        let muchLater = t0.addingTimeInterval(3600)
        #expect(session.duration(at: muchLater) == 3600)
        // There is deliberately no API that turns elapsed time into a state.
        #expect(session.state == .busy)
    }
}

// MARK: - Enrichment

@Suite("State machine — metadata enrichment")
struct EnrichmentTests {

    @Test("TERM_PROGRAM identifies the host application")
    func hostFromTermProgram() {
        var f = EventFactory()
        let (session, _) = run(newSession(), [
            f.make(.sessionStart, turn: .some(nil), cwd: "/Users/x/proj", termProgram: "Apple_Terminal"),
        ])
        #expect(session.hostApplication == .terminal)
        #expect(session.hostBundleIdentifier == "com.apple.Terminal")
        #expect(session.cwd == "/Users/x/proj")
    }

    @Test("A later event missing metadata never erases what we already knew")
    func enrichmentIsAdditive() {
        var f = EventFactory()
        let (session, _) = run(newSession(), [
            f.make(.sessionStart, turn: .some(nil), cwd: "/Users/x/proj", termProgram: "Apple_Terminal"),
            f.make(.userPromptSubmit, at: 1), // carries no cwd or term program
        ])
        #expect(session.cwd == "/Users/x/proj")
        #expect(session.hostApplication == .terminal)
    }
}

// MARK: - Deduplicator

@Suite("Event deduplication")
struct DeduplicatorTests {

    @Test("The same id is admitted exactly once")
    func admitsOnce() {
        var dedup = EventDeduplicator(capacity: 8)
        let first = dedup.admit(EventID("a"))
        let second = dedup.admit(EventID("a"))
        #expect(first)
        #expect(!second)
        #expect(dedup.contains(EventID("a")))
    }

    @Test("The window is bounded and evicts oldest first")
    func boundedWindow() {
        var dedup = EventDeduplicator(capacity: 3)
        for id in ["a", "b", "c"] { _ = dedup.admit(EventID(id)) }
        #expect(dedup.count == 3)

        _ = dedup.admit(EventID("d"))
        #expect(dedup.count == 3)
        #expect(!dedup.contains(EventID("a")))   // evicted
        #expect(dedup.contains(EventID("d")))
    }

    @Test("Delivering a duplicated event twice yields one state change")
    func duplicateDeliveryNotifiesOnce() {
        var f = EventFactory()
        let stop = f.make(.stop, id: "stop-once")
        var dedup = EventDeduplicator()
        var session = newSession(state: .busy)
        var changes = 0

        for _ in 0..<3 {
            guard dedup.admit(stop.id) else { continue }
            let result = StateReducer.reduce(session, applying: stop)
            session = result.session
            if isStateChange(result.outcome) { changes += 1 }
        }

        #expect(changes == 1)
        #expect(session.state == .free)
    }
}
