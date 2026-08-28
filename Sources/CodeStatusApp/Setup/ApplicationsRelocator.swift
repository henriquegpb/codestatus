import AppKit
import CodeStatusCore
import os

/// Gets the app into `/Applications`, because three separate things quietly
/// stop working anywhere else.
///
/// Opening an app straight from a downloaded disk image makes Gatekeeper run it
/// from a randomised, read-only path — App Translocation. Left there, or left in
/// `~/Downloads`:
///
///  * updates can never apply, because the installer cannot replace a bundle it
///    cannot write to (``UpdateInstaller/immovability()`` already knows this,
///    and says so in a status row nobody is looking at);
///  * launch at login registers whatever path the app happens to occupy, so the
///    login item points at a translocated directory that will not exist next
///    time, and silently never opens anything;
///  * and the hooks keep working perfectly, because the hook binary is copied
///    out of the bundle to a stable path — which is what makes this so hard to
///    notice. The app looks fine. Three things are broken.
///
/// So this is asked once, at first launch, in the one place where the answer is
/// still cheap.
enum ApplicationsRelocator {

    private static let logger = Logger(subsystem: "co.codestatus", category: "relocate")
    private static let declinedKey = "co.codestatus.declinedRelocation"

    /// What is wrong with where we are, if anything.
    ///
    /// Nil for a development build: an executable with no bundle identifier, or
    /// anything not shaped like an `.app`, is not something to relocate.
    static func situation(
        bundleURL: URL = Bundle.main.bundleURL,
        identifier: String? = Bundle.main.bundleIdentifier
    ) -> AppLocation.Placement? {
        guard identifier != nil else { return nil }
        let placement = AppLocation.placement(of: bundleURL)
        return AppLocation.isSettled(placement) ? nil : placement
    }

    /// Where a relocated copy would go.
    static func destination(for bundleURL: URL = Bundle.main.bundleURL) -> URL {
        URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(bundleURL.lastPathComponent)
    }

    static var wasDeclined: Bool {
        UserDefaults.standard.bool(forKey: declinedKey)
    }

    /// Asks, and acts on the answer.
    ///
    /// Returns true when the app has been relocated and relaunched, in which
    /// case the caller must stop setting itself up and quit: the copy the user
    /// will actually use is a different process.
    @MainActor
    static func offerIfNeeded() -> Bool {
        guard !wasDeclined, let situation = situation() else { return false }

        let alert = NSAlert()
        alert.messageText = "Move CodeStatus to Applications?"
        alert.informativeText = switch situation {
        case .translocated:
            "CodeStatus is running from a read-only copy macOS made because it "
                + "was opened straight from the download. Left here, updates cannot "
                + "install and Open at Login will not work — and neither failure "
                + "announces itself."
        default:
            "CodeStatus works best from the Applications folder. Left where it "
                + "is, updates cannot install and Open at Login breaks if the app "
                + "is ever moved."
        }
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational

        guard alert.runModal() == .alertFirstButtonReturn else {
            // Remembered, because an app that reopens the same argument at every
            // launch is one people quit rather than answer.
            UserDefaults.standard.set(true, forKey: declinedKey)
            logger.info("relocation declined")
            return false
        }

        do {
            let moved = try relocate()
            logger.info("relocated to \(moved.path, privacy: .public)")
            NSWorkspace.shared.openApplication(
                at: moved, configuration: NSWorkspace.OpenConfiguration()
            )
            return true
        } catch {
            logger.error("relocation failed: \(error.localizedDescription, privacy: .public)")
            let failure = NSAlert()
            failure.messageText = "Could not move CodeStatus"
            failure.informativeText = error.localizedDescription
                + "\n\nDrag CodeStatus to your Applications folder by hand, then open it from there."
            failure.alertStyle = .warning
            failure.runModal()
            return false
        }
    }

    /// Copies the running bundle into `/Applications`.
    ///
    /// A copy rather than a move, deliberately. From a translocated path there
    /// is nothing to move — the source is a read-only mirror macOS made, and the
    /// real download is somewhere we were never told about. Copying the mirror
    /// is what LaunchServices itself expects here, and it produces a complete,
    /// un-quarantined bundle.
    static func relocate(
        from bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let target = destination(for: bundleURL)
        if fileManager.fileExists(atPath: target.path) {
            // Something is already there under our name. Trash rather than
            // delete: if it turns out to have been someone else's, it is
            // recoverable, and if it was an older CodeStatus this is exactly
            // what replacing it should look like.
            try fileManager.trashItem(at: target, resultingItemURL: nil)
        }
        try fileManager.copyItem(at: bundleURL, to: target)
        return target
    }
}
