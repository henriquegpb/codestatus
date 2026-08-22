import Foundation

/// Bounded, insertion-ordered set of event ids used to drop repeat deliveries.
///
/// Hooks can fire more than once for the same logical event (a retry, a spool
/// replay after a restart, both a `PermissionRequest` hook and its matching
/// `Notification`). Dropping repeats here is what guarantees the spec's "one
/// sound and one notification per transition".
///
/// A FIFO window rather than a true LRU: events arrive as a stream, so the
/// oldest id is always the least likely to recur, and eviction stays O(1).
public struct EventDeduplicator: Sendable {
    private var seen: Set<EventID> = []
    private var order: [EventID] = []
    private let capacity: Int

    /// - Parameter capacity: how many recent ids to remember. The default holds
    ///   several minutes of heavy multi-session tool use.
    public init(capacity: Int = 4096) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        order.reserveCapacity(capacity)
    }

    /// Records an id and reports whether it had not been seen before.
    ///
    /// Returns `false` for a repeat, which callers treat as "drop silently".
    public mutating func admit(_ id: EventID) -> Bool {
        guard seen.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity {
            let evicted = order.removeFirst()
            seen.remove(evicted)
        }
        return true
    }

    /// Whether an id is inside the current window, without recording it.
    public func contains(_ id: EventID) -> Bool {
        seen.contains(id)
    }

    public var count: Int { order.count }
}
