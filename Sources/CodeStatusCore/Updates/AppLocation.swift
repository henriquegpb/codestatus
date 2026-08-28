import Foundation

/// Where the app bundle is sitting, and whether that is somewhere it can work.
///
/// One place, because two different parts of the app ask closely related
/// questions about the same path and were answering them separately: the
/// updater needs to know whether it can replace the bundle, and first run needs
/// to know whether to offer to move it. A translocated path fails both, and two
/// independent string tests for it is one too many.
public enum AppLocation {

    public enum Placement: Equatable, Sendable {
        /// `/Applications`.
        case applications
        /// `~/Applications`, a deliberate choice rather than a mistake.
        case userApplications
        /// Gatekeeper's randomised read-only mirror, made when an app is opened
        /// straight from a downloaded disk image.
        case translocated
        /// A real, writable location that is neither Applications folder —
        /// `~/Downloads`, the Desktop, a project directory.
        case elsewhere
        /// Not an app bundle at all: a development build run from the terminal.
        case notABundle
    }

    /// Gatekeeper's mirror lives under a path containing this component.
    ///
    /// Matched on the path because there is no public API that answers the
    /// question. `SecTranslocateIsTranslocatedURL` exists but is private, and
    /// the directory name has been stable across every macOS that has the
    /// feature.
    static let translocationMarker = "/AppTranslocation/"

    public static func isTranslocated(_ bundleURL: URL) -> Bool {
        bundleURL.path.contains(translocationMarker)
    }

    public static func placement(
        of bundleURL: URL,
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        isBundle: Bool = true
    ) -> Placement {
        guard isBundle, bundleURL.pathExtension == "app" else { return .notABundle }
        if isTranslocated(bundleURL) { return .translocated }

        // Standardized so a path spelled with a trailing slash or a `..` still
        // compares equal to the directory it names.
        let parent = bundleURL.standardizedFileURL.deletingLastPathComponent().path
        if parent == "/Applications" { return .applications }
        if parent == home.appendingPathComponent("Applications").standardizedFileURL.path {
            return .userApplications
        }
        return .elsewhere
    }

    /// Whether the app can update itself and keep a working login item here.
    ///
    /// Both need a stable, writable path, and both fail silently without one —
    /// which is why this is asked at first launch rather than discovered later.
    public static func isSettled(_ placement: Placement) -> Bool {
        switch placement {
        case .applications, .userApplications, .notABundle: return true
        case .translocated, .elsewhere: return false
        }
    }
}
