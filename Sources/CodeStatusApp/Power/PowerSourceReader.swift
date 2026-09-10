import Foundation
import IOKit.ps

/// Reads battery charge and whether the Mac is plugged in.
///
/// Public `IOPowerSources` API, no privilege of any kind. Reports `nil` charge
/// rather than a guess when there is no internal battery or the description is
/// missing keys, because ``WakeLockPolicy`` treats unknown and empty very
/// differently and must not receive one dressed as the other.
struct PowerSourceReader {

    struct Snapshot: Equatable {
        /// `nil` on a desktop, or when the reading is unavailable.
        var percentage: Int?
        var isOnExternalPower: Bool
        var isLowPowerModeEnabled: Bool
    }

    func read() -> Snapshot {
        Snapshot(
            percentage: batteryPercentage(),
            isOnExternalPower: isOnExternalPower(),
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// Whether the Mac is running on anything other than its own battery.
    ///
    /// Asked of the *providing* source rather than by looking for an attached
    /// adapter: a connected but non-charging adapter still means the machine is
    /// not draining, and that is the question the policy is actually asking.
    private func isOnExternalPower() -> Bool {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() else {
            // No answer at all is likeliest on a desktop, which is never at risk
            // of running its battery down.
            return true
        }
        return (type as String) != kIOPSBatteryPowerValue
    }

    private func batteryPercentage() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            // Only the internal battery. A UPS or a Bluetooth mouse also appears
            // in this list, and a mouse at 5% is not a reason to let the Mac
            // sleep in the middle of a turn.
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int,
                  max > 0
            else { continue }
            return Int((Double(current) / Double(max) * 100).rounded())
        }
        return nil
    }
}
