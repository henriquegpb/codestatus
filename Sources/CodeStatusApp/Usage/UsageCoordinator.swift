import CodeStatusCore
import Foundation
import Observation
import os

/// Keeps the usage totals current, and publishes them for the HUD.
///
/// Scanning happens off the main actor: the first pass reads every transcript on
/// the machine, which measured 5.2 seconds on a real one, and the menu bar must
/// stay responsive through it. Later passes are incremental and take
/// milliseconds, so they can follow turn boundaries.
@MainActor
@Observable
final class UsageCoordinator {

    /// Today's spend at list API rates, **in US dollars** — the rates are
    /// published in USD and nothing here converts. Every surface says so, because
    /// a bare `$` next to a figure invites comparison with a billing console in
    /// another currency, which is a different measurement besides.
    ///
    /// Claude Code only: Codex models have no rate here, so folding them in would
    /// mean inventing one. `nil` until the first pass finishes, so the HUD can say
    /// "reading" rather than claim a confident zero.
    private(set) var todayCost: Double?
    private(set) var todayUsage = TokenUsage()
    private(set) var totalCost: Double = 0
    /// What is left of the Codex plan's quota. Always `nil` for Claude Code,
    /// which publishes nothing equivalent anywhere on disk.
    private(set) var codexLimits: RateLimitSnapshot?
    /// Codex tokens seen across every session on this Mac. Counted and shown,
    /// never priced — see ``ModelPricing``.
    private(set) var codexTokens = TokenUsage()
    /// Plan quota per session, newest reading first. The headline: it answers
    /// "how much can I still spend", which no cost estimate can.
    private(set) var plans: [PlanMetrics] = []
    /// Context fill worked out from the newest transcript turn, for sessions that
    /// never render a status line — see ``ContextEstimate``. Only consulted when
    /// the agent reported nothing itself; its own figure always wins.
    private(set) var contextEstimate: ContextEstimate?
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var unpricedModels: [String] = []

    /// Recent days and per-model totals, for the detail window.
    private(set) var days: [(day: Date, usage: TokenUsage, cost: Double)] = []
    private(set) var models: [(model: String, usage: TokenUsage, cost: Double)] = []

    var isEnabled = true {
        didSet { if isEnabled { refresh() } else { clear() } }
    }

    private let scanner = UsageScannerActor()
    private var timer: Timer?
    private let logger = Logger(subsystem: "co.codestatus", category: "usage")

    func start() {
        guard isEnabled else { return }
        refresh()
        // A backstop only. Turn boundaries drive the refresh, and this catches
        // usage from agents CodeStatus is not watching — a session started
        // before the hooks were installed still writes a transcript.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Rescans what has been appended since the last pass.
    ///
    /// Cheap and coalesced, so callers may fire it on any registry change.
    func refresh() {
        guard isEnabled, !isScanning else { return }
        isScanning = true
        Task {
            let result = await scanner.scan()
            self.apply(result)
        }
    }

    private func apply(_ result: UsageScannerActor.Result) {
        todayUsage = result.todayUsage
        todayCost = result.todayCost
        totalCost = result.totalCost
        codexLimits = result.codexLimits
        codexTokens = result.codexTokens
        plans = result.plans
        contextEstimate = result.contextEstimate
        days = result.days
        models = result.models
        unpricedModels = result.unpricedModels
        lastScan = Date()
        isScanning = false
        if !result.unpricedModels.isEmpty {
            logger.notice("usage seen for unpriced models: \(result.unpricedModels.joined(separator: ", "), privacy: .public)")
        }
    }

    private func clear() {
        todayCost = nil
        todayUsage = TokenUsage()
        totalCost = 0
        codexLimits = nil
        codexTokens = TokenUsage()
        plans = []
        contextEstimate = nil
        days = []
        models = []
    }

    // MARK: - Presentation

    /// One agent's reported quota, in the shape every provider is drawn in.
    ///
    /// The two providers deliver this through completely different files, and
    /// collapsing that difference here is the point: a reader asking "how much
    /// have I got left" should not have to know that Claude Code answers on a
    /// status line and Codex in a rollout file.
    struct ProviderQuota: Identifiable, Sendable {
        let provider: String
        let planType: String?
        let windows: [PlanMetrics.Window]
        /// Nil for Codex, whose rollout files are appended as the session runs
        /// rather than restated, so there is no single "as of" to report.
        let observedAt: Date?

        var id: String { provider }

        /// The window closest to being exhausted, which is the one worth showing.
        var tightest: PlanMetrics.Window? {
            windows.max { $0.usedPercent < $1.usedPercent }
        }

        var title: String { planType.map { "\(provider) · \($0)" } ?? provider }
    }

    /// Every agent that reported a quota, whichever file it arrived in.
    ///
    /// Ordered by how close each is to running out, so the agent the reader is
    /// about to be stopped by is first. Alphabetical or fixed order would put a
    /// provider at 7% above one at 91%.
    var quotas: [ProviderQuota] {
        var result: [ProviderQuota] = []
        if let claude = plans.first(where: \.hasQuota) {
            result.append(ProviderQuota(
                provider: "Claude Code",
                planType: nil,
                windows: [claude.fiveHour, claude.sevenDay].compactMap { $0 },
                observedAt: claude.observedAt
            ))
        }
        if let codex = codexLimits {
            result.append(ProviderQuota(
                provider: "Codex",
                planType: codex.planType,
                windows: [codex.primary.asPlanWindow]
                    + (codex.secondary.map { [$0.asPlanWindow] } ?? []),
                observedAt: nil
            ))
        }
        return result.sorted {
            ($0.tightest?.usedPercent ?? 0) > ($1.tightest?.usedPercent ?? 0)
        }
    }

    /// The single window nearest exhaustion, and who reported it.
    ///
    /// What the headline and the popover both lead with. Named by provider
    /// because "13% of your weekly window" means nothing if the reader assumes
    /// the wrong agent.
    var tightestQuota: (provider: String, window: PlanMetrics.Window)? {
        let candidates = quotas.compactMap { quota in
            quota.tightest.map { (provider: quota.provider, window: $0) }
        }
        return candidates.max { $0.window.usedPercent < $1.window.usedPercent }
    }

    /// The freshest Claude Code plan reading, for the staleness line that only
    /// its status line can date.
    var plan: PlanMetrics? { plans.first { $0.hasQuota } }

    /// The context fill of the most recently active session.
    var context: PlanMetrics? { plans.first { $0.contextPercent != nil } }

    /// Today's spend, formatted the way a glanceable row needs it.
    var todayLabel: String? {
        guard let todayCost else { return nil }
        return Self.money(todayCost)
    }

    /// Formatted as US dollars, explicitly.
    ///
    /// `US$` rather than a bare `$` in the places that carry the headline figure:
    /// the app is used outside the United States, and a bare dollar sign beside a
    /// four-figure number reads as local currency to anyone whose console shows
    /// one.
    static func money(_ amount: Double, prefix: String = "$") -> String {
        if amount >= 100 { return String(format: "%@%.0f", prefix, amount) }
        if amount >= 1 { return String(format: "%@%.2f", prefix, amount) }
        if amount > 0 { return String(format: "%@%.3f", prefix, amount) }
        return "\(prefix)0"
    }

    static func compactTokens(_ count: Int) -> String {
        switch count {
        case 1_000_000_000...: return String(format: "%.1fB", Double(count) / 1e9)
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1e6)
        case 1_000...: return String(format: "%.0fK", Double(count) / 1e3)
        default: return "\(count)"
        }
    }
}

/// Owns the ledger and the file cursors, off the main actor.
///
/// An actor rather than a queue because the ledger and the reader are value
/// types that must not be touched from two passes at once, and this is the whole
/// of their concurrency story.
actor UsageScannerActor {

    struct Result: Sendable {
        var todayUsage = TokenUsage()
        var todayCost: Double = 0
        var totalCost: Double = 0
        var codexLimits: RateLimitSnapshot?
        var codexTokens = TokenUsage()
        var plans: [PlanMetrics] = []
        var contextEstimate: ContextEstimate?
        var days: [(day: Date, usage: TokenUsage, cost: Double)] = []
        var models: [(model: String, usage: TokenUsage, cost: Double)] = []
        var unpricedModels: [String] = []
    }

    private var ledger = UsageLedger()
    private var claudeReader = TranscriptReader()
    private var codexReader = TranscriptReader()
    /// The newest turn seen in each Claude Code transcript, for the context
    /// gauge. Kept per file and replaced rather than accumulated: each turn
    /// restates the whole prompt, so the last one is the reading and summing
    /// them would report a long session as an impossibly large context.
    private var claudeContext: [URL: ContextEstimate] = [:]
    private var latestCodexLimits: RateLimitSnapshot?
    private var latestCodexLimitAt: Date?
    /// Keyed by session file: each `token_count` event carries the session's
    /// running total, so the newest reading replaces the previous one. Summing
    /// them instead would multiply a long session by the number of turns in it.
    private var codexTotals: [URL: TokenUsage] = [:]

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let paths = RuntimePaths()

    /// Reads what the status line hook left for each live session.
    ///
    /// Whole-directory each pass rather than incrementally: these are gauges the
    /// agent overwrites, so there is no "new bytes since last time" — the file
    /// either has a fresher reading or it does not.
    private func readPlanMetrics() -> [PlanMetrics] {
        let directory = paths.run.appendingPathComponent("metrics", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> PlanMetrics? in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name))
                else { return nil }
                return PlanMetricsFile.decode(data)
            }
            .sorted { $0.observedAt > $1.observedAt }
    }

    func scan() -> Result {
        claudeReader.readNewLines(under: home.appending(path: ".claude/projects")) { line, url in
            guard let record = ClaudeUsageParser.record(from: line) else { return }
            ledger.add(record)

            // Synthetic messages carry no prompt of their own, so letting one be
            // the newest turn would report a context that briefly collapsed.
            guard !ModelPricing.isSynthetic(record.model), record.usage.promptTokens > 0,
                  claudeContext[url].map({ record.timestamp > $0.observedAt }) ?? true
            else { return }
            claudeContext[url] = ContextEstimate(
                tokens: record.usage.promptTokens,
                model: record.model,
                observedAt: record.timestamp
            )
        }

        // Only the quota reading is taken from Codex. Its token totals are a
        // running per-session figure rather than per-message deltas, and its
        // models have no rate in the table, so folding them into a dollar total
        // would mean inventing both a delta and a price.
        codexReader.readNewLines(under: home.appending(path: ".codex/sessions")) { line, url in
            guard let reading = CodexUsageParser.reading(from: line) else { return }
            codexTotals[url] = reading.usage
            guard let limits = reading.limits,
                  latestCodexLimitAt.map({ reading.timestamp > $0 }) ?? true else { return }
            latestCodexLimits = limits
            latestCodexLimitAt = reading.timestamp
        }

        let today = Date()
        return Result(
            todayUsage: ledger.usage(on: today),
            todayCost: ledger.cost(on: today),
            totalCost: ledger.totalCost,
            codexLimits: latestCodexLimits,
            codexTokens: codexTotals.values.reduce(TokenUsage(), +),
            plans: readPlanMetrics(),
            contextEstimate: claudeContext.values.max { $0.observedAt < $1.observedAt },
            days: ledger.days(limit: 30),
            models: ledger.byModel(),
            unpricedModels: ledger.unpricedModels.sorted()
        )
    }
}
