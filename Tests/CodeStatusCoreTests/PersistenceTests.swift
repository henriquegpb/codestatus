import Testing
import Foundation
@testable import CodeStatusCore

/// A throwaway home directory, so every test drives the real `RuntimePaths`
/// layout instead of a parallel one that could drift from production.
private func makeTestHome() throws -> URL {
    let home = URL(fileURLWithPath: "/tmp/cs-persist-\(getuid())-\(UInt32.random(in: 0..<0xFFFFFF))")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

/// One event exactly as `codestatus-hook` writes it, minus the parts under test.
private func spoolLine(
    id: String,
    event: String,
    session: String,
    turn: String? = nil,
    seconds: Double,
    notification: String? = nil
) -> String {
    var fields: [String] = [
        #""v":1"#,
        #""id":"\#(id)""#,
        #""provider":"claudeCode""#,
        #""ts":\#(seconds)"#,
        #""hook_event_name":"\#(event)""#,
        #""session_id":"\#(session)""#,
        #""cwd":"/tmp/proj""#,
    ]
    if let turn { fields.append(#""prompt_id":"\#(turn)""#) }
    if let notification { fields.append(#""notification_type":"\#(notification)""#) }
    return "{" + fields.joined(separator: ",") + "}\n"
}

@discardableResult
private func writeSpoolFile(_ paths: RuntimePaths, named name: String, contents: String) throws -> URL {
    try paths.createDirectories()
    let url = paths.spool.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url
}

private func spoolContents(_ paths: RuntimePaths) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: paths.spool.path)) ?? []).sorted()
}

@Suite("Event spool")
struct EventSpoolTests {

    @Test("Spooled events are replayed oldest first, whatever order the directory lists them in")
    func drainsInTimestampOrder() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(home: home)

        try writeSpoolFile(paths, named: "300-c.ndjson",
                           contents: spoolLine(id: "third", event: "Stop", session: "s", turn: "t", seconds: 300))
        try writeSpoolFile(paths, named: "100-a.ndjson",
                           contents: spoolLine(id: "first", event: "SessionStart", session: "s", seconds: 100))
        try writeSpoolFile(paths, named: "200-b.ndjson",
                           contents: spoolLine(id: "second", event: "UserPromptSubmit", session: "s", turn: "t", seconds: 200))

        var seen: [String] = []
        let report = EventSpool(paths: paths).drain { seen.append($0.id.rawValue) }

        #expect(seen == ["first", "second", "third"])
        #expect(report.delivered == 3)
        #expect(report.isComplete)
        #expect(spoolContents(paths).isEmpty, "a fully drained spool must leave nothing behind")
    }

    @Test("Replaying the spool in order reproduces the session the daemon missed")
    func drainRebuildsSessionState() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(home: home)

        try writeSpoolFile(paths, named: "100-a.ndjson",
                           contents: spoolLine(id: "e1", event: "UserPromptSubmit", session: "s", turn: "t", seconds: 100))
        try writeSpoolFile(paths, named: "101-b.ndjson",
                           contents: spoolLine(id: "e2", event: "PreToolUse", session: "s", turn: "t", seconds: 101))
        try writeSpoolFile(paths, named: "102-c.ndjson",
                           contents: spoolLine(id: "e3", event: "Stop", session: "s", turn: "t", seconds: 102))

        var registry = SessionRegistry()
        EventSpool(paths: paths).drain { _ = registry.ingest($0, now: Date(timeIntervalSince1970: 200)) }

        #expect(registry.all.count == 1)
        #expect(registry.all.first?.state == .free)
    }

    @Test("A file that will never decode is removed and counted, not fatal")
    func malformedFileIsRemovedAndCounted() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(home: home)

        try writeSpoolFile(paths, named: "100-a.ndjson", contents: "this is not json\n")
        try writeSpoolFile(paths, named: "110-b.ndjson", contents: "")
        try writeSpoolFile(paths, named: "120-c.ndjson",
                           contents: spoolLine(id: "good", event: "Stop", session: "s", seconds: 120))

        var seen: [String] = []
        let report = EventSpool(paths: paths).drain { seen.append($0.id.rawValue) }

        #expect(seen == ["good"], "one bad file must not cost us the good ones")
        #expect(report.delivered == 1)
        #expect(report.undecodable == 2)
        #expect(spoolContents(paths).isEmpty)
    }

    @Test("An in-flight .tmp file is left for the hook to finish")
    func temporaryFilesAreIgnored() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(home: home)

        try writeSpoolFile(paths, named: "100-a.ndjson.tmp", contents: #"{"v":1,"id":"half"#)
        try writeSpoolFile(paths, named: "100-b.ndjson",
                           contents: spoolLine(id: "whole", event: "Stop", session: "s", seconds: 100))

        var seen: [String] = []
        let report = EventSpool(paths: paths).drain { seen.append($0.id.rawValue) }

        #expect(seen == ["whole"])
        #expect(report.ignored == 1)
        #expect(spoolContents(paths) == ["100-a.ndjson.tmp"], "the hook still owns its temp file")
    }

    @Test("A file the spool cannot own — a symlink out of the directory — is never read")
    func symlinksAreNotFollowed() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(home: home)
        try paths.createDirectories()

        let outside = home.appendingPathComponent("elsewhere.ndjson")
        try Data(spoolLine(id: "outside", event: "Stop", session: "s", seconds: 100).utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: paths.spool.appendingPathComponent("100-link.ndjson"), withDestinationURL: outside
        )

        var seen: [String] = []
        let report = EventSpool(paths: paths).drain { seen.append($0.id.rawValue) }

        #expect(seen.isEmpty)
        #expect(report.unreadable == 1)
        #expect(spoolContents(paths).isEmpty, "the dangling link is cleared")
        #expect(FileManager.default.fileExists(atPath: outside.path), "its target is untouched")
    }

    @Test("A pathological spool is bounded per drain and reports what it deferred")
    func fileCapIsEnforcedAndReported() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(home: home)

        for index in 0..<10 {
            try writeSpoolFile(
                paths, named: "\(100 + index)-x.ndjson",
                contents: spoolLine(id: "e\(index)", event: "Stop", session: "s\(index)", seconds: Double(100 + index))
            )
        }

        let spool = EventSpool(paths: paths, limits: .init(maxFiles: 3))
        var first: [String] = []
        let firstReport = spool.drain { first.append($0.id.rawValue) }

        #expect(first == ["e0", "e1", "e2"])
        #expect(firstReport.deferred == 7)
        #expect(firstReport.isComplete == false)
        #expect(spoolContents(paths).count == 7, "deferred files are kept, never truncated away")

        var second: [String] = []
        let secondReport = spool.drain { second.append($0.id.rawValue) }
        #expect(second == ["e3", "e4", "e5"])
        #expect(secondReport.deferred == 4)
    }

    @Test("The byte budget stops a drain, and one oversized file cannot block progress")
    func byteCapsAreEnforced() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(home: home)

        let line = spoolLine(id: "e1", event: "Stop", session: "s1", seconds: 100)
        try writeSpoolFile(paths, named: "100-a.ndjson", contents: line)
        try writeSpoolFile(paths, named: "110-b.ndjson", contents: spoolLine(id: "e2", event: "Stop", session: "s2", seconds: 110))
        // Far too large to be an event line: a truncated log or a hostile write.
        try writeSpoolFile(paths, named: "120-c.ndjson", contents: String(repeating: "x", count: 4096))

        var seen: [String] = []
        // A budget smaller than one file still delivers that file, then stops.
        let report = EventSpool(paths: paths, limits: .init(maxTotalBytes: 1, maxFileBytes: 1024))
            .drain { seen.append($0.id.rawValue) }

        #expect(seen == ["e1"])
        #expect(report.bytesRead == line.utf8.count)
        #expect(report.deferred == 2)

        var rest: [String] = []
        let restReport = EventSpool(paths: paths, limits: .init(maxFileBytes: 1024)).drain { rest.append($0.id.rawValue) }
        #expect(rest == ["e2"])
        #expect(restReport.oversized == 1)
        #expect(spoolContents(paths).isEmpty)
    }

    @Test("An empty spool directory is a no-op, not an error")
    func emptySpoolIsHarmless() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(home: home)

        // Not even created yet: this is the very first launch.
        let report = EventSpool(paths: paths).drain { _ in Issue.record("nothing should be delivered") }
        #expect(report == EventSpool.DrainReport())
    }
}

@Suite("State persistence")
struct StatePersistenceTests {

    /// Every stored property of ``AgentSession``, reviewed field by field and
    /// confirmed to be metadata. The test below pins this list, so adding a field
    /// to the session model fails here until someone has made the same judgement
    /// about it — which is what stops content from ever reaching disk by accident.
    static let reviewedSessionFields: Set<String> = [
        "id", "provider", "providerSessionID", "providerTurnID",
        "state", "previousState", "stateConfidence", "stateChangedAt",
        "startedAt", "lastEventAt",
        "pid", "parentPID", "processStartTime", "tty",
        "cwd", "gitRoot", "repositoryName", "workspaceName",
        "hostApplication", "hostBundleIdentifier",
        "sourceAdapter", "capabilities", "controlTarget", "lastError", "clock",
    ]

    private func makeSession(now: Date) -> AgentSession {
        var session = AgentSession(
            id: SessionID.provider(.claudeCode, "abc-123"),
            provider: .claudeCode,
            state: .waitingForApproval,
            stateConfidence: .high,
            now: now,
            sourceAdapter: "claudeCodeHook"
        )
        session.providerSessionID = "abc-123"
        session.providerTurnID = "turn-9"
        session.previousState = .busy
        session.pid = 4242
        session.parentPID = 4241
        session.processStartTime = 99_887_766
        session.tty = "/dev/ttys003"
        session.cwd = "/Users/x/proj"
        session.gitRoot = "/Users/x/proj"
        session.repositoryName = "proj"
        session.workspaceName = "proj.code-workspace"
        session.hostApplication = .iTerm
        session.hostBundleIdentifier = HostApplication.iTerm.bundleIdentifier
        session.lastError = "overloaded_error"
        session.capabilities = [.canOpen, .canIdentifyExactConversation]
        session.controlTarget = ControlTarget(
            hostApplication: .iTerm, tty: "/dev/ttys003",
            termSessionID: "tsid-42", workspacePath: "/Users/x/proj"
        )
        return session
    }

    @Test("A saved session comes back with its state, timing, capabilities, and control target intact")
    func roundTripPreservesEverything() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(home: home)

        let savedAt = Date(timeIntervalSince1970: 1_700_000_000.25)
        let session = makeSession(now: savedAt)
        let persistence = StatePersistence(paths: paths)
        try persistence.save([session], now: savedAt)

        guard case .restored(let snapshot) = persistence.load() else {
            Issue.record("expected the snapshot to be restored")
            return
        }
        #expect(snapshot.version == StatePersistence.schemaVersion)
        #expect(snapshot.savedAt == savedAt)
        #expect(snapshot.sessions == [session])

        let restored = try #require(snapshot.sessions.first)
        #expect(restored.state == .waitingForApproval)
        #expect(restored.previousState == .busy)
        #expect(restored.stateConfidence == .high)
        #expect(restored.stateChangedAt == savedAt)
        #expect(restored.capabilities == [.canOpen, .canIdentifyExactConversation])
        #expect(restored.controlTarget.termSessionID == "tsid-42")
        #expect(restored.controlTarget.tty == "/dev/ttys003")
        #expect(restored.controlTarget.hostApplication == .iTerm)
    }

    @Test("The snapshot file is owner-only, because it lists every repository the user works in")
    func snapshotIsOwnerOnly() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(home: home)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try StatePersistence(paths: paths).save([makeSession(now: now)], now: now)

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.sessionsSnapshot.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)

        // And no temporary file survives the publish.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.state.path)
        #expect(leftovers == ["sessions.json"])
    }

    @Test("A snapshot from a future build is discarded rather than misread")
    func futureSchemaIsRefused() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(home: home)
        try paths.createDirectories()

        let future = #"{"version":99,"savedAt":0,"sessions":[{"shape":"we do not know"}]}"#
        try Data(future.utf8).write(to: paths.sessionsSnapshot)

        let persistence = StatePersistence(paths: paths)
        #expect(persistence.load() == .discarded(.futureSchema))
        #expect(FileManager.default.fileExists(atPath: paths.sessionsSnapshot.path) == false)
        #expect(persistence.load() == .none)
    }

    @Test("A corrupt snapshot is discarded so the daemon can still start")
    func corruptSnapshotIsDiscarded() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(home: home)
        try paths.createDirectories()
        try Data("{ truncated".utf8).write(to: paths.sessionsSnapshot)

        #expect(StatePersistence(paths: paths).load() == .discarded(.corrupt))
        #expect(FileManager.default.fileExists(atPath: paths.sessionsSnapshot.path) == false)
    }

    @Test("Saving twice replaces the snapshot atomically rather than appending to it")
    func saveIsIdempotent() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(home: home)
        let persistence = StatePersistence(paths: paths)

        let first = Date(timeIntervalSince1970: 1_000)
        try persistence.save([makeSession(now: first)], now: first)
        let second = Date(timeIntervalSince1970: 2_000)
        try persistence.save([], now: second)

        guard case .restored(let snapshot) = persistence.load() else {
            Issue.record("expected the snapshot to be restored")
            return
        }
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.savedAt == second)
        #expect(snapshot.age(at: Date(timeIntervalSince1970: 9_200)) == 7_200)
    }

    @Test("Nothing content-like can reach the snapshot without a human noticing")
    func onlyReviewedMetadataIsPersisted() throws {
        // The model itself: adding any field to AgentSession fails here first.
        let session = makeSession(now: Date(timeIntervalSince1970: 1_000))
        let declared = Set(Mirror(reflecting: session).children.compactMap(\.label))
        #expect(
            declared == Self.reviewedSessionFields,
            "AgentSession gained or lost a field — review it for content before persisting it"
        )

        // And the bytes actually written, in case encoding ever adds a key.
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(home: home)
        try StatePersistence(paths: paths).save([session], now: Date(timeIntervalSince1970: 1_000))

        let data = try Data(contentsOf: paths.sessionsSnapshot)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "savedAt", "sessions"])

        let sessions = try #require(object["sessions"] as? [[String: Any]])
        let encoded = Set(sessions.flatMap(\.keys))
        #expect(encoded.isSubset(of: Self.reviewedSessionFields))

        // The obvious content-bearing names, spelled out so the guarantee is
        // readable rather than implied by a set comparison.
        let text = try #require(String(data: data, encoding: .utf8))
        for forbidden in ["prompt", "message", "transcript", "content", "tool_input", "response"] {
            #expect(text.lowercased().contains(forbidden) == false, "snapshot mentions \(forbidden)")
        }
    }
}

@Suite("Sleep and wake reconciliation")
struct SleepWakeCoordinatorTests {

    private func transition(
        to state: AgentState,
        at occurredAt: Date,
        session: String = "s1"
    ) -> Transition {
        Transition(
            sessionID: SessionID.provider(.claudeCode, session),
            from: .reconnecting,
            to: state,
            eventID: EventID("e-\(session)"),
            source: .hook,
            confidence: .high,
            occurredAt: occurredAt,
            reason: "test"
        )
    }

    @Test("Going to sleep asks for a snapshot and nothing that would keep the Mac awake")
    func sleepOnlySnapshots() {
        var coordinator = SleepWakeCoordinator()
        let at = Date(timeIntervalSince1970: 1_000)
        let actions = coordinator.handle(.willSleep(at))
        #expect(actions == [.saveSnapshot(at)])
        #expect(coordinator.reconciliationCount == 0)
    }

    @Test("Waking reconciles: reconnect everything, replay the spool, then sweep processes")
    func wakeRequestsReconciliation() {
        var coordinator = SleepWakeCoordinator()
        let at = Date(timeIntervalSince1970: 2_000)
        let actions = coordinator.handle(.didWake(at))
        #expect(actions == [.markAllReconnecting(at), .drainSpool, .sweepProcesses])
    }

    @Test("A daemon restart is reconciled exactly like a wake")
    func restartReconcilesLikeWake() {
        var coordinator = SleepWakeCoordinator()
        let at = Date(timeIntervalSince1970: 3_000)
        let actions = coordinator.handle(.daemonRestarted(at))
        #expect(actions == [.markAllReconnecting(at), .drainSpool, .sweepProcesses])
    }

    @Test("A wake delivered twice still reconciles only once")
    func duplicateWakesCoalesce() {
        var coordinator = SleepWakeCoordinator(coalescingWindow: 5)
        let at = Date(timeIntervalSince1970: 4_000)
        let first = coordinator.handle(.didWake(at))
        let second = coordinator.handle(.didWake(at.addingTimeInterval(1)))
        let later = coordinator.handle(.didWake(at.addingTimeInterval(60)))

        #expect(first.isEmpty == false)
        #expect(second.isEmpty)
        #expect(later.isEmpty == false)
        #expect(coordinator.reconciliationCount == 2)
    }

    @Test("A replayed state change from before the sleep updates state but does not notify")
    func staleTransitionIsSilent() {
        let coordinator = SleepWakeCoordinator()
        let now = Date(timeIntervalSince1970: 10_000)
        let old = transition(to: .waitingForApproval, at: now.addingTimeInterval(-7_200))
        #expect(coordinator.shouldNotify(for: old, now: now) == false)
    }

    @Test("A session that died while the Mac slept is still worth telling the user about")
    func endedTransitionNotifiesEvenWhenStale() {
        let coordinator = SleepWakeCoordinator()
        let now = Date(timeIntervalSince1970: 10_000)
        let old = transition(to: .ended, at: now.addingTimeInterval(-7_200))
        #expect(coordinator.shouldNotify(for: old, now: now))
    }

    @Test("A state change from moments ago notifies normally")
    func recentTransitionNotifies() {
        let coordinator = SleepWakeCoordinator()
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = transition(to: .waitingForApproval, at: now.addingTimeInterval(-30))
        #expect(coordinator.shouldNotify(for: recent, now: now))
    }

    @Test("The staleness threshold is injectable and applied at its boundary")
    func thresholdIsInjectable() {
        let now = Date(timeIntervalSince1970: 10_000)
        let strict = SleepWakeCoordinator(staleThreshold: 10)
        #expect(strict.shouldNotify(for: transition(to: .free, at: now.addingTimeInterval(-10)), now: now))
        #expect(strict.shouldNotify(for: transition(to: .free, at: now.addingTimeInterval(-11)), now: now) == false)

        let lenient = SleepWakeCoordinator(staleThreshold: 86_400)
        #expect(lenient.shouldNotify(for: transition(to: .free, at: now.addingTimeInterval(-7_200)), now: now))
    }

    /// The scenario this whole file exists for: the Mac sleeps for two hours with
    /// three live sessions, the agents carry on until they block or exit, and the
    /// hook spools everything. On wake the user must get the correct picture and
    /// exactly one banner — not one per replayed event.
    @Test("Waking after a two-hour sleep reconciles once and produces no notification avalanche")
    func twoHourSleepWithThreeSessions() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(home: home)

        let sleepAt = Date(timeIntervalSince1970: 1_700_000_000)
        let wakeAt = sleepAt.addingTimeInterval(7_200)

        // Three sessions mid-turn when the Mac went to sleep.
        var registry = SessionRegistry()
        for index in 1...3 {
            let start = AgentEvent(
                id: EventID("start-\(index)"), provider: .claudeCode, kind: .userPromptSubmit,
                source: .hook, timestamp: sleepAt.addingTimeInterval(-60),
                providerSessionID: "s\(index)", providerTurnID: "t\(index)", cwd: "/tmp/proj\(index)"
            )
            _ = registry.ingest(start, now: sleepAt)
        }
        #expect(registry.counts()[.busy] == 3)

        var coordinator = SleepWakeCoordinator()
        let sleepActions = coordinator.handle(.willSleep(sleepAt))
        #expect(sleepActions == [.saveSnapshot(sleepAt)])

        let persistence = StatePersistence(paths: paths)
        try persistence.save(registry.all, now: sleepAt)

        // What the agents did while we were away, spooled by the hook.
        let duringSleep = sleepAt.addingTimeInterval(120)
        try writeSpoolFile(paths, named: "\(Int(duringSleep.timeIntervalSince1970))-a.ndjson",
                           contents: spoolLine(id: "w1", event: "Stop", session: "s1", turn: "t1",
                                               seconds: duringSleep.timeIntervalSince1970))
        try writeSpoolFile(paths, named: "\(Int(duringSleep.timeIntervalSince1970) + 1)-b.ndjson",
                           contents: spoolLine(id: "w2", event: "Notification", session: "s2", turn: "t2",
                                               seconds: duringSleep.timeIntervalSince1970 + 1,
                                               notification: "permission_prompt"))
        try writeSpoolFile(paths, named: "\(Int(duringSleep.timeIntervalSince1970) + 2)-c.ndjson",
                           contents: spoolLine(id: "w3", event: "SessionEnd", session: "s3", turn: "t3",
                                               seconds: duringSleep.timeIntervalSince1970 + 2))

        // The daemon comes back and reloads what it knew.
        guard case .restored(let snapshot) = persistence.load() else {
            Issue.record("expected the pre-sleep snapshot to be restored")
            return
        }
        #expect(snapshot.sessions.count == 3)
        #expect(snapshot.age(at: wakeAt) == 7_200)

        // One wake, and a redundant second delivery of it.
        let wakeActions = coordinator.handle(.didWake(wakeAt))
        let redundant = coordinator.handle(.didWake(wakeAt.addingTimeInterval(0.5)))
        #expect(redundant.isEmpty)
        #expect(coordinator.reconciliationCount == 1, "exactly one reconciliation pass")
        #expect(wakeActions == [.markAllReconnecting(wakeAt), .drainSpool, .sweepProcesses])

        var notified: [Transition] = []
        var transitions: [Transition] = []
        for action in wakeActions {
            switch action {
            case .markAllReconnecting(let at):
                registry.markAllReconnecting(now: at)
                #expect(registry.counts()[.indeterminate] == 3)

            case .drainSpool:
                let report = EventSpool(paths: paths).drain { event in
                    for result in registry.ingest(event, now: wakeAt) {
                        if case .sessionChanged(let transition) = result { transitions.append(transition) }
                    }
                }
                #expect(report.delivered == 3)
                #expect(report.isComplete)

            case .sweepProcesses, .saveSnapshot:
                break
            }
        }

        for transition in transitions where coordinator.shouldNotify(for: transition, now: wakeAt) {
            notified.append(transition)
        }

        // Every session's state was corrected...
        #expect(transitions.count == 3)
        #expect(registry[SessionID.provider(.claudeCode, "s1")]?.state == .free)
        #expect(registry[SessionID.provider(.claudeCode, "s2")]?.state == .waitingForApproval)
        #expect(registry[SessionID.provider(.claudeCode, "s3")]?.state == .ended)

        // ...but only the death of a session was worth interrupting the user for.
        #expect(notified.count == 1)
        #expect(notified.first?.to == .ended)
        #expect(notified.first?.sessionID == SessionID.provider(.claudeCode, "s3"))

        #expect(spoolContents(paths).isEmpty)
    }
}
