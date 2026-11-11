import Foundation
import Testing
import CodeStatusCore
@testable import CodeStatusApp

@Suite("Notifications when agents are ready for work")
@MainActor
struct NotificationTests {
    @Test("Shared-process exit ignores discovery placeholders and alerts only for unfinished work",
          arguments: [false, true])
    func sharedProcessExit(finishTurn: Bool) throws {
        var registry = SessionRegistry()
        let now = Date()
        _ = registry.adopt(provider: .codex, pid: 42, startTime: 100, now: now)
        let kinds: [HookEventKind] = finishTurn
            ? [.sessionStart, .userPromptSubmit, .stop] : [.sessionStart, .userPromptSubmit]
        for (index, kind) in kinds.enumerated() {
            _ = registry.ingest(AgentEvent(
                id: EventID("hook-\(index)"), provider: .codex, kind: kind,
                source: .hook, timestamp: now.addingTimeInterval(Double(index)),
                providerSessionID: "conversation", pid: 42
            ))
        }
        _ = registry.enrichProcess(ProcessSnapshot(
            pid: 42, parentPID: 1, startTime: 100, name: "codex"
        ))
        let changes = registry.ingest(ProcessWatcher.exitEvent(
            pid: 42, startTime: 100, provider: .codex, at: now.addingTimeInterval(10)
        ))
        #expect(changes.count == 2, "both the placeholder and the conversation must end")
        #expect(registry.all.allSatisfy { $0.state == .ended })
        var alertingSessions: [SessionID] = []
        for change in changes {
            guard case .sessionChanged(let transition) = change else { continue }
            let session = try #require(registry[transition.sessionID])
            if NotificationCoordinator.content(for: transition, session: session) != nil {
                alertingSessions.append(session.id)
            }
        }
        let expected: [SessionID] = finishTurn ? [] : [.provider(.codex, "conversation")]
        #expect(alertingSessions == expected)
    }

    @Test("Finishing work announces readiness even while a reply or approval was pending",
          arguments: [AgentState.busy, .waitingForApproval, .waitingForInput])
    func completion(from state: AgentState) throws {
        let (session, transition) = try reduce(from: state, event: .stop)
        let content = try #require(NotificationCoordinator.content(for: transition, session: session))
        #expect(content.title == "Claude Code finished in project")
        #expect(content.body.contains("Ready for another prompt."))
    }

    @Test("Opening or rediscovering an idle session never announces finished work",
          arguments: [AgentState.discovering, .unknown, .reconnecting, .failed])
    func opening(from state: AgentState) throws {
        let (session, transition) = try reduce(from: state, event: .sessionStart)
        #expect(NotificationCoordinator.content(for: transition, session: session) == nil)
    }

    private func reduce(from state: AgentState, event: HookEventKind) throws -> (AgentSession, Transition) {
        let now = Date()
        var session = AgentSession(
            id: SessionID("claudeCode:test"), provider: .claudeCode,
            now: now, sourceAdapter: "test"
        )
        session.state = state
        session.cwd = "/tmp/project"
        let event = AgentEvent(
            id: EventID("test"), provider: .claudeCode, kind: event,
            source: .hook, timestamp: now, providerSessionID: "test"
        )
        let reduction = StateReducer.reduce(session, applying: event)
        guard case .stateChanged(let transition) = reduction.outcome else {
            Issue.record("Expected a state transition")
            throw TestError.noTransition
        }
        return (reduction.session, transition)
    }

    private enum TestError: Error { case noTransition }
}
