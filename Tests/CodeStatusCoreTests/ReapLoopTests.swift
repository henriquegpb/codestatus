import Testing
import Foundation
@testable import CodeStatusCore

/// The reaper's one tool is an exit event whose id is derived from pid and
/// start time, so it is byte-identical every time it is built for the same
/// process. The registry drops repeated ids before the reducer ever sees them.
///
/// That makes the reaper structurally unable to retry: if its first attempt
/// does not end the session, no later attempt can, and the session stays
/// visible as an active agent for a process that no longer exists. Observed in
/// the wild as one log line every ten seconds, forever:
///
///     reaping claudeCode:pid-67032-1787804933874096: its process is gone
@Suite("Reaping a dead process")
struct ReapLoopTests {

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

        #expect(
            results.contains { if case .eventDropped(_, .duplicate) = $0 { true } else { false } },
            "the second delivery is dropped as a duplicate, so it can change nothing"
        )
        #expect(afterFirst == afterSecond, "and therefore nothing about the session moves")
        #expect(
            afterSecond?.isActive != true,
            "so the first attempt has to have been the one that worked"
        )
    }
}
