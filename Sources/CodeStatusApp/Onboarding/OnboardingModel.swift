import AppKit
import CodeStatusCore
import Observation
import ServiceManagement

/// Drives first run.
///
/// Two rules shape the whole flow. Nothing is written to an agent's
/// configuration until the user has seen exactly what will change — a diff, not
/// a promise. And invasive permissions are never requested here: Automation is
/// asked for the first time someone clicks "Open session", because asking during
/// setup trains people to grant things they have no use for yet.
@MainActor
@Observable
final class OnboardingModel {

    enum Step: Int, CaseIterable {
        case welcome
        case privacy
        case notifications
        case detect
        case install
        case launchAtLogin
        case done

        var title: String {
            switch self {
            case .welcome: return "CodeStatus"
            case .privacy: return "Everything stays on your Mac"
            case .notifications: return "Notifications"
            case .detect: return "What we found"
            case .install: return "Connect your agents"
            case .launchAtLogin: return "Start with your Mac"
            case .done: return "Ready"
            }
        }
    }

    private(set) var step: Step = .welcome
    private(set) var adapters: [AdapterStatus] = []
    private(set) var installPlans: [InstallPreview] = []
    private(set) var installError: String?
    private(set) var notificationsGranted: Bool?
    var launchAtLogin: Bool = LoginItem.isEnabled

    /// A pending change to one agent's configuration, rendered for review.
    struct InstallPreview: Identifiable, Sendable {
        var id: String { targetPath }
        var provider: AgentProvider
        var targetPath: String
        var willCreateFile: Bool
        var eventCount: Int
        /// The file exactly as it will be on disk afterwards.
        var resultingText: String
        var alreadyInstalled: Bool
    }

    private let paths: RuntimePaths
    private let notifications: NotificationCoordinator

    init(paths: RuntimePaths = RuntimePaths(), notifications: NotificationCoordinator) {
        self.paths = paths
        self.notifications = notifications
    }

    // MARK: - Navigation

    var canGoBack: Bool { step != .welcome && step != .done }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
        if step == .detect { detect() }
    }

    func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    // MARK: - Steps

    func requestNotifications() async {
        notificationsGranted = await notifications.requestAuthorization()
    }

    /// Reports what is installed on this machine, and what that means.
    func detect() {
        var found: [AdapterStatus] = []

        let claudeCLI = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let claudeExtension = Self.vsCodeExtension(prefix: "anthropic.claude-code")
        if claudeCLI != nil || claudeExtension != nil {
            found.append(AdapterStatus(
                name: "Claude Code",
                state: .notConfigured,
                detail: claudeExtension != nil && claudeCLI != nil
                    ? "CLI and VS Code extension — one setup covers both"
                    : (claudeExtension != nil ? "VS Code extension" : "Command line")
            ))
        }

        let codexCLI = ["/Applications/Codex.app/Contents/Resources/codex",
                        "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        if codexCLI != nil {
            found.append(AdapterStatus(
                name: "Codex",
                state: .notConfigured,
                detail: "Codex will ask you to trust the hooks before it runs them"
            ))
        }

        adapters = found
        preparePlans()
    }

    /// Builds the previews without touching anything on disk.
    func preparePlans() {
        var previews: [InstallPreview] = []
        installError = nil

        if adapters.contains(where: { $0.name == "Claude Code" }) {
            let installer = ClaudeHookInstaller(paths: paths)
            do {
                let plan = try installer.planInstall()
                previews.append(InstallPreview(
                    provider: .claudeCode,
                    targetPath: installer.settingsURL.path,
                    willCreateFile: plan.createsFile,
                    eventCount: ClaudeHookInstaller.events.count,
                    resultingText: plan.previewText,
                    alreadyInstalled: plan.isNoOp
                ))
            } catch {
                installError = "Claude Code: \(error.localizedDescription)"
            }
        }

        if adapters.contains(where: { $0.name == "Codex" }) {
            let installer = CodexHookInstaller(paths: paths)
            do {
                let plan = try installer.planInstall()
                previews.append(InstallPreview(
                    provider: .codex,
                    targetPath: installer.hooksURL.path,
                    willCreateFile: plan.createsFile,
                    eventCount: CodexHookInstaller.events.count,
                    resultingText: plan.previewText,
                    alreadyInstalled: plan.isNoOp
                ))
            } catch {
                installError = [installError, "Codex: \(error.localizedDescription)"]
                    .compactMap { $0 }.joined(separator: "\n")
            }
        }

        installPlans = previews
    }

    /// Applies the previewed changes. Every write is backed up and validated;
    /// a failure restores the original file rather than leaving it half-edited.
    func install() {
        installError = nil
        var failures: [String] = []

        for plan in installPlans where !plan.alreadyInstalled {
            do {
                switch plan.provider {
                case .claudeCode: _ = try ClaudeHookInstaller(paths: paths).install()
                case .codex: _ = try CodexHookInstaller(paths: paths).install()
                case .generic: break
                }
            } catch {
                failures.append("\(plan.provider.displayName): \(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            adapters = adapters.map {
                AdapterStatus(
                    name: $0.name,
                    state: $0.name == "Codex" ? .needsVerification : .connected,
                    detail: $0.name == "Codex" ? CodexHookInstaller.trustInstructions : $0.detail
                )
            }
            preparePlans()
        } else {
            installError = failures.joined(separator: "\n")
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            launchAtLogin = LoginItem.isEnabled
        } catch {
            launchAtLogin = LoginItem.isEnabled
        }
    }

    private static func vsCodeExtension(prefix: String) -> String? {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".vscode/extensions")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return nil }
        return entries.filter { $0.hasPrefix(prefix) }.sorted().last
    }
}
