import Foundation
import Testing

@testable import CodeStatusCore

@Suite("Dismissing a session")
struct SessionRemovalTests {

    /// The × in the popover. Distinct from ending a session: the process may
    /// still be running and we are simply told to stop showing it.
    @Test func removeDropsTheSessionAndReportsIt() {
        var registry = SessionRegistry()
        let now = Date()
        let added = registry.adopt(provider: .codex, pid: 4242, startTime: 99, now: now)
        #expect(added != nil)

        let id = SessionID.process(.codex, pid: 4242, startTime: 99)
        #expect(registry[id] != nil)

        let events = registry.remove(id)
        #expect(events == [.sessionRemoved(id)])
        #expect(registry[id] == nil)
        #expect(registry.all.isEmpty)
    }

    /// Removing frees the pid index too, so a later process reusing that pid is
    /// not routed into the session that just went away.
    @Test func removeReleasesThePidIndex() {
        var registry = SessionRegistry()
        _ = registry.adopt(provider: .codex, pid: 4242, startTime: 99, now: Date())
        registry.remove(SessionID.process(.codex, pid: 4242, startTime: 99))

        let readopted = registry.adopt(
            provider: .codex, pid: 4242, startTime: 1234, now: Date()
        )
        #expect(readopted != nil)
        #expect(registry.all.count == 1)
        // The new process, under its own identity — not the removed one
        // resurrected because its pid was still indexed.
        #expect(registry[SessionID.process(.codex, pid: 4242, startTime: 1234)] != nil)
        #expect(registry[SessionID.process(.codex, pid: 4242, startTime: 99)] == nil)
    }

    @Test func removingSomethingAbsentIsSilent() {
        var registry = SessionRegistry()
        #expect(registry.remove(SessionID("nope")).isEmpty)
    }
}
