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
    /// Claude Code only: a tool that ended in an error. Its *replacement* for
    /// `PostToolUse`, not a companion to it — a failing tool emits this and
    /// nothing else, so without it a failed tool use never closes.
    case postToolUseFailure = "PostToolUseFailure"
    /// Claude Code only: every tool in a parallel batch has settled.
    case postToolBatch = "PostToolBatch"
    case permissionRequest = "PermissionRequest"
    /// Claude Code only.
    case permissionDenied = "PermissionDenied"
    /// Claude Code only. Meaning depends on ``AgentEvent/notificationType``.
    case notification = "Notification"
    /// Claude Code only: an MCP server is asking the user something and the
    /// tool call is blocked until they answer.
    case elicitation = "Elicitation"
    /// Claude Code only: that answer arrived, whatever it was.
    case elicitationResult = "ElicitationResult"
    case stop = "Stop"
    /// Claude Code only: the turn ended because of an API error.
    case stopFailure = "StopFailure"
    case subagentStop = "SubagentStop"
    case sessionEnd = "SessionEnd"

    /// Synthesised locally when the process disappears without a `SessionEnd`.
    case processExited = "__processExited"
}

/// The `notification_type` values we act on.
///
/// Claude Code 2.1.247 emits fourteen — `permission_prompt`, `idle_prompt`,
/// `auth_success`, `elicitation_dialog`, `agent_needs_input`, `agent_completed`,
/// `elicitation_url_dialog`, `worker_permission_prompt`, `push_notification`,
/// `computer_use_enter`, `computer_use_exit`, and three `quota_auto_resume_*`
/// variants. Only the two that describe *this* session's state are modelled;
/// everything else is deliberately absent so it decodes to `nil` and no-ops.
///
/// `agent_needs_input` and `agent_completed` are the trap in that list. Both
/// read like the signal we want, and neither is about the session whose hook
/// fired: they come from the fleet-view watcher and describe some *other*
/// agent — a background task or a teammate — changing band. Acting on them
/// would mark this session free, or blocked, because a different one did.
public enum NotificationType: String, Codable, Sendable {
    case permissionPrompt = "permission_prompt"
    case idlePrompt = "idle_prompt"
}

/// Tools whose *call* is the question, rather than an action awaiting consent.
///
/// Claude Code routes these through the ordinary permission pipeline: they
/// declare `requiresUserInteraction()`, which forces `behavior: "ask"` no matter
/// what the permission mode says. Verified against 2.1.247 — a blocked
/// `AskUserQuestion` emits `PreToolUse` immediately, `PermissionRequest` about
/// 3ms later, and `Notification(permission_prompt)` about six seconds later.
///
/// Without this list they land on ``AgentState/waitingForApproval``, which tells
/// the user to go review a command that does not exist. The state is right that
/// the session is blocked and wrong about what it is blocked on.
///
/// Not exhaustive by construction: an MCP server can mark its own tools with
/// `anthropic/requiresUserInteraction`, and those names cannot be known here.
/// They keep landing on approval, which stays true enough — blocked is blocked.
public let toolsThatAskTheUser: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

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

    /// Whether this event concerns a tool that blocks waiting for the user to
    /// answer, rather than to approve. See ``toolsThatAskTheUser``.
    var asksTheUser: Bool {
        guard let toolName else { return false }
        return toolsThatAskTheUser.contains(toolName)
    }

    /// Ordering position of this event *within one tool use*.
    ///
    /// Ranks exist to reject stragglers that would otherwise regress a session.
    /// The important gaps:
    ///
    /// - `permissionRequest` outranks `preToolUse`, so a late `PreToolUse`
    ///   cannot knock a session out of a waiting state back into `busy`.
    /// - `postToolUse` outranks `permissionRequest`, so the tool actually
    ///   running after approval *does* correctly return the session to `busy`.
    ///
    /// The scope matters: a turn holds many tool uses, and this ladder only
    /// describes the shape of one. ``LogicalClock`` is what keeps a second tool
    /// use from being ordered against the first one's high-water mark.
    var rank: Int {
        switch kind {
        case .sessionStart: return 0
        case .userPromptSubmit: return 1
        case .preToolUse: return 2
        case .permissionRequest, .permissionDenied: return 3
        // An MCP server's question arrives *after* its tool's permission check
        // and carries neither `tool_name` nor `tool_use_id`, so it rides in the
        // step that check opened. Equal rank is what lets it in there.
        //
        // The cost of having no identifier of its own: a server that raises a
        // second elicitation inside one tool call has its later questions
        // outranked by the first result. The session reads `busy` rather than
        // blocked until `PostToolUse` closes the step. Rare, and it errs toward
        // under-claiming rather than inventing a block that is not there.
        case .elicitation: return 3
        case .notification:
            switch notificationType {
            // `permission_prompt` is the same fact as `PermissionRequest`,
            // announced about six seconds later and without the `tool_name`
            // that tells a question apart from an approval. Ranking it just
            // below `permissionRequest` keeps it in its proper role — the
            // backstop that fires when that hook was never delivered — instead
            // of arriving late to relabel a question as an approval.
            case .permissionPrompt: return 2
            // `idle_prompt` means the turn is long over and the prompt has been
            // sitting untouched, so it has to outrank `stop`. At rank 3 it was
            // rejected by every session that had actually finished a turn,
            // which is every session that can produce it.
            case .idlePrompt: return 9
            case nil: return 3
            }
        case .postToolUse, .postToolUseFailure, .elicitationResult: return 4
        case .subagentStop: return 5
        // The batch closes after every tool in it has settled, so it outranks
        // the individual results it summarises.
        case .postToolBatch: return 6
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
