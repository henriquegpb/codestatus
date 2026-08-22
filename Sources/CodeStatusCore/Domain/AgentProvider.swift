import Foundation

/// Which coding agent a session belongs to.
public enum AgentProvider: String, Codable, Sendable, CaseIterable {
    case claudeCode
    case codex
    /// Reserved for future adapters; never produced by the V1 adapters.
    case generic

    /// Name shown in the HUD and notifications.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .generic: return "Agent"
        }
    }
}

/// The application hosting a session's terminal or editor.
public enum HostApplication: String, Codable, Sendable {
    case terminal
    case vsCode
    case iTerm
    case ghostty
    case warp
    case unknown

    public var bundleIdentifier: String? {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .vsCode: return "com.microsoft.VSCode"
        case .iTerm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .warp: return "dev.warp.Warp-Stable"
        case .unknown: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .vsCode: return "VS Code"
        case .iTerm: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        case .unknown: return "Unknown"
        }
    }

    /// Maps the `TERM_PROGRAM` value a terminal exports into its child processes.
    ///
    /// The hook inherits this from the agent, which inherited it from the
    /// terminal, so it identifies the host directly without walking the process
    /// tree. Values are matched case-insensitively.
    public init(termProgram: String?) {
        guard let raw = termProgram?.lowercased(), !raw.isEmpty else {
            self = .unknown
            return
        }
        switch raw {
        case "apple_terminal": self = .terminal
        case "iterm.app": self = .iTerm
        case "vscode": self = .vsCode
        case "ghostty": self = .ghostty
        case "warpterminal": self = .warp
        default: self = .unknown
        }
    }
}

/// What CodeStatus can actually do with a given session.
///
/// Capabilities are declared per session rather than assumed per provider,
/// because two sessions of the same agent can differ: one launched by
/// CodeStatus through a PTY is controllable, one discovered in a terminal is
/// not. The prompt bar is enabled *only* by ``canSendPrompt``.
public struct Capability: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// We can bring the user back to this session.
    public static let canOpen = Capability(rawValue: 1 << 0)
    /// We have a safe, public input channel. Deferred to V1.1.
    public static let canSendPrompt = Capability(rawValue: 1 << 1)
    /// We can ask the agent to stop the current turn.
    public static let canRequestStop = Capability(rawValue: 1 << 2)
    /// We can resolve the session to an exact window or tab, not just an app.
    public static let canIdentifyExactWindow = Capability(rawValue: 1 << 3)
    /// We know precisely which conversation this is, via a provider session id.
    public static let canIdentifyExactConversation = Capability(rawValue: 1 << 4)
}
