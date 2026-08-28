import CodeStatusCore
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    var onFinish: () -> Void

    /// Purely a label swap on the copy button, so it lives in the view rather
    /// than in the model that decides what to install.
    @State private var copiedCommand = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(28)
            }
            Divider()
            footer.padding(16)
        }
        .frame(width: 580, height: 500)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.step.title).font(.system(size: 22, weight: .semibold))

            switch model.step {
            case .welcome: welcome
            case .privacy: privacy
            case .notifications: notifications
            case .detect: detect
            case .install: install
            case .verify: verify
            case .launchAtLogin: launchAtLogin
            case .done: done
            }
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start several coding agents, keep working, and come back only when one is actually done or actually needs you.")
                .font(.system(size: 13))
            counterPreview
            Text("CodeStatus watches Claude Code and Codex sessions and shows their state in the menu bar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var counterPreview: some View {
        HStack(spacing: 18) {
            ForEach([(StateBucket.free, 1), (.busy, 2), (.needsYou, 1)], id: \.0) { bucket, count in
                HStack(spacing: 5) {
                    Circle().fill(bucket.tint).frame(width: 7, height: 7)
                    Text("\(count) \(bucket.label)").font(.system(size: 12, weight: .medium))
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Capsule().fill(.quaternary.opacity(0.4)))
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 10) {
            bullet("No account, no server, no telemetry, no network code at all.")
            bullet("Your prompts and the agents' replies are never read. The hook that agents run skips past everything that is not metadata, so content cannot reach us even by accident.")
            bullet("What we do read: which session, which project, which state, and which app is hosting it.")
            bullet("Diagnostics exports are scrubbed of usernames and anything credential-shaped before you can copy them.")
        }
    }

    /// Reports what macOS currently thinks, and offers the only action that can
    /// still change it.
    ///
    /// Once the prompt has been refused, nothing this app calls brings it back —
    /// so a screen that keeps offering "Allow Notifications" is offering a
    /// button that does nothing, on the one screen someone reopened Setup to
    /// fix.
    private var notifications: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CodeStatus needs permission to tell you when an agent finishes or needs you.")
                .font(.system(size: 13))

            switch model.notificationStatus {
            case .authorized, .provisional, .ephemeral:
                statusLine("Allowed", tint: .green)
            case .denied:
                statusLine("Turned off for CodeStatus", tint: .orange)
                Text("macOS only ever asks once, so this has to be changed in System Settings.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Open System Settings") { model.openNotificationSettings() }
                    Button("Check again") {
                        Task { await model.refreshNotificationStatus() }
                    }
                }
            case .notDetermined:
                Button("Allow Notifications") {
                    Task { await model.requestNotifications() }
                }
                .controlSize(.large)
            default:
                ProgressView().controlSize(.small)
            }

            Text("The HUD and the menu bar work either way.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    /// Every supported agent, found or not, each one connectable.
    ///
    /// The unfound agent stays on the list and stays checked. Detection is
    /// evidence, not permission: an agent installed somewhere we did not think
    /// to look is still an agent the user has, and the only person who can
    /// settle that is the person reading this screen.
    private var detect: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Choose what CodeStatus should watch. Uncheck anything you do not use.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if model.isDetecting {
                    ProgressView().controlSize(.small)
                }
            }

            ForEach(model.agents) { agent in
                Toggle(isOn: Binding(
                    get: { agent.isSelected },
                    set: { model.setSelected($0, for: agent.provider) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(agent.provider.displayName)
                                .font(.system(size: 13, weight: .medium))
                            if agent.isVerified {
                                badge("verified", tint: .green)
                            } else if !agent.evidence.isPresent {
                                badge("not found", tint: .secondary)
                            }
                        }
                        Text(agent.evidence.summary)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if !agent.evidence.isPresent {
                            Text("Connect it anyway if you have it — we only look in the usual places, and installers do not always use them.")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.vertical, 3)
            }
        }
    }

    private var install: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.connectedAgents.isEmpty {
                Text("Nothing selected. Go back and pick at least one agent.")
                    .font(.system(size: 13))
            } else {
                Text("Here is exactly what will change. Nothing is written until you press Connect.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)

                ForEach(model.connectedAgents) { plan in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(plan.provider.displayName).font(.system(size: 13, weight: .medium))
                            Spacer()
                            if plan.alreadyInstalled {
                                statusLine("Already connected", tint: .green)
                            } else {
                                Text(plan.willCreateFile ? "creates file" : "edits file")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Text(plan.targetPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text("\(plan.eventCount) lifecycle events, all registered as non-blocking")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if let planError = plan.planError {
                            Text(planError).font(.system(size: 11)).foregroundStyle(.red)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
                }
            }

            if let error = model.installError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
        }
    }

    /// Waits for a real event rather than declaring victory on a successful
    /// write.
    ///
    /// Writing the file correctly and having the agent ignore it is the single
    /// most common way this app fails, and it is invisible from the install side:
    /// Codex will not run a `hooks.json` it has not been told to trust, and says
    /// nothing when it declines. So the last screen of setup is the one that
    /// waits to be proven right.
    private var verify: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open a session in each agent. This turns green the moment CodeStatus actually hears from it.")
                .font(.system(size: 12)).foregroundStyle(.secondary)

            ForEach(model.connectedAgents) { plan in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if plan.isVerified {
                            statusLine("Receiving events", tint: .green)
                        } else {
                            ProgressView().controlSize(.small)
                            Text("Waiting for the first event")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(plan.provider.displayName).font(.system(size: 13, weight: .medium))
                    }

                    if plan.needsManualTrust && !plan.isVerified {
                        codexTrustSteps
                    }
                    // The default is to connect every agent, found or not, so
                    // someone who does not have one will sit here watching a
                    // spinner that can never resolve. Say so rather than let
                    // them conclude the app is broken.
                    if !plan.evidence.isPresent && !plan.isVerified {
                        Text("We did not find \(plan.provider.displayName) on this Mac. If you do not use it, ignore this row — the hooks we wrote do nothing until it runs.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
            }

            Text("Already-open sessions will not report: both agents read their hook configuration once, when the session starts. Start a new one.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The one step of setup CodeStatus is not allowed to take for the user.
    ///
    /// Spelled out as numbered actions rather than a paragraph, because the
    /// paragraph is what people skip — and skipping it leaves Codex working
    /// perfectly while CodeStatus shows nothing, which reads as CodeStatus
    /// being broken.
    private var codexTrustSteps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Codex needs one thing from you")
                .font(.system(size: 12, weight: .medium))
            step(1, "Quit any Codex session that is open and start a new one.")
            step(2, "Type /hooks and press Return.")
            step(3, "Select each CodeStatus entry and trust it. Installed and Active should both read \(CodexHookInstaller.events.count).")

            HStack(spacing: 10) {
                Button(copiedCommand ? "Copied" : "Copy /hooks") { copyHooksCommand() }
                    .controlSize(.small)
                    .disabled(copiedCommand)
                // The single most useful thing when /hooks reports nothing is
                // seeing that the file exists at all — it separates "Codex has
                // not been told to trust this" from "there is nothing there",
                // which are two very different problems with one symptom.
                Button("Show hooks.json") { revealCodexHooksFile() }
                    .controlSize(.small)
            }

            Text("We cannot do this for you: approving hooks on your behalf would defeat the protection the step exists to provide.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private func copyHooksCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("/hooks", forType: .string)
        copiedCommand = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedCommand = false
        }
    }

    private func revealCodexHooksFile() {
        let url = CodexHookInstaller(paths: RuntimePaths()).hooksURL
        // Selecting the file needs it to exist; by this screen it does, but a
        // failed install would otherwise open a Finder window onto nothing.
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(number).")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(text).font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var launchAtLogin: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Open CodeStatus at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .font(.system(size: 13))
            Text("It runs in the menu bar with no Dock icon. macOS may ask you to confirm this in System Settings.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CodeStatus is watching.").font(.system(size: 13))
            counterPreview
            Text("If an agent ever goes quiet, reopen this from Settings › Agents — it re-detects every time, and there is a Repair button next to it.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Chrome

    private var footer: some View {
        HStack {
            if model.canGoBack {
                Button("Back") { model.goBack() }
            }
            Spacer()
            switch model.step {
            case .install:
                if model.pendingInstalls.isEmpty {
                    Button("Continue") { model.advance() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip") { model.advance() }
                    Button("Connect") { model.install() }
                        .keyboardShortcut(.defaultAction)
                }
            case .verify:
                // Never a trap: the user can move on with a agent still
                // unverified, because the menu bar keeps telling them.
                Button(model.allSelectedVerified ? "Continue" : "Continue anyway") {
                    model.advance()
                }
                .keyboardShortcut(.defaultAction)
            case .done:
                Button("Done", action: onFinish).keyboardShortcut(.defaultAction)
            default:
                Button("Continue") { model.advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.15)))
    }

    private func statusLine(_ text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
