import AppKit
import CodeStatusCore
import ServiceManagement
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = HUDModel()
    private var notifications: NotificationCoordinator!
    private var daemon: SessionDaemon!
    private var menuBar: MenuBarController!
    private var opener: SessionOpener!
    private var diagnostics: DiagnosticsWindowController!
    private var onboarding: OnboardingWindowController!
    private var settingsWindow: SettingsWindowController!
    private let settings = SettingsModel()
    private let updates = UpdateCoordinator()
    private let logger = Logger(subsystem: "co.codestatus", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar companion, not a windowed app: no Dock icon, no window on
        // launch. LSUIElement in Info.plist says the same thing, but setting it
        // here keeps `swift run` behaving the same as the bundle.
        NSApp.setActivationPolicy(.accessory)

        installHookBinaryIfNeeded()

        opener = SessionOpener()
        notifications = NotificationCoordinator(
            suppression: FrontmostSessionSuppressor(
                selectedTTYProvider: { [opener] in opener?.frontmostTerminalTTY() }
            )
        )
        daemon = SessionDaemon(model: model, notifications: notifications)
        menuBar = MenuBarController(model: model, updates: updates)

        // "Quiet" is the only precondition for swapping the app underneath the
        // user, and it means nobody is mid-turn or being asked something. A
        // session sitting free is fine: relaunching loses nothing it holds.
        updates.isBusy = { [model] in model.busy > 0 || model.needsYou > 0 }

        wireInteractions()

        daemon.onRegistryChanged = { [weak self] in
            self?.menuBar.refresh()
        }
        daemon.start()
        updates.start()

        // First run walks the user through permissions and hook installation.
        // On later launches we ask for notification permission directly, since
        // macOS only shows the prompt once and the user may have deferred it.
        onboarding = OnboardingWindowController(notifications: notifications) { [weak self] in
            self?.daemon.refreshAdapters()
            self?.logger.info("onboarding completed")
        }
        if OnboardingWindowController.hasCompleted {
            Task { await notifications.requestAuthorization() }
            migrateClaudeHooksIfNeeded()
            migrateCodexHooksIfNeeded()
        } else {
            onboarding.showIfNeeded()
        }
    }

    /// Brings an older build's Claude Code entries up to the current event list.
    ///
    /// A build that registers more events than the installed entries cover reads
    /// as *not installed*, so without this an existing user would be told to set
    /// up an agent they already connected, and would silently lose the states
    /// the new events carry. As with Codex, this only ever refreshes entries
    /// that are already ours.
    ///
    /// It is announced rather than silent for one reason: Claude Code reads its
    /// hooks when a session starts, so nothing already open picks these up.
    private func migrateClaudeHooksIfNeeded() {
        let installer = ClaudeHookInstaller(paths: RuntimePaths())
        do {
            guard try installer.needsMigration() else { return }
            _ = try installer.install()
            logger.info("refreshed Claude Code hooks onto the current event list")
            notifications.postSetupNotice(
                title: "Claude Code hooks updated",
                body: "CodeStatus now sees tool failures and MCP questions. "
                    + "Restart your Claude Code sessions to pick them up.",
                identifier: "co.codestatus.setup.claude-migrated"
            )
        } catch {
            logger.error("Claude hook migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Moves an older build's Codex entries onto the path Codex can actually
    /// spawn, for users who will never open Setup again because as far as they
    /// know it is already done.
    ///
    /// Rewriting `hooks.json` invalidates the trust the user granted, and Codex
    /// runs nothing until they grant it again — so this cannot be silent. It
    /// only ever refreshes entries that are already ours: a user who never
    /// connected Codex is left alone.
    private func migrateCodexHooksIfNeeded() {
        let installer = CodexHookInstaller(paths: RuntimePaths())
        do {
            guard try installer.needsMigration() else { return }
            _ = try installer.install()
            logger.info("migrated Codex hooks off the unspawnable path")
            notifications.postSetupNotice(
                title: "Codex hooks updated",
                body: "They could not run from their old location. "
                    + "Run /hooks in Codex to trust them again.",
                identifier: "co.codestatus.setup.codex-migrated"
            )
        } catch {
            logger.error("Codex hook migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        daemon.stop()
    }

    private func wireInteractions() {
        diagnostics = DiagnosticsWindowController(
            builder: DiagnosticsBuilder(
                daemon: daemon, notifications: notifications, paths: RuntimePaths()
            ),
            onSendTestEvent: { [weak self] in self?.sendTestEvent() }
        )

        settingsWindow = SettingsWindowController(
            model: settings,
            updates: updates,
            onOpenSetup: { [weak self] in self?.onboarding.show() },
            onUninstallHooks: { [weak self] in self?.uninstallHooks() }
        )
        settings.onChange = { [weak self] in self?.applySettings() }
        applySettings()

        menuBar.onOpenSession = { [weak self] session in self?.open(session) }
        // Declared and passed into the row since the popover was written, but
        // never connected to anything, so the × was decoration.
        menuBar.onDismissSession = { [weak self] session in self?.daemon.dismiss(session) }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.onOpenDiagnostics = { [weak self] in self?.diagnostics.show() }
        menuBar.onOpenPreferences = { [weak self] in self?.settingsWindow.show() }
        // A sweep, not a restart: it finds sessions that started before their
        // hooks were installed, which is the case the button exists for.
        menuBar.onRefresh = { [weak self] in self?.daemon.refreshAdapters() }
    }

    /// Exercises the whole delivery path — hook binary, socket, reducer, sound,
    /// notification — without involving a real agent.
    ///
    /// Runs the *installed* hook rather than synthesising an event internally,
    /// so a failure here implicates the same binary and the same socket an agent
    /// would use. A test that bypassed them could pass while the real path was
    /// broken.
    private func sendTestEvent() {
        let hook = RuntimePaths().hookBinary
        guard FileManager.default.isExecutableFile(atPath: hook.path) else {
            logger.error("no installed hook binary to test with")
            return
        }

        let session = "codestatus-test-\(UInt32.random(in: 0..<0xFFFFFF))"
        let payloads = [
            #"{"session_id":"\#(session)","hook_event_name":"UserPromptSubmit","cwd":"\#(NSHomeDirectory())","prompt_id":"t1"}"#,
            #"{"session_id":"\#(session)","hook_event_name":"Stop","cwd":"\#(NSHomeDirectory())","prompt_id":"t1"}"#,
        ]

        Task.detached {
            for payload in payloads {
                let process = Process()
                process.executableURL = hook
                process.arguments = ["--provider", "claude-code"]
                let input = Pipe()
                process.standardInput = input
                guard (try? process.run()) != nil else { continue }
                input.fileHandleForWriting.write(Data(payload.utf8))
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private func open(_ session: AgentSession) {
        opener.open(session)
    }

    private func applySettings() {
        notifications.preferences = settings.notificationPreferences
    }

    /// Removes our entries from both agents' configuration.
    ///
    /// Offered in Settings rather than only in an uninstaller script because the
    /// case that actually harms people is deleting the app and leaving the hook
    /// entries behind.
    private func uninstallHooks() {
        let paths = RuntimePaths()
        do {
            _ = try ClaudeHookInstaller(paths: paths).uninstall()
            _ = try CodexHookInstaller(paths: paths).uninstall()
            logger.info("removed CodeStatus hook entries")
        } catch {
            logger.error("uninstall failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keeps the hook binary at a stable path that agents' configs point at.
    ///
    /// Copied out of the bundle rather than referenced inside it, and refreshed
    /// whenever the versions differ. That is what lets the user move the app to
    /// a different folder, or update it, without any agent configuration having
    /// to be rewritten — and it means a deleted app leaves behind a hook that
    /// exits immediately rather than a dangling path that errors on every call.
    private func installHookBinaryIfNeeded() {
        let paths = RuntimePaths()
        // Built into Contents/Helpers, which is where a signed helper executable
        // belongs. `url(forAuxiliaryExecutable:)` only looks in Contents/MacOS,
        // so the path is constructed rather than asked for.
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/codestatus-hook"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/codestatus-hook"),
        ]
        guard let bundled = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            logger.notice("no bundled hook binary; running from a development build")
            return
        }

        do {
            try paths.createDirectories()
            // Two copies of one binary. Codex cannot spawn anything under
            // `Application Support` — it splits a hook's `command` on
            // whitespace — so it gets its own copy on a space-free path, named
            // for the provider because Codex also drops the entry's `args`.
            try stageHookBinary(from: bundled, to: paths.hookBinary)
            try stageHookBinary(from: bundled, to: paths.codexHookBinary)
        } catch {
            logger.error("hook binary install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copies the bundled hook to `destination` unless it is already there byte
    /// for byte.
    private func stageHookBinary(from bundled: URL, to destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            let current = try? Data(contentsOf: destination)
            let candidate = try? Data(contentsOf: bundled)
            if current == candidate { return }
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: bundled, to: destination)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        logger.info("installed hook binary at \(destination.path, privacy: .public)")
    }
}

/// Launch-at-login, backed by the public `SMAppService` API.
enum LoginItem {
    /// `.requiresApproval` counts as on: registration succeeded and macOS is
    /// merely waiting for the user to confirm in System Settings. Treating it as
    /// off would make the toggle snap back and look broken.
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
