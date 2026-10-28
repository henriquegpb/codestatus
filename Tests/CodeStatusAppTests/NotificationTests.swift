import Foundation
import Testing
import CodeStatusCore
@testable import CodeStatusApp

@Suite("Notifications when agents are ready for work")
@MainActor
struct NotificationTests {
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
