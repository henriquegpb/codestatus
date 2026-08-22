import CodeStatusCore
import SwiftUI

/// What the HUD draws, in both shapes.
struct HUDContentView: View {
    @Bindable var model: HUDModel
    @Environment(\.hudPresentation) private var presentation

    var onOpen: ((AgentSession) -> Void)?
    var onDismiss: ((AgentSession) -> Void)?

    var body: some View {
        Group {
            switch presentation {
            case .compact: CompactCounters(model: model)
            case .expanded: ExpandedSessionList(model: model, onOpen: onOpen, onDismiss: onDismiss)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The at-a-glance state: one dot and number per non-empty bucket.
///
/// Empty buckets are omitted rather than shown as zero — on a notched display
/// the whole thing has to fit inside the camera housing, so every group has to
/// earn its width.
private struct CompactCounters: View {
    @Bindable var model: HUDModel

    private var groups: [(bucket: StateBucket, count: Int)] {
        [(.free, model.free), (.busy, model.busy),
         (.needsYou, model.needsYou), (.indeterminate, model.indeterminate)]
            .filter { $0.1 > 0 }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(groups, id: \.bucket) { group in
                HStack(spacing: 4) {
                    Circle()
                        .fill(group.bucket.tint)
                        .frame(width: 6, height: 6)
                    Text("\(group.count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(group.count) \(group.bucket.label)")
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(.black.opacity(0.55)))
    }
}

/// The full list, shown on hover or click.
private struct ExpandedSessionList: View {
    @Bindable var model: HUDModel
    var onOpen: ((AgentSession) -> Void)?
    var onDismiss: ((AgentSession) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.sessions) { session in
                SessionRow(session: session, now: model.now, onOpen: onOpen, onDismiss: onDismiss)
                if session.id != model.sessions.last?.id {
                    Divider().opacity(0.15)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let now: Date
    var onOpen: ((AgentSession) -> Void)?
    var onDismiss: ((AgentSession) -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.state.tint)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(session.provider.displayName)
                    Text("·")
                    Text(session.state.label)
                    // Duration is only meaningful while something is happening;
                    // showing "Free · 3h" invites the reading that something is
                    // stuck when the session is simply idle and available.
                    if session.state == .busy || session.state.needsAttention {
                        Text("·")
                        Text(DurationFormatter.short(session.duration(at: now)))
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isHovering {
                actions
            } else if session.hostApplication != .unknown {
                Text(session.hostApplication.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(session.displayName), \(session.provider.displayName), \(session.state.label)"
        )
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if session.capabilities.contains(.canOpen) {
                Button("Open") { onOpen?(session) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
            }

            // Present but disabled until a session is one CodeStatus launched
            // and controls through a PTY. Showing it greyed out with a reason is
            // more honest than hiding a capability that exists for other
            // sessions — see the capability matrix in the README.
            if !session.capabilities.contains(.canSendPrompt) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                    .help("CodeStatus can only send prompts to sessions it started itself.")
            }

            Button {
                onDismiss?(session)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Stop watching this session")
        }
    }
}
