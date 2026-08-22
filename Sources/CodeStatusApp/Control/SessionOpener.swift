import AppKit
import CodeStatusCore
import os

/// Brings the user back to a session.
///
/// Reading a Terminal tab's `tty` is a public, scriptable property, so this
/// needs no Accessibility and no private API — only the user's Automation
/// permission, which is requested lazily on the first click rather than during
/// onboarding.
///
/// It never writes to a terminal. Selecting a tab is the whole contract: sending
/// text or keystrokes to a session we do not control can land in the wrong place
/// once the agent has moved on, which is why "Send prompt" stays disabled for
/// sessions CodeStatus did not start.
@MainActor
final class SessionOpener {

    /// AppleScript's error code for a denied Automation grant. Worth matching
    /// exactly: it is the difference between "the user said no, fall back" and
    /// "something is broken", and without it a denial looks like a dead button.
    private static let automationDeniedCode = -1743

    private let logger = Logger(subsystem: "co.codestatus", category: "opener")

    func open(_ session: AgentSession) {
        switch session.hostApplication {
        case .terminal:
            openTerminal(session)
        case .vsCode:
            openEditor(session, bundleIdentifier: HostApplication.vsCode.bundleIdentifier)
        case .iTerm, .ghostty, .warp:
            // Recognised hosts we can raise but cannot address a tab in yet.
            activate(bundleIdentifier: session.hostApplication.bundleIdentifier)
        case .unknown:
            openWorkspaceFolder(session)
        }
    }

    // MARK: - Terminal

    private func openTerminal(_ session: AgentSession) {
        guard let tty = session.tty ?? session.controlTarget.tty else {
            activate(bundleIdentifier: HostApplication.terminal.bundleIdentifier)
            return
        }

        // Escaped defensively even though a tty is always of the form
        // /dev/ttysNNN: it reaches us from process inspection, and interpolating
        // unvalidated text into a script is a habit worth not having.
        let escaped = tty.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escaped)" then
                        set selected tab of w to t
                        set frontmost of w to true
                        activate
                        return true
                    end if
                end repeat
            end repeat
            activate
            return false
        end tell
        """

        let result = run(script)
        if case .denied = result {
            // Right application, wrong tab. Better than doing nothing, and the
            // spec accepts it explicitly as the fallback.
            logger.info("automation denied; activating Terminal without tab selection")
            activate(bundleIdentifier: HostApplication.terminal.bundleIdentifier)
        }
    }

    /// The TTY of the frontmost Terminal tab, used to decide whether the user is
    /// already looking at a session before we notify them about it.
    ///
    /// Returns nil when Terminal is not running, has no window, or Automation is
    /// denied — all of which mean "we cannot tell", and the caller falls back to
    /// a per-application check.
    func frontmostTerminalTTY() -> String? {
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == HostApplication.terminal.bundleIdentifier
        }) else { return nil }

        let script = """
        tell application "Terminal"
            if (count of windows) is 0 then return ""
            return tty of selected tab of front window
        end tell
        """
        guard case .success(let value) = run(script), let tty = value, !tty.isEmpty else {
            return nil
        }
        return tty
    }

    // MARK: - Editors

    private func openEditor(_ session: AgentSession, bundleIdentifier: String?) {
        // Open the folder so the right window comes forward. We deliberately do
        // not try to address the extension's own session list: that would mean
        // depending on internal commands or its private storage.
        if let path = session.controlTarget.workspacePath ?? session.gitRoot ?? session.cwd,
           let appURL = bundleIdentifier.flatMap({
               NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
           }) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [URL(fileURLWithPath: path)], withApplicationAt: appURL,
                configuration: configuration
            ) { [logger] _, error in
                if let error {
                    logger.error("open failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }
        activate(bundleIdentifier: bundleIdentifier)
    }

    private func openWorkspaceFolder(_ session: AgentSession) {
        guard let path = session.gitRoot ?? session.cwd else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func activate(bundleIdentifier: String?) {
        guard let bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    // MARK: - AppleScript

    private enum ScriptResult {
        case success(String?)
        case denied
        case failed(String)
    }

    private func run(_ source: String) -> ScriptResult {
        guard let script = NSAppleScript(source: source) else {
            return .failed("could not compile script")
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            if code == Self.automationDeniedCode { return .denied }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown"
            return .failed(message)
        }
        return .success(descriptor.stringValue)
    }
}
