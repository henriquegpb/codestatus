import AppKit
import CodeStatusCore
import UserNotifications
import os

/// Decides whether the user is already looking at the session that just changed.
///
/// Kept as a protocol so the coordinator has no dependency on AppleScript or on
/// Automation permission, and so the policy is testable with a stub.
@MainActor
public protocol NotificationSuppressing {
    /// True when a notification for this session would tell the user something
    /// they can already see.
    func isUserLookingAt(_ session: AgentSession) -> Bool
}

/// Turns state transitions into sound and macOS notifications, exactly once each.
///
/// The hard requirement from the spec is one notification per transition, never
/// a duplicate and never a burst after waking. Two mechanisms enforce that: the
/// transition's `eventID` becomes the notification request identifier, so the
/// system itself collapses repeats; and stale transitions are filtered by
/// ``SleepWakeCoordinator`` before they ever reach here.
@MainActor
public final class NotificationCoordinator {

    /// User-facing settings. Defaults match the spec's recommended behaviour.
    public struct Preferences: Sendable, Equatable {
        public var soundEnabled = true
        /// Only make noise when the user is not already in the host app.
        public var onlyWhenHostUnfocused = true
        public var notificationsEnabled = true
        /// Set by the "mute for a while" action; nil means not muted.
        public var mutedUntil: Date?

        public init() {}

        public func isMuted(at now: Date) -> Bool {
            guard let mutedUntil else { return false }
            return now < mutedUntil
        }
    }

    public var preferences = Preferences()

    private let center = UNUserNotificationCenter.current()
    private let suppression: NotificationSuppressing?
    private let logger = Logger(subsystem: "co.codestatus", category: "notifications")
    private var didRequestAuthorization = false

    /// Notification identifiers we have already posted, so a replayed event
    /// cannot produce a second banner even if it reaches us twice.
    private var posted = EventDeduplicator(capacity: 512)

    public init(suppression: NotificationSuppressing? = nil) {
        self.suppression = suppression
    }

    // MARK: - Authorization

    /// Asks for permission, once.
    ///
    /// On macOS 26 this silently fails for an unsigned bundle — the request
    /// resolves but nothing is ever delivered. Diagnostics surfaces
    /// ``authorizationStatus()`` for exactly that reason.
    @discardableResult
    public func requestAuthorization() async -> Bool {
        guard !didRequestAuthorization else { return await isAuthorized() }
        didRequestAuthorization = true
        registerCategories()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    private func isAuthorized() async -> Bool {
        switch await authorizationStatus() {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    private func registerCategories() {
        let open = UNNotificationAction(
            identifier: Action.open.rawValue,
            title: "Open Session",
            options: [.foreground]
        )
        // Deliberately only "Open". Approving or denying from a notification
        // would mean typing into a terminal we do not control, which can land
        // in the wrong place — see docs/spikes/03-terminal-tab-mapping.md.
        let category = UNNotificationCategory(
            identifier: Category.session.rawValue,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    public enum Category: String { case session = "co.codestatus.session" }
    public enum Action: String { case open = "co.codestatus.open" }

    // MARK: - Posting

    /// Handles one transition, posting at most one notification.
    public func handle(_ transition: Transition, session: AgentSession, now: Date = Date()) {
        guard let content = Self.content(for: transition, session: session) else { return }
        guard shouldDeliver(transition, session: session, now: now) else { return }
        guard posted.admit(transition.eventID) else { return }

        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.categoryIdentifier = Category.session.rawValue
        notification.userInfo = ["sessionID": session.id.rawValue]
        if preferences.soundEnabled && !preferences.isMuted(at: now) {
            notification.sound = content.tone.sound
        }

        // The event id as request identifier means even a delivery we failed to
        // filter is collapsed by the system rather than shown twice.
        let request = UNNotificationRequest(
            identifier: transition.eventID.rawValue,
            content: notification,
            trigger: nil
        )
        center.add(request) { [logger] error in
            if let error {
                logger.error("notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Posts a one-off notice about CodeStatus's own setup.
    ///
    /// Deliberately not routed through ``handle(_:session:now:)``: none of the
    /// session rules apply. "Only when the host is unfocused" is about not
    /// interrupting someone watching a session, and there is no session here;
    /// applying it would drop the notice exactly when the user is at their Mac
    /// and able to act on it. Muting and the master switch still hold, because
    /// those are the user saying they want quiet.
    ///
    /// `identifier` collapses repeats: the same notice re-posted on a later
    /// launch replaces the old one rather than stacking.
    public func postSetupNotice(title: String, body: String, identifier: String, now: Date = Date()) {
        guard preferences.notificationsEnabled, !preferences.isMuted(at: now) else { return }

        let notification = UNMutableNotificationContent()
        notification.title = title
        notification.body = body
        let request = UNNotificationRequest(identifier: identifier, content: notification, trigger: nil)
        center.add(request) { [logger] error in
            if let error {
                logger.error("setup notice failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func shouldDeliver(_ transition: Transition, session: AgentSession, now: Date) -> Bool {
        guard preferences.notificationsEnabled else { return false }
        guard !preferences.isMuted(at: now) else { return false }

        // Never interrupt someone who is already watching the session that
        // changed. Checked per tab rather than per app: being in a *different*
        // Terminal tab should still notify.
        if preferences.onlyWhenHostUnfocused, let suppression,
           suppression.isUserLookingAt(session) {
            return false
        }
        return true
    }

    // MARK: - Content

    enum Tone {
        /// A turn finished and nothing is blocked.
        case completion
        /// Something needs the user before work can continue.
        case attention

        var sound: UNNotificationSound {
            switch self {
            case .completion: return .default
            case .attention: return .defaultCritical
            }
        }
    }

    struct Content {
        let title: String
        let body: String
        let tone: Tone
    }

    /// Builds the user-facing text.
    ///
    /// Metadata only: agent, project, state, and a safe action. Never a summary
    /// of what the agent said — reading the transcript to produce one is exactly
    /// the privacy line this project does not cross.
    static func content(for transition: Transition, session: AgentSession) -> Content? {
        let agent = session.provider.displayName
        let project = session.displayName

        switch transition.to {
        case .free:
            // Only interesting as the end of actual work.
            guard transition.from == .busy else { return nil }
            return Content(
                title: "\(agent) finished in \(project)",
                body: "Ready for another prompt.",
                tone: .completion
            )

        case .waitingForApproval:
            return Content(
                title: "\(agent) needs your approval in \(project)",
                body: "Open the session to review the command.",
                tone: .attention
            )

        case .waitingForInput:
            return Content(
                title: "\(agent) is waiting for you in \(project)",
                body: "Open the session to answer.",
                tone: .attention
            )

        case .failed:
            return Content(
                title: "\(agent) stopped with an error in \(project)",
                body: "Open the session to see what happened.",
                tone: .attention
            )

        case .ended:
            // Only when it died mid-flight; a clean exit is not news.
            guard transition.source == .process, transition.from != .free else { return nil }
            return Content(
                title: "\(agent) stopped unexpectedly",
                body: "The session in \(project) is no longer running.",
                tone: .attention
            )

        case .busy, .discovering, .reconnecting, .unknown:
            return nil
        }
    }
}

/// Suppresses notifications for the session the user is currently looking at.
///
/// Falls back to a per-application check whenever the exact tab cannot be
/// determined — no Automation permission, no TTY, or a host we cannot script.
@MainActor
public struct FrontmostSessionSuppressor: NotificationSuppressing {
    private let selectedTTYProvider: () -> String?

    public init(selectedTTYProvider: @escaping () -> String?) {
        self.selectedTTYProvider = selectedTTYProvider
    }

    public func isUserLookingAt(_ session: AgentSession) -> Bool {
        guard let bundleID = session.hostApplication.bundleIdentifier,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
        else { return false }

        // Host app is frontmost. If we can resolve the selected tab, require an
        // exact match; otherwise fall back to "the app is focused".
        guard let sessionTTY = session.tty, let selected = selectedTTYProvider() else {
            return true
        }
        return sessionTTY == selected
    }
}
