import Testing
import Foundation
@testable import CodeStatusCore

/// A snapshot records what was true when the app last ran. Restoring it
/// unchecked is how a session that ended hours ago becomes a permanently `free`
/// row: `free` is the correct state for a finished turn, and it stops being
/// true the moment the agent exits without a `SessionEnd` anyone heard.
@Suite("Restored sessions are checked against reality")
struct RestoreLivenessTests {

    private func session(
        _ id: String,
        state: AgentState = .free,
        pid: pid_t? = 4242,
        startTime: UInt64? = 111
    ) -> AgentSession {
        var s = AgentSession(
            id: SessionID(id), provider: .claudeCode,
            now: Date(timeIntervalSince1970: 0), sourceAdapter: "test"
        )
        s.state = state
        s.pid = pid
        s.processStartTime = startTime
        return s
    }

    @Test("A session whose process is gone is dropped, not restored as free")
    func deadSessionsAreDropped() {
        let live = StatePersistence.filterToLiveSessions(
            [session("a"), session("b")],
            isAlive: { _, _ in false }
        )
        #expect(live.isEmpty)
    }

    @Test("A session whose process is still running is kept")
    func liveSessionsSurvive() {
        let live = StatePersistence.filterToLiveSessions(
            [session("a")],
            isAlive: { _, _ in true }
        )
        #expect(live.count == 1)
        #expect(live.first?.state == .free)
    }

    /// Pids are recycled within minutes. Checking the pid alone would let an
    /// unrelated new process keep a dead agent's session alive on screen.
    @Test("Liveness is judged on pid and start time together")
    func startTimeIsPartOfIdentity() {
        var seen: [(pid_t, UInt64)] = []
        _ = StatePersistence.filterToLiveSessions([session("a", pid: 900, startTime: 777)]) {
            seen.append(($0, $1))
            return true
        }
        #expect(seen.count == 1)
        #expect(seen.first?.0 == 900)
        #expect(seen.first?.1 == 777)
    }

    /// A phantom `free` row costs the user a click and their trust in every
    /// other row. Re-finding a live session costs the process watcher one sweep.
    @Test("A session we cannot check at all is dropped rather than trusted")
    func uncheckableSessionsAreDropped() {
        let candidates = [
            session("no-pid", pid: nil),
            session("no-start-time", startTime: nil),
        ]
        let live = StatePersistence.filterToLiveSessions(candidates, isAlive: { _, _ in true })
        #expect(live.isEmpty)
    }

    @Test("Restoring three finished sessions from a dead run leaves nothing behind")
    func theActualBug() {
        // What the HUD showed: three "mobile · Free" rows for the same project,
        // all of them past runs that had exited.
        let stale = (0..<3).map { session("mobile-\($0)", pid: pid_t(1000 + $0), startTime: 42) }
        let live = StatePersistence.filterToLiveSessions(stale, isAlive: { _, _ in false })
        #expect(live.isEmpty)
    }
}

/// The HUD answers one question: how many agents are working, free, or waiting
/// on you. A session found by scanning processes proves something is running
/// and says nothing about what it is doing, so letting it into that answer
/// makes the answer partly guesswork.
@Suite("Only sessions that have reported are counted")
struct ReportingSessionTests {

    private func hookEvent(_ kind: HookEventKind, session: String, id: String) -> AgentEvent {
        AgentEvent(
            id: EventID(id), provider: .claudeCode, kind: kind, source: .hook,
            timestamp: Date(timeIntervalSince1970: 100), providerSessionID: session,
            providerTurnID: "t1"
        )
    }

    @Test("A process we merely found is tracked but not listed or counted")
    func discoveredSessionsAreNotListed() {
        var registry = SessionRegistry()
        _ = registry.adopt(provider: .claudeCode, pid: 4242, startTime: 1, now: Date())

        #expect(registry.all.count == 1, "it must still be tracked, for exit detection")
        #expect(registry.visible.isEmpty)
        #expect(registry.unreported.count == 1)
        #expect(registry.counts().isEmpty)
    }

    @Test("It joins the list the moment its agent reports")
    func reportingPromotesASession() {
        var registry = SessionRegistry()
        _ = registry.ingest(hookEvent(.userPromptSubmit, session: "s1", id: "e1"))

        #expect(registry.visible.count == 1)
        #expect(registry.unreported.isEmpty)
        #expect(registry.counts()[.busy] == 1)
    }

    /// The exact shape that put four permanent grey rows in the HUD: three
    /// conversation tabs the VS Code extension had restored, none of which had
    /// run a turn since hooks were installed, next to one real session.
    @Test("Four found processes and one live session read as one session")
    func theActualScreenshot() {
        var registry = SessionRegistry()
        for index in 0..<4 {
            _ = registry.adopt(
                provider: .claudeCode, pid: pid_t(500 + index), startTime: 1, now: Date()
            )
        }
        _ = registry.ingest(hookEvent(.stop, session: "real", id: "e1"))

        #expect(registry.visible.count == 1)
        #expect(registry.visible.first?.state == .free)
        #expect(registry.counts() == [.free: 1])
        #expect(registry.unreported.count == 4, "the four are reported as a count, not hidden")
    }

    @Test("Process exit still removes a session nobody ever reported on")
    func exitStillAppliesToUnreportedSessions() {
        var registry = SessionRegistry()
        _ = registry.adopt(provider: .claudeCode, pid: 4242, startTime: 1, now: Date())

        let exit = AgentEvent(
            id: EventID("x"), provider: .claudeCode, kind: .processExited, source: .process,
            timestamp: Date(timeIntervalSince1970: 200), pid: 4242
        )
        _ = registry.ingest(exit)

        #expect(registry.unreported.isEmpty)
        #expect(registry.all.first?.state == .ended)
    }
}
