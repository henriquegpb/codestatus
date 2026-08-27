import Foundation

/// Registers CodeStatus in `~/.claude/settings.json`.
///
/// That one file is shared by the Claude CLI and the VS Code extension — the
/// extension bundles its own CLI binary but reads the same user config — so
/// installing here covers both surfaces with a single edit, and makes the
/// format-preserving requirement non-negotiable: this file usually contains the
/// user's permissions, environment, and status line as well.
public struct ClaudeHookInstaller: Sendable {

    /// Every lifecycle hook Claude Code emits that changes what we can say about
    /// a session's state.
    ///
    /// `Notification` is included because its `permission_prompt` and
    /// `idle_prompt` subtypes are the only signal for "the agent is waiting on
    /// you" that arrives without a matching tool event. `StopFailure` is
    /// included because a turn that ends in error must not be shown as free.
    ///
    /// 2.1.247 offers 31 events, not the 11 this list was drawn from. The ones
    /// added here earn their place by changing what we can say about a session;
    /// the rest are deliberately left out, because every registered event is a
    /// process spawned on the agent's machine. `MessageDisplay` is the clearest
    /// refusal — it fires per assistant message and tells us nothing a tool
    /// event does not. See docs/spikes/07-blocking-questions.md.
    public static let events: [String] = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        // A failing tool emits this *instead of* `PostToolUse`.
        "PostToolUseFailure",
        // Closes a parallel batch even if one result went missing.
        "PostToolBatch",
        "PermissionRequest",
        "PermissionDenied",
        "Notification",
        // An MCP server asking the user something — the other way a session
        // blocks on a human without the turn ending.
        "Elicitation",
        "ElicitationResult",
        "Stop",
        "StopFailure",
        "SessionEnd",
    ]

    public static func settingsURL(home: URL) -> URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    public let installer: HookInstaller

    public init(
        paths: RuntimePaths,
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        hookBinary: URL? = nil
    ) {
        installer = HookInstaller(
            paths: paths,
            provider: .claudeCode,
            targetURL: Self.settingsURL(home: home),
            events: Self.events,
            hookBinary: hookBinary
        )
    }

    public var settingsURL: URL { installer.targetURL }

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

    /// Whether entries of ours are present but predate the current event list.
    ///
    /// This is what a build that registers new events looks like to an existing
    /// user: not "never set up", but "set up against a shorter list".
    public func needsMigration(fileManager: FileManager = .default) throws -> Bool {
        try installer.needsMigration(fileManager: fileManager)
    }
}
