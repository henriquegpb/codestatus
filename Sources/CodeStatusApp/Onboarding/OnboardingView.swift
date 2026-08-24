import CodeStatusCore
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(28)
            Divider()
            footer.padding(16)
        }
        .frame(width: 560, height: 460)
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

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CodeStatus needs permission to tell you when an agent finishes or needs you.")
                .font(.system(size: 13))
            switch model.notificationsGranted {
            case .some(true):
                statusLine("Allowed", tint: .green)
            case .some(false):
                statusLine("Not allowed — you can change this later in System Settings › Notifications", tint: .orange)
            case nil:
                Button("Allow Notifications") {
                    Task { await model.requestNotifications() }
                }
                .controlSize(.large)
            }
            Text("The HUD and the menu bar work either way.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var detect: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.adapters.isEmpty {
                Text("No Claude Code or Codex installation found on this Mac.")
                    .font(.system(size: 13))
                Text("Install one and reopen this window from the menu bar. CodeStatus will still run; it simply has nothing to watch yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(model.adapters) { adapter in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(adapter.name).font(.system(size: 13, weight: .medium))
                        if let detail = adapter.detail {
                            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var install: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.installPlans.isEmpty {
                Text("Nothing to connect.").font(.system(size: 13))
            } else {
                Text("Here is exactly what will change. Nothing is written until you press Connect.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)

                ForEach(model.installPlans) { plan in
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
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
                }
            }

            if let error = model.installError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }

            // The Codex trust step cannot be automated: forging its trust record
            // would defeat the control it exists to provide.
            if model.installPlans.contains(where: { $0.provider == .codex }) {
                Text(CodexHookInstaller.trustInstructions)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            Text("Open a session in Claude Code or Codex and the counters will move. Right-click the menu bar item for diagnostics, where you can send a test event and see exactly what works on this Mac.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
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
                let pending = model.installPlans.contains { !$0.alreadyInstalled }
                if pending {
                    Button("Skip") { model.advance() }
                    Button("Connect") { model.install() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { model.advance() }
                        .keyboardShortcut(.defaultAction)
                }
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

    private func statusLine(_ text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
