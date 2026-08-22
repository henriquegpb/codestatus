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
