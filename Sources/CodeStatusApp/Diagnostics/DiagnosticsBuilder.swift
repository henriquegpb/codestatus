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
        let adapters = detectAdapters(survey: await AgentDiscovery().survey())
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

    /// Reports what the same detection Setup uses found, plus what came back
    /// over the socket.
    ///
    /// The evidence is named rather than reduced to a yes/no, because the
    /// question a diagnostics export has to answer is "why did it not find my
    /// Codex", and only the evidence answers that.
    private func detectAdapters(survey: [AgentProvider: AgentEvidence]) -> [AdapterStatus] {
        var adapters: [AdapterStatus] = []
        let evidenceByProvider = daemon.hookEvidence

        // Claude Code — one settings file covers both the CLI and the extension,
        // so they share an install state but are listed separately because a user
        // may have only one of them.
        let claudeInstalled = (try? ClaudeHookInstaller(paths: paths).isInstalled()) ?? false
        let claude = survey[.claudeCode] ?? AgentEvidence()
        adapters.append(AdapterStatus(
            name: "Claude Code CLI",
            state: Self.state(
                found: claude.executable != nil || claude.configDirectory != nil,
                installed: claudeInstalled,
                verified: evidenceByProvider[.claudeCode] != nil,
                needsTrust: false
            ),
            detail: Self.detail(claude, installed: claudeInstalled, provider: .claudeCode, evidence: evidenceByProvider),
            version: claude.executable.flatMap(Self.version(of:))
        ))

        adapters.append(AdapterStatus(
            name: "Claude Code for VS Code",
            state: claude.editorExtension == nil
                ? .notInstalled
                : (claudeInstalled ? .connected : .notConfigured),
            detail: claude.editorExtension == nil
                ? nil
                : "Shares ~/.claude/settings.json with the CLI",
            version: claude.editorExtension
        ))

        // Codex — hooks.json is ours to write, but Codex will not execute
        // anything in it until the user trusts it through /hooks. We cannot read
        // that decision, but an event arriving *is* the proof, so a verified
        // Codex is reported as connected rather than as awaiting trust forever.
        let codexInstalled = (try? CodexHookInstaller(paths: paths).isInstalled()) ?? false
        let codex = survey[.codex] ?? AgentEvidence()
        adapters.append(AdapterStatus(
            name: "Codex CLI",
            state: Self.state(
                found: codex.executable != nil || codex.configDirectory != nil,
                installed: codexInstalled,
                verified: evidenceByProvider[.codex] != nil,
                needsTrust: true
            ),
            detail: Self.detail(codex, installed: codexInstalled, provider: .codex, evidence: evidenceByProvider),
            version: codex.executable.flatMap(Self.version(of:))
        ))

        // App-server delivery is confirmed: ~/.codex/logs_2.sqlite records
        // `codex_app_server … hook/started` and `hook/completed` for entries
        // written to ~/.codex/hooks.json. The trust caveat is the CLI's.
        adapters.append(AdapterStatus(
            name: "Codex for VS Code",
            state: codex.editorExtension == nil
                ? .notInstalled
                : (codexInstalled ? .needsVerification : .notConfigured),
            detail: codex.editorExtension == nil
                ? nil
                : "Runs as app-server, and delivers hooks from ~/.codex/hooks.json in that mode",
            version: codex.editorExtension
        ))

        adapters.append(AdapterStatus(
            name: "Terminal.app",
            state: .connected,
            detail: "Tab targeting uses the public tty property"
        ))

        return adapters
    }

    /// An agent whose hooks have actually fired is connected, whatever the
    /// trust caveat says in the abstract.
    private static func state(
        found: Bool,
        installed: Bool,
        verified: Bool,
        needsTrust: Bool
    ) -> AdapterStatus.State {
        guard found || installed else { return .notInstalled }
        guard installed else { return .notConfigured }
        if verified { return .connected }
        return needsTrust ? .needsVerification : .connected
    }

    private static func detail(
        _ evidence: AgentEvidence,
        installed: Bool,
        provider: AgentProvider,
        evidence hookEvidence: [AgentProvider: HookEvidence]
    ) -> String? {
        if let seen = hookEvidence[provider] {
            return "Hooks confirmed running — last event \(seen.lastSeen.formatted(.relative(presentation: .named)))"
        }
        if !installed {
            return evidence.isPresent
                ? "Found (\(evidence.summary.lowercased())) — hooks not installed yet"
                : "Not found. Setup can still connect it if you have it."
        }
        return provider == .codex ? CodexHookInstaller.trustInstructions : "No events received yet"
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
