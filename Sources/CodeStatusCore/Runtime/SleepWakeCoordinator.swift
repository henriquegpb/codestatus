import Foundation

/// A power or lifecycle moment that invalidates what we believe about sessions.
///
/// The app layer translates `NSWorkspace.willSleepNotification` and
/// `didWakeNotification` into these. Keeping the vocabulary here rather than the
/// notification names keeps ``CodeStatusCore`` free of AppKit, which is what lets
/// the entire reconciliation policy be tested without a running app.
public enum PowerEvent: Sendable, Equatable {
    case willSleep(Date)
    case didWake(Date)
    /// The daemon started, or restarted after a crash. Indistinguishable from a
    /// wake as far as our knowledge of the world goes: events were missed.
    case daemonRestarted(Date)
}

/// Work the coordinator asks the app layer to perform.
///
/// Returned as data rather than executed here, so the policy — what happens after
/// a wake, and in what order — is a pure function that tests can assert on
/// directly instead of inferring from side effects.
public enum ReconciliationAction: Sendable, Equatable {
    case saveSnapshot(Date)
    case markAllReconnecting(Date)
    case drainSpool
    case sweepProcesses
}

/// Decides what happens around sleep, wake, and restart — and, crucially, what
/// the user is allowed to be interrupted about afterwards.
public struct SleepWakeCoordinator: Sendable {

    /// Five minutes: long enough that a notification still refers to something
    /// the user can act on, short enough that a replayed backlog from a two-hour
    /// sleep is silent.
    public static let defaultStaleThreshold: TimeInterval = 5 * 60

    public let staleThreshold: TimeInterval
    /// Wake is not delivered exactly once in practice — a wake can be followed by
    /// a display wake, and a restart can race a wake. Two reconciliation passes
    /// would double every process sweep for no new information.
    public let coalescingWindow: TimeInterval

    public private(set) var lastSleepAt: Date?
    public private(set) var lastReconciliationAt: Date?
    public private(set) var reconciliationCount = 0

    public init(
        staleThreshold: TimeInterval = SleepWakeCoordinator.defaultStaleThreshold,
        coalescingWindow: TimeInterval = 5
    ) {
        self.staleThreshold = staleThreshold
        self.coalescingWindow = coalescingWindow
    }

    public mutating func handle(_ event: PowerEvent) -> [ReconciliationAction] {
        switch event {
        case .willSleep(let date):
            lastSleepAt = date
            // Snapshot only. We deliberately take no IOPMAssertion here: holding
            // a wake lock to finish tidying would keep the Mac awake and burn
            // battery, which is a far worse outcome than losing a few seconds of
            // state that the spool will replay anyway.
            return [.saveSnapshot(date)]

        case .didWake(let date), .daemonRestarted(let date):
            if let last = lastReconciliationAt, abs(date.timeIntervalSince(last)) < coalescingWindow {
                // `abs`, because the clock is resynchronised against the RTC on
                // wake and can step backwards; a backwards step must not be read
                // as "the last pass is still in the future, skip forever".
                return []
            }
            lastReconciliationAt = date
            reconciliationCount += 1
            // Order matters. Reconnecting first, so nothing is displayed as
            // trustworthy while we catch up. Spool before sweep, because the
            // spool holds real hook evidence — including the `SessionEnd` of a
            // session that exited cleanly — and the sweep only needs to
            // synthesise an exit for whatever the spool did not already close.
            // The reverse order would end a session on process evidence and then
            // discard its spooled events as `ignoredEnded`, losing the metadata
            // they carry.
            return [.markAllReconnecting(date), .drainSpool, .sweepProcesses]
        }
    }

    /// Whether a state change is still worth interrupting the user for.
    ///
    /// This is the guard against the wake-time notification avalanche: after a
    /// two-hour sleep the spool replays every event the agents produced, and each
    /// one legitimately moves a session's state. Almost none of them are still
    /// worth a banner — "approval needed" from ninety minutes ago is noise, and
    /// the approval prompt itself has long since timed out.
    ///
    /// A transition to ``AgentState/ended`` is exempt: the user's mental model
    /// says that session is still running, and correcting that stays useful no
    /// matter how long ago it happened.
    ///
    /// Scope is staleness only. Whether a given target state deserves a
    /// notification at all is the notification layer's decision, not this one's.
    public func shouldNotify(for transition: Transition, now: Date) -> Bool {
        if transition.to == .ended { return true }
        return now.timeIntervalSince(transition.occurredAt) <= staleThreshold
    }

    /// How long the machine was away, once it has woken.
    public func sleepDuration(at now: Date) -> TimeInterval? {
        guard let lastSleepAt else { return nil }
        return now.timeIntervalSince(lastSleepAt)
    }
}
