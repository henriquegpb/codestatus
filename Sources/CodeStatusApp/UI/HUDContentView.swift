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
    var updates: UpdateCoordinator?
    var usage: UsageCoordinator?

    var onOpen: ((AgentSession) -> Void)?
    var onDismiss: ((AgentSession) -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenUsage: (() -> Void)?
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

            if let updates, let banner = UpdateBanner.text(for: updates.state) {
                Divider().opacity(0.5)
                UpdateBanner(text: banner, canInstallNow: updates.state.isWaitingForQuiet) {
                    updates.installNow()
                }
            }

            // Sits directly above the footer rather than among the sessions:
            // it describes the machine's spend, not any one session.
            if let usage, usage.isEnabled {
                Divider().opacity(0.5)
                UsageRow(usage: usage) { onOpenUsage?() }
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
        // Here rather than at the call site so it can follow the model: a title
        // can arrive mid-session, and the popover is often already open when it
        // does.
        .frame(width: model.preferredWidth)
        .animation(.easeInOut(duration: 0.18), value: model.preferredWidth)
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
            // Before the trust callout, because it is the more fundamental
            // problem: there is nothing in the file to trust.
            if !model.unreportedDiagnosis.notConnected.isEmpty {
                NotConnectedCallout(providers: model.unreportedDiagnosis.notConnected)
                    .padding(.top, model.sessions.isEmpty ? 0 : 8)
            }
            if model.showsCodexTrustCallout {
                CodexTrustCallout(
                    count: model.unreportedDiagnosis.codexAwaitingTrust,
                    onDismiss: { model.dismissCodexTrustCallout() }
                )
                .padding(.top, model.sessions.isEmpty ? 0 : 8)
            }
            // Silent sessions with no specific advice attached are deliberately
            // not surfaced. In practice they are editor panels left open: the
            // process lives as long as the window, whether or not a conversation
            // is happening in it, so the count reported open tabs rather than
            // anything wrong, and reading "aren't reporting yet" sent people
            // looking for a fault that was not there. They are still tracked, and
            // still adopt a real state the moment a hook arrives.
            //
            // Causes that *do* have advice keep their callouts above.
        }
        // Text pinned to the edge of a popover reads as clipped, and the popover
        // supplies no inset of its own.
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Never connected

/// Says that an agent is running that CodeStatus was never set up to watch.
///
/// The most explainable silence there is, and for a long time the least
/// explained: detection used a short list of binary directories, so an agent
/// installed anywhere else was never offered during setup, never connected, and
/// then ran in front of the user reporting nothing at all. The app looked
/// broken, the agent looked fine, and the popover said nothing that would have
/// pointed at the difference.
private struct NotConnectedCallout: View {
    let providers: [AgentProvider: Int]

    private var names: String {
        providers.keys
            .map(\.displayName)
            .sorted()
            .formatted(.list(type: .and))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(names) is running but not connected")
                    .font(.system(size: 12, weight: .semibold))
                Text("CodeStatus has no hooks installed for it. Open Settings › Agents › Open Setup.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.orange.opacity(0.12))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Codex trust

/// Says that Codex is running and silent, and what to do about it.
///
/// Loud on purpose. This is the one failure the app cannot recover from on its
/// own and cannot even detect without being told: Codex refuses to run hooks it
/// has not been trusted with, and it refuses *silently*, so the symptom is an
/// app that appears to do nothing. A grey footnote is what this used to be, and
/// it read as "nothing is happening" rather than "something is wrong".
private struct CodexTrustCallout: View {
    let count: Int
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    count == 1
                        ? "A Codex session isn’t reporting"
                        : "\(count) Codex sessions aren’t reporting"
                )
                .font(.system(size: 12, weight: .semibold))

                // Concatenated rather than laid out in an HStack: stacked, each
                // fragment wrapped inside its own box, which broke the sentence
                // into a ragged column. Joined into one Text it flows and wraps
                // as the single sentence it is, and the monospaced run keeps its
                // own font through the concatenation.
                (
                    Text("Run ")
                        + Text("/hooks")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        + Text(" in Codex and trust the CodeStatus entries.")
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            // Dismissible because the instruction is not always one the reader
            // means to follow: plenty of people run Codex without wanting
            // CodeStatus to see it, and for them this is a permanent banner
            // reporting a decision they already made.
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .help("Hide this until another Codex session goes silent.")
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.orange.opacity(0.12))
        }
        .help(CodexHookInstaller.trustInstructions)
        .accessibilityElement(children: .combine)
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
                // The location leads and the agent's title rides beside it,
                // dimmed. Sharing the top line rather than taking the one below
                // is what keeps the meta line readable: the location added
                // there truncated both itself and the provider next to it.
                //
                // The layout priority is the whole trick — without it the two
                // shrink together and a long title takes the repository down
                // with it. The location is short and fixed, so it is given the
                // space it needs and the title truncates into what is left.
                HStack(spacing: 4) {
                    Text(session.primaryLabel)
                        .font(.system(size: 13, weight: .medium))
                        .layoutPriority(1)

                    if let title = session.secondaryLabel {
                        Text("·")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text(title)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
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
            [
                session.primaryLabel,
                session.secondaryLabel,
                session.provider.displayName,
                session.state.label,
            ].compactMap { $0 }.joined(separator: ", ")
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

            // No prompt affordance here yet. There was a greyed-out one, on the
            // reasoning that showing a disabled capability beats hiding one
            // other sessions have — but `canSendPrompt` is granted nowhere, so
            // it appeared on every row forever and read as broken rather than
            // honest. It belongs here again when a session can actually take a
            // prompt, and not before.
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
