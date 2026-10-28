import CodeStatusCore
import Foundation
import Testing
@testable import CodeStatusApp

@Suite("Approval alert grace period")
@MainActor
struct ApprovalAlertDelayTests {
    @Test("An unresolved permission check delivers only after the grace period")
    func pendingApproval() async throws {
        let flow = NotificationFlow(delay: .milliseconds(10))
        let task = try #require(flow.send(.permissionRequest))
        #expect(flow.notifications.isEmpty)
        await task.value
        #expect(flow.notifications.count == 1)
    }

    @Test("A quick tool result cancels the approval alert through the real state transitions")
    func quickTool() async throws {
        let flow = NotificationFlow(delay: .seconds(60))
        let task = try #require(flow.send(.permissionRequest))
        flow.send(.postToolUse)
        await task.value
        #expect(flow.notifications.isEmpty)
        #expect(flow.session.state == .busy)
    }

    @Test("A long automatically approved tool never claims human approval is confirmed")
    func longTool() async throws {
        let flow = NotificationFlow(delay: .zero)
        flow.send(.preToolUse)
        let task = try #require(flow.send(.permissionRequest))
        // Approval can resolve here without a hook. While the tool runs there
        // is no new evidence, even after the grace period expires.
        await task.value
        let content = try #require(flow.notifications.first)
        #expect(content.title == "Codex may need approval in project")
        #expect(content.body.contains("The command may already be running."))
        flow.send(.postToolUse)
        #expect(flow.session.state == .busy)
        #expect(flow.notifications.count == 1)
    }

    @Test("A replacement task survives cancellation of the older task")
    func replacement() async throws {
        let flow = NotificationFlow(delay: .zero)
        let old = try #require(flow.send(.permissionRequest))
        flow.send(.postToolUse)
        flow.send(.preToolUse, toolID: "next-tool")
        let current = try #require(flow.send(.permissionRequest))
        await old.value
        await current.value
        #expect(flow.notifications.count == 1)
    }

    @Test("A stale transition still cancels an earlier approval alert")
    func staleResult() async throws {
        let flow = NotificationFlow(delay: .seconds(60))
        let task = try #require(flow.send(.permissionRequest))
        flow.send(.postToolUse, eligible: false)
        await task.value
        #expect(flow.notifications.isEmpty)
    }

    @Test("Resolving one session never cancels another session's approval alert")
    func independentSessions() async throws {
        let delay = ApprovalAlertDelay(delay: .zero)
        let one = NotificationFlow(id: "one", delay: delay)
        let two = NotificationFlow(id: "two", delay: delay)
        let first = try #require(one.send(.permissionRequest))
        let second = try #require(two.send(.permissionRequest))
        one.send(.postToolUse)
        await first.value
        await second.value
        #expect(one.notifications.isEmpty)
        #expect(two.notifications.count == 1)
    }

    @Test("Removal or reconciliation cancels pending approval alerts")
    func removalAndReconciliation() async throws {
        let flow = NotificationFlow(delay: .seconds(60))
        let removed = try #require(flow.send(.permissionRequest))
        flow.delay.cancel(for: flow.session.id)
        await removed.value
        #expect(flow.notifications.isEmpty)
        flow.send(.postToolUse)
        flow.send(.preToolUse, toolID: "next-tool")
        let reconciled = try #require(flow.send(.permissionRequest))
        flow.delay.cancelAll()
        await reconciled.value
        #expect(flow.notifications.isEmpty)
    }

    @Test("Reply requests remain immediate and cancel a pending approval alert")
    func replyRequest() async throws {
        let flow = NotificationFlow(delay: .seconds(60))
        let task = try #require(flow.send(.permissionRequest))
        flow.send(.elicitation)
        #expect(flow.notifications.count == 1)
        #expect(flow.notifications.first?.title == "Codex is waiting for you in project")
        await task.value
        #expect(flow.notifications.count == 1)
    }
}

/// Uses the reducer and delivery router together, without macOS notification
/// permissions or a signed test runner. No tool payloads are needed.
@MainActor
private final class NotificationFlow {
    let delay: ApprovalAlertDelay
    private(set) var session: AgentSession
    private(set) var notifications: [NotificationCoordinator.Content] = []
    private var eventNumber = 0
    private var activeToolID = "first-tool"

    convenience init(delay: Duration) {
        self.init(id: "one", delay: ApprovalAlertDelay(delay: delay))
    }

    init(id: String, delay: ApprovalAlertDelay) {
        self.delay = delay
        session = AgentSession(
            id: SessionID(id), provider: .codex,
            now: Date(timeIntervalSince1970: 1_770_000_000), sourceAdapter: "test"
        )
        session.state = .busy
        session.cwd = "/tmp/project"
    }

    @discardableResult
    func send(_ kind: HookEventKind, eligible: Bool = true, toolID: String? = nil) -> Task<Void, Never>? {
        eventNumber += 1
        if kind == .preToolUse, let toolID { activeToolID = toolID }
        let identifiesToolUse = kind == .preToolUse || kind == .postToolUse
        let event = AgentEvent(
            id: EventID("event-\(eventNumber)"), provider: .codex, kind: kind,
            source: .hook, timestamp: session.lastEventAt.addingTimeInterval(1),
            providerSessionID: session.id.rawValue, providerTurnID: "turn-1",
            toolName: kind == .elicitation ? nil : "Bash",
            toolUseID: identifiesToolUse ? activeToolID : nil
        )
        let reduction = StateReducer.reduce(session, applying: event)
        session = reduction.session
        guard case .stateChanged(let transition) = reduction.outcome else { return nil }
        let snapshot = session
        return delay.handle(transition, eligible: eligible) { [self] in
            if let content = NotificationCoordinator.content(for: transition, session: snapshot) {
                notifications.append(content)
            }
        }
    }
}
