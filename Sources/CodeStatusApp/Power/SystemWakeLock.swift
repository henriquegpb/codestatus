import Foundation
import IOKit.pwr_mgt
import os

/// Holds one `PreventUserIdleSystemSleep` assertion, and nothing more.
///
/// Two other assertion types look like they would do more, and neither does
/// from an app like this one. Both were measured, not assumed:
///
/// - `PreventSystemSleep` is accepted — `IOPMAssertionCreateWithName` returns
///   success and the assertion is listed against our pid — but `powerd` reports
///   it as **0** in the system-wide aggregate, i.e. recorded and not honoured,
///   absent a private entitlement we cannot obtain.
/// - `InternalPreventSleep`, the type `powerd` uses for its own lid handling,
///   behaves the same way and does not appear in the aggregate at all.
///
/// So this is the only lever available here, and it governs idle sleep only.
/// Closing the lid still sleeps the Mac. See ``WakeLockPolicy`` for why that is
/// a property of macOS rather than something left unfinished.
///
/// Display sleep is deliberately *not* held. Keeping the screen lit for an
/// agent working in a terminal nobody is looking at is pure waste, and the
/// panel is the single biggest draw on the machine.
@MainActor
final class SystemWakeLock {

    private var assertionID: IOPMAssertionID?
    private let logger = Logger(subsystem: "co.codestatus", category: "wakelock")

    /// What the assertion is called in `pmset -g assertions`.
    ///
    /// Chosen so that someone debugging a Mac that will not sleep finds the app
    /// responsible by name on the first try, without having to know that
    /// CodeStatus has anything to do with power.
    static let assertionName = "CodeStatus - keeping this Mac awake for a working agent"

    var isHeld: Bool { assertionID != nil }

    /// Takes the assertion, or does nothing if it is already held.
    func acquire() {
        guard assertionID == nil else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionName as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            // Not fatal and not worth interrupting anyone over: the Mac keeps
            // its normal sleep behaviour, which is the same outcome as the
            // feature being switched off.
            logger.error("could not take the wake lock: 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)")
            return
        }
        assertionID = id
        logger.info("wake lock acquired")
    }

    /// Releases the assertion, or does nothing if it is not held.
    func release() {
        guard let id = assertionID else { return }
        assertionID = nil
        let result = IOPMAssertionRelease(id)
        if result != kIOReturnSuccess {
            logger.error("wake lock release returned 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)")
        } else {
            logger.info("wake lock released")
        }
    }

    /// Releases on the way out.
    ///
    /// The kernel drops assertions belonging to a dead process anyway, so this
    /// is tidiness rather than the safety net. That an assertion cannot outlive
    /// its process is the reason this feature needs no watchdog — and the reason
    /// the lid-close route, which sets a persistent system-wide flag, would.
    deinit {
        if let id = assertionID { IOPMAssertionRelease(id) }
    }
}
