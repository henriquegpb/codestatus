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
