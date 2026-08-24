import CodeStatusCore
import Foundation
import Observation
import SwiftUI

/// The view-facing projection of the session registry.
///
/// Every surface — HUD, menu bar, notifications, diagnostics — reads from the
/// one registry rather than keeping its own idea of state. This type is the only
/// bridge between that registry and SwiftUI, so there is exactly one place where
/// the truth becomes pixels.
@MainActor
@Observable
public final class HUDModel {

    public private(set) var sessions: [AgentSession] = []
    public private(set) var counts: [StateBucket: Int] = [:]
    /// Live sessions no agent has reported on yet. Shown as a footnote rather
    /// than as rows, so a running agent is never silently omitted but also never
    /// pretends to have a state.
    public private(set) var unreportedCount: Int = 0
    /// Why those sessions are silent, when we can tell. Set by the daemon,
    /// which is the only thing that knows when the hooks were installed.
    public private(set) var unreportedDiagnosis = UnreportedDiagnosis()
    /// Ticks so durations re-render without every view owning a timer.
    public private(set) var now: Date = Date()

    public init() {}

    public var hasActiveSessions: Bool {
        !sessions.isEmpty
    }

    /// Whether there is anything at all to show, reportable or not.
    public var hasAnything: Bool {
        !sessions.isEmpty || unreportedCount > 0
    }

    public var free: Int { counts[.free] ?? 0 }
    public var busy: Int { counts[.busy] ?? 0 }
    public var needsYou: Int { counts[.needsYou] ?? 0 }
    public var indeterminate: Int { counts[.indeterminate] ?? 0 }

    /// Replaces the snapshot. Called on every registry change.
    public func apply(
        _ registry: SessionRegistry,
        diagnosis: UnreportedDiagnosis = UnreportedDiagnosis(),
        now: Date = Date()
    ) {
        sessions = registry.visible
        counts = registry.counts()
        unreportedCount = registry.unreported.count
        unreportedDiagnosis = diagnosis
        self.now = now
    }

    public func tick(_ now: Date = Date()) {
        self.now = now
    }
}

// MARK: - Presentation of state

public extension AgentState {
    /// The HUD colour for this state.
    ///
    /// Deliberately not derived from `bucket` alone: `failed` shares the
    /// "needs you" bucket for counting, but reads better in the list with its
    /// own weight.
    var tint: Color {
        switch self {
        case .free: return .green
        case .busy: return .orange
        case .waitingForApproval, .waitingForInput: return Color(red: 1.0, green: 0.42, blue: 0.38)
        case .failed: return .red
        case .discovering, .reconnecting, .unknown: return .secondary
        case .ended: return .secondary
        }
    }

    /// Short label used in the session list.
    var label: String {
        switch self {
        case .discovering: return "Discovering"
        case .busy: return "Busy"
        case .free: return "Free"
        case .waitingForApproval: return "Needs approval"
        case .waitingForInput: return "Needs a reply"
        case .failed: return "Failed"
        case .reconnecting: return "Reconnecting"
        case .unknown: return "Unknown"
        case .ended: return "Ended"
        }
    }
}

public extension StateBucket {
    var tint: Color {
        switch self {
        case .free: return .green
        case .busy: return .orange
        case .needsYou: return Color(red: 1.0, green: 0.42, blue: 0.38)
        case .indeterminate, .gone: return .secondary
        }
    }

    var label: String {
        switch self {
        case .free: return "free"
        case .busy: return "busy"
        case .needsYou: return "needs you"
        case .indeterminate: return "unknown"
        case .gone: return ""
        }
    }
}

/// Formats a duration the way a glanceable HUD should: coarse, never jittery.
public enum DurationFormatter {
    public static func short(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m"
    }
}
