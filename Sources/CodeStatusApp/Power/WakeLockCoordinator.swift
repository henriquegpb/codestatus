import CodeStatusCore
import Foundation
import Observation
import os

/// Keeps the wake lock in step with what the agents are doing.
///
/// Three things can change the answer, so all three are observed rather than
/// polled: the session registry (an agent started or finished a turn), the power
/// source (unplugged, or the battery crossed the floor), and Low Power Mode.
/// Polling would either lag a turn boundary or spend a timer on a machine where
/// nothing is happening.
///
/// The decision itself lives in ``WakeLockPolicy``. This type only observes,
/// applies, and publishes — which is what keeps the policy testable without a
/// running app or a battery.
@MainActor
@Observable
final class WakeLockCoordinator {

    /// The current decision, for Settings to display.
    ///
    /// Published because a wake lock the user cannot see the state of is one
    /// they distrust and switch off. Same principle as the rest of the app:
    /// show what is true, including when the answer is "not holding".
    private(set) var decision: WakeLockPolicy.Decision = .release(.disabled)

    var isEnabled = false { didSet { reevaluate() } }
    var engagement: WakeLockPolicy.Engagement = .whileAgentsWork { didSet { reevaluate() } }
    var batteryFloor = WakeLockPolicy.defaultBatteryFloor { didSet { reevaluate() } }

    private let lock = SystemWakeLock()
    private let reader = PowerSourceReader()
    private let sessions: () -> [AgentSession]
    private let logger = Logger(subsystem: "co.codestatus", category: "wakelock")

    private var powerSourceSource: CFRunLoopSource?
    private var powerStateObserver: NSObjectProtocol?

    init(sessions: @escaping () -> [AgentSession]) {
        self.sessions = sessions
    }

    func start() {
        observePowerSource()
        observeLowPowerMode()
        reevaluate()
    }

    func stop() {
        if let source = powerSourceSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceSource = nil
        }
        if let observer = powerStateObserver {
            NotificationCenter.default.removeObserver(observer)
            powerStateObserver = nil
        }
        lock.release()
        decision = .release(.disabled)
    }

    /// Recomputes and applies. Cheap and idempotent, so callers may fire it
    /// freely on any registry change.
    func reevaluate() {
        let power = reader.read()
        let conditions = WakeLockPolicy.Conditions(
            isEnabled: isEnabled,
            engagement: engagement,
            batteryPercentage: power.percentage,
            isOnExternalPower: power.isOnExternalPower,
            isLowPowerModeEnabled: power.isLowPowerModeEnabled,
            batteryFloor: batteryFloor
        )
        let next = WakeLockPolicy.decide(sessions: sessions(), conditions: conditions)

        if next.isHolding { lock.acquire() } else { lock.release() }

        // Logged only on a change: this runs on every state transition of every
        // session, and a line per tool call would bury everything else.
        if next != decision {
            logger.info("wake lock \(next.isHolding ? "holding" : "released", privacy: .public): \(Self.logDescription(next.reason), privacy: .public)")
        }
        decision = next
    }

    // MARK: - Observation

    /// Fires when the adapter comes or goes, and as the charge changes.
    private func observePowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let coordinator = Unmanaged<WakeLockCoordinator>.fromOpaque(context)
                .takeUnretainedValue()
            MainActor.assumeIsolated { coordinator.reevaluate() }
        }, context)?.takeRetainedValue() else {
            logger.error("could not observe the power source; battery floor will lag")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceSource = source
    }

    private func observeLowPowerMode() {
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
    }

    // MARK: - Presentation

    /// One line saying what is happening and why, for the Settings row.
    ///
    /// Never speculative and never congratulatory: it reports the reason the
    /// policy actually returned.
    var statusDescription: String {
        switch decision {
        case .hold(let reason):
            switch reason {
            case .always:
                return "Holding: set to always"
            case .agentsWorking(let count):
                return count == 1
                    ? "Holding: 1 agent working"
                    : "Holding: \(count) agents working"
            case .disabled, .noAgentsWorking, .batteryLow, .lowPowerMode:
                return "Holding"
            }
        case .release(let reason):
            switch reason {
            case .disabled:
                return "Off: this Mac sleeps normally"
            case .noAgentsWorking:
                return "Not holding: no agent is working"
            case .batteryLow(let percentage, let floor):
                return "Not holding: battery \(percentage)%, below the \(floor)% floor"
            case .lowPowerMode:
                return "Not holding: Low Power Mode is on"
            case .always, .agentsWorking:
                return "Not holding"
            }
        }
    }

    private static func logDescription(_ reason: WakeLockPolicy.Reason) -> String {
        switch reason {
        case .disabled: return "disabled"
        case .always: return "always"
        case .agentsWorking(let count): return "\(count) working"
        case .noAgentsWorking: return "none working"
        case .batteryLow(let percentage, let floor): return "battery \(percentage) <= \(floor)"
        case .lowPowerMode: return "low power mode"
        }
    }
}
