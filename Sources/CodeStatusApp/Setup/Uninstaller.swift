import AppKit
import CodeStatusCore
import ServiceManagement
import os

/// Removes CodeStatus completely, from inside CodeStatus.
///
/// This exists because of what people actually do, which is drag the app to the
/// Trash. That leaves our hook entries in `~/.claude/settings.json` and
/// `~/.codex/hooks.json` pointing at a binary under `Application Support` that
/// is still there — so every tool call in every agent, forever, spawns a process
/// belonging to an app the user believes they deleted. It exits immediately and
/// costs almost nothing, which is exactly why nobody ever finds it.
///
/// A shell script shipped beside the app cannot do this job. Removing our
/// entries means editing the user's JSON without disturbing anything else in
/// it — ownership decided by resolving each entry's command to a real path, the
/// file backed up, replaced atomically, re-parsed, and restored if the result is
/// not what was promised. That is what ``HookInstaller`` is, and reimplementing
/// a fraction of it in `sed` is how someone's settings file gets destroyed.
@MainActor
enum Uninstaller {

    private static let logger = Logger(subsystem: "co.codestatus", category: "uninstall")

    struct Outcome {
        var removedFrom: [String] = []
        var failures: [String] = []
        var trashedApp = false
    }

    /// Asks, then removes everything, then quits.
    static func run(paths: RuntimePaths = RuntimePaths()) {
        let alert = NSAlert()
        alert.messageText = "Remove CodeStatus from this Mac?"
        alert.informativeText = """
            This takes our hook entries out of Claude Code and Codex, leaving any \
            hooks of your own alone, and removes the files CodeStatus installed. \
            Your agents are not otherwise touched.

            Deleting the app on its own cannot do this: the hook entries would \
            stay behind and keep running.
            """
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let trash = NSButton(checkboxWithTitle: "Also move CodeStatus to the Trash", target: nil, action: nil)
        trash.state = .on
        alert.accessoryView = trash

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let outcome = perform(paths: paths, trashingApp: trash.state == .on)
        report(outcome)

        guard outcome.failures.isEmpty else { return }
        NSApp.terminate(nil)
    }

    /// The removal itself, in an order that matters.
    ///
    /// Hook entries come out first, and nothing else happens unless they did.
    /// Deleting the staged binary while an entry still points at it is strictly
    /// worse than leaving both: the orphaned hook we are trying to prevent at
    /// least exits 0, while an entry naming a binary that no longer exists makes
    /// the agent report a failing hook on every single tool call.
    static func perform(paths: RuntimePaths, trashingApp: Bool) -> Outcome {
        var outcome = Outcome()

        for (name, remove) in [
            ("Claude Code", { try ClaudeHookInstaller(paths: paths).uninstall() }),
            ("Codex", { try CodexHookInstaller(paths: paths).uninstall() }),
        ] as [(String, () throws -> HookInstaller.Plan)] {
            do {
                _ = try remove()
                outcome.removedFrom.append(name)
            } catch {
                outcome.failures.append("\(name): \(error.localizedDescription)")
            }
        }

        guard outcome.failures.isEmpty else {
            logger.error("uninstall stopped: hook entries could not be removed")
            return outcome
        }

        try? LoginItem.setEnabled(false)

        // Trashed rather than deleted. `backups` holds copies of the user's own
        // configuration files, and destroying those outright on the way out is
        // not a thing an uninstaller should be able to do by accident.
        for directory in [paths.base, paths.home.appendingPathComponent(".codestatus")] {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            do {
                try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
            } catch {
                logger.error("could not trash \(directory.path, privacy: .public)")
            }
        }

        if trashingApp {
            let bundle = Bundle.main.bundleURL
            // A translocated bundle is macOS's own read-only mirror; trashing it
            // removes the mirror and leaves the real download untouched, which
            // would look like the uninstall failed.
            if bundle.pathExtension == "app", !AppLocation.isTranslocated(bundle) {
                outcome.trashedApp = (try? FileManager.default.trashItem(
                    at: bundle, resultingItemURL: nil
                )) != nil
            }
        }

        logger.info("uninstalled from: \(outcome.removedFrom.joined(separator: ", "), privacy: .public)")
        return outcome
    }

    private static func report(_ outcome: Outcome) {
        let alert = NSAlert()
        if outcome.failures.isEmpty {
            alert.messageText = "CodeStatus removed"
            var lines = ["Hook entries removed from \(outcome.removedFrom.formatted(.list(type: .and)))."]
            lines.append("Open sessions keep running; they simply stop reporting.")
            if !outcome.trashedApp {
                lines.append("You can drag CodeStatus to the Trash now — nothing is left behind.")
            }
            alert.informativeText = lines.joined(separator: "\n\n")
            alert.alertStyle = .informational
        } else {
            alert.messageText = "CodeStatus was not removed"
            alert.informativeText = outcome.failures.joined(separator: "\n")
                + "\n\nNothing else was deleted. Your agents' configuration is unchanged."
            alert.alertStyle = .warning
        }
        alert.runModal()
    }
}
