import AppKit
import CodeStatusCore
import Foundation
import os

/// Wires the runtime together and owns the one true ``SessionRegistry``.
///
/// Everything that learns something about a session — the socket, the process
/// watcher, the spool, a restored snapshot — funnels through `apply(_:)` on the
/// main actor. That single choke point is what makes "one notification per
/// transition" enforceable: there is exactly one place where a transition can
/// be observed, so there is exactly one place that can emit.
@MainActor
final class SessionDaemon {

    private var registry = SessionRegistry()
    private var sleepWake = SleepWakeCoordinator()

    private let model: HUDModel
    private let notifications: NotificationCoordinator
    private let paths: RuntimePaths
    private let spool: EventSpool
    private let persistence: StatePersistence
    private let logger = Logger(subsystem: "co.codestatus", category: "daemon")

    private var socketServer: EventSocketServer?
    private var processWatcher: ProcessWatcher?
    private var heartbeatTimer: Timer?
    private var tickTimer: Timer?
    private var powerObservers: [(NotificationCenter, NSObjectProtocol)] = []

    /// How long an ended session stays visible before leaving the counters, so
    /// the user sees it finish rather than having a row vanish under the cursor.
    private let endedLinger: TimeInterval = 4

    var onRegistryChanged: (() -> Void)?

    init(
        model: HUDModel,
        notifications: NotificationCoordinator,
        paths: RuntimePaths = RuntimePaths()
    ) {
        self.model = model
        self.notifications = notifications
        self.paths = paths
        spool = EventSpool(paths: paths)
        persistence = StatePersistence(paths: paths)
    }

    // MARK: - Lifecycle

    func start() {
        do {
            try paths.createDirectories()
        } catch {
            logger.error("could not create runtime directories: \(error.localizedDescription, privacy: .public)")
        }

        restoreSnapshot()
        startSocketServer()
        startProcessWatcher()
        startTimers()
        observePower()

        // A restart is indistinguishable from a wake: we missed events either
        // way, so we reconcile rather than trusting what we restored.
        perform(sleepWake.handle(.daemonRestarted(Date())))
        publish()
    }

    func stop() {
        heartbeatTimer?.invalidate()
        tickTimer?.invalidate()
        heartbeatTimer = nil
        tickTimer = nil
        for (center, token) in powerObservers { center.removeObserver(token) }
        powerObservers.removeAll()
        processWatcher?.stop()
        processWatcher = nil
        socketServer?.stop()
        socketServer = nil
        saveSnapshot()
    }

    // MARK: - Inputs

    private func startSocketServer() {
        let server = EventSocketServer(
            paths: paths,
            onEvent: { [weak self] event in
                Task { @MainActor in self?.apply(event) }
            },
            onDecodeFailure: { [logger] error in
                // Never log the offending line: it is the one thing that might
                // carry content if a future agent version adds a field we do not
                // expect. The error alone is enough to diagnose.
                logger.debug("rejected an event: \(String(describing: error), privacy: .public)")
            }
        )
        do {
            try server.start()
            socketServer = server
            server.writeHeartbeat()
            logger.info("listening on \(server.socketURL?.path ?? "unknown", privacy: .public)")
        } catch {
            logger.error("socket server failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startProcessWatcher() {
        let watcher = ProcessWatcher(
            onDiscovered: { [weak self] process in
                Task { @MainActor in self?.adopt(process) }
            },
            onExit: { [weak self] event in
                Task { @MainActor in self?.apply(event) }
            }
        )
        watcher.start()
        processWatcher = watcher
    }

    private func startTimers() {
        // The heartbeat is what permits the hook to spool. If we stop touching
        // it, a stale install stops accumulating files — see EventSpool.
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.socketServer?.writeHeartbeat() }
        }

        // Durations in the HUD need to advance, and ended sessions need to age
        // out. One shared timer rather than one per row.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func observePower() {
        let center = NSWorkspace.shared.notificationCenter
        let sleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.perform(self?.handlePower(.willSleep(Date())) ?? []) }
        }
        let wake = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.perform(self?.handlePower(.didWake(Date())) ?? []) }
        }
        powerObservers = [(center, sleep), (center, wake)]
    }

    private func handlePower(_ event: PowerEvent) -> [ReconciliationAction] {
        sleepWake.handle(event)
    }

    // MARK: - Applying evidence

    private func apply(_ event: AgentEvent) {
        let results = registry.ingest(event)
        handle(results)
    }

    private func adopt(_ process: AgentProcess) {
        // Enters `.unknown`, never a guessed state: we know a session exists but
        // have no evidence of what it is doing.
        guard let added = registry.adopt(
            provider: process.provider,
            pid: process.pid,
            startTime: process.startTime,
            now: Date()
        ) else { return }
        handle([added])
        enrich(pid: process.pid)
    }

    private func handle(_ results: [RegistryEvent]) {
        var changed = false
        for result in results {
            switch result {
            case .sessionAdded(let id):
                changed = true
                if let session = registry[id], let pid = session.pid { enrich(pid: pid) }

            case .sessionChanged(let transition):
                changed = true
                guard let session = registry[transition.sessionID] else { continue }
                // The stale filter is what prevents a wake from firing a burst
                // of notifications for turns that finished hours ago.
                if sleepWake.shouldNotify(for: transition, now: Date()) {
                    notifications.handle(transition, session: session)
                }

            case .sessionRefreshed, .sessionRemoved:
                changed = true

            case .eventDropped(let id, let reason):
                logger.debug("dropped \(id.rawValue, privacy: .public): \(reason.rawValue, privacy: .public)")
            }
        }
        if changed { publish() }
    }

    /// Fills in the details a hook cannot know: tty, working directory, git root,
    /// and which application is hosting the session.
    private func enrich(pid: pid_t) {
        let inspector = ProcessInspector()
        guard let snapshot = inspector.snapshot(pid: pid) else { return }
        guard var session = registry.all.first(where: { $0.pid == pid }) else { return }

        session.parentPID = snapshot.parentPID
        session.processStartTime = snapshot.startTime
        if let tty = snapshot.tty {
            session.tty = tty
            session.controlTarget.tty = tty
            // A tty means we can name the exact tab, not just the application.
            session.capabilities.insert(.canIdentifyExactWindow)
        }
        if session.cwd == nil { session.cwd = inspector.workingDirectory(of: pid) }
        if let cwd = session.cwd {
            let root = Self.gitRoot(for: cwd)
            session.gitRoot = root
            session.repositoryName = root.map { ($0 as NSString).lastPathComponent }
            session.controlTarget.workspacePath = root ?? cwd
        }
        registry.update(session)
    }

    /// Walks up from a directory looking for a `.git` entry.
    ///
    /// Deliberately a filesystem walk rather than shelling out to `git`: this
    /// runs for every discovered session, and spawning a process per session
    /// would be both slower and one more thing that can hang.
    private static func gitRoot(for path: String) -> String? {
        var current = URL(fileURLWithPath: path).standardizedFileURL
        for _ in 0..<32 {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    // MARK: - Reconciliation

    private func perform(_ actions: [ReconciliationAction]) {
        for action in actions {
            switch action {
            case .saveSnapshot:
                saveSnapshot()
            case .markAllReconnecting(let date):
                registry.markAllReconnecting(now: date)
            case .drainSpool:
                let report = spool.drain { [weak self] event in
                    self?.apply(event)
                }
                let dropped = report.undecodable + report.unreadable + report.oversized
                if dropped > 0 || report.deferred > 0 {
                    // Report rather than hide: silently truncating a backlog
                    // would read as "everything was replayed" when it was not.
                    logger.notice("""
                        spool: \(report.delivered) replayed, \(dropped) dropped, \
                        \(report.deferred) deferred
                        """)
                }
            case .sweepProcesses:
                processWatcher?.sweep()
            }
        }
        publish()
    }

    private func restoreSnapshot() {
        switch persistence.load() {
        case .restored(let snapshot):
            for session in snapshot.sessions where session.state.isActive {
                registry.update(session)
            }
            logger.info("restored \(snapshot.sessions.count) sessions")
        case .none:
            break
        case .discarded(let reason):
            logger.notice("discarded snapshot: \(reason.rawValue, privacy: .public)")
        }
    }

    private func saveSnapshot() {
        do {
            try persistence.save(registry.all.filter { $0.state.isActive })
        } catch {
            logger.error("snapshot save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Output

    private func tick() {
        let now = Date()
        let removed = registry.pruneEnded(olderThan: endedLinger, now: now)
        if removed.isEmpty {
            model.tick(now)
        } else {
            publish(now)
        }
    }

    private func publish(_ now: Date = Date()) {
        model.apply(registry, now: now)
        onRegistryChanged?()
    }

    /// Re-scans after onboarding installs hooks, so sessions that were already
    /// running show up without waiting for the next safety sweep.
    func refreshAdapters() {
        processWatcher?.sweep()
        publish()
    }

    // MARK: - Reading, for other surfaces

    var sessions: [AgentSession] { registry.visible }

    func session(withID id: SessionID) -> AgentSession? { registry[id] }

    var socketStats: EventSocketServer.Stats? { socketServer?.currentStats() }
}
