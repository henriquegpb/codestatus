import Foundation

/// Where a piece of evidence came from.
///
/// Hooks are the source of truth. Process observation exists for discovery,
/// enrichment, and reconciliation — it may report that a session *stopped
/// existing*, but it never invents what the agent is doing internally.
public enum EventSource: String, Codable, Sendable {
    /// An official lifecycle hook from the agent.
    case hook
    /// Observed process lifecycle (currently: exit detection via kqueue).
    case process
    /// Produced by the daemon while reconciling after a restart or wake.
    case reconciliation
}

/// The normalised lifecycle event vocabulary.
///
/// Claude Code and Codex use the same PascalCase names for the events they
/// share, so one enum covers both; provider-specific extras are marked.
public enum HookEventKind: String, Codable, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case permissionRequest = "PermissionRequest"
    /// Claude Code only.
    case permissionDenied = "PermissionDenied"
    /// Claude Code only. Meaning depends on ``AgentEvent/notificationType``.
    case notification = "Notification"
    case stop = "Stop"
    /// Claude Code only: the turn ended because of an API error.
    case stopFailure = "StopFailure"
    case subagentStop = "SubagentStop"
    case sessionEnd = "SessionEnd"

    /// Synthesised locally when the process disappears without a `SessionEnd`.
    case processExited = "__processExited"
}

/// The `notification_type` values Claude Code actually emits today.
///
/// Verified against the shipping binary: only these three exist. The spec
/// anticipated an `agent_needs_input` type that does not exist, so unknown
/// values must be a no-op rather than an error — that keeps us forward
/// compatible when new types appear.
public enum NotificationType: String, Codable, Sendable {
    case permissionPrompt = "permission_prompt"
    case idlePrompt = "idle_prompt"
    case agentCompleted = "agent_completed"
}

/// A single piece of evidence about a session, already stripped of content.
///
/// Everything here is metadata. No prompt, response, tool input, tool output,
/// or file content ever reaches this type — the hook's scanner drops those
/// keys before they cross the socket.
public struct AgentEvent: Sendable, Equatable {
    /// Idempotency key. Repeated delivery of the same id is ignored.
    public let id: EventID
    public let provider: AgentProvider
    public let kind: HookEventKind
    public let source: EventSource
    /// When the hook observed the event, not when we processed it.
    public let timestamp: Date

    // Session identity
    public let providerSessionID: String?
    public let providerTurnID: String?

    // Event detail
    public let notificationType: NotificationType?
    public let toolName: String?
    public let toolUseID: String?
    public let startReason: String?
    public let endReason: String?
    public let errorType: String?
    public let permissionMode: String?
    public let model: String?

    // Environment enrichment
    public let cwd: String?
    /// The agent's pid, captured by the hook as `getppid()`.
    public let pid: pid_t?
    public let termProgram: String?
    public let termSessionID: String?

    public init(
        id: EventID,
        provider: AgentProvider,
        kind: HookEventKind,
        source: EventSource,
        timestamp: Date,
        providerSessionID: String? = nil,
        providerTurnID: String? = nil,
        notificationType: NotificationType? = nil,
        toolName: String? = nil,
        toolUseID: String? = nil,
        startReason: String? = nil,
        endReason: String? = nil,
        errorType: String? = nil,
        permissionMode: String? = nil,
        model: String? = nil,
        cwd: String? = nil,
        pid: pid_t? = nil,
        termProgram: String? = nil,
        termSessionID: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.source = source
        self.timestamp = timestamp
        self.providerSessionID = providerSessionID
        self.providerTurnID = providerTurnID
        self.notificationType = notificationType
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.startReason = startReason
        self.endReason = endReason
        self.errorType = errorType
        self.permissionMode = permissionMode
        self.model = model
        self.cwd = cwd
        self.pid = pid
        self.termProgram = termProgram
        self.termSessionID = termSessionID
    }
}

public extension AgentEvent {
    /// Host application implied by `TERM_PROGRAM`, when the hook captured it.
    var hostApplication: HostApplication {
        HostApplication(termProgram: termProgram)
    }

    /// Terminal events are applied unconditionally: a session that has ended
    /// cannot be revived by a straggler from before it ended.
    var isTerminal: Bool {
        kind == .sessionEnd || kind == .processExited
    }

    /// Ordering position of this event *within* a turn.
    ///
    /// Ranks exist to reject stragglers that would otherwise regress a session.
    /// The important gaps:
    ///
    /// - `permissionRequest` outranks `preToolUse`, so a late `PreToolUse`
    ///   cannot knock a session out of `waitingForApproval` back into `busy`.
    /// - `postToolUse` outranks `permissionRequest`, so the tool actually
    ///   running after approval *does* correctly return the session to `busy`.
    var rank: Int {
        switch kind {
        case .sessionStart: return 0
        case .userPromptSubmit: return 1
        case .preToolUse: return 2
        case .permissionRequest, .permissionDenied: return 3
        case .notification:
            switch notificationType {
            case .permissionPrompt, .idlePrompt: return 3
            case .agentCompleted: return 8
            case nil: return 3
            }
        case .postToolUse: return 4
        case .subagentStop: return 5
        case .stop, .stopFailure: return 8
        case .sessionEnd, .processExited: return 9
        }
    }
}

/// A globally unique, idempotent identifier for one event delivery.
///
/// Minted by the hook as `pid-machTime-counter`, which is unique without
/// needing a random source or coordination between concurrent hook processes.
public struct EventID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}
