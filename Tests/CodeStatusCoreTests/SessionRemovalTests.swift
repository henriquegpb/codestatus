import Foundation
import Testing

@testable import CodeStatusCore

@Suite("Dismissing a session")
struct SessionRemovalTests {

    @Test("PID-only hooks cannot choose between conversations on a shared server")
    func ambiguousHooksAreDropped() {
        var registry = SessionRegistry()
        for id in ["a", "b"] {
            _ = registry.ingest(AgentEvent(
                id: EventID(id), provider: .codex, kind: .preToolUse,
                source: .hook, timestamp: Date(), providerSessionID: id, pid: 42
            ))
        }
        let results = registry.ingest(AgentEvent(
            id: EventID("ambiguous"), provider: .codex, kind: .stop,
            source: .hook, timestamp: Date(), pid: 42
        ))
        #expect(results == [.eventDropped(EventID("ambiguous"), .unroutable)])
        #expect(registry.counts()[.busy] == 2)
        registry.remove(.provider(.codex, "a"))
        _ = registry.ingest(AgentEvent(
            id: EventID("unambiguous"), provider: .codex, kind: .stop,
            source: .hook, timestamp: Date(), pid: 42
        ))
        #expect(registry[.provider(.codex, "b")]?.state == .free)
    }

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

    /// Removing a session cannot block discovery of a later process reusing its PID.
    @Test func removeAllowsPIDReuse() {
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
