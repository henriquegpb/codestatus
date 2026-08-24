import Foundation
import Testing

@testable import CodeStatusCore

private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

/// A hook event from a known process, which is what makes a session reported.
private func hookEvent(
    _ provider: AgentProvider,
    sessionID: String,
    pid: pid_t,
    id: String
) -> AgentEvent {
    AgentEvent(
        id: EventID(id),
        provider: provider,
        kind: .userPromptSubmit,
        source: .hook,
        timestamp: t0,
        providerSessionID: sessionID,
        providerTurnID: "turn-1",
        pid: pid
    )
}

@Suite("Counting sessions that are not reporting")
struct UnreportedDedupTests {

    /// One agent is adopted twice before its first hook lands: once by process
    /// discovery, keyed on `(provider, pid, startTime)`, and once by the hook,
    /// keyed on the agent's own session id. Counting both told the user an
    /// agent was silent while its own row sat above saying it was busy.
    @Test func aProcessAlreadyReportingIsNotAlsoCountedAsSilent() {
        var registry = SessionRegistry()

        _ = registry.adopt(provider: .claudeCode, pid: 500, startTime: 7, now: t0)
        #expect(registry.unreported.count == 1, "discovered but silent, so far so good")

        _ = registry.ingest(
            hookEvent(.claudeCode, sessionID: "sess-abc", pid: 500, id: "e1"), now: t0
        )

        #expect(registry.visible.count == 1)
        #expect(
            registry.unreported.isEmpty,
            "the same process must not be both listed as a row and counted as silent"
        )
    }

    /// A genuinely silent agent, on a different process, is still reported —
    /// the deduplication must not become a way of hiding real sessions.
    @Test func aSeparateSilentProcessIsStillCounted() {
        var registry = SessionRegistry()

        _ = registry.adopt(provider: .codex, pid: 900, startTime: 3, now: t0)
        _ = registry.adopt(provider: .claudeCode, pid: 500, startTime: 7, now: t0)
        _ = registry.ingest(
            hookEvent(.claudeCode, sessionID: "sess-abc", pid: 500, id: "e1"), now: t0
        )

        #expect(registry.unreported.count == 1)
        #expect(registry.unreported.first?.pid == 900)
    }

    /// Two silent processes are two silent processes.
    @Test func distinctSilentProcessesAreCountedSeparately() {
        var registry = SessionRegistry()
        _ = registry.adopt(provider: .codex, pid: 900, startTime: 3, now: t0)
        _ = registry.adopt(provider: .codex, pid: 901, startTime: 4, now: t0)

        #expect(registry.unreported.count == 2)
    }
}
