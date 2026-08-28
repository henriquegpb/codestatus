import AppKit
import CodeStatusCore
import Observation
import ServiceManagement
import UserNotifications

/// Drives first run, and every run of Setup after it.
///
/// Three rules shape the whole flow.
///
/// Nothing is written to an agent's configuration until the user has seen
/// exactly what will change — a diff, not a promise.
///
/// Detection informs the screen but never gates it. Every agent CodeStatus
/// supports is listed and connectable whether or not we found it, because the
/// two failures are not symmetric: offering to connect an agent the user does
/// not have leaves an inert JSON file nobody reads, while failing to offer one
/// they *do* have leaves them with an app that silently watches nothing and no
/// way to say otherwise. That case is not hypothetical — a Codex installed to
/// `~/.local/bin` was invisible to the previous path list, and there was no
/// screen on which to disagree.
///
/// And invasive permissions are never requested here: Automation is asked for
/// the first time someone clicks "Open session", because asking during setup
/// trains people to grant things they have no use for yet.
@MainActor
@Observable
final class OnboardingModel {

    enum Step: Int, CaseIterable {
        case welcome
        case privacy
        case notifications
        case detect
        case install
        case verify
        case launchAtLogin
        case done

        var title: String {
            switch self {
            case .welcome: return "CodeStatus"
            case .privacy: return "Everything stays on your Mac"
            case .notifications: return "Notifications"
            case .detect: return "Your agents"
            case .install: return "Connect your agents"
            case .verify: return "Checking it works"
            case .launchAtLogin: return "Start with your Mac"
            case .done: return "Ready"
            }
        }
    }

    /// One agent, everything known about it, and what we are about to do to it.
    struct AgentPlan: Identifiable, Sendable {
        var provider: AgentProvider
        var evidence: AgentEvidence
        /// Whether this agent will be connected when the user presses Connect.
        var isSelected: Bool
        var targetPath: String
        var willCreateFile: Bool
        var eventCount: Int
        /// The file exactly as it will be on disk afterwards.
        var resultingText: String
        var alreadyInstalled: Bool
        /// Why we could not even plan a change here, if we could not.
        var planError: String?
        /// A hook event has actually arrived from this agent.
        var isVerified: Bool

        var id: String { provider.rawValue }

        /// Codex refuses to run a `hooks.json` the user has not trusted through
        /// `/hooks`, and refuses silently. So installed is not running, and this
        /// is the one agent whose setup has a step we cannot take for them.
        var needsManualTrust: Bool { provider == .codex }
    }

    private(set) var step: Step = .welcome
    private(set) var agents: [AgentPlan] = []
    private(set) var isDetecting = false
    private(set) var installError: String?
    /// What macOS currently thinks, not what it answered once.
    ///
    /// Re-read on every visit to the step. `requestAuthorization` only ever
    /// prompts once per install, so a model that cached its first answer would
    /// show a returning user a button that silently does nothing — and show
    /// nothing at all to the user who fixed the permission in System Settings
    /// and came back to check.
    private(set) var notificationStatus: UNAuthorizationStatus?
    var launchAtLogin: Bool = LoginItem.isEnabled

    /// Providers that have delivered a hook event, from the daemon.
    private var verifiedProviders: Set<AgentProvider> = []

    private let paths: RuntimePaths
    private let notifications: NotificationCoordinator
    private let discovery: AgentDiscovery

    init(
        paths: RuntimePaths = RuntimePaths(),
        notifications: NotificationCoordinator,
        discovery: AgentDiscovery = AgentDiscovery()
    ) {
        self.paths = paths
        self.notifications = notifications
        self.discovery = discovery
        verifiedProviders = Set(HookEvidenceStore(paths: paths).load().keys)
    }

    // MARK: - Navigation

    var canGoBack: Bool { step != .welcome && step != .done }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        enter(next)
    }

    func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        enter(previous)
    }

    /// Moves to a step and does whatever that step has to ask the system.
    ///
    /// Centralised so arriving at a step from behind is the same as arriving at
    /// it from in front. Every step here reports live state — which agents
    /// exist, what macOS thinks of our notification permission — and a step that
    /// refreshed only when entered forwards would show stale answers to anyone
    /// who pressed Back.
    private func enter(_ next: Step) {
        step = next
        switch next {
        case .detect: detect()
        case .notifications: Task { await refreshNotificationStatus() }
        default: break
        }
    }

    /// Puts the flow back at a useful place, and re-detects.
    ///
    /// Load-bearing, and its absence is what made "Open Setup" a dead end: the
    /// window controller keeps one model for the lifetime of the process, so
    /// after a first run finished it reopened on the final "Ready" screen —
    /// a single Done button, no Back, nothing re-detected. Someone whose agent
    /// was missed at first run had no way back to the install step short of
    /// deleting the app, which is exactly what one of them did.
    ///
    /// From the top, because Setup is the app's one recovery path and any step
    /// in it can be the one that went wrong.
    func restart(at entry: Step = .welcome) {
        installError = nil
        enter(entry)
    }

    // MARK: - Steps

    func requestNotifications() async {
        _ = await notifications.requestAuthorization(force: true)
        // The request's own return value is not the answer we want to show:
        // after the one prompt macOS allows, it reports the cached decision
        // rather than anything the user just did in System Settings.
        await refreshNotificationStatus()
    }

    func refreshNotificationStatus() async {
        notificationStatus = await notifications.authorizationStatus()
    }

    /// Whether the only way forward is System Settings.
    ///
    /// macOS prompts once per install. Once it has been refused, nothing this
    /// app calls will ever bring the prompt back, so offering the button again
    /// is offering a button that does nothing.
    var notificationsNeedSystemSettings: Bool {
        notificationStatus == .denied
    }

    /// Opens the Notifications pane, landing on CodeStatus where macOS obliges.
    func openNotificationSettings() {
        // The modern pane identifier first; the old one is still what several
        // macOS versions answer to, and a URL nothing handles opens nothing at
        // all rather than failing visibly.
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    /// Surveys the machine, then builds a plan for every supported agent.
    ///
    /// Asynchronous because two of the strongest signals cost real time: asking
    /// the user's login shell where `codex` resolves, and walking the process
    /// table. Both find installs no list of directories can anticipate, and
    /// neither is worth freezing the window for.
    func detect() {
        isDetecting = true
        // Rendered immediately from the filesystem alone, so the list is never
        // empty while the slower signals come in.
        rebuild(with: fastEvidence())
        Task { [discovery] in
            let survey = await discovery.survey()
            self.rebuild(with: survey)
            self.isDetecting = false
        }
    }

    private func fastEvidence() -> [AgentProvider: AgentEvidence] {
        AgentDiscovery.supportedProviders.reduce(into: [:]) { result, provider in
            result[provider] = discovery.evidence(for: provider)
        }
    }

    /// Rebuilds the agent list, preserving choices the user has already made.
    private func rebuild(with survey: [AgentProvider: AgentEvidence]) {
        let previousSelection = Dictionary(
            uniqueKeysWithValues: agents.map { ($0.provider, $0.isSelected) }
        )
        installError = nil

        agents = AgentDiscovery.supportedProviders.map { provider in
            let evidence = survey[provider] ?? AgentEvidence()
            var plan = AgentPlan(
                provider: provider,
                evidence: evidence,
                // Selected by default whether or not we found the agent. The
                // checkbox exists for the user who knows they do not want one,
                // not as a puzzle for the user whose agent we failed to spot.
                isSelected: previousSelection[provider] ?? true,
                targetPath: targetPath(for: provider),
                willCreateFile: false,
                eventCount: eventCount(for: provider),
                resultingText: "",
                alreadyInstalled: false,
                planError: nil,
                isVerified: verifiedProviders.contains(provider)
            )

            do {
                let preview = try planInstall(for: provider)
                plan.willCreateFile = preview.createsFile
                plan.resultingText = preview.previewText
                plan.alreadyInstalled = preview.isNoOp
            } catch {
                plan.planError = error.localizedDescription
            }
            return plan
        }
    }

    func setSelected(_ selected: Bool, for provider: AgentProvider) {
        guard let index = agents.firstIndex(where: { $0.provider == provider }) else { return }
        agents[index].isSelected = selected
    }

    /// Agents the user has asked us to connect and that are not already done.
    var pendingInstalls: [AgentPlan] {
        agents.filter { $0.isSelected && !$0.alreadyInstalled && $0.planError == nil }
    }

    /// Agents that will be watched once this flow ends.
    var connectedAgents: [AgentPlan] {
        agents.filter { $0.isSelected && ($0.alreadyInstalled || $0.planError == nil) }
    }

    /// Applies the previewed changes. Every write is backed up and validated;
    /// a failure restores the original file rather than leaving it half-edited.
    func install() {
        installError = nil
        var failures: [String] = []

        for plan in pendingInstalls {
            do {
                try applyInstall(for: plan.provider)
            } catch {
                failures.append("\(plan.provider.displayName): \(error.localizedDescription)")
            }
        }

        rebuild(with: fastEvidence())
        if failures.isEmpty {
            step = .verify
        } else {
            installError = failures.joined(separator: "\n")
        }
    }

    /// Re-runs every install that is already ours, without adding any.
    ///
    /// The button for "it stopped working and I do not know why". It is safe to
    /// press at any time: an install is idempotent, and an agent the user never
    /// connected is untouched, so this can never quietly opt someone in.
    @discardableResult
    func repairConnectedAgents() -> [AgentProvider] {
        var repaired: [AgentProvider] = []
        for provider in AgentDiscovery.supportedProviders {
            do {
                guard try isInstalled(provider) || needsMigration(provider) else { continue }
                try applyInstall(for: provider)
                repaired.append(provider)
            } catch {
                installError = [installError, "\(provider.displayName): \(error.localizedDescription)"]
                    .compactMap { $0 }.joined(separator: "\n")
            }
        }
        rebuild(with: fastEvidence())
        return repaired
    }

    /// Called by the daemon the first time a provider is heard from.
    func markVerified(_ provider: AgentProvider) {
        verifiedProviders.insert(provider)
        guard let index = agents.firstIndex(where: { $0.provider == provider }) else { return }
        agents[index].isVerified = true
    }

    /// Whether every agent the user chose is demonstrably delivering events.
    var allSelectedVerified: Bool {
        let selected = connectedAgents
        return !selected.isEmpty && selected.allSatisfy(\.isVerified)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            launchAtLogin = LoginItem.isEnabled
        } catch {
            launchAtLogin = LoginItem.isEnabled
        }
    }

    // MARK: - Per-provider installers

    private func planInstall(for provider: AgentProvider) throws -> HookInstaller.Plan {
        switch provider {
        case .claudeCode: return try ClaudeHookInstaller(paths: paths).planInstall()
        case .codex: return try CodexHookInstaller(paths: paths).planInstall()
        case .generic: throw CocoaError(.featureUnsupported)
        }
    }

    private func applyInstall(for provider: AgentProvider) throws {
        switch provider {
        case .claudeCode: _ = try ClaudeHookInstaller(paths: paths).install()
        case .codex: _ = try CodexHookInstaller(paths: paths).install()
        case .generic: break
        }
    }

    private func isInstalled(_ provider: AgentProvider) throws -> Bool {
        switch provider {
        case .claudeCode: return try ClaudeHookInstaller(paths: paths).isInstalled()
        case .codex: return try CodexHookInstaller(paths: paths).isInstalled()
        case .generic: return false
        }
    }

    private func needsMigration(_ provider: AgentProvider) throws -> Bool {
        switch provider {
        case .claudeCode: return try ClaudeHookInstaller(paths: paths).needsMigration()
        case .codex: return try CodexHookInstaller(paths: paths).needsMigration()
        case .generic: return false
        }
    }

    private func targetPath(for provider: AgentProvider) -> String {
        switch provider {
        case .claudeCode: return ClaudeHookInstaller(paths: paths).settingsURL.path
        case .codex: return CodexHookInstaller(paths: paths).hooksURL.path
        case .generic: return ""
        }
    }

    private func eventCount(for provider: AgentProvider) -> Int {
        switch provider {
        case .claudeCode: return ClaudeHookInstaller.events.count
        case .codex: return CodexHookInstaller.events.count
        case .generic: return 0
        }
    }
}
