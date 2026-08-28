import AppKit
import CodeStatusCore
import Observation
import SwiftUI

/// Preferences, persisted in `UserDefaults`.
///
/// Deliberately small. Every option here exists because the spec names it or
/// because it turns something off — a menu bar tool earns trust by being
/// silenceable, not by being configurable.
@MainActor
@Observable
final class SettingsModel {

    private enum Key {
        static let soundEnabled = "co.codestatus.soundEnabled"
        static let notificationsEnabled = "co.codestatus.notificationsEnabled"
        static let onlyWhenUnfocused = "co.codestatus.onlyWhenUnfocused"
    }

    var soundEnabled: Bool { didSet { persist() } }
    var notificationsEnabled: Bool { didSet { persist() } }
    var onlyWhenUnfocused: Bool { didSet { persist() } }
    var launchAtLogin: Bool

    /// Nil when not muted; otherwise when the quiet period ends.
    var mutedUntil: Date? { didSet { onChange?() } }

    var onChange: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.soundEnabled: true,
            Key.notificationsEnabled: true,
            Key.onlyWhenUnfocused: true,
        ])
        soundEnabled = defaults.bool(forKey: Key.soundEnabled)
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        onlyWhenUnfocused = defaults.bool(forKey: Key.onlyWhenUnfocused)
        launchAtLogin = LoginItem.isEnabled
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(soundEnabled, forKey: Key.soundEnabled)
        defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled)
        defaults.set(onlyWhenUnfocused, forKey: Key.onlyWhenUnfocused)
        onChange?()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        try? LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
    }

    func mute(for interval: TimeInterval) {
        mutedUntil = Date().addingTimeInterval(interval)
    }

    func unmute() {
        mutedUntil = nil
    }

    var notificationPreferences: NotificationCoordinator.Preferences {
        var preferences = NotificationCoordinator.Preferences()
        preferences.soundEnabled = soundEnabled
        preferences.notificationsEnabled = notificationsEnabled
        preferences.onlyWhenHostUnfocused = onlyWhenUnfocused
        preferences.mutedUntil = mutedUntil
        return preferences
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    var updates: UpdateCoordinator?
    var onOpenSetup: () -> Void
    var onRepairHooks: () -> Void
    var onUninstallHooks: () -> Void
    var onUninstall: () -> Void

    var body: some View {
        Form {
            Section("Alerts") {
                Toggle("Play a sound", isOn: $model.soundEnabled)
                Toggle("Show notifications", isOn: $model.notificationsEnabled)
                Toggle("Only when the app is not in front", isOn: $model.onlyWhenUnfocused)
                    .help("Stays quiet while you are already looking at the session that changed.")

                if let mutedUntil = model.mutedUntil, mutedUntil > Date() {
                    HStack {
                        Text("Muted until \(mutedUntil.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Unmute") { model.unmute() }
                    }
                } else {
                    HStack {
                        Text("Quiet for a while").foregroundStyle(.secondary)
                        Spacer()
                        Button("30 min") { model.mute(for: 30 * 60) }
                        Button("2 hours") { model.mute(for: 2 * 3600) }
                    }
                }
            }

            Section("General") {
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if let updates {
                    Toggle("Keep CodeStatus up to date", isOn: Binding(
                        get: { updates.isEnabled },
                        set: { updates.isEnabled = $0 }
                    ))
                    .help("Installs updates when no agent is working or waiting on you, "
                        + "then restarts. Sessions are unaffected.")
                    UpdateStatusRow(updates: updates)
                }
            }

            Section("Agents") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect or reconnect agents")
                        Text("Re-detects every time it opens, and lists agents it did not find.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Setup", action: onOpenSetup)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("An agent stopped reporting")
                        // Named for the symptom rather than the mechanism,
                        // because the alternative people reach for is deleting
                        // the app and downloading it again.
                        Text("Re-installs the hooks CodeStatus already owns. Adds nothing new.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Repair", action: onRepairHooks)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stop watching my agents")
                        Text("Removes only our entries. Your own hooks are left alone.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect", action: onUninstallHooks)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remove CodeStatus from this Mac")
                        // Offered here as well as in the menu because the
                        // alternative people reach for — dragging the app to the
                        // Trash — is the one action that cannot clean up after
                        // itself, and leaves a hook running in their agent for
                        // as long as the machine lives.
                        Text("Deleting the app on its own leaves the hook entries behind.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Uninstall…", action: onUninstall)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel
    private let updates: UpdateCoordinator?
    private let onOpenSetup: () -> Void
    private let onRepairHooks: () -> Void
    private let onUninstallHooks: () -> Void
    private let onUninstall: () -> Void

    init(
        model: SettingsModel,
        updates: UpdateCoordinator? = nil,
        onOpenSetup: @escaping () -> Void,
        onRepairHooks: @escaping () -> Void,
        onUninstallHooks: @escaping () -> Void,
        onUninstall: @escaping () -> Void
    ) {
        self.model = model
        self.updates = updates
        self.onOpenSetup = onOpenSetup
        self.onRepairHooks = onRepairHooks
        self.onUninstallHooks = onUninstallHooks
        self.onUninstall = onUninstall
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "CodeStatus Settings"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentViewController = NSHostingController(
                rootView: SettingsView(
                    model: model,
                    updates: updates,
                    onOpenSetup: onOpenSetup,
                    onRepairHooks: onRepairHooks,
                    onUninstallHooks: onUninstallHooks,
                    onUninstall: onUninstall
                )
            )
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
