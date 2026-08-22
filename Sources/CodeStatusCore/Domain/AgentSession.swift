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
/// each newly seen turn a monotonically increasing sequence number and order
/// events by `(turnSequence, rank)`.
public struct LogicalClock: Sendable, Codable, Equatable {
    private(set) var turnSequence: Int
    private(set) var lastAppliedRank: Int
    private(set) var currentTurnID: String?

    public init() {
        turnSequence = 0
        lastAppliedRank = -1
        currentTurnID = nil
    }

    /// Position of an event in this session's timeline, assigning a new turn
    /// sequence if the event belongs to a turn we have not seen yet.
    ///
    /// Returns `nil` for events that carry no turn and cannot be ordered, which
    /// the caller treats as "always current".
    func position(for event: AgentEvent) -> (turn: Int, rank: Int) {
        guard let turnID = event.providerTurnID else {
            return (turnSequence, event.rank)
        }
        if turnID == currentTurnID {
            return (turnSequence, event.rank)
        }
        // A turn we have not seen: it is newer than everything so far.
        return (turnSequence + 1, event.rank)
    }

    /// Whether an event is new enough to apply.
    public func accepts(_ event: AgentEvent) -> Bool {
        if event.isTerminal { return true }
        let pos = position(for: event)
        if pos.turn > turnSequence { return true }
        if pos.turn < turnSequence { return false }
        return pos.rank >= lastAppliedRank
    }

    /// Records that an event was applied.
    public mutating func advance(with event: AgentEvent) {
        let pos = position(for: event)
        if pos.turn > turnSequence {
            turnSequence = pos.turn
            currentTurnID = event.providerTurnID
            lastAppliedRank = pos.rank
        } else if pos.turn == turnSequence {
            lastAppliedRank = max(lastAppliedRank, pos.rank)
            if currentTurnID == nil { currentTurnID = event.providerTurnID }
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
