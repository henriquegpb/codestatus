import AppKit
import CodeStatusCore
import SwiftUI

/// Shows first run, once.
///
/// "Once" is recorded only after the user reaches the end, so quitting halfway
/// through brings the flow back rather than leaving someone with an app that
/// silently watches nothing because they never got to the install step.
@MainActor
final class OnboardingWindowController {

    private static let completionKey = "co.codestatus.onboardingCompleted"

    private var window: NSWindow?
    private let model: OnboardingModel
    private let onCompletion: () -> Void

    init(notifications: NotificationCoordinator, onCompletion: @escaping () -> Void) {
        model = OnboardingModel(notifications: notifications)
        self.onCompletion = onCompletion
    }

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completionKey)
    }

    func showIfNeeded() {
        guard !Self.hasCompleted else { return }
        show()
    }

    /// Reopens Setup from the beginning, whatever state the flow was left in.
    ///
    /// The model outlives the window, so without this the second visit reopened
    /// on whatever screen the first one ended on — for a completed run, the
    /// final "Ready" page with one Done button, no Back, and no re-detection.
    /// That made Settings › Open Setup a dead end for exactly the users who
    /// needed it: the ones whose agent was missed the first time.
    ///
    /// From the beginning, and not from the agent list, because Setup is this
    /// app's one recovery path and any step in it can be the broken one. The
    /// notification permission is the case that proves it: denied at first run,
    /// never asked again by macOS, and reachable from a flow entered at
    /// detection only by pressing Back — a strange thing to ask of someone who
    /// just opened a setup flow. Three Continue clicks is not friction worth
    /// reintroducing a dead end for.
    func reopen() {
        show()
        model.restart()
    }

    /// Fed by the daemon, so the verification screen updates live.
    func markVerified(_ provider: AgentProvider) {
        model.markVerified(provider)
    }

    @discardableResult
    func repairConnectedAgents() -> [AgentProvider] {
        model.repairConnectedAgents()
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to CodeStatus"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentViewController = NSHostingController(
                rootView: OnboardingView(model: model) { [weak self] in self?.finish() }
            )
            self.window = window
        }
        // An accessory app has to activate explicitly, or its window opens
        // behind whatever the user is looking at.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completionKey)
        window?.close()
        onCompletion()
    }
}
