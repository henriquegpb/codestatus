import Foundation

/// Watches agent processes for the one thing process observation is allowed to
/// decide: that a process stopped existing.
///
/// Death is detected with `EVFILT_PROC`/`NOTE_EXIT` — the kernel tells us the
/// instant the process exits, with no polling and no interval to tune. That
/// matters because the alternative, decaying a session after N seconds of
/// silence, misclassifies a genuinely busy agent: a six-minute build or test run
/// emits no hooks at all and would be declared dead by a timer.
///
/// `DispatchSource.makeProcessSource` rather than a hand-rolled kqueue, for two
/// verified reasons:
///
/// 1. libdispatch multiplexes every `EVFILT_PROC` registration onto its own
///    shared kqueue. Twenty watched processes cost zero extra file descriptors
///    (measured), where a private kqueue would cost one descriptor plus a read
///    source plus manual `EV_SET` bookkeeping and re-arming.
/// 2. Registering against a pid that has *already* exited still delivers the
///    exit event (measured) instead of silently dropping it, which closes the
///    race between discovering a process and subscribing to it.
///
/// Everything here is discovery, reconciliation, and exit detection. Nothing
/// here ever infers what an agent is doing — hooks own that.
public final class ProcessWatcher: @unchecked Sendable {

    public struct Configuration: Sendable {
        /// How often to re-scan for agents nobody told us about — a VS Code
        /// window opened before the app launched, or a session whose hooks are
        /// not installed yet. It is a safety net, not the mechanism, so it can
        /// be slow and lazy.
        ///
        /// Injectable so tests drive sweeps explicitly instead of waiting on the
        /// wall clock. Zero or infinite disables the timer entirely.
        public var safetySweepInterval: TimeInterval
        public var sweepOnStart: Bool

        public init(safetySweepInterval: TimeInterval = 120, sweepOnStart: Bool = true) {
            self.safetySweepInterval = safetySweepInterval
            self.sweepOnStart = sweepOnStart
        }
    }

    /// A process currently subscribed to, remembered with its start time so a
    /// recycled pid can never be mistaken for the process we meant to watch.
    public struct Watch: Sendable, Equatable {
        public let pid: pid_t
        public let startTime: UInt64
        public let provider: AgentProvider
    }

    private let inspector: ProcessInspector
    private let configuration: Configuration
    private let onDiscovered: @Sendable (AgentProcess) -> Void
    private let onExit: @Sendable (AgentEvent) -> Void

    /// Guards all mutable state below.
    private let queue = DispatchQueue(label: "co.codestatus.process", qos: .utility)
    /// Callbacks are delivered here, never on `queue`, so a handler is free to
    /// call back into `stop()` or `watch(pid:provider:)` without deadlocking on
    /// the lock it is already inside.
    private let delivery = DispatchQueue(label: "co.codestatus.process.delivery", qos: .utility)

    private var sources: [pid_t: DispatchSourceProcess] = [:]
    private var watches: [pid_t: Watch] = [:]
    private var discovered: Set<SessionID> = []
    private var timer: DispatchSourceTimer?
    private var running = false

    public init(
        configuration: Configuration = Configuration(),
        inspector: ProcessInspector = ProcessInspector(),
        onDiscovered: @escaping @Sendable (AgentProcess) -> Void = { _ in },
        onExit: @escaping @Sendable (AgentEvent) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.inspector = inspector
        self.onDiscovered = onDiscovered
        self.onExit = onExit
    }

    deinit {
        // Sources must be cancelled before they are released; a suspended or
        // still-armed source that is deallocated traps.
        for source in sources.values { source.cancel() }
        timer?.cancel()
    }

    // MARK: - Lifecycle

    /// Idempotent: starting an already-running watcher does nothing.
    public func start() {
        queue.sync {
            guard !running else { return }
            running = true
            if configuration.sweepOnStart { performSweep() }
            scheduleTimer()
        }
    }

    /// Drops every subscription. Safe to call repeatedly, and safe to call from
    /// inside a callback.
    ///
    /// Deliberately silent: stopping the watcher is not evidence that any agent
    /// exited, so it must not synthesise exit events.
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            for source in sources.values { source.cancel() }
            sources.removeAll()
            watches.removeAll()
            discovered.removeAll()
            running = false
        }
    }

    /// Runs a discovery sweep now: at launch, on wake, and whenever the app has
    /// reason to believe it missed something.
    ///
    /// Synchronous, and costs about 4 ms on a machine with 500 processes.
    public func sweep() {
        queue.sync { performSweep() }
    }

    public var activeWatches: [Watch] {
        queue.sync { Array(watches.values) }
    }

    // MARK: - Watching

    /// Subscribes to a process discovered elsewhere — typically a pid learned
    /// from a hook event, which is authoritative and may name a binary the path
    /// table does not recognise.
    ///
    /// Returns false if the process is already gone, in which case the exit is
    /// reported immediately rather than waited for forever.
    @discardableResult
    public func watch(pid: pid_t, provider: AgentProvider) -> Bool {
        guard let snapshot = inspector.snapshot(pid: pid) else {
            deliverExit(pid: pid, startTime: 0, provider: provider)
            return false
        }
        return watch(pid: pid, startTime: snapshot.startTime, provider: provider)
    }

    /// Subscribes to an exactly identified process. Returns false when that
    /// process was already being watched.
    @discardableResult
    public func watch(pid: pid_t, startTime: UInt64, provider: AgentProvider) -> Bool {
        queue.sync { register(pid: pid, startTime: startTime, provider: provider) }
    }

    /// The exit event a dead process produces.
    ///
    /// The id is derived, not minted from a counter, so the same death observed
    /// twice — by the kqueue subscription and by a reconciliation sweep — is one
    /// event that the registry's de-duplicator collapses on its own.
    public static func exitEvent(
        pid: pid_t, startTime: UInt64, provider: AgentProvider, at timestamp: Date = Date()
    ) -> AgentEvent {
        AgentEvent(
            id: EventID("exit-\(pid)-\(startTime)"),
            provider: provider,
            kind: .processExited,
            source: .process,
            timestamp: timestamp,
            pid: pid
        )
    }

    // MARK: - Internals, all on `queue`

    private func scheduleTimer() {
        let interval = configuration.safetySweepInterval
        guard interval > 0, interval.isFinite else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway: this sweep only backstops the hooks, so letting the
        // kernel coalesce it with other wakeups is worth more than punctuality.
        let leeway = Int(max(1, min(interval / 10, 60)))
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(leeway))
        source.setEventHandler { [weak self] in self?.performSweep() }
        timer = source
        source.resume()
    }

    private func performSweep() {
        for agent in inspector.discoverAgents() {
            let isNew = register(pid: agent.pid, startTime: agent.startTime, provider: agent.provider)
            // Identity carries the start time, so a recycled pid is reported as
            // the new process it is rather than suppressed as a duplicate.
            let identity = SessionID.process(agent.provider, pid: agent.pid, startTime: agent.startTime)
            guard isNew, discovered.insert(identity).inserted else { continue }
            let callback = onDiscovered
            delivery.async { callback(agent) }
        }
    }

    private func register(pid: pid_t, startTime: UInt64, provider: AgentProvider) -> Bool {
        if let existing = watches[pid] {
            guard existing.startTime != startTime else { return false }
            // The pid was recycled between observations: the process we were
            // watching is definitively gone, so report it before re-targeting.
            finish(existing)
        }

        watches[pid] = Watch(pid: pid, startTime: startTime, provider: provider)

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleExit(pid: pid, startTime: startTime)
        }
        sources[pid] = source
        source.resume()

        // Closes the window between observing the process and subscribing to it:
        // if it died in between, or the pid already belongs to something else,
        // the exit is reported now instead of never.
        if !inspector.isAlive(pid: pid, startTime: startTime) {
            handleExit(pid: pid, startTime: startTime)
        }
        return true
    }

    private func handleExit(pid: pid_t, startTime: UInt64) {
        guard let watch = watches[pid], watch.startTime == startTime else { return }
        finish(watch)
    }

    private func finish(_ watch: Watch) {
        watches.removeValue(forKey: watch.pid)
        sources.removeValue(forKey: watch.pid)?.cancel()
        discovered.remove(SessionID.process(watch.provider, pid: watch.pid, startTime: watch.startTime))
        deliverExit(pid: watch.pid, startTime: watch.startTime, provider: watch.provider)
    }

    private func deliverExit(pid: pid_t, startTime: UInt64, provider: AgentProvider) {
        let event = Self.exitEvent(pid: pid, startTime: startTime, provider: provider)
        let callback = onExit
        delivery.async { callback(event) }
    }
}
