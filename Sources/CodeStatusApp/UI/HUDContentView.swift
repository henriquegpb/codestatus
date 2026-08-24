import CodeStatusCore
import SwiftUI

/// What the menu bar popover draws: the session list, and the controls under it.
///
/// The popover supplies its own surface and sizes itself to whatever this view
/// reports, so the content hugs rather than fills and must not draw a background
/// of its own — a card inside a card reads as a layout bug, which is exactly how
/// it looked.
struct HUDContentView: View {
    @Bindable var model: HUDModel

    var onOpen: ((AgentSession) -> Void)?
    var onDismiss: ((AgentSession) -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    /// Beyond this the list scrolls instead of growing. Twelve sessions is
    /// already an unusual day; a window that keeps growing past it would run off
    /// the screen with no way to reach the bottom rows.
    private static let maximumVisibleRows = 12

    var body: some View {
        VStack(spacing: 0) {
            // Only scroll once there is something to scroll. A ScrollView has no
            // intrinsic height, so wrapping unconditionally would force the
            // popover to a fixed size and reintroduce the empty space below a
            // short list that this whole shape exists to avoid.
            if model.sessions.count > Self.maximumVisibleRows {
                ScrollView { list }.frame(height: 560)
            } else {
                list
            }

            // Full-bleed, unlike the inset dividers between rows: it separates
            // two zones rather than two items of the same kind.
            Divider().opacity(0.5)

            FooterBar(
                onRefresh: onRefresh,
                onOpenSettings: onOpenSettings,
                onQuit: onQuit
            )
        }
    }

    private var list: some View {
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
        // Text pinned to the edge of a popover reads as clipped, and the popover
        // supplies no inset of its own.
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
}

// MARK: - Footer

/// Refresh, Settings, and Quit, under the list.
///
/// The same three actions live in the status item's right-click menu, which
/// almost nobody discovers — a menu bar app that can only be quit by a gesture
/// you have to already know about is one the user cannot get rid of. Quit sits
/// apart from the other two because it is the one click here that cannot be
/// taken back.
private struct FooterBar: View {
    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            FooterButton(
                title: "Refresh",
                systemImage: "arrow.clockwise",
                acknowledgesTap: true
            ) { onRefresh?() }
                .help("Re-scan for agent sessions.")

            FooterButton(title: "Settings", systemImage: "gearshape") { onOpenSettings?() }

            Spacer(minLength: 8)

            FooterButton(title: "Quit", systemImage: "power") { onQuit?() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct FooterButton: View {
    let title: String
    let systemImage: String
    /// Swaps the icon for a spinner for a beat after a tap. The action behind
    /// it usually changes nothing visible, and a button that looks inert is one
    /// the user presses again and again.
    var acknowledgesTap = false
    var action: () -> Void

    /// Long enough to register as a response, short enough that it never reads
    /// as work still in progress — the sweep is already finished by the time it
    /// clears.
    private static let acknowledgementDuration = Duration.milliseconds(250)

    /// Both the glyph and the spinner are laid out in a box this wide, so the
    /// swap cannot shift the label beside it.
    private static let iconSide: CGFloat = 11

    @State private var isHovering = false
    @State private var isAcknowledging = false

    var body: some View {
        Button {
            acknowledgeTap()
            action()
        } label: {
            HStack(spacing: 5) {
                icon
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            // A capsule rather than a rounded rectangle: the radius tracks the
            // height, so the ends stay fully round whatever the text metrics do.
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(.primary.opacity(isHovering ? 0.09 : 0))
            }
            // Without this the gaps between icon and label are not clickable,
            // and the hover highlight flickers as the cursor crosses them.
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? .primary : .secondary)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        if isAcknowledging {
            ProgressView()
                .controlSize(.mini)
                // Deliberately drawn larger than the box it reserves: a spinner
                // matched to a 10pt glyph is too fine to read at a glance. The
                // frame keeps the layout identical to the glyph's, and there is
                // padding either side for the overflow to spill into.
                .scaleEffect(0.9)
                .frame(width: Self.iconSide, height: Self.iconSide)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .frame(width: Self.iconSide, height: Self.iconSide)
        }
    }

    private func acknowledgeTap() {
        // A second click while the spinner is up refreshes again but does not
        // restart it; two overlapping timers would leave it up for whichever
        // finished last.
        guard acknowledgesTap, !isAcknowledging else { return }
        isAcknowledging = true
        Task {
            try? await Task.sleep(for: Self.acknowledgementDuration)
            isAcknowledging = false
        }
    }
}

// MARK: - Rows

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
                    // Shown for free sessions too: how long one has been idle is
                    // how you spot the session you finished with an hour ago and
                    // forgot to close. The states without a duration are the ones
                    // where the clock would be meaningless — we do not know when
                    // a discovering or reconnecting session entered that state.
                    if session.state == .free
                        || session.state == .busy
                        || session.state.needsAttention {
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
