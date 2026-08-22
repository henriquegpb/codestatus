import CodeStatusCore
import SwiftUI

/// What the HUD draws, in both shapes.
///
/// The same view serves two very different containers, which is why the two
/// flags exist. The floating panel is a transparent, borderless window sized by
/// `NotchGeometry`: it has no surface of its own and its content must fill it.
/// The popover already draws a surface and sizes itself to what it is given, so
/// there the content has to hug and must not draw a second background — a card
/// inside a card reads as a layout bug, which is exactly how it looked.
struct HUDContentView: View {
    @Bindable var model: HUDModel
    @Environment(\.hudPresentation) private var presentation

    var drawsBackground: Bool = true
    var fillsAvailableSpace: Bool = true

    var onOpen: ((AgentSession) -> Void)?
    var onDismiss: ((AgentSession) -> Void)?

    var body: some View {
        Group {
            switch presentation {
            case .compact:
                CompactCounters(model: model)
            case .expanded:
                ExpandedSessionList(
                    model: model,
                    drawsBackground: drawsBackground,
                    onOpen: onOpen,
                    onDismiss: onDismiss
                )
            }
        }
        .frame(
            maxWidth: fillsAvailableSpace ? .infinity : nil,
            maxHeight: fillsAvailableSpace ? .infinity : nil
        )
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
    var drawsBackground: Bool = true
    var onOpen: ((AgentSession) -> Void)?
    var onDismiss: ((AgentSession) -> Void)?

    /// Beyond this the list scrolls instead of growing. Twelve sessions is
    /// already an unusual day; a window that keeps growing past it would run off
    /// the screen with no way to reach the bottom rows.
    private static let maximumVisibleRows = 12

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.sessions.isEmpty {
                Text(model.unreportedCount > 0 ? "No sessions reporting yet." : "No agent sessions.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(model.sessions) { session in
                SessionRow(session: session, now: model.now, onOpen: onOpen, onDismiss: onDismiss)
                if session.id != model.sessions.last?.id {
                    Divider().opacity(0.15)
                }
            }
            if model.unreportedCount > 0 {
                unreportedFootnote
            }
        }
    }

    /// Running agents that have never sent us an event.
    ///
    /// A count rather than rows: they are real, so hiding them entirely would be
    /// its own dishonesty, but each is a session whose state we would have to
    /// invent. Almost always this means hooks were installed after the session
    /// started — both agents read their hook configuration once, at session
    /// start — so the fix is to start a new one, and saying so is more useful
    /// than a row that says Unknown forever.
    private var unreportedFootnote: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.sessions.isEmpty { Divider().opacity(0.15).padding(.bottom, 6) }
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(
                    model.unreportedCount == 1
                        ? "1 other session isn’t reporting yet"
                        : "\(model.unreportedCount) other sessions aren’t reporting yet"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .help("They started before hooks were installed. Agents read their hook configuration at session start, so a new session will report normally.")
            .padding(.vertical, 3)
        }
    }

    var body: some View {
        Group {
            // Only scroll once there is something to scroll. A ScrollView has no
            // intrinsic height, so wrapping unconditionally would force the
            // popover to a fixed size and reintroduce the empty space below a
            // short list that this whole shape exists to avoid.
            if model.sessions.count > Self.maximumVisibleRows {
                ScrollView { rows }.frame(height: 560)
            } else {
                rows
            }
        }
        // Horizontal inset is the same either way: text pinned to the edge of a
        // popover reads as clipped, and the popover supplies no inset of its own.
        // Only the vertical differs, because the floating panel draws the card
        // the content sits in while the popover already has one.
        .padding(.horizontal, 14)
        .padding(.vertical, drawsBackground ? 12 : 8)
        .background {
            if drawsBackground {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial)
            }
        }
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
