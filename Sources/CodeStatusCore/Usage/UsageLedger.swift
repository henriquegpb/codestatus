import Foundation

/// Accumulates usage records into the totals the app displays.
///
/// The de-duplication is the reason this is a type rather than a `reduce`. The
/// same assistant message appears in more than one transcript file whenever a
/// session is resumed or branched — Claude Code copies the prior history into
/// the new file — so a naive sum over the directory double-counts, and does so
/// worst for exactly the heavy sessions a usage display exists to surface.
/// Measured on a real machine, ignoring this inflated the monthly total
/// substantially.
///
/// Value semantics and no I/O: the whole aggregation is asserted directly in
/// tests, the same way the state machine is.
public struct UsageLedger: Sendable {

    /// One day's usage for one model, which is the finest grain anything
    /// displays and the grain pricing needs (rates are per model).
    public struct Key: Hashable, Sendable {
        public let day: Date
        public let model: String

        public init(day: Date, model: String) {
            self.day = day
            self.model = model
        }
    }

    private var totals: [Key: TokenUsage] = [:]
    /// Identity of every record already counted.
    private var seen: Set<String> = []
    private var calendar: Calendar

    public private(set) var recordCount = 0
    /// Models seen that ``ModelPricing`` has no rate for. Surfaced rather than
    /// silently priced at zero, so a new model shows up as a gap in the total
    /// instead of quietly understating it.
    public private(set) var unpricedModels: Set<String> = []

    public init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    /// Adds a record unless it has been counted before.
    ///
    /// Identity is the API's `message.id` paired with `requestId`. Either alone
    /// is insufficient: one message id can span several requests when a turn is
    /// retried, and a request id is absent on older records.
    @discardableResult
    public mutating func add(_ record: UsageRecord) -> Bool {
        let identity: String
        if let messageID = record.messageID {
            identity = "\(messageID)|\(record.requestID ?? "")"
        } else if let requestID = record.requestID {
            identity = "|\(requestID)"
        } else {
            // Nothing to key on. Counted, because dropping real usage is the
            // worse error, and this is rare enough not to distort a total.
            identity = "anon-\(recordCount)"
        }
        guard seen.insert(identity).inserted else { return false }

        recordCount += 1
        if !ModelPricing.isSynthetic(record.model), ModelPricing.forModel(record.model) == nil {
            unpricedModels.insert(record.model)
        }
        let key = Key(day: calendar.startOfDay(for: record.timestamp), model: record.model)
        totals[key, default: TokenUsage()] += record.usage
        return true
    }

    // MARK: - Reading

    public var isEmpty: Bool { totals.isEmpty }

    public func usage(on day: Date) -> TokenUsage {
        let start = calendar.startOfDay(for: day)
        return totals
            .filter { $0.key.day == start }
            .values
            .reduce(TokenUsage(), +)
    }

    public func cost(on day: Date) -> Double {
        let start = calendar.startOfDay(for: day)
        return totals
            .filter { $0.key.day == start }
            .reduce(0) { $0 + priced($1.key.model, $1.value) }
    }

    public var totalUsage: TokenUsage {
        totals.values.reduce(TokenUsage(), +)
    }

    public var totalCost: Double {
        totals.reduce(0) { $0 + priced($1.key.model, $1.value) }
    }

    /// Days that have any usage, newest first.
    public func days(limit: Int = 30) -> [(day: Date, usage: TokenUsage, cost: Double)] {
        var byDay: [Date: TokenUsage] = [:]
        var costByDay: [Date: Double] = [:]
        for (key, usage) in totals {
            byDay[key.day, default: TokenUsage()] += usage
            costByDay[key.day, default: 0] += priced(key.model, usage)
        }
        return byDay.keys.sorted(by: >).prefix(limit).map {
            ($0, byDay[$0] ?? TokenUsage(), costByDay[$0] ?? 0)
        }
    }

    /// Per-model totals across everything, largest spend first.
    public func byModel() -> [(model: String, usage: TokenUsage, cost: Double)] {
        var byModel: [String: TokenUsage] = [:]
        for (key, usage) in totals {
            byModel[key.model, default: TokenUsage()] += usage
        }
        return byModel
            .map { ($0.key, $0.value, priced($0.key, $0.value)) }
            .filter { !$0.1.isEmpty }
            .sorted { $0.2 > $1.2 }
    }

    private func priced(_ model: String, _ usage: TokenUsage) -> Double {
        ModelPricing.forModel(model)?.cost(of: usage) ?? 0
    }
}
