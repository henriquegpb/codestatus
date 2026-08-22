import AppKit
import CodeStatusCore
import SwiftUI

/// Hosts the diagnostics window on demand.
///
/// CodeStatus is an accessory app with no windows of its own, so opening one
/// means temporarily behaving like a regular app: without activating, the window
/// would appear behind whatever the user is working in and look like it failed
/// to open.
@MainActor
final class DiagnosticsWindowController {

    private var window: NSWindow?
    private let builder: DiagnosticsBuilder
    private let onSendTestEvent: () -> Void

    init(builder: DiagnosticsBuilder, onSendTestEvent: @escaping () -> Void) {
        self.builder = builder
        self.onSendTestEvent = onSendTestEvent
    }

    func show() {
        Task { await present() }
    }

    private func present() async {
        let report = await builder.build()
        let view = DiagnosticsView(
            report: report,
            onRefresh: { [weak self] in self?.show() },
            onSendTestEvent: onSendTestEvent
        )

        if let window {
            window.contentViewController = NSHostingController(rootView: view)
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "CodeStatus Diagnostics"
            window.contentViewController = NSHostingController(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
