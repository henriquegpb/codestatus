import CodeStatusCore
import SwiftUI

/// The usage summary in the popover: one line per agent.
///
/// One line each rather than a single combined figure, because the two agents
/// can report different things and a single line has to pick one. Codex reports
/// a quota and no price; Claude Code, outside the terminal, reports a price and
/// no quota. Collapsing that into one row meant the row showed whichever the
/// code happened to look at first, and a bare dollar figure answered a question
/// nobody had asked.
///
/// Each line leads with whatever its agent can actually report: quota where
/// there is one, since *how much can I still spend* is the real question and it
/// is a number the agent was told rather than one we computed, and the estimate
/// only where there is not.
struct UsageRow: View {
    @Bindable var usage: UsageCoordinator
    var onOpenDetail: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(usage.quotas) { quota in
                if let window = quota.tightest {
                    line(label: quota.provider) {
                        QuotaPip(window: window)
                    }
                }
            }
            // Claude Code's own line, when it reported no quota to take one of
            // the rows above. Its cost is the only thing it can offer then, and
            // it is labelled as an estimate wherever it appears.
            if !usage.quotas.contains(where: { $0.provider == "Claude Code" }) {
                line(label: "Claude Code") {
                    if let today = usage.todayLabel {
                        Text(today).font(.system(size: 11, weight: .semibold))
                        Text("today, est.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text("Reading usage…")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// One agent's row, drawn identically whatever figure it carries.
    private func line<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: onOpenDetail) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)

                content()

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText(for: label))
    }

    private func helpText(for provider: String) -> String {
        guard let quota = usage.quotas.first(where: { $0.provider == provider }),
              let window = quota.tightest
        else {
            return "\(provider) reported no plan quota. Click for the token and "
                + "cost breakdown."
        }
        var text = "\(window.displayPercent)% of your \(provider) \(window.label) window used"
        if let resets = window.resetsAt {
            text += ", resets \(resets.formatted(date: .omitted, time: .shortened))"
        }
        return text + ". Click for the full breakdown."
    }
}

/// How much of one quota window is spent.
struct QuotaPip: View {
    let window: PlanMetrics.Window

    private var tint: Color {
        switch window.usedPercent {
        case ..<70: return .secondary
        case ..<90: return .orange
        default: return Color(red: 1.0, green: 0.42, blue: 0.38)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(width: 34, height: 4)
                Capsule().fill(tint)
                    .frame(width: max(2, 34 * min(1, window.usedPercent / 100)), height: 4)
            }
            Text("\(window.displayPercent)%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(window.label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}
