import CodeStatusCore
import SwiftUI

/// What the updater is doing, in Settings.
///
/// Exists so that "keep up to date" is not a switch with no feedback: an update
/// mechanism the user cannot inspect is one they have to take on faith, and the
/// version line is also the fastest way to answer "did it actually update?".
struct UpdateStatusRow: View {
    let updates: UpdateCoordinator

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if updates.state.isWaitingForQuiet {
                Button("Restart now") { updates.installNow() }
            } else if updates.isEnabled, case .unavailable = updates.state {
                // No button: nothing the user does here fixes it, and offering
                // one that cannot work is worse than the plain sentence.
                EmptyView()
            } else if updates.isEnabled {
                Button("Check now") { Task { await updates.check() } }
            }
        }
    }

    private var headline: String {
        UpdateCoordinator.runningVersion().map { "Version \($0)" } ?? "Development build"
    }

    private var detail: String? {
        switch updates.state {
        case .idle: return updates.isEnabled ? "Up to date." : nil
        case .checking: return "Checking…"
        case .available(let version): return "Version \(version) is ready to install."
        case .installing(let version): return "Installing \(version)…"
        case .unavailable(let why): return why
        case .failed: return "Could not check for updates. It will try again later."
        }
    }
}
