import Testing
import Foundation
@testable import CodeStatusCore

/// Exit reconciliation is repeatable: shared servers and hooks arriving after
/// the first exit observation must converge without duplicate notifications.
@Suite("Reaping a dead process")
struct ReapLoopTests {

    @Test("Reconciliation stamps new sessions before emitting an old incarnation's exit")
    func reconciliationKeepsTheReplacementAlive() {
        var registry = SessionRegistry()
        _ = registry.adopt(provider: .codex, pid: 42, startTime: 100, now: Date())
        for id in ["new-a", "new-b"] {
            _ = registry.ingest(AgentEvent(
                id: EventID(id), provider: .codex, kind: .preToolUse,
                source: .hook, timestamp: Date(), providerSessionID: id, pid: 42
            ))
        }
        let replacement = ProcessSnapshot(pid: 42, parentPID: 99, startTime: 200, name: "codex")
        let results = registry.enrichProcess(replacement)
        #expect(results.count == 1)
        #expect(registry[.process(.codex, pid: 42, startTime: 100)]?.state == .ended)
        for id in ["new-a", "new-b"] {
            #expect(registry[.provider(.codex, id)]?.processStartTime == 200)
            #expect(registry[.provider(.codex, id)]?.state == .busy)
        }
        let repeated = registry.enrichProcess(replacement)
        #expect(repeated.isEmpty)
    }

    @Test("Exit evidence can close a session learned from a later hook")
    func exitBeforeHook() {
        var registry = SessionRegistry()
        let exit = ProcessWatcher.exitEvent(pid: 42, startTime: 100, provider: .codex)
        let initialExit = registry.ingest(exit)
        #expect(initialExit.isEmpty)
        _ = registry.ingest(AgentEvent(
            id: EventID("late"), provider: .codex, kind: .preToolUse,
            source: .hook, timestamp: exit.timestamp, providerSessionID: "late", pid: 42
        ))
        let lateExit = registry.ingest(exit)
        #expect(lateExit.count == 1)
        #expect(registry[.provider(.codex, "late")]?.state == .ended)
        let repeatedExit = registry.ingest(exit)
        #expect(repeatedExit.isEmpty)
    }

    @Test("Enrichment preserves stale process identity for exit reconciliation")
    func enrichmentDoesNotReassignReusedPID() {
        var registry = SessionRegistry()
        _ = registry.adopt(provider: .codex, pid: 42, startTime: 100, now: Date())
        let oldID = SessionID.process(.codex, pid: 42, startTime: 100)
        var old = registry[oldID]!
        let replacement = ProcessSnapshot(
            pid: 42, parentPID: 99, startTime: 200, name: "codex", tty: "/dev/ttys007"
        )
        let enrichedOld = old.enrichProcess(replacement)
        #expect(!enrichedOld)
        #expect(old.processStartTime == 100)
        #expect(old.parentPID == nil)
        #expect(old.tty == nil)
        let replacementAdded = registry.adopt(provider: .codex, pid: 42, startTime: 200, now: Date())
        #expect(replacementAdded != nil)
        _ = registry.ingest(ProcessWatcher.exitEvent(pid: 42, startTime: 100, provider: .codex))
        #expect(registry[oldID]?.state == .ended)
        #expect(registry[.process(.codex, pid: 42, startTime: 200)]?.state == .unknown)
    }

    @Test("Enrichment fills missing identity and terminal metadata for the same process")
    func enrichmentFillsUnknownStartTime() {
        var session = AgentSession(
            id: .provider(.codex, "s"), provider: .codex, now: Date(), sourceAdapter: "test"
        )
        session.pid = 42
        let snapshot = ProcessSnapshot(
            pid: 42, parentPID: 99, startTime: 200, name: "codex", tty: "/dev/ttys007"
        )
        let enriched = session.enrichProcess(snapshot)
        #expect(enriched)
        #expect(session.processStartTime == 200)
        #expect(session.parentPID == 99)
        #expect(session.controlTarget.tty == "/dev/ttys007")
        let enrichedAgain = session.enrichProcess(snapshot)
        #expect(enrichedAgain)
    }

    @Test("A shared server exit ends all its sessions and preserves a recycled PID")
    func sharedServerExit() {
        var registry = SessionRegistry()
        for (id, start) in [("a", UInt64(100)), ("b", 100), ("recycled", 200)] {
            _ = registry.ingest(AgentEvent(
                id: EventID(id), provider: .codex, kind: .preToolUse,
                source: .hook, timestamp: Date(), providerSessionID: id, pid: 42
            ))
            var session = registry[.provider(.codex, id)]!
            session.processStartTime = start
            registry.update(session)
        }
        let exit = ProcessWatcher.exitEvent(pid: 42, startTime: 100, provider: .codex)
        let results = registry.ingest(exit)
        #expect(results.count == 2)
        #expect(registry[.provider(.codex, "a")]?.state == .ended)
        #expect(registry[.provider(.codex, "b")]?.state == .ended)
        #expect(registry[.provider(.codex, "recycled")]?.state == .busy)
        _ = registry.ingest(exit)
        #expect(registry.visible.count == 1)
    }

    private func discoveredSession(
        pid: pid_t = 4242,
        startTime: UInt64 = 1_787_804_933_874_096
    ) -> (registry: SessionRegistry, id: SessionID) {
        var registry = SessionRegistry()
        let added = registry.adopt(
            provider: .claudeCode, pid: pid, startTime: startTime, now: Date()
        )
        #expect(added != nil, "the fixture must actually create a session")
        return (registry, SessionID.process(.claudeCode, pid: pid, startTime: startTime))
    }

    @Test("One exit event ends a session discovered by the process watcher")
    func exitEndsADiscoveredSession() {
        var (registry, id) = discoveredSession()
        #expect(registry.all.first(where: { $0.id == id })?.state.isActive == true)

        _ = registry.ingest(ProcessWatcher.exitEvent(
            pid: 4242, startTime: 1_787_804_933_874_096, provider: .claudeCode
        ))

        let session = registry.all.first { $0.id == id }
        #expect(
            session == nil || session?.state.isActive == false,
            "a reaped session must not still count as active"
        )
    }

    /// What the reaper actually does on a live machine: it finds the same dead
    /// session on every sweep and builds the same event again.
    @Test("Reaping the same dead process twice does not leave it active")
    func repeatedReapingConverges() {
        var (registry, id) = discoveredSession()
        let exit = ProcessWatcher.exitEvent(
            pid: 4242, startTime: 1_787_804_933_874_096, provider: .claudeCode
        )

        _ = registry.ingest(exit)
        let afterFirst = registry.all.first { $0.id == id }?.state

        // The reaper's second sweep, ten seconds later, builds an identical
        // event -- identical id included.
        let results = registry.ingest(exit)
        let afterSecond = registry.all.first { $0.id == id }?.state

        #expect(results.isEmpty, "an ended session produces no second transition")
        #expect(afterFirst == afterSecond, "repeating exit evidence leaves the ended state unchanged")
        #expect(
            afterSecond?.isActive != true,
            "a dead process must have no active sessions"
        )
    }
}
