import SwiftUI

/// The only place an update is ever visible before it happens.
///
/// Deliberately not a dialog and not a notification. An update that installs
/// itself the moment the machine goes quiet does not need announcing; this
/// exists for the two cases where the user genuinely has something to decide —
/// a machine that has been busy long enough that "quiet" never arrived, and an
/// installation that cannot update itself where it lives.
struct UpdateBanner: View {
    let text: String
    let canInstallNow: Bool
    let installNow: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if canInstallNow {
                Button("Restart", action: installNow)
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    /// What to say, or nothing at all — which is the answer almost always, since
    /// a healthy updater is one the user never notices.
    static func text(for state: UpdateCoordinator.State) -> String? {
        switch state {
        case .idle, .checking:
            return nil
        case .available(let version):
            return "Version \(version) is ready — it will install when nothing is running."
        case .installing(let version):
            return "Installing \(version)…"
        case .unavailable(let why):
            return why
        case .failed:
            // A failed check is the network being the network. It retries on its
            // own and there is nothing here for the user to act on.
            return nil
        }
    }
}

extension UpdateCoordinator.State {
    /// Whether the user could sensibly take the update right now.
    var isWaitingForQuiet: Bool {
        if case .available = self { return true }
        return false
    }
}
