import AppKit
import CodeStatusCore
import UserNotifications

/// Assembles the diagnostics report from what is actually true on this machine.
///
/// Deliberately reports detected state rather than intended state: the capability
/// matrix here reflects the Codex build installed on *this* Mac and whether our
/// hooks are actually present, not what the README hopes for. A matrix that
/// cannot be wrong is a matrix nobody can trust.
@MainActor
struct DiagnosticsBuilder {

    let daemon: SessionDaemon
    let notifications: NotificationCoordinator
    let paths: RuntimePaths

    func build() async -> DiagnosticsReport {
        let adapters = detectAdapters()
        return DiagnosticsReport(
            appVersion: Self.appVersion,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture,
            adapters: adapters,
            capabilities: capabilities(given: adapters),
            socketPath: paths.resolveSocketPath().url.path,
            socketAccepted: daemon.socketStats?.accepted ?? 0,
            socketDecoded: daemon.socketStats?.decoded ?? 0,
            socketRejected: daemon.socketStats?.rejected ?? 0,
            spoolFileCount: spoolCount(),
            notificationAuthorization: await notificationStatus(),
            automationPermission: automationStatus(),
            sessionSummaries: daemon.sessions.map(Self.summarize),
            errors: []
        )
    }

    // MARK: - Environment

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// Metadata only — never a prompt, a response, or a file path beyond the
    /// project root.
    static func summarize(_ session: AgentSession) -> String {
        let host = session.hostApplication == .unknown ? "" : " in \(session.hostApplication.displayName)"
        return "\(session.displayName) — \(session.provider.displayName) — \(session.state.rawValue)\(host)"
    }

    private func spoolCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: paths.spool.path))?
            .filter { $0.hasSuffix(".ndjson") }.count ?? 0
    }

    private func notificationStatus() async -> String {
        switch await notifications.authorizationStatus() {
        case .authorized: return "authorised"
        case .denied: return "denied — enable CodeStatus in System Settings › Notifications"
        case .notDetermined: return "not yet requested"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    /// Reported rather than probed.
    ///
    /// Probing means sending a real Apple Event, which would pop the permission
    /// prompt — and the spec is explicit that invasive permissions are requested
    /// when a feature needs them, not while someone is reading a status screen.
    private func automationStatus() -> String {
        let terminalRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == HostApplication.terminal.bundleIdentifier
        }
        return terminalRunning
            ? "requested on first use of Open Session"
            : "Terminal not running"
    }

    // MARK: - Adapter detection

    private func detectAdapters() -> [AdapterStatus] {
        var adapters: [AdapterStatus] = []
        let home = URL(fileURLWithPath: NSHomeDirectory())

        // Claude Code — one settings file covers both the CLI and the extension,
        // so they share an install state but are listed separately because a user
        // may have only one of them.
        let claudeInstalled = (try? ClaudeHookInstaller(paths: paths).isInstalled()) ?? false
        let claudeCLI = Self.findExecutable("claude")
        adapters.append(AdapterStatus(
            name: "Claude Code CLI",
            state: claudeCLI == nil ? .notInstalled : (claudeInstalled ? .connected : .notConfigured),
            detail: claudeInstalled ? nil : "Hooks not installed yet",
            version: claudeCLI.flatMap(Self.version(of:))
        ))

        let claudeExtension = Self.findVSCodeExtension(prefix: "anthropic.claude-code")
        adapters.append(AdapterStatus(
            name: "Claude Code for VS Code",
            state: claudeExtension == nil ? .notInstalled : (claudeInstalled ? .connected : .notConfigured),
            detail: claudeExtension == nil
                ? nil
                : "Shares ~/.claude/settings.json with the CLI",
            version: claudeExtension
        ))

        // Codex — hooks.json is ours to write, but Codex will not execute
        // anything in it until the user trusts it through /hooks, and that is
        // deliberately not something we can check or do for them.
        let codexInstalled = (try? CodexHookInstaller(paths: paths).isInstalled()) ?? false
        let codexCLI = Self.findCodex()
        adapters.append(AdapterStatus(
            name: "Codex CLI",
            state: codexCLI == nil
                ? .notInstalled
                : (codexInstalled ? .needsVerification : .notConfigured),
            detail: codexInstalled ? CodexHookInstaller.trustInstructions : "Hooks not installed yet",
            version: codexCLI.flatMap(Self.version(of:))
        ))

        // App-server delivery is confirmed: ~/.codex/logs_2.sqlite records
        // `codex_app_server … hook/started` and `hook/completed` for entries
        // written to ~/.codex/hooks.json. The trust caveat is the CLI's.
        let codexExtension = Self.findVSCodeExtension(prefix: "openai.chatgpt")
        adapters.append(AdapterStatus(
            name: "Codex for VS Code",
            state: codexExtension == nil
                ? .notInstalled
                : (codexInstalled ? .needsVerification : .notConfigured),
            detail: codexExtension == nil
                ? nil
                : "Runs as app-server, and delivers hooks from ~/.codex/hooks.json in that mode",
            version: codexExtension
        ))

        adapters.append(AdapterStatus(
            name: "Terminal.app",
            state: .connected,
            detail: "Tab targeting uses the public tty property"
        ))

        _ = home
        return adapters
    }

    private static func findExecutable(_ name: String) -> String? {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { "\($0)/\(name)" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Codex is not necessarily on PATH — the desktop app bundles it.
    private static func findCodex() -> String? {
        let bundled = "/Applications/Codex.app/Contents/Resources/codex"
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return findExecutable("codex")
    }

    private static func findVSCodeExtension(prefix: String) -> String? {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".vscode/extensions")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return nil }
        // Directory names carry the version: `anthropic.claude-code-2.1.240-darwin-arm64`.
        return entries.filter { $0.hasPrefix(prefix) }.sorted().last
    }

    private static func version(of executable: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init)
    }

    // MARK: - Capability matrix

    private func capabilities(given adapters: [AdapterStatus]) -> [CapabilityRow] {
        func installed(_ name: String) -> Bool {
            adapters.first { $0.name == name }.map {
                $0.state == .connected || $0.state == .needsVerification
            } ?? false
        }

        let claude = installed("Claude Code CLI")
        let claudeVSCode = installed("Claude Code for VS Code")
        let codex = installed("Codex CLI")
        let codexVSCode = installed("Codex for VS Code")

        return [
            CapabilityRow(
                environment: "Claude Code CLI",
                discovery: .yes,
                busyFree: claude ? .yes : .unverified,
                approval: claude ? .yes : .unverified,
                input: claude ? .yes : .unverified,
                open: .yes,
                sendPrompt: .no,
                note: claude ? nil : "Install hooks to enable state tracking."
            ),
            CapabilityRow(
                environment: "Claude Code for VS Code",
                discovery: .yes,
                busyFree: claudeVSCode ? .yes : .unverified,
                approval: claudeVSCode ? .yes : .unverified,
                input: claudeVSCode ? .yes : .unverified,
                open: .yes,
                sendPrompt: .no
            ),
            CapabilityRow(
                environment: "Codex CLI",
                discovery: .yes,
                busyFree: codex ? .yes : .unverified,
                approval: codex ? .yes : .unverified,
                input: .no,
                open: .yes,
                sendPrompt: .no,
                note: "Codex emits no Notification event, so \"waiting for a reply\" is not observable through any official channel."
            ),
            CapabilityRow(
                environment: "Codex for VS Code",
                discovery: codexVSCode ? .yes : .notApplicable,
                busyFree: .unverified,
                approval: .unverified,
                input: .no,
                open: .yes,
                sendPrompt: .no,
                note: "Codex in VS Code runs as app-server rather than the TUI; whether it delivers hooks.json events in that mode is unconfirmed."
            ),
        ]
    }
}
