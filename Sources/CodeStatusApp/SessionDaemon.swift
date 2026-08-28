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

    /// When each provider's hook configuration was written.
    ///
    /// Cached rather than read per publish: this is a file read, and publish
    /// runs on every event. It only changes when we install or uninstall, and
    /// both of those paths reload it.
    private var hooksInstalledAt: [AgentProvider: Date] = [:]

    /// Providers whose hook entries are in their config file.
    ///
    /// Read rather than inferred from the receipts, because the two disagree in
    /// the direction that matters: a receipt proves we once wrote the file, not
    /// that the entries are still there. A user who edited their settings by
    /// hand, or restored them from a dotfiles repo, has a receipt and no hooks,
    /// and would otherwise be told to go and trust hooks that are not in the
    /// file.
    ///
    /// Cached for the same reason as ``hooksInstalledAt``: answering it costs
    /// two file reads and two JSON parses, and `publish` runs on every event.
    private var connectedProviders: Set<AgentProvider> = []

    /// Which providers have ever actually delivered a hook event to us.
    ///
    /// Separate from the install receipts on purpose: those record what we
    /// wrote, this records what came back. Setup can only claim an agent works
    /// on the strength of the second one — writing `~/.codex/hooks.json`
    /// perfectly and having Codex ignore it for want of `/hooks` produces an
    /// impeccable receipt and total silence.
    private var evidenceLedger = HookEvidenceLedger()
    private lazy var evidenceStore = HookEvidenceStore(paths: paths)

    var hookEvidence: [AgentProvider: HookEvidence] { evidenceLedger.table }

    /// Fired the first time a provider is heard from, so a setup screen waiting
    /// on exactly that can stop waiting.
    var onProviderVerified: ((AgentProvider) -> Void)?

    /// So the "Codex is not reporting" notice is posted once per run rather
    /// than on every sweep that re-observes the same silent session.
    private var didWarnAboutCodexTrust = false

    /// Which set of unconnected agents we have already mentioned, so the notice
    /// returns if a *different* agent appears but never repeats itself.
    private var didWarnAboutUnconnected: Set<String> = []

    /// Sessions the user dismissed by hand, so process discovery does not
    /// immediately re-adopt what they just cleared away.
    private var dismissed: Set<SessionID> = []

    private var ticksSinceReap = 0

    /// Seconds between liveness sweeps of the registry.
    ///
    /// A backstop, not the mechanism: `EVFILT_PROC` reports an exit the instant
    /// it happens, and this only catches sessions we somehow never subscribed
    /// to. Checking a handful of pids is a sysctl each, so the interval is
    /// about keeping the work invisible rather than about accuracy.
    private static let reapInterval = 10

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

        reloadInstallReceipts()
        evidenceLedger = HookEvidenceLedger(evidenceStore.load())
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
        if event.source == .hook { recordHookEvidence(for: event.provider) }
        let results = registry.ingest(event)
        // A hook event is the session telling us it is alive. Honouring a
        // dismissal past that point would mean hiding a working session, which
        // is the same failure as showing a dead one with the sign flipped.
        if event.source == .hook, !dismissed.isEmpty {
            for result in results {
                if case .sessionAdded(let id) = result { dismissed.remove(id) }
                if case .sessionChanged(let transition) = result {
                    dismissed.remove(transition.sessionID)
                }
            }
        }
        handle(results)
    }

    /// Notes that a provider's hooks are demonstrably running.
    ///
    /// The write is skipped on all but the first event and the occasional
    /// refresh — see ``HookEvidenceStore/writeInterval`` — because this sits on
    /// the path every tool call takes.
    private func recordHookEvidence(for provider: AgentProvider) {
        let outcome = evidenceLedger.record(provider)
        if outcome.shouldPersist {
            do {
                try evidenceStore.save(evidenceLedger.table)
            } catch {
                logger.error("could not record hook evidence: \(error.localizedDescription, privacy: .public)")
            }
        }
        if outcome.isFirstEver {
            logger.info("first hook event from \(provider.rawValue, privacy: .public)")
            onProviderVerified?(provider)
        }
    }

    /// Replays anything the hook had to leave on disk.
    ///
    /// The spool is the hook's fallback for when it cannot reach the socket, and
    /// until now it was only ever read during reconciliation — at launch and on
    /// wake. So a daemon that was running but unreachable never read it, and the
    /// events piled up unseen while the UI went on displaying whatever state it
    /// had last heard about, with total confidence.
    ///
    /// That is not hypothetical. A second copy of the app binds the socket by
    /// unlinking whatever is at the path, which takes it away from the daemon
    /// already listening; the first daemon keeps a descriptor nothing can reach.
    /// It stayed alive, kept touching the heartbeat — which is precisely what
    /// permits the hook to keep spooling — and accumulated 302 undelivered
    /// events over 28 minutes while showing sessions as free that were not.
    ///
    /// Reading the spool on the reap cadence closes that. It costs a directory
    /// listing every ten seconds and it means a daemon can be deaf on the socket
    /// and still be correct, because the hook's fallback finally has a reader.
    private func drainSpoolIfNotEmpty() {
        let report = spool.drain { [weak self] event in
            self?.apply(event)
        }
        guard report.delivered > 0 || report.deferred > 0 else { return }
        // Worth a line: a healthy machine never gets here, so anything replayed
        // this way means direct delivery was not working.
        logger.notice("""
            replayed \(report.delivered, privacy: .public) spooled events \
            (\(report.deferred, privacy: .public) deferred) — the socket was not \
            reachable when they were written
            """)
        publish()
    }

    /// Ends any session whose process is no longer there.
    ///
    /// Belt to the kqueue's braces. Every path that should have caught these is
    /// now wired, but a session whose exit we miss is invisible-by-omission in
    /// the worst way: it claims an agent is busy when nothing is running, which
    /// is precisely the report that makes the whole app untrustworthy.
    private func reapDeadSessions() {
        let inspector = ProcessInspector()
        for session in registry.all where session.state.isActive {
            guard let pid = session.pid else { continue }
            let alive = session.processStartTime.map {
                inspector.isAlive(pid: pid, startTime: $0)
            } ?? (inspector.snapshot(pid: pid) != nil)
            guard !alive else { continue }
            logger.info("reaping \(session.id.rawValue, privacy: .public): its process is gone")
            apply(ProcessWatcher.exitEvent(
                pid: pid,
                startTime: session.processStartTime ?? 0,
                provider: session.provider
            ))
        }
    }

    /// Removes a session because the user asked us to stop watching it.
    ///
    /// Suppressed from process discovery afterwards, or the next sweep would
    /// put it straight back. A later *hook* event un-dismisses it: that is the
    /// session demonstrably alive and talking to us, and continuing to hide it
    /// would be the same dishonesty as showing a phantom.
    func dismiss(_ session: AgentSession) {
        dismissed.insert(session.id)
        handle(registry.remove(session.id))
        publish()
    }

    private func adopt(_ process: AgentProcess) {
        // Identity is (provider, pid, start time), so this suppresses the exact
        // process the user dismissed and not a later one that reuses its pid.
        let identity = SessionID.process(
            process.provider, pid: process.pid, startTime: process.startTime
        )
        guard !dismissed.contains(identity) else { return }
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
    ///
    /// Also the point where we start watching the process, because this is the
    /// moment we learn its start time — and a session is only safely watchable
    /// once we can tell its process from a recycled pid.
    private func enrich(pid: pid_t) {
        let inspector = ProcessInspector()
        guard let snapshot = inspector.snapshot(pid: pid) else {
            // Already gone. A hook can reach us after its process has died —
            // the event is queued, delivered, and only then do we look — and
            // without this the session would sit in the list forever, since
            // nothing else was ever going to tell us about a process we never
            // subscribed to.
            if let session = registry.all.first(where: { $0.pid == pid }), session.state.isActive {
                logger.info("pid \(pid, privacy: .public) was already gone when we went to enrich it")
                apply(ProcessWatcher.exitEvent(
                    pid: pid,
                    startTime: session.processStartTime ?? 0,
                    provider: session.provider
                ))
            }
            return
        }
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
        // The fix for phantom rows. Sessions born from a hook event used to
        // reach here and never subscribe to anything, so an agent that exited
        // without sending SessionEnd — `codex exec` does exactly this — stayed
        // Busy until the next sleep/wake reconciliation, which might be never.
        watchForExit(session)
    }

    /// Subscribes to a session's process so its exit is noticed even when the
    /// agent never sends `SessionEnd`.
    private func watchForExit(_ session: AgentSession) {
        guard let pid = session.pid else { return }
        if let startTime = session.processStartTime {
            _ = processWatcher?.watch(pid: pid, startTime: startTime, provider: session.provider)
        } else {
            _ = processWatcher?.watch(pid: pid, provider: session.provider)
        }
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
                // kqueue registrations die with the process that made them, so
                // anything restored from a snapshot needs re-subscribing.
                for session in registry.all where session.state.isActive {
                    watchForExit(session)
                }
            }
        }
        publish()
    }

    private func restoreSnapshot() {
        switch persistence.load() {
        case .restored(let snapshot):
            let inspector = ProcessInspector()
            let live = StatePersistence.filterToLiveSessions(
                snapshot.sessions.filter { $0.state.isActive },
                isAlive: { inspector.isAlive(pid: $0, startTime: $1) }
            )
            for session in live { registry.update(session) }
            let dropped = snapshot.sessions.count - live.count
            logger.info("restored \(live.count) sessions, dropped \(dropped) that no longer exist")
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
        ticksSinceReap += 1
        if ticksSinceReap >= Self.reapInterval {
            ticksSinceReap = 0
            reapDeadSessions()
            drainSpoolIfNotEmpty()
        }
        let removed = registry.pruneEnded(olderThan: endedLinger, now: now)
        guard removed.isEmpty else {
            publish(now)
            return
        }
        // The diagnosis depends on elapsed time, not just on registry changes:
        // a silent session crosses the settling period while nothing else
        // happens, and publish alone would never notice. Re-deriving it each
        // second is a walk over the handful of sessions that are not reporting.
        if currentDiagnosis(now) != model.unreportedDiagnosis {
            publish(now)
        } else {
            model.tick(now)
        }
    }

    private func currentDiagnosis(_ now: Date) -> UnreportedDiagnosis {
        UnreportedDiagnosis.diagnose(
            sessions: registry.unreported,
            hooksInstalledAt: hooksInstalledAt,
            connectedProviders: connectedProviders,
            now: now
        )
    }


    private func publish(_ now: Date = Date()) {
        let diagnosis = currentDiagnosis(now)
        model.apply(registry, diagnosis: diagnosis, now: now)
        warnAboutCodexTrustIfNeeded(diagnosis)
        onRegistryChanged?()
    }

    /// Re-scans after onboarding installs hooks, so sessions that were already
    /// running show up without waiting for the next safety sweep.
    func refreshAdapters() {
        // Receipts first: an install that just happened changes what the
        // silence of every existing session means.
        reloadInstallReceipts()
        // Pressing Refresh is asking for the list to be rebuilt from what is
        // actually running, which includes undoing dismissals. Keeping them
        // would make the button unable to serve the most common reason for
        // reaching for it — a row cleared away by accident — and it would fail
        // silently, since a suppressed session looks exactly like no session.
        dismissed.removeAll()
        processWatcher?.resync()
        publish()
    }

    /// Reads when each provider's hooks were installed.
    ///
    /// A missing receipt is not an error — it means we never installed for that
    /// provider, and the diagnosis correctly declines to explain anything.
    private func reloadInstallReceipts() {
        let store = InstallReceiptStore(paths: paths)
        let receipts = store.load()
        var installed: [AgentProvider: Date] = [:]
        installed[.claudeCode] = receipts[ClaudeHookInstaller(paths: paths).settingsURL.path]?.installedAt
        installed[.codex] = receipts[CodexHookInstaller(paths: paths).hooksURL.path]?.installedAt
        hooksInstalledAt = installed

        var connected: Set<AgentProvider> = []
        if (try? ClaudeHookInstaller(paths: paths).isInstalled()) == true {
            connected.insert(.claudeCode)
        }
        if (try? CodexHookInstaller(paths: paths).isInstalled()) == true {
            connected.insert(.codex)
        }
        connectedProviders = connected
    }

    /// Tells the user once that Codex is running but silent.
    ///
    /// Codex fails this case silently — it works normally and simply never
    /// reports — so without this the only symptom is CodeStatus appearing to do
    /// nothing, which reads as CodeStatus being broken. The popover carries the
    /// same message persistently; this is what reaches someone who is not
    /// looking at it.
    private func warnAboutCodexTrustIfNeeded(_ diagnosis: UnreportedDiagnosis) {
        // "Never connected" first: pointing someone at /hooks when their
        // hooks.json has no entries sends them to a screen that correctly
        // reports zero, which is how a user ends up concluding the app is
        // broken rather than unconfigured.
        if !diagnosis.notConnected.isEmpty {
            warnAboutUnconnectedAgents(diagnosis.notConnected)
            return
        }
        guard diagnosis.codexAwaitingTrust > 0, !didWarnAboutCodexTrust else { return }
        didWarnAboutCodexTrust = true
        logger.notice("codex sessions running with untrusted hooks")
        notifications.postSetupNotice(
            title: "Codex isn’t reporting",
            body: "Codex only runs hooks you have trusted. Run /hooks in Codex "
                + "and trust the CodeStatus entries.",
            identifier: "co.codestatus.setup.codex-untrusted"
        )
    }

    /// Tells the user, once per set of agents, that one is running unwatched.
    ///
    /// Deliberately not self-healing. We know the agent is there and we know
    /// which file would connect it, and writing that file because we noticed is
    /// precisely the thing this app promises never to do. So it points at Setup
    /// and stops.
    private func warnAboutUnconnectedAgents(_ providers: [AgentProvider: Int]) {
        let names = providers.keys.map(\.displayName).sorted()
        guard didWarnAboutUnconnected != Set(names) else { return }
        didWarnAboutUnconnected = Set(names)
        logger.notice("unconnected agents running: \(names.joined(separator: ", "), privacy: .public)")
        notifications.postSetupNotice(
            title: "\(names.formatted(.list(type: .and))) isn’t connected",
            body: "It is running on this Mac and CodeStatus is not watching it. "
                + "Open Settings › Agents › Open Setup to connect it.",
            identifier: "co.codestatus.setup.unconnected.\(names.joined(separator: "+"))"
        )
    }

    // MARK: - Reading, for other surfaces

    var sessions: [AgentSession] { registry.visible }

    func session(withID id: SessionID) -> AgentSession? { registry[id] }

    var socketStats: EventSocketServer.Stats? { socketServer?.currentStats() }
}
