import Foundation

/// Stable identity for a session, independent of any visible window.
public struct SessionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// Preferred identity: the agent told us its own session id.
    public static func provider(_ provider: AgentProvider, _ sessionID: String) -> SessionID {
        SessionID("\(provider.rawValue):\(sessionID)")
    }

    /// Fallback identity when no provider session id is known.
    ///
    /// Start time is part of the key because pids are recycled — a pid alone
    /// would let a brand new process inherit a dead session's state.
    public static func process(_ provider: AgentProvider, pid: pid_t, startTime: UInt64) -> SessionID {
        SessionID("\(provider.rawValue):pid-\(pid)-\(startTime)")
    }
}

/// How CodeStatus can reach a session to bring the user back to it.
public struct ControlTarget: Sendable, Codable, Equatable {
    public var hostApplication: HostApplication
    /// The TTY device, e.g. `/dev/ttys003`, used to select the exact tab.
    public var tty: String?
    /// `TERM_SESSION_ID`, where the terminal provides one.
    public var termSessionID: String?
    /// Folder or workspace to open, for editor-hosted sessions.
    public var workspacePath: String?

    public init(
        hostApplication: HostApplication = .unknown,
        tty: String? = nil,
        termSessionID: String? = nil,
        workspacePath: String? = nil
    ) {
        self.hostApplication = hostApplication
        self.tty = tty
        self.termSessionID = termSessionID
        self.workspacePath = workspacePath
    }
}

/// Tracks event ordering within a session so that duplicated or late-arriving
/// events cannot corrupt state.
///
/// Hooks run concurrently and asynchronously, so delivery order is not
/// guaranteed. Turn ids are opaque strings with no inherent order, so we assign
/// each newly seen turn a monotonically increasing sequence number.
///
/// A turn is not the finest grain that matters, though: one turn contains many
/// tool uses, and ``AgentEvent/rank`` describes the shape of a *single* one —
/// `PreToolUse` before `PermissionRequest` before `PostToolUse`. Ordering a
/// whole turn by rank alone therefore starves every tool use after the first:
/// once a `PostToolUse` has pushed the floor to 4, the next tool's `PreToolUse`
/// (2) and `PermissionRequest` (3) are both rejected as out-of-order. That is
/// invisible while every tool maps to `busy` — and very visible the moment a
/// tool blocks on the user, because the session sits on `busy` for as long as
/// the person is being asked a question.
///
/// So events are ordered by `(turnSequence, stepSequence, rank)`, where a step
/// is one tool use. Rank keeps its straggler duty inside a step; steps keep
/// tool uses from starving each other.
public struct LogicalClock: Sendable, Codable, Equatable {
    private(set) var turnSequence: Int
    private(set) var lastAppliedRank: Int
    private(set) var currentTurnID: String?
    private(set) var stepSequence: Int
    private(set) var currentToolUseID: String?
    private(set) var currentToolName: String?

    public init() {
        turnSequence = 0
        lastAppliedRank = -1
        currentTurnID = nil
        stepSequence = 0
        currentToolUseID = nil
        currentToolName = nil
    }

    /// Decoded leniently so a snapshot written before steps existed still
    /// restores: a session that comes back without them simply starts at step 0.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turnSequence = try container.decode(Int.self, forKey: .turnSequence)
        lastAppliedRank = try container.decode(Int.self, forKey: .lastAppliedRank)
        currentTurnID = try container.decodeIfPresent(String.self, forKey: .currentTurnID)
        stepSequence = try container.decodeIfPresent(Int.self, forKey: .stepSequence) ?? 0
        currentToolUseID = try container.decodeIfPresent(String.self, forKey: .currentToolUseID)
        currentToolName = try container.decodeIfPresent(String.self, forKey: .currentToolName)
    }

    /// Position of an event in this session's timeline, assigning a new turn
    /// sequence if the event belongs to a turn we have not seen yet.
    func position(for event: AgentEvent) -> (turn: Int, step: Int, rank: Int) {
        guard let turnID = event.providerTurnID, turnID != currentTurnID else {
            return (turnSequence, step(for: event), event.rank)
        }
        // A turn we have not seen: it is newer than everything so far, and its
        // first tool use starts the step count over.
        return (turnSequence + 1, 0, event.rank)
    }

    /// Which tool use an event belongs to.
    ///
    /// `PreToolUse` and `PostToolUse` carry `tool_use_id` and identify their step
    /// exactly. `PermissionRequest` does not — verified against Claude Code
    /// 2.1.247, which sends only `tool_name` on it — so it is matched by tool
    /// name instead, which is enough because it always concerns the tool use
    /// currently in flight. Matching by name also holds the line when the two
    /// arrive out of order: a `PreToolUse` that loses the race to its own
    /// `PermissionRequest` lands in the step that request opened, where its
    /// lower rank rejects it rather than dragging the session back to `busy`.
    private func step(for event: AgentEvent) -> Int {
        guard let name = event.toolName else { return stepSequence }
        guard let id = event.toolUseID else {
            return name == currentToolName ? stepSequence : stepSequence + 1
        }
        guard let current = currentToolUseID else {
            // The current step was opened by an event carrying no id.
            return name == currentToolName ? stepSequence : stepSequence + 1
        }
        return id == current ? stepSequence : stepSequence + 1
    }

    /// Whether an event is new enough to apply.
    public func accepts(_ event: AgentEvent) -> Bool {
        if event.isTerminal { return true }
        let pos = position(for: event)
        if pos.turn != turnSequence { return pos.turn > turnSequence }
        if pos.step != stepSequence { return pos.step > stepSequence }
        return pos.rank >= lastAppliedRank
    }

    /// Records that an event was applied.
    public mutating func advance(with event: AgentEvent) {
        let pos = position(for: event)
        guard pos.turn >= turnSequence else { return }

        let startsNewTurn = pos.turn > turnSequence
        let startsNewStep = startsNewTurn || pos.step > stepSequence

        if startsNewTurn {
            turnSequence = pos.turn
            currentTurnID = event.providerTurnID
            currentToolName = nil
            currentToolUseID = nil
        } else if currentTurnID == nil {
            currentTurnID = event.providerTurnID
        }

        if startsNewStep {
            stepSequence = pos.step
            lastAppliedRank = pos.rank
        } else if pos.step == stepSequence {
            lastAppliedRank = max(lastAppliedRank, pos.rank)
        }

        // Only a tool event names the step; a Stop or Notification in between
        // must not erase whose step we are in.
        if event.toolName != nil {
            currentToolName = event.toolName
            currentToolUseID = event.toolUseID
        }
    }
}

/// Everything known about one agent session.
public struct AgentSession: Identifiable, Sendable, Codable, Equatable {
    public let id: SessionID
    public var provider: AgentProvider

    // Provider identity
    public var providerSessionID: String?
    public var providerTurnID: String?

    // State
    public var state: AgentState
    public var previousState: AgentState?
    public var stateConfidence: StateConfidence
    public var stateChangedAt: Date
    public var startedAt: Date
    public var lastEventAt: Date

    // Process identity
    public var pid: pid_t?
    public var parentPID: pid_t?
    public var processStartTime: UInt64?
    public var tty: String?

    // Location
    public var cwd: String?
    public var gitRoot: String?
    public var repositoryName: String?
    public var workspaceName: String?

    // Host
    public var hostApplication: HostApplication
    public var hostBundleIdentifier: String?

    // Wiring
    public var sourceAdapter: String
    public var capabilities: Capability
    public var controlTarget: ControlTarget
    public var lastError: String?

    /// Whether an official hook event has ever arrived for this session.
    ///
    /// The distinction the HUD is built on. Process discovery proves a session
    /// *exists*; only a hook says what it is doing. A session we found but have
    /// never heard from cannot contribute to "how many are busy" — counting it
    /// would answer that question with a number that is partly guesswork.
    public var hasHookEvidence: Bool = false

    /// Ordering guard; not part of the user-visible model.
    public var clock: LogicalClock

    public init(
        id: SessionID,
        provider: AgentProvider,
        state: AgentState = .discovering,
        stateConfidence: StateConfidence = .low,
        now: Date,
        sourceAdapter: String
    ) {
        self.id = id
        self.provider = provider
        self.state = state
        self.previousState = nil
        self.stateConfidence = stateConfidence
        self.stateChangedAt = now
        self.startedAt = now
        self.lastEventAt = now
        self.hostApplication = .unknown
        self.sourceAdapter = sourceAdapter
        self.capabilities = []
        self.controlTarget = ControlTarget()
        self.clock = LogicalClock()
    }

    /// Best available human label for the session: repo, then workspace, then
    /// the last path component of the working directory.
    ///
    /// A process whose working directory is `/` — anything launched by a daemon
    /// rather than from a shell — would otherwise be labelled `/`, which reads
    /// as a bug rather than as a name. Falling through to the provider is less
    /// informative and more honest.
    public var displayName: String {
        if let repositoryName, !repositoryName.isEmpty { return repositoryName }
        if let workspaceName, !workspaceName.isEmpty { return workspaceName }
        if let cwd, !cwd.isEmpty {
            let component = (cwd as NSString).lastPathComponent
            if !component.isEmpty && component != "/" { return component }
        }
        return provider.displayName
    }

    /// How long the session has been in its current state.
    public func duration(at now: Date) -> TimeInterval {
        now.timeIntervalSince(stateChangedAt)
    }
}
