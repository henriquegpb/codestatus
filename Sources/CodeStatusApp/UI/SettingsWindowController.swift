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
        static let keepAwakeEnabled = "co.codestatus.keepAwakeEnabled"
        static let keepAwakeEngagement = "co.codestatus.keepAwakeEngagement"
        static let keepAwakeBatteryFloor = "co.codestatus.keepAwakeBatteryFloor"
    }

    var soundEnabled: Bool { didSet { persist() } }
    var notificationsEnabled: Bool { didSet { persist() } }
    var onlyWhenUnfocused: Bool { didSet { persist() } }
    var launchAtLogin: Bool

    /// Off by default. It changes how the machine behaves rather than how the app
    /// behaves, and a menu bar tool does not get to make that choice for anyone.
    var keepAwakeEnabled: Bool { didSet { persist() } }
    var keepAwakeEngagement: WakeLockPolicy.Engagement { didSet { persist() } }
    var keepAwakeBatteryFloor: Int { didSet { persist() } }

    /// Nil when not muted; otherwise when the quiet period ends.
    var mutedUntil: Date? { didSet { onChange?() } }

    var onChange: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.soundEnabled: true,
            Key.notificationsEnabled: true,
            Key.onlyWhenUnfocused: true,
            Key.keepAwakeEnabled: false,
            Key.keepAwakeBatteryFloor: WakeLockPolicy.defaultBatteryFloor,
        ])
        soundEnabled = defaults.bool(forKey: Key.soundEnabled)
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        onlyWhenUnfocused = defaults.bool(forKey: Key.onlyWhenUnfocused)
        keepAwakeEnabled = defaults.bool(forKey: Key.keepAwakeEnabled)
        keepAwakeEngagement = WakeLockPolicy.Engagement(
            rawValue: defaults.string(forKey: Key.keepAwakeEngagement) ?? ""
        ) ?? .whileAgentsWork
        keepAwakeBatteryFloor = defaults.integer(forKey: Key.keepAwakeBatteryFloor)
        launchAtLogin = LoginItem.isEnabled
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(soundEnabled, forKey: Key.soundEnabled)
        defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled)
        defaults.set(onlyWhenUnfocused, forKey: Key.onlyWhenUnfocused)
        defaults.set(keepAwakeEnabled, forKey: Key.keepAwakeEnabled)
        defaults.set(keepAwakeEngagement.rawValue, forKey: Key.keepAwakeEngagement)
        defaults.set(keepAwakeBatteryFloor, forKey: Key.keepAwakeBatteryFloor)
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
    var wakeLock: WakeLockCoordinator?
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

            // Named for the machine rather than for the agents, because what it
            // changes is when this Mac sleeps — and the limit below is the whole
            // reason the section cannot be called "keep agents running".
            Section("Sleep") {
                Toggle("Keep this Mac awake", isOn: $model.keepAwakeEnabled)
                Text("Stops the idle sleep that interrupts a long turn. "
                    + "**Closing the lid still sleeps this Mac** — macOS reserves that "
                    + "for the system, and no app can hold it open.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.keepAwakeEnabled {
                    Picker("Hold it", selection: $model.keepAwakeEngagement) {
                        Text("While agents work").tag(WakeLockPolicy.Engagement.whileAgentsWork)
                        Text("Always").tag(WakeLockPolicy.Engagement.always)
                    }
                    .pickerStyle(.segmented)
                    .help("While agents work releases the moment a turn ends — and while "
                        + "an agent is waiting on you, since nothing is progressing then.")

                    // Deliberately not lower than 5%: below that the machine is
                    // minutes from shutting down on its own, and a floor that
                    // cannot be trusted to fire is worse than none.
                    Stepper(
                        value: $model.keepAwakeBatteryFloor,
                        in: 5...50,
                        step: 5
                    ) {
                        HStack {
                            Text("Let it sleep below")
                            Spacer()
                            Text("\(model.keepAwakeBatteryFloor)%").foregroundStyle(.secondary)
                        }
                    }
                    .help("Ignored while plugged in. Opening your bag to a Mac at 0% "
                        + "loses more than the interrupted turn would have.")

                    if let wakeLock {
                        Text(wakeLock.statusDescription)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
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
        .frame(width: 460, height: 560)
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel
    private let updates: UpdateCoordinator?
    private let wakeLock: WakeLockCoordinator?
    private let onOpenSetup: () -> Void
    private let onRepairHooks: () -> Void
    private let onUninstallHooks: () -> Void
    private let onUninstall: () -> Void

    init(
        model: SettingsModel,
        updates: UpdateCoordinator? = nil,
        wakeLock: WakeLockCoordinator? = nil,
        onOpenSetup: @escaping () -> Void,
        onRepairHooks: @escaping () -> Void,
        onUninstallHooks: @escaping () -> Void,
        onUninstall: @escaping () -> Void
    ) {
        self.model = model
        self.updates = updates
        self.wakeLock = wakeLock
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
                    wakeLock: wakeLock,
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
