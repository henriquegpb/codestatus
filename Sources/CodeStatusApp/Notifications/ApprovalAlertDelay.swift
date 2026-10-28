import CodeStatusCore

/// Delays approval alerts until quick tools have completed. Long-running tools
/// can still outlast this grace period after automatic approval: hooks do not
/// report the moment execution starts. Registry state is never inferred here.
@MainActor
final class ApprovalAlertDelay {
    private var pending: [SessionID: Task<Void, Never>] = [:]
    private let delay: Duration

    init(delay: Duration = .seconds(3)) {
        self.delay = delay
    }

    @discardableResult
    func handle(
        _ transition: Transition,
        eligible: Bool = true,
        deliver: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>? {
        let sessionID = transition.sessionID
        // Stale transitions must still cancel a previously scheduled alert.
        cancel(for: sessionID)
        guard eligible else { return nil }
        guard transition.to == .waitingForApproval else {
            deliver()
            return nil
        }
        let delay = delay
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            // No suspension between cancellation checking and delivery: on the
            // main actor an older task cannot remove a newer task's entry.
            guard !Task.isCancelled, let self else { return }
            self.pending.removeValue(forKey: sessionID)
            deliver()
        }
        pending[sessionID] = task
        return task
    }

    func cancel(for sessionID: SessionID) {
        pending.removeValue(forKey: sessionID)?.cancel()
    }

    func cancelAll() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }
}
