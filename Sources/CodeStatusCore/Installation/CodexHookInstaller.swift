import Foundation

/// Registers CodeStatus in `~/.codex/hooks.json`.
///
/// Two deliberate boundaries, both of which prior art crosses:
///
///  * `~/.codex/config.toml` is never read and never written. Codex treats
///    `hooks.json` as a user-layer source in its own right, so there is no need
///    to parse or rewrite the user's TOML — and on a machine where the `notify`
///    key is already claimed by Codex Computer Use, rewriting it would break a
///    shipped feature.
///  * `trusted_hash` is never written. Codex requires the user to explicitly
///    trust a hooks file through `/hooks` before it will execute anything in it.
///    That is a security control against exactly the thing we are doing;
///    forging it would defeat it. We install the entries and then tell the user
///    what to approve — see ``trustRequirement(fileManager:)``.
public struct CodexHookInstaller: Sendable {

    /// Codex's hook set overlaps Claude's but is not identical: there is no
    /// `Notification` event and no `StopFailure`, and its approval signal
    /// arrives only as `PermissionRequest`. `SubagentStart`/`SubagentStop`,
    /// `PreCompact`, and `PostCompact` are deliberately not registered: they do
    /// not change the state we show, and every hook we register is a process
    /// spawned inside the user's agent.
    public static let events: [String] = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "Stop",
        "SessionEnd",
    ]

    /// What the user has to do themselves, verbatim enough to show in the UI.
    public static let trustInstructions = """
        Codex only runs hooks you have explicitly trusted. Open Codex, run \
        /hooks, review the CodeStatus entries in ~/.codex/hooks.json, and trust \
        them. CodeStatus cannot do this for you: approving hooks on your behalf \
        would defeat the protection it exists to provide.
        """

    /// Whether Codex will actually run what we installed.
    public enum TrustRequirement: Sendable, Equatable {
        /// Nothing of ours is in `hooks.json`, so there is nothing to trust.
        case notInstalled
        /// Our entries are present. Whether Codex has been told to trust them is
        /// knowable only from `trusted_hash`, which we refuse to read or write,
        /// so we always report this and let the user confirm in `/hooks`.
        case awaitingUserTrust(instructions: String)
    }

    public static func hooksURL(home: URL) -> URL {
        home.appendingPathComponent(".codex/hooks.json")
    }

    public let installer: HookInstaller

    public init(
        paths: RuntimePaths,
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        hookBinary: URL? = nil
    ) {
        installer = HookInstaller(
            paths: paths,
            provider: .codex,
            targetURL: Self.hooksURL(home: home),
            events: Self.events,
            // Not `paths.hookBinary`: that path contains a space, and Codex
            // splits a hook's `command` on whitespace. See
            // ``RuntimePaths/codexHookBinary``.
            hookBinary: hookBinary ?? paths.codexHookBinary,
            legacyHookBinaries: [paths.hookBinary]
        )
    }

    public var hooksURL: URL { installer.targetURL }

    public func planInstall(fileManager: FileManager = .default) throws -> HookInstaller.Plan {
        try installer.planInstall(fileManager: fileManager)
    }

    public func planUninstall(fileManager: FileManager = .default) throws -> HookInstaller.Plan {
        try installer.planUninstall(fileManager: fileManager)
    }

    @discardableResult
    public func install(fileManager: FileManager = .default) throws -> HookInstaller.Plan {
        try installer.install(fileManager: fileManager)
    }

    @discardableResult
    public func uninstall(fileManager: FileManager = .default) throws -> HookInstaller.Plan {
        try installer.uninstall(fileManager: fileManager)
    }

    public func isInstalled(fileManager: FileManager = .default) throws -> Bool {
        try installer.isInstalled(fileManager: fileManager)
    }

    /// Whether an older build's entries are still in `hooks.json`.
    ///
    /// True for everyone who connected Codex before the hook moved off the
    /// spaced path, which is everyone who connected it at all: those entries
    /// could never run. See ``RuntimePaths/codexHookBinary``.
    public func needsMigration(fileManager: FileManager = .default) throws -> Bool {
        try installer.needsMigration(fileManager: fileManager)
    }

    /// The manual step onboarding must surface after a successful install.
    public func trustRequirement(fileManager: FileManager = .default) throws -> TrustRequirement {
        try isInstalled(fileManager: fileManager)
            ? .awaitingUserTrust(instructions: Self.trustInstructions)
            : .notInstalled
    }
}
