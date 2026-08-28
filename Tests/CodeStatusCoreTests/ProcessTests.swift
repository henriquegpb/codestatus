import Testing
import Foundation
@testable import CodeStatusCore

// MARK: - Fixtures

/// Collects callbacks from the watcher's delivery queue with a bounded wait, so
/// a subscription that never fires fails the suite instead of hanging it.
private final class Inbox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []

    func append(_ item: Value) {
        lock.lock(); items.append(item); lock.unlock()
    }

    var all: [Value] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    @discardableResult
    func wait(forAtLeast count: Int, timeout: TimeInterval = 5) -> [Value] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = all
            if snapshot.count >= count { return snapshot }
            usleep(10_000)
        }
        return all
    }
}

/// One row of the identification table, as a named type so the case shows up
/// readably in test output.
private struct IdentificationCase: Sendable, CustomStringConvertible {
    let path: String
    let provider: AgentProvider
    let host: HostApplication
    var description: String { path }
}

/// A child that exits on its own shortly after launch, for exit-detection tests.
private func spawnShortLivedProcess(seconds: String = "0.2") throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = [seconds]
    try process.run()
    return process
}

/// An agent the watcher will believe in, built on this process.
///
/// Its pid is our own, which is the point: the watcher subscribes to the exit
/// of everything a sweep reports, and a pid belonging to nothing fires that
/// subscription immediately — taking the entry back out of the announced set
/// and quietly turning any assertion about re-announcement into a test of the
/// scheduler.
///
/// Spawning something real is not an alternative. A copy of `/bin/sleep` named
/// `codex` is killed by the kernel within milliseconds, because a platform
/// binary's signature does not survive being moved off the system volume, so
/// the test ends up measuring a dead process.
private func selfAsAgent(provider: AgentProvider = .codex) throws -> AgentProcess {
    let snapshot = try #require(inspector.snapshot(pid: getpid()))
    return AgentProcess(
        provider: provider,
        snapshot: snapshot,
        hostApplication: .unknown,
        evidence: .executablePath,
        workingDirectory: nil,
        ancestorPIDs: []
    )
}

private let inspector = ProcessInspector()

// MARK: - Inspection

@Suite("Process inspection")
struct ProcessInspectorTests {

    @Test("The inspector finds the process running these tests")
    func findsSelf() throws {
        let me = try #require(inspector.snapshot(pid: getpid()))
        #expect(me.pid == getpid())
        #expect(me.parentPID == getppid())
        #expect(me.startTime > 0)

        let path = try #require(me.executablePath)
        #expect(path.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }

    @Test("A full sweep contains the test process and agrees with the targeted lookup")
    func sweepAgreesWithTargetedLookup() throws {
        let all = inspector.snapshotAll()
        #expect(all.count > 1)

        let fromSweep = try #require(all.first { $0.pid == getpid() })
        let targeted = try #require(inspector.snapshot(pid: getpid()))
        #expect(fromSweep.startTime == targeted.startTime)
        #expect(fromSweep.parentPID == targeted.parentPID)
        #expect(fromSweep.executablePath == targeted.executablePath)
    }

    @Test("Start time is stable across two inspections, so it can key an identity")
    func startTimeIsStable() throws {
        let first = try #require(inspector.snapshot(pid: getpid()))
        usleep(50_000)
        let second = try #require(inspector.snapshot(pid: getpid()))
        #expect(first.startTime == second.startTime)
        #expect(inspector.isAlive(pid: getpid(), startTime: first.startTime))
        // The same pid with any other start time is a different process.
        #expect(!inspector.isAlive(pid: getpid(), startTime: first.startTime &+ 1))
    }

    @Test("A pid that is not running reports nothing rather than a zeroed record")
    func absentProcessIsNil() {
        // pid_t is signed; a negative pid can never name a live process.
        #expect(inspector.snapshot(pid: -1) == nil)
        #expect(inspector.isAlive(pid: -1, startTime: 0) == false)
    }

    /// `PROC_PIDVNODEPATHINFO` is refused to a sandboxed process, so the guarantee
    /// is asserted only where the API is actually available — skipped, never flaky.
    @Test(
        "The test process reports a working directory",
        .enabled(
            if: ProcessInspector().workingDirectory(of: getpid()) != nil,
            "PROC_PIDVNODEPATHINFO is unavailable here, which happens under sandboxing"
        )
    )
    func workingDirectoryResolves() throws {
        let cwd = try #require(inspector.workingDirectory(of: getpid()))
        #expect(cwd.hasPrefix("/"))
        // `/tmp` and friends are firmlinked, so compare resolved paths.
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == expected.path)
    }

    @Test("Ancestry walks upwards and stops before launchd")
    func ancestryStopsBeforeLaunchd() {
        let chain = inspector.ancestry(of: getpid())
        #expect(chain.first == getppid())
        #expect(!chain.contains(1))
        #expect(!chain.contains(getpid()))
        #expect(chain.count <= 16)
    }

    @Test("Argument capture never reaches argv[2], where user content begins")
    func argumentsAreCappedBeforeUserContent() {
        let arguments = inspector.identificationArguments(of: getpid())
        #expect(arguments.count <= 2)
        if let first = arguments.first {
            #expect(!first.isEmpty)
        }
    }

    @Test("CPU time is readable for diagnostics and never negative")
    func cpuSampleIsAvailable() throws {
        let sample = try #require(inspector.cpuSample(of: getpid()))
        #expect(sample.totalNanoseconds == sample.userNanoseconds + sample.systemNanoseconds)
        #expect(sample.totalNanoseconds > 0)
    }

    @Test("A discovery sweep never mistakes the test process for an agent")
    func sweepDoesNotMisidentifyTheTestRunner() {
        let agents = inspector.discoverAgents()
        #expect(!agents.contains { $0.pid == getpid() })
        // Whatever it did find must be justified by a real binary path.
        for agent in agents {
            #expect(agent.snapshot.executablePath?.isEmpty == false)
            #expect(agent.startTime > 0)
        }
    }
}

// MARK: - Identification

@Suite("Agent identification")
struct AgentIdentificationTests {

    /// Paths taken verbatim from processes running on this machine, plus the
    /// documented install locations of each CLI.
    @Test(
        "Real agent binaries identify as their provider",
        arguments: [
            IdentificationCase(
                path: "/Users/x/.vscode/extensions/anthropic.claude-code-2.1.240-darwin-arm64"
                    + "/resources/native-binary/claude",
                provider: .claudeCode, host: .vsCode
            ),
            // The ChatGPT extension's codex is deliberately absent here: it is
            // only ever the long-lived `app-server`, never a session. See
            // ServiceProcessTests, which asserts it identifies as nothing.
            IdentificationCase(
                path: "/Users/x/.nvm/versions/node/v22.3.0/lib/node_modules"
                    + "/@anthropic-ai/claude-code/bin/claude.exe",
                provider: .claudeCode, host: .unknown
            ),
            IdentificationCase(path: "/opt/homebrew/bin/claude", provider: .claudeCode, host: .unknown),
            IdentificationCase(
                path: "/Applications/Codex.app/Contents/Resources/codex", provider: .codex, host: .unknown
            ),
        ]
    )
    fileprivate func identifiesKnownBinaries(_ example: IdentificationCase) {
        let identity = AgentIdentification.identify(executablePath: example.path)
        #expect(identity?.provider == example.provider)
        #expect(identity?.hostApplication == example.host)
    }

    @Test(
        "Ordinary binaries identify as nothing at all",
        arguments: [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/bin/zsh",
            "/bin/bash",
            "/usr/bin/ssh",
            "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
            "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
            "",
        ]
    )
    func refusesOrdinaryBinaries(path: String) {
        #expect(AgentIdentification.identify(executablePath: path) == nil)
    }

    @Test("A missing executable path identifies as nothing")
    func refusesMissingPath() {
        #expect(AgentIdentification.identify(executablePath: nil) == nil)
    }

    /// This is a real path from this machine: the per-session scratch directory
    /// is named `claude-501`. Substring matching would have called it an agent.
    @Test("A directory that merely contains the word claude is not an agent")
    func refusesIncidentalNameMatches() {
        #expect(AgentIdentification.identify(executablePath: "/private/tmp/claude-501/abc/probe") == nil)
        #expect(AgentIdentification.identify(executablePath: "/Users/x/src/claude-code/build/server") == nil)
        #expect(AgentIdentification.identify(executablePath: "/Users/x/codex-experiments/bin/run") == nil)
    }

    @Test("A node process is an agent only because of what it was told to run")
    func nodeNeedsItsScript() {
        let bare = AgentIdentification.identify(executablePath: "/usr/local/bin/node", arguments: ["node"])
        #expect(bare == nil)

        let hosting = AgentIdentification.identify(
            executablePath: "/usr/local/bin/node",
            arguments: ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]
        )
        #expect(hosting?.provider == .claudeCode)
        #expect(hosting?.evidence == .interpreterScript)

        let unrelated = AgentIdentification.identify(
            executablePath: "/usr/local/bin/node", arguments: ["node", "/Users/x/project/server.js"]
        )
        #expect(unrelated == nil)
    }

    @Test("Arguments are read only for interpreters, because argv exposes the environment")
    func argumentInspectionIsGated() {
        #expect(AgentIdentification.needsArgumentInspection(executablePath: "/usr/local/bin/node"))
        #expect(AgentIdentification.needsArgumentInspection(executablePath: "/opt/homebrew/bin/bun"))
        #expect(!AgentIdentification.needsArgumentInspection(executablePath: "/bin/zsh"))
        #expect(!AgentIdentification.needsArgumentInspection(executablePath: "/opt/homebrew/bin/claude"))
        #expect(!AgentIdentification.needsArgumentInspection(executablePath: nil))
    }

    @Test("Host attribution names the outermost app bundle, not the helper inside it")
    func hostAttributionUsesTheOutermostBundle() {
        let helper = "/Applications/Visual Studio Code.app/Contents/Frameworks/"
            + "Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        #expect(AgentIdentification.hostApplication(forExecutablePath: helper) == .vsCode)
        #expect(
            AgentIdentification.hostApplication(
                forExecutablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
            ) == .terminal
        )
        #expect(
            AgentIdentification.hostApplication(
                forExecutablePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"
            ) == .ghostty
        )
        #expect(AgentIdentification.hostApplication(forExecutablePath: "/bin/zsh") == .unknown)
    }
}

// MARK: - Exit detection

@Suite("Process exit detection", .serialized)
struct ProcessWatcherTests {

    @Test("A watched process reports its exit within a bounded wait")
    func reportsExitOfLiveProcess() throws {
        let inbox = Inbox<AgentEvent>()
        let watcher = ProcessWatcher(
            configuration: .init(safetySweepInterval: 0, sweepOnStart: false),
            onExit: { inbox.append($0) }
        )
        watcher.start()
        defer { watcher.stop() }

        let child = try spawnShortLivedProcess()
        let pid = child.processIdentifier
        let startTime = try #require(inspector.snapshot(pid: pid)).startTime
        #expect(watcher.watch(pid: pid, startTime: startTime, provider: .claudeCode))
        #expect(watcher.activeWatches.count == 1)

        let events = inbox.wait(forAtLeast: 1)
        child.waitUntilExit()

        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.pid == pid)
        #expect(event.kind == .processExited)
        #expect(event.source == .process)
        #expect(event.id == EventID("exit-\(pid)-\(startTime)"))
        #expect(watcher.activeWatches.isEmpty)
    }

    @Test("A process that died before registration still reports its exit")
    func reportsExitOfAlreadyDeadProcess() throws {
        let inbox = Inbox<AgentEvent>()
        let watcher = ProcessWatcher(
            configuration: .init(safetySweepInterval: 0, sweepOnStart: false),
            onExit: { inbox.append($0) }
        )
        watcher.start()
        defer { watcher.stop() }

        let child = try spawnShortLivedProcess(seconds: "0.01")
        let pid = child.processIdentifier
        child.waitUntilExit()

        // Registering against a corpse must not subscribe to silence forever.
        #expect(!watcher.watch(pid: pid, provider: .codex))
        let events = inbox.wait(forAtLeast: 1, timeout: 2)
        #expect(events.count == 1)
        #expect(events.first?.pid == pid)
        #expect(events.first?.provider == .codex)
    }

    @Test("Watching the same process twice subscribes once and reports one exit")
    func watchingTwiceIsIdempotent() throws {
        let inbox = Inbox<AgentEvent>()
        let watcher = ProcessWatcher(
            configuration: .init(safetySweepInterval: 0, sweepOnStart: false),
            onExit: { inbox.append($0) }
        )
        watcher.start()
        defer { watcher.stop() }

        let child = try spawnShortLivedProcess()
        let pid = child.processIdentifier
        let startTime = try #require(inspector.snapshot(pid: pid)).startTime

        #expect(watcher.watch(pid: pid, startTime: startTime, provider: .claudeCode))
        #expect(!watcher.watch(pid: pid, startTime: startTime, provider: .claudeCode))
        #expect(watcher.activeWatches.count == 1)

        _ = inbox.wait(forAtLeast: 1)
        child.waitUntilExit()
        // Give a second delivery the chance to arrive before ruling it out.
        usleep(200_000)
        #expect(inbox.all.count == 1)
    }

    @Test("A recycled pid reports the death of the process that actually ended")
    func recycledPIDClosesTheOldWatch() throws {
        let inbox = Inbox<AgentEvent>()
        let watcher = ProcessWatcher(
            configuration: .init(safetySweepInterval: 0, sweepOnStart: false),
            onExit: { inbox.append($0) }
        )
        watcher.start()
        defer { watcher.stop() }

        let child = try spawnShortLivedProcess(seconds: "2")
        let pid = child.processIdentifier
        let real = try #require(inspector.snapshot(pid: pid)).startTime

        // A stale start time stands in for the process that held this pid before.
        let stale = real &- 1_000_000
        #expect(watcher.watch(pid: pid, startTime: stale, provider: .claudeCode))
        // The liveness check sees a different process on that pid and closes the
        // stale watch immediately, rather than waiting for an exit that happened
        // before we ever subscribed.
        let events = inbox.wait(forAtLeast: 1, timeout: 2)
        #expect(events.first?.id == EventID("exit-\(pid)-\(stale)"))

        child.terminate()
        child.waitUntilExit()
    }

    @Test("A stopped watcher stays silent and can be started again")
    func stopIsSilentAndRepeatable() throws {
        let inbox = Inbox<AgentEvent>()
        let watcher = ProcessWatcher(
            configuration: .init(safetySweepInterval: 0, sweepOnStart: false),
            onExit: { inbox.append($0) }
        )
        watcher.start()
        watcher.start()

        // Long enough that the child is unambiguously still alive when the
        // watcher is stopped, so silence afterwards means something.
        let child = try spawnShortLivedProcess(seconds: "0.6")
        let pid = child.processIdentifier
        let startTime = try #require(inspector.snapshot(pid: pid)).startTime
        #expect(watcher.watch(pid: pid, startTime: startTime, provider: .claudeCode))

        // Stopping is not evidence that anything exited.
        watcher.stop()
        watcher.stop()
        #expect(watcher.activeWatches.isEmpty)

        child.waitUntilExit()
        usleep(200_000)
        #expect(inbox.all.isEmpty, "stopping the watcher must not synthesise exits")

        watcher.start()
        #expect(watcher.activeWatches.isEmpty)
        watcher.stop()
    }

    @Test("A discovery sweep runs on demand without waiting on any timer")
    func sweepIsDrivenExplicitly() {
        let found = Inbox<AgentProcess>()
        let watcher = ProcessWatcher(
            configuration: .init(safetySweepInterval: .infinity, sweepOnStart: false),
            onDiscovered: { found.append($0) }
        )
        watcher.start()
        defer { watcher.stop() }

        #expect(watcher.activeWatches.isEmpty, "sweepOnStart: false must mean no sweep")
        watcher.sweep()

        // Whatever agents this machine happens to be running, the sweep must
        // watch exactly what it reported, and must never claim the test process.
        let watched = watcher.activeWatches
        #expect(!watched.contains { $0.pid == getpid() })
        let reported = found.wait(forAtLeast: watched.count, timeout: 2)
        #expect(Set(reported.map(\.pid)) == Set(watched.map(\.pid)))
    }

    /// The Refresh button's whole job, and for a long time it could not do it.
    ///
    /// An ordinary sweep announces each process exactly once, which is right for
    /// the safety timer and useless to a person who pressed Refresh because a
    /// session went missing. Their session is not absent because we never saw
    /// it — it is absent because the app lost it, and a sweep is guaranteed not
    /// to mention a process it has mentioned before.
    /// The Refresh button's whole job, and for a long time it could not do it.
    ///
    /// A sweep announces each process exactly once — right for the safety timer,
    /// useless to someone who pressed Refresh because a session went missing.
    /// Their session is not absent because we never saw it; it is absent because
    /// the app lost it, and a sweep is guaranteed not to mention a process it
    /// has mentioned before.
    @Test("Refresh re-announces agents an ordinary sweep would stay quiet about")
    func resyncReannouncesWhatSweepWillNot() throws {
        let agent = try selfAsAgent()
        let found = Inbox<AgentProcess>()
        let watcher = ProcessWatcher(
            configuration: .init(safetySweepInterval: .infinity, sweepOnStart: false),
            onDiscovered: { found.append($0) }
        )
        watcher.discoveryProbe = { [agent] in [agent] }
        watcher.start()
        defer { watcher.stop() }

        watcher.sweep()
        #expect(found.wait(forAtLeast: 1, timeout: 2).count == 1)

        // A second sweep is deliberately silent: nothing here is new.
        watcher.sweep()
        usleep(200_000)
        #expect(found.all.count == 1, "a plain sweep must not repeat itself")

        watcher.resync()
        #expect(
            found.wait(forAtLeast: 2, timeout: 2).count == 2,
            "resync announces a live agent the sweep had already reported"
        )
        #expect(found.all.allSatisfy { $0.pid == agent.pid })
    }

    @Test("The exit event is derived from pid and start time, so a repeat is one event")
    func exitEventIsIdempotent() {
        let first = ProcessWatcher.exitEvent(pid: 4242, startTime: 99, provider: .claudeCode)
        let second = ProcessWatcher.exitEvent(
            pid: 4242, startTime: 99, provider: .claudeCode, at: Date().addingTimeInterval(30)
        )
        #expect(first.id == second.id)
        #expect(first.id == EventID("exit-4242-99"))

        var deduplicator = EventDeduplicator()
        let admitted = deduplicator.admit(first.id)
        let readmitted = deduplicator.admit(second.id)
        #expect(admitted)
        #expect(!readmitted)
    }

    @Test("An observed exit ends the session it belongs to")
    func exitEndsTheSession() {
        var registry = SessionRegistry()
        let now = Date()
        let added = registry.adopt(provider: .claudeCode, pid: 4242, startTime: 99, now: now)
        #expect(added != nil)

        let results = registry.ingest(
            ProcessWatcher.exitEvent(pid: 4242, startTime: 99, provider: .claudeCode, at: now), now: now
        )
        let session = registry[SessionID.process(.claudeCode, pid: 4242, startTime: 99)]
        #expect(session?.state == .ended)
        #expect(session?.stateConfidence == .high)
        #expect(results.contains { if case .sessionChanged = $0 { return true } else { return false } })
    }
}
