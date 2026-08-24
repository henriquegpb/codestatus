import AppKit
import CodeStatusCore
import SwiftUI

/// The menu bar item, and the only surface CodeStatus has.
///
/// It replaced a floating panel that sat around the notch. The panel was the
/// same information in a place the system does not manage: it had to be told
/// about display changes, Spaces, and full-screen apps, and it looked wrong on
/// every Mac without a camera housing to hide behind. The menu bar is where a
/// status item belongs, and macOS handles all of that for us.
@MainActor
final class MenuBarController {

    private let statusItem: NSStatusItem
    private let model: HUDModel
    private let popover = NSPopover()

    var onOpenSession: ((AgentSession) -> Void)?
    var onDismissSession: ((AgentSession) -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenDiagnostics: (() -> Void)?
    var onOpenPreferences: (() -> Void)?
    var onQuit: (() -> Void)?

    init(model: HUDModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        configurePopover()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        // We want to tell left from right click, which requires opting into both.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refresh()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // No contentSize: the hosting controller reports its own preferred size
        // and the popover follows it, so the window is exactly as tall as the
        // number of sessions. A fixed size left a small card marooned in a large
        // empty window whenever fewer sessions were running than it allowed for.
    }

    // MARK: - Rendering

    /// Redraws the title to match current counts.
    ///
    /// Rendered as text rather than an image so it stays legible at any menu bar
    /// height and inherits the system's dark/light treatment for free.
    func refresh() {
        guard let button = statusItem.button else { return }

        let groups: [(StateBucket, Int)] = [
            (.free, model.free), (.busy, model.busy),
            (.needsYou, model.needsYou), (.indeterminate, model.indeterminate),
        ].filter { $0.1 > 0 }

        if groups.isEmpty {
            button.attributedTitle = NSAttributedString(
                string: "●",
                attributes: [
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 11),
                ]
            )
            button.toolTip = model.unreportedCount > 0
                ? "CodeStatus — \(model.unreportedCount) session(s) found but not reporting"
                : "CodeStatus — no active agent sessions"
            return
        }

        let title = NSMutableAttributedString()
        for (index, group) in groups.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: "  ")) }
            title.append(NSAttributedString(
                string: "●",
                attributes: [
                    .foregroundColor: NSColor(group.0.tint),
                    .font: NSFont.systemFont(ofSize: 9),
                ]
            ))
            title.append(NSAttributedString(
                string: " \(group.1)",
                attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                ]
            ))
        }
        button.attributedTitle = title
        button.toolTip = groups
            .map { "\($0.1) \($0.0.label)" }
            .joined(separator: ", ")
    }

    // MARK: - Interaction

    @objc private func handleClick() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isRightClick {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let hosting = NSHostingController(
            rootView: HUDContentView(
                model: model,
                onOpen: { [weak self] in self?.onOpenSession?($0) },
                onDismiss: { [weak self] in self?.onDismissSession?($0) },
                onRefresh: { [weak self] in self?.onRefresh?() },
                // Both close the popover first: Settings opens a window that
                // would otherwise appear behind it, and a Quit that leaves the
                // popover on screen while the app dies looks like a crash.
                onOpenSettings: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.onOpenPreferences?()
                },
                onQuit: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.onQuit?()
                }
            )
            .frame(width: 320)
        )
        // Lets the popover size itself to the list rather than to a constant.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Without this the popover appears behind the frontmost app, because
        // CodeStatus is an accessory app that never activates on its own.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "CodeStatus", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let diagnostics = NSMenuItem(
            title: "Diagnostics…", action: #selector(openDiagnostics), keyEquivalent: "d"
        )
        diagnostics.target = self
        menu.addItem(diagnostics)

        let preferences = NSMenuItem(
            title: "Settings…", action: #selector(openPreferences), keyEquivalent: ","
        )
        preferences.target = self
        menu.addItem(preferences)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit CodeStatus", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Assigning and immediately clearing is the supported way to show a menu
        // from a status item that also handles clicks itself.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openDiagnostics() { onOpenDiagnostics?() }
    @objc private func openPreferences() { onOpenPreferences?() }
    @objc private func quit() { onQuit?() }
}
