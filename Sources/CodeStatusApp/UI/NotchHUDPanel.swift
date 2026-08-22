import AppKit
import CodeStatusCore
import SwiftUI

extension ScreenDescription {
    /// Bridges AppKit's screen into the plain description the geometry works on.
    ///
    /// The bridge exists so that all the actual maths lives in `CodeStatusCore`
    /// as pure functions, testable with no display attached — which matters
    /// because the notch cases are exactly the ones a CI machine cannot exercise.
    init(_ screen: NSScreen) {
        self.init(
            frame: screen.frame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            backingScaleFactor: screen.backingScaleFactor
        )
    }
}

/// The floating window the HUD lives in.
///
/// A non-activating panel so it can never take focus away from the editor or
/// terminal the user is actually working in — the whole point is to be glanceable
/// without interrupting.
final class NotchHUDPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Above the menu bar, so the pill can sit in the notch itself.
        level = .statusBar
        // Follow the user between Spaces and sit above full-screen apps; without
        // .fullScreenAuxiliary the HUD would vanish exactly when someone is
        // heads-down in a full-screen editor waiting on an agent.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Excluded from screenshots of "all windows" and from Mission Control
        // cycling, so it behaves like system chrome rather than a document.
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
    }

    // A borderless panel refuses key status by default, which would make the
    // prompt field unusable later. Accepting key without *activating* is the
    // combination we want.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Holds notification tokens and unregisters them when it goes away.
///
/// A separate object because a `@MainActor` class cannot touch non-`Sendable`
/// state from its nonisolated `deinit` under Swift 6. `removeObserver` is
/// thread-safe, so doing the cleanup here is genuinely safe rather than merely
/// silencing the checker.
private final class ObserverBag: @unchecked Sendable {
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func add(_ token: NSObjectProtocol, to center: NotificationCenter) {
        tokens.append((center, token))
    }

    deinit {
        for entry in tokens { entry.center.removeObserver(entry.token) }
    }
}

/// Owns the HUD window: where it sits, when it is visible, and what shape it is in.
@MainActor
final class NotchHUDController {

    private var panel: NotchHUDPanel?
    private let model: HUDModel
    private var presentation: HUDPresentation = .compact
    private let observers = ObserverBag()

    /// Set false to disable the HUD entirely; the menu bar item remains.
    var isEnabled = true {
        didSet { refresh() }
    }

    init(model: HUDModel) {
        self.model = model
        observeEnvironment()
    }

    // MARK: - Environment

    private func observeEnvironment() {
        // Resolution changes, display connect/disconnect, and the main display
        // moving all arrive here; each invalidates our frame.
        let application = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.add(application, to: NotificationCenter.default)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let space = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.add(space, to: workspaceCenter)
    }

    /// The display the HUD belongs on: the one with the menu bar, since that is
    /// where the notch is and where the user's attention sits.
    private var targetScreen: NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: - Presentation

    func setExpanded(_ expanded: Bool) {
        let next = HUDPresentation(isExpanded: expanded)
        guard next != presentation else { return }
        presentation = next
        refresh()
    }

    /// Shows, hides, and repositions the panel to match current state.
    ///
    /// The HUD is visible only while at least one session is active — an empty
    /// HUD is clutter, not information.
    func refresh() {
        guard isEnabled, model.hasActiveSessions, let screen = targetScreen else {
            hide()
            return
        }

        let description = ScreenDescription(screen)
        let contentSize = model.contentSize(for: presentation)
        let frame = NotchGeometry.hudFrame(
            for: description,
            presentation: presentation,
            contentSize: contentSize
        )

        let panel = existingPanel(initialFrame: frame)
        if panel.frame != frame {
            // Never animate a reposition caused by the environment changing;
            // it reads as jitter rather than motion.
            panel.setFrame(frame, display: true, animate: shouldAnimate)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private var shouldAnimate: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func existingPanel(initialFrame: NSRect) -> NotchHUDPanel {
        if let panel { return panel }
        let panel = NotchHUDPanel(contentRect: initialFrame)
        let hosting = NSHostingView(
            rootView: HUDContentView(model: model)
                .environment(\.hudPresentation, presentation)
        )
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func teardown() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}
