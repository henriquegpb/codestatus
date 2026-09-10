import Foundation

/// Decides whether this Mac should be held awake, and says why.
///
/// Scope is deliberately narrow: **idle sleep only**. macOS has two separate
/// paths into sleep and this policy governs exactly one of them.
///
/// - *Idle sleep* is a software decision `powerd` makes after a period without
///   user activity. A `PreventUserIdleSystemSleep` assertion suppresses it, and
///   that is what this policy drives.
/// - *Clamshell sleep* is triggered by the lid sensor down a separate path that
///   ignores every assertion an unprivileged process can hold. Apple's own
///   documentation for the idle-sleep assertion type says so outright: "The
///   system may still sleep for lid close, Apple menu, low battery, or other
///   sleep reasons."
///
/// So closing the lid still sleeps, and no wording in this app may imply
/// otherwise. Suppressing the lid path needs `pmset disablesleep`, which needs
/// root — a different feature with a different risk profile, not a setting.
///
/// Returned as a decision rather than executed here, so the whole policy is a
/// pure function tests can assert on directly. The same reason
/// ``SleepWakeCoordinator`` returns actions instead of performing them.
public struct WakeLockPolicy: Sendable {

    /// Below this, the Mac is allowed to sleep even mid-turn.
    ///
    /// The failure this exists to prevent is opening a bag to a machine at 0%:
    /// a dead Mac loses the agent's work *and* everything else, which is
    /// strictly worse than the interrupted turn we were trying to avoid.
    public static let defaultBatteryFloor = 20

    /// When the lock should be taken.
    public enum Engagement: String, Codable, Sendable, CaseIterable {
        /// Hold only while an agent is genuinely mid-turn. The default: it is the
        /// only mode where the battery cost is paid for something.
        case whileAgentsWork
        /// Hold whenever the app is running, agents or not. Still floored by
        /// battery — "always" is a statement about idle sleep, not permission to
        /// discharge to zero.
        case always
    }

    /// Everything outside the session list that bears on the decision.
    public struct Conditions: Sendable, Equatable {
        public var isEnabled: Bool
        public var engagement: Engagement
        /// `nil` on a desktop, or when the reading is unavailable. Absent is not
        /// treated as empty: an unknown battery must not trigger the floor.
        public var batteryPercentage: Int?
        public var isOnExternalPower: Bool
        public var isLowPowerModeEnabled: Bool
        public var batteryFloor: Int

        public init(
            isEnabled: Bool = false,
            engagement: Engagement = .whileAgentsWork,
            batteryPercentage: Int? = nil,
            isOnExternalPower: Bool = false,
            isLowPowerModeEnabled: Bool = false,
            batteryFloor: Int = WakeLockPolicy.defaultBatteryFloor
        ) {
            self.isEnabled = isEnabled
            self.engagement = engagement
            self.batteryPercentage = batteryPercentage
            self.isOnExternalPower = isOnExternalPower
            self.isLowPowerModeEnabled = isLowPowerModeEnabled
            self.batteryFloor = batteryFloor
        }
    }

    /// Why the lock is held or released, in the app's own vocabulary.
    ///
    /// Enumerated rather than pre-formatted so the policy stays free of user
    /// strings and every reason is something a test can name. The HUD renders
    /// these verbatim — a wake lock the user cannot explain is one they turn off.
    public enum Reason: Sendable, Equatable {
        /// The setting is off.
        case disabled
        /// Engagement is `.always` and nothing vetoes it.
        case always
        /// This many sessions are mid-turn.
        case agentsWorking(Int)
        /// Nothing is mid-turn. Notably includes sessions *waiting on the user*:
        /// see ``workingSessions(in:)``.
        case noAgentsWorking
        /// Battery is at or under the floor, on battery power.
        case batteryLow(percentage: Int, floor: Int)
        /// The user asked macOS to prioritise battery, and we are on battery.
        case lowPowerMode
    }

    public enum Decision: Sendable, Equatable {
        case hold(Reason)
        case release(Reason)

        public var isHolding: Bool {
            if case .hold = self { return true }
            return false
        }

        public var reason: Reason {
            switch self {
            case .hold(let reason), .release(let reason): return reason
            }
        }
    }

    /// The sessions that justify holding the Mac awake.
    ///
    /// `busy` is the whole of it, plus one narrow exception. Three states are
    /// deliberately excluded even though a competitor's process-watching
    /// approach would count them:
    ///
    /// - `waitingForApproval` / `waitingForInput`: the agent is blocked on *the
    ///   user*. Nothing advances while the Mac stays awake, so holding here
    ///   spends battery to make no progress. This is the one thing that needs a
    ///   real lifecycle-hook state to get right — anything watching CPU or
    ///   process liveness cannot tell this apart from working, and so burns the
    ///   battery through every approval prompt.
    /// - `unknown`: a session found by scanning processes, with no hook evidence
    ///   of what it is doing. Holding on it would let one stale `node` process
    ///   keep a Mac awake indefinitely, and the user would have no way to see
    ///   why. Consistent with the registry, which refuses to count these too.
    ///
    /// `reconnecting` is the exception, and only when the session was busy
    /// before. After a wake every session is marked reconnecting until it is
    /// re-verified; dropping the lock in that window would let the Mac idle back
    /// to sleep underneath an agent that never stopped working. It resolves in
    /// seconds, and the pre-wake state is the best evidence available.
    public static func workingSessions(in sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter { session in
            guard session.hasHookEvidence else { return false }
            switch session.state {
            case .busy:
                return true
            case .reconnecting:
                return session.previousState == .busy
            case .discovering, .free, .waitingForApproval, .waitingForInput,
                 .failed, .unknown, .ended:
                return false
            }
        }
    }

    /// The decision, given the sessions and the machine's conditions.
    ///
    /// Order of precedence is the point of this function. The vetoes come first
    /// and apply to `.always` as much as to `.whileAgentsWork`, because a mode
    /// that could out-vote the battery floor would make the floor decorative.
    public static func decide(
        sessions: [AgentSession],
        conditions: Conditions
    ) -> Decision {
        guard conditions.isEnabled else { return .release(.disabled) }

        // On external power the battery reading says nothing about risk, so
        // neither veto applies. Both are about not stranding someone on a dead
        // machine, and a plugged-in Mac cannot be stranded.
        if !conditions.isOnExternalPower {
            if let percentage = conditions.batteryPercentage,
               percentage <= conditions.batteryFloor {
                return .release(.batteryLow(percentage: percentage, floor: conditions.batteryFloor))
            }
            // Low Power Mode is the user telling the *system* to favour battery.
            // Overriding it because our own toggle is on would make one of the
            // two settings a lie, and the system-wide one should win.
            if conditions.isLowPowerModeEnabled {
                return .release(.lowPowerMode)
            }
        }

        if conditions.engagement == .always { return .hold(.always) }

        let working = workingSessions(in: sessions).count
        return working > 0 ? .hold(.agentsWorking(working)) : .release(.noAgentsWorking)
    }
}
