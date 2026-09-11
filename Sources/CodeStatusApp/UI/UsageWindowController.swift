import AppKit
import CodeStatusCore
import SwiftUI

/// The usage breakdown: what was spent, on which days, on which models.
///
/// A window rather than more popover, because this is something you sit down and
/// read rather than glance at — and because the popover closes the moment focus
/// moves, which makes it useless for anything you want to study.
struct UsageDetailView: View {
    @Bindable var usage: UsageCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                // One column per agent, never interleaved. The two report
                // fundamentally different things: Claude Code gives token counts
                // that can be priced, Codex gives a quota and models with no rate
                // here. An earlier layout stacked them, which buried whichever
                // agent came second under the other's whole breakdown, and put a
                // Codex quota bar between two Claude dollar figures where it read
                // as one mixed total. Side by side, neither is the footnote.
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 24) {
                        claudeColumn.frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        codexColumn.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    caveat
                }
                .padding(16)
            }
        }
        .frame(width: 700, height: 540)
    }

    /// Everything Claude Code reports, in one column.
    private var claudeColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            claudeQuota
            spendGroup
        }
    }

    /// Everything Codex reports, in the other.
    private var codexColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            codexQuota
            codexTokensSection
        }
    }

    /// The dollar figures, fenced off from the quota above them.
    ///
    /// A rule and a heading rather than more spacing, because the two halves of
    /// this column are different kinds of number and the confusion between them
    /// is the expensive one: the quota is what the plan has left, and everything
    /// below is the raw worth of tokens at list rates, which nobody is charged.
    /// Adjacent and unlabelled, the second reads as the price of the first.
    private var spendGroup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            GroupHeading("Raw usage rates (not billed)", note: Self.listRateNote)
            daysSection
            modelsSection
        }
    }

    /// One headline per agent, over the column that agent owns.
    ///
    /// Split rather than combined because a single headline had to choose, and
    /// whichever it chose was silently about one agent while sitting above both.
    /// Each side leads with a quota where its agent reports one, since that is a
    /// real number the API told it, and falls back to the list-rate figure only
    /// where there is no quota to show.
    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            claudeHeadline.frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            codexHeadline.frame(maxWidth: .infinity, alignment: .leading)
        }
        // A `Divider` in an HStack grows to fill whatever height it is offered,
        // and without this it took the window's, leaving the headlines stranded
        // in a screen of empty space. Pinned to its own content instead.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var claudeHeadline: some View {
        VStack(alignment: .leading, spacing: 3) {
            HeadlineLabel("Claude Code", note: Self.claudeNote)
            if let window = usage.quotas.first(where: { $0.provider == "Claude Code" })?.tightest {
                Text("\(window.displayPercent)%")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                HStack(spacing: 5) {
                    Text("of your \(window.label) window")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    InfoTip("How much of the plan's rolling window this account "
                        + "has spent, as the agent was told by the API. Not an "
                        + "estimate, and not derived from any cost here.")
                }
                if let plan = usage.plan {
                    Text(freshness(plan))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            } else {
                Text(usage.todayLabel ?? "—")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                HStack(spacing: 5) {
                    Text("today, list rates")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    InfoTip(Self.listRateNote)
                }
                Text("No plan quota reported.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            // Kept whichever figure led above, because the two answer different
            // questions and dropping one to make room loses the answer.
            HStack(spacing: 5) {
                Text("\(UsageCoordinator.money(usage.totalCost)) all time, list rates")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                InfoTip(Self.listRateNote)
            }
            .padding(.top, 1)
        }
    }

    private var codexHeadline: some View {
        VStack(alignment: .leading, spacing: 3) {
            HeadlineLabel(
                usage.quotas.first { $0.provider == "Codex" }?.title ?? "Codex",
                note: Self.codexNote
            )
            if let window = usage.quotas.first(where: { $0.provider == "Codex" })?.tightest {
                Text("\(window.displayPercent)%")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                HStack(spacing: 5) {
                    Text("of your \(window.label) window")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    InfoTip("How much of the plan's rolling quota Codex reports "
                        + "as spent. Reported from every session, whatever it is "
                        + "running in.")
                }
            } else {
                Text("—")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                Text("No quota reported.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // No dollar figure to balance the other column with, and inventing
            // one would mean inventing a rate. The token count is what Codex
            // actually gives.
            if !usage.codexTokens.isEmpty {
                Text("\(UsageCoordinator.compactTokens(usage.codexTokens.total)) tokens seen, not priced")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
        }
    }

    /// What each column's agent reports, and how.
    private static let claudeNote =
        "Token counts read from transcripts on this Mac and priced at published "
        + "list API rates. Its plan quota arrives only on the status line, which "
        + "terminal sessions draw and IDE and SDK sessions do not."

    private static let codexNote =
        "Reports its plan quota from every session, in its own rollout files. "
        + "Tokens are counted but never priced: its model rates are not published "
        + "here, and nothing in the Claude Code column includes them."

    /// What every dollar figure on this screen is, and what it is not.
    ///
    /// Shared by each of them deliberately. The number is the raw worth of the
    /// tokens at list rates, which is a different quantity from what the account
    /// is charged: a plan covers usage up to its quota and bills nothing extra
    /// for it, and overage beyond that draws on usage credits in the account's
    /// own currency. Neither is observable from a transcript, so this figure
    /// cannot be either, and saying only "est." invited it to be read as a
    /// rounded version of the bill rather than a different measurement.
    private static let listRateNote =
        "Raw list-rate worth of the tokens, in US dollars. This is not what you "
        + "were billed and not your extra usage spend: a plan covers usage inside "
        + "its quota, and overage draws on usage credits in your own currency. "
        + "Neither figure appears in a transcript, so neither is shown here. Use "
        + "this to compare days and models against each other."

    /// Says how old the reading is rather than implying it is live.
    ///
    /// The status line only fires while a session is open and rendering, so this
    /// is a last-known value. Pretending otherwise would be the same dishonesty
    /// the app refuses elsewhere.
    private func freshness(_ plan: PlanMetrics) -> String {
        let age = plan.age(at: Date())
        let when = age < 90 ? "just now" : "\(DurationFormatter.short(age)) ago"
        var text = "read \(when)"
        if let resets = plan.tightest?.resetsAt {
            text += " · resets \(resets.formatted(date: .omitted, time: .shortened))"
        }
        return text
    }

    /// Claude Code's quota, or why there is none.
    @ViewBuilder
    private var claudeQuota: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(
                "Plan windows",
                note: "How much of the rolling quota is spent, as the agent itself "
                    + "was told by the API. Not an estimate, and unrelated to the "
                    + "cost below."
            )
            if let quota = usage.quotas.first(where: { $0.provider == "Claude Code" }) {
                ForEach(quota.windows, id: \.label) { window in
                    QuotaBar(label: window.label, window: window)
                }
                if let plan = usage.plan {
                    Text(freshness(plan))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            } else {
                // Named rather than left to silence: a reader who sees a Codex bar
                // and no Claude Code one will otherwise read it as a setup they
                // got wrong.
                HStack(spacing: 5) {
                    Text("Terminal sessions only.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    InfoTip("Claude Code sends plan quota only to its status "
                        + "line, and only the terminal draws one. The VS Code and "
                        + "JetBrains extensions, the SDK, and claude -p never do, "
                        + "so no quota reaches CodeStatus from those sessions "
                        + "however it is installed.")
                    Spacer()
                }
            }
            contextRow
        }
    }

    /// Codex's quota, in the same shape, so the two columns read as one design.
    @ViewBuilder
    private var codexQuota: some View {
        if let quota = usage.quotas.first(where: { $0.provider == "Codex" }) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(
                    "Plan windows",
                    note: "How much of the rolling quota is spent, as Codex reports "
                        + "it in its rollout files. Reported from every session, "
                        + "whatever it is running in."
                )
                ForEach(quota.windows, id: \.label) { window in
                    QuotaBar(label: window.label, window: window)
                }
            }
        }
    }

    /// The agent's own context reading when it gave one, and a count worked out
    /// from the transcript when it did not.
    ///
    /// Never both, and never blended: the reported figure is a percentage of a
    /// window the agent knows, and the derived one is a token count whose window
    /// is unknowable from disk — see ``ContextEstimate``. Showing them in the same
    /// shape would hide which of the two the reader is looking at.
    @ViewBuilder
    private var contextRow: some View {
        if let context = usage.context, let percent = context.contextPercent {
            HStack(spacing: 10) {
                Text("context")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: 8)
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(2, geometry.size.width * min(1, percent / 100)), height: 8)
                    }
                    .frame(height: geometry.size.height, alignment: .center)
                }
                .frame(height: 12)
                Text("\(Int(percent))%")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
            }
        } else if let estimate = usage.contextEstimate {
            HStack(spacing: 10) {
                Text("context")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                Text("\(UsageCoordinator.compactTokens(estimate.tokens)) tokens")
                    .font(.system(size: 11, design: .monospaced))
                InfoTip(estimate.exceedsStandardWindow
                    ? "Tokens in the newest turn's prompt, counted from its "
                        + "transcript because this session never reported one "
                        + "itself. Over 200K, so it was opened with the long "
                        + "context window."
                    : "Tokens in the newest turn's prompt, counted from its "
                        + "transcript because this session never reported one "
                        + "itself. A count rather than a percentage: transcripts "
                        + "do not record whether a session opened with the 200K "
                        + "window or the 1M one, and dividing by a guess would be "
                        + "wrong by five times.")
                Spacer()
            }
        }
    }

    // MARK: - Codex

    @ViewBuilder
    private var codexTokensSection: some View {
        if !usage.codexTokens.isEmpty || usage.codexLimits?.creditBalance != nil {
            VStack(alignment: .leading, spacing: 14) {
                // The same rule as the other column, in the same place, so the
                // two read as one layout rather than two.
                Divider()
                GroupHeading(
                    "Counted, never priced",
                    note: "Codex model rates are not published here. Inventing "
                        + "one to fill the column beside the Claude Code figures "
                        + "would be worse than the gap."
                )
                SectionTitle("Tokens")
                if !usage.codexTokens.isEmpty {
                    HStack(spacing: 6) {
                        Text("Seen").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text(UsageCoordinator.compactTokens(usage.codexTokens.total))
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                if let balance = usage.codexLimits?.creditBalance, balance != "0" {
                    HStack(spacing: 6) {
                        Text("Credits").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text(balance).font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
    }

    private var daysSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(
                "By day",
                note: "Bars are relative to the busiest day shown. Dated by when "
                    + "each turn was recorded on this Mac, not by any billing "
                    + "period."
            )
            if usage.days.isEmpty {
                Text(usage.isScanning ? "Reading transcripts…" : "Nothing recorded yet.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // Bars are relative to the busiest day on screen, so the shape of a
            // month is readable without anyone doing arithmetic.
            let peak = usage.days.map(\.cost).max() ?? 1
            ForEach(usage.days.prefix(14), id: \.day) { entry in
                HStack(spacing: 10) {
                    Text(entry.day.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary).frame(height: 8)
                            Capsule().fill(Color.accentColor.opacity(0.75))
                                .frame(
                                    width: max(2, geometry.size.width * (peak > 0 ? entry.cost / peak : 0)),
                                    height: 8
                                )
                        }
                        .frame(height: geometry.size.height, alignment: .center)
                    }
                    .frame(height: 12)

                    Text(UsageCoordinator.money(entry.cost))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 62, alignment: .trailing)
                }
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(
                "By model",
                note: "Cache reads price at a fraction of fresh input, so the dollar "
                    + "column is not proportional to the token count beside it."
            )
            ForEach(usage.models.prefix(8), id: \.model) { entry in
                HStack(spacing: 10) {
                    Text(entry.model)
                        .font(.system(size: 11))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(UsageCoordinator.compactTokens(entry.usage.total))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(UsageCoordinator.money(entry.cost))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 62, alignment: .trailing)
                }
            }
            if !usage.unpricedModels.isEmpty {
                // Named rather than folded into the total, so a model we have no
                // rate for reads as a known gap instead of quietly understating
                // the figure above.
                Text("Not priced: \(usage.unpricedModels.joined(separator: ", ")). "
                    + "Counted, but excluded from the totals above.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The one caveat that stays on screen.
    ///
    /// Everything else on this window moved behind an ``InfoTip``, and this did
    /// not: mistaking the estimate for a bill is the error with a cost attached,
    /// and a warning nobody clicks is not a warning. The reasoning behind it
    /// still moves, so the line itself can be short.
    private var caveat: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 5) {
                Text("**Raw list rates, not your invoice.**")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                InfoTip("Token counts recorded on this Mac, priced at published "
                    + "list API rates in US dollars. Subscriptions, overage, and "
                    + "negotiated rates all differ, and a billing console covers "
                    + "its own date range, so the two will not agree. What it is "
                    + "good for is comparison: which day cost several times the "
                    + "others, and which model the spend is in. Nothing is "
                    + "uploaded, and only token counts are read from transcripts.")
                Spacer()
            }
            .padding(.top, 4)
        }
    }
}

/// Names which agent a headline belongs to.
///
/// Small and quiet on purpose: it is a caption telling you which column you are
/// reading, not a title competing with the figure under it.
private struct HeadlineLabel: View {
    let text: String
    let note: String

    init(_ text: String, note: String) {
        self.text = text
        self.note = note
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(text.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            InfoTip(note)
        }
    }
}

/// Says what kind of number everything under it is.
///
/// Above ``SectionTitle`` in weight, because what it separates is not another
/// list but another unit: a quota in percent from a worth in dollars, or priced
/// figures from counted ones. Sections say what a list contains; this says what
/// reading it wrongly would cost.
private struct GroupHeading: View {
    let title: String
    let note: String

    init(_ title: String, note: String) {
        self.title = title
        self.note = note
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            InfoTip(note)
            Spacer(minLength: 0)
        }
    }
}

/// What a figure on this screen actually measures, one click away.
///
/// Every caveat here used to be printed under the number it qualified, which
/// meant the screen read as an argument rather than a report, and the numbers
/// themselves competed with the prose explaining them. The caveats still matter —
/// an estimate mistaken for an invoice is the failure this app most wants to
/// avoid — so they are kept in full and moved behind a target, rather than
/// shortened into something that no longer says the true thing.
private struct InfoTip: View {
    let text: String
    @State private var isPresented = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("What this means")
        // Also on hover, so the keyboard-free path to it is not a click that
        // opens something the reader then has to dismiss.
        .help(text)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}

private struct SectionTitle: View {
    let title: String
    var note: String?

    init(_ title: String, note: String? = nil) {
        self.title = title
        self.note = note
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if let note { InfoTip(note) }
        }
    }
}

private struct QuotaBar: View {
    let label: String
    let window: PlanMetrics.Window

    private var tint: Color {
        switch window.usedPercent {
        case ..<70: return .accentColor
        case ..<90: return .orange
        default: return Color(red: 1.0, green: 0.42, blue: 0.38)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 8)
                    Capsule().fill(tint)
                        .frame(
                            width: max(2, geometry.size.width * min(1, window.usedPercent / 100)),
                            height: 8
                        )
                }
                .frame(height: geometry.size.height, alignment: .center)
            }
            .frame(height: 12)
            Text("\(window.displayPercent)%")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
            if let resetsAt = window.resetsAt {
                Text(resetsAt, format: .dateTime.hour().minute())
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }
}

@MainActor
final class UsageWindowController {
    private var window: NSWindow?
    private let usage: UsageCoordinator

    init(usage: UsageCoordinator) {
        self.usage = usage
    }

    func show() {
        // Refreshed on the way in: the popover's figure may be a couple of
        // minutes old, and this is the surface someone opens *because* they
        // want the current number.
        usage.refresh()

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "CodeStatus Usage"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentViewController = NSHostingController(
                rootView: UsageDetailView(usage: usage)
            )
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
