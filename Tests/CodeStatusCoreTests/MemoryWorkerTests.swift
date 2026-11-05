import Foundation
import Testing
@testable import CodeStatusCore

@Suite("Codex memory workers")
struct MemoryWorkerTests {
    @Test("An unidentified memory hook cannot delete a conversation sharing its PID")
    func unidentifiedWorkerKeepsTheChat() {
        var registry = SessionRegistry()
        _ = registry.ingest(AgentEvent(
            id: EventID("chat"), provider: .codex, kind: .preToolUse,
            source: .hook, timestamp: Date(), providerSessionID: "chat", pid: 42
        ))
        let rejected = AgentEvent(
            id: EventID("unidentified-worker"), provider: .codex, kind: .preToolUse,
            source: .hook, timestamp: Date(), cwd: "/custom/codex/memories", pid: 42
        )
        let removed = registry.removeSession(for: rejected)
        #expect(removed.isEmpty)
        #expect(registry[.provider(.codex, "chat")]?.state == .busy)
    }

    @Test("Rejecting a worker hook removes its identity before cwd enrichment")
    func rejectPreviouslyUnclassifiedWorker() {
        var registry = SessionRegistry()
        _ = registry.ingest(AgentEvent(
            id: EventID("start"), provider: .codex, kind: .sessionStart,
            source: .hook, timestamp: Date(), providerSessionID: "worker", pid: 42
        ))
        _ = registry.ingest(AgentEvent(
            id: EventID("chat"), provider: .codex, kind: .preToolUse,
            source: .hook, timestamp: Date(), providerSessionID: "chat", pid: 42
        ))
        let rejected = AgentEvent(
            id: EventID("worker-tool"), provider: .codex, kind: .preToolUse,
            source: .hook, timestamp: Date(), providerSessionID: "worker",
            cwd: "/custom/codex/memories", pid: 42
        )
        let removed = registry.removeSession(for: rejected)
        #expect(removed == [.sessionRemoved(.provider(.codex, "worker"))])
        #expect(registry[.provider(.codex, "chat")]?.state == .busy)
    }

    @Test("Only a memory workspace inside a verified Codex home matches")
    func workspaceEvidence() {
        let files: Set<String> = [
            "/custom/codex/config.toml", "/custom/codex/memories_1.sqlite",
            "/projects/config.toml",
        ]
        #expect(CodexMemoryWorkspace.matches("/custom/codex/memories", fileExists: files.contains))
        #expect(!CodexMemoryWorkspace.matches("/projects/memories", fileExists: files.contains))
        #expect(!CodexMemoryWorkspace.matches("/custom/codex/project", fileExists: files.contains))
        #expect(!CodexMemoryWorkspace.matches("memories", fileExists: files.contains))
    }

    @Test("Cleaning up memory workers preserves conversations sharing their process")
    func cleanupKeepsConversations() {
        var registry = SessionRegistry()
        for (id, provider, cwd) in [
            ("worker", AgentProvider.codex, "/custom/codex/memories"),
            ("chat", AgentProvider.codex, "/projects/memories"),
            ("claude", AgentProvider.claudeCode, "/custom/codex/memories"),
        ] {
            _ = registry.ingest(AgentEvent(
                id: EventID(id), provider: provider, kind: .preToolUse,
                source: .hook, timestamp: Date(), providerSessionID: id,
                cwd: cwd, pid: 42
            ))
        }
        let removed = registry.removeCodexMemoryWorkers { $0 == "/custom/codex/memories" }
        #expect(removed == [.sessionRemoved(.provider(.codex, "worker"))])
        #expect(registry.visible.count == 2)
        #expect(registry.counts()[.busy] == 2)
    }
}
