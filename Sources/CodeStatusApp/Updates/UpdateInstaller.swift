import AppKit
import CodeStatusCore
import Foundation
import os

/// Downloads a release, proves it is ours, and swaps it in.
///
/// Ordered so that nothing irreversible happens until everything checkable has
/// been checked: the running app is only touched after the replacement has been
/// unpacked, read, and cryptographically verified. Every failure before that
/// point leaves the installation exactly as it was.
struct UpdateInstaller {

    enum Failure: Error, CustomStringConvertible {
        case notReplaceable(UpdateInstaller.Immovability)
        case unpackFailed(String)
        case noAppInArchive
        case versionMismatch(expected: ReleaseVersion, found: String?)
        case signature(BundleSignature.Failure)

        var description: String {
            switch self {
            case .notReplaceable(let why): return why.description
            case .unpackFailed(let detail): return "could not unpack the download: \(detail)"
            case .noAppInArchive: return "the download did not contain CodeStatus.app"
            case .versionMismatch(let expected, let found):
                return "expected version \(expected) but the download says \(found ?? "nothing")"
            case .signature(let failure): return failure.description
            }
        }
    }

    /// Why this installation cannot replace itself in place.
    enum Immovability: Equatable, CustomStringConvertible {
        case translocated
        case readOnlyLocation

        var description: String {
            switch self {
            case .translocated:
                return "CodeStatus is running from a quarantined copy; "
                    + "move it to Applications to enable updates"
            case .readOnlyLocation:
                return "CodeStatus cannot write to its own location"
            }
        }
    }

    private let logger = Logger(subsystem: "co.codestatus", category: "updates")

    /// Where the running app lives.
    let installedURL: URL

    init(installedURL: URL = Bundle.main.bundleURL) {
        self.installedURL = installedURL
    }

    // MARK: - Preconditions

    /// Whether an in-place replacement is possible at all.
    ///
    /// Gatekeeper runs an app opened straight from a disk image out of a
    /// randomised read-only path, so an installer that did not check this would
    /// spend every cycle downloading an update it can never apply.
    func immovability() -> Immovability? {
        if installedURL.path.contains("/AppTranslocation/") { return .translocated }
        let parent = installedURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            return .readOnlyLocation
        }
        return nil
    }

    var isReplaceable: Bool { immovability() == nil }

    // MARK: - Installing

    /// Fetches, verifies, and installs `release`, leaving the app on disk ready
    /// for the next launch. Does not relaunch — that is the caller's call, made
    /// when it knows nobody is watching.
    func install(_ release: ReleaseInfo, team: String) async throws {
        if let why = immovability() { throw Failure.notReplaceable(why) }

        let (downloaded, response) = try await URLSession.shared.download(from: release.archiveURL)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Failure.unpackFailed("server returned HTTP \(http.statusCode)")
        }

        // Staged on the same volume as the installed app so the final swap is a
        // rename rather than a copy: `replaceItemAt` cannot be atomic across
        // volumes, and a half-copied app bundle is the worst outcome available.
        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: installedURL,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        try unpack(downloaded, into: staging)
        let candidate = try locateApp(in: staging)

        // Read the version out of the bundle rather than trusting the tag: they
        // disagree only if the release was built wrong, and installing a build
        // that is not the one we decided on is exactly what must not happen.
        let declared = Bundle(url: candidate)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let declared, ReleaseVersion(declared) == release.version else {
            throw Failure.versionMismatch(expected: release.version, found: declared)
        }

        do {
            try BundleSignature.verify(bundleAt: candidate, isSignedBy: team)
        } catch let failure as BundleSignature.Failure {
            throw Failure.signature(failure)
        }

        // Only now is anything on the user's disk allowed to change.
        _ = try FileManager.default.replaceItemAt(installedURL, withItemAt: candidate)
        logger.notice("installed \(release.version.description, privacy: .public)")
    }

    private func unpack(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // `-x -k` is unzip; `--noqtn` keeps the quarantine flag off the result,
        // which is ours to decide because we verify the signature ourselves and
        // refuse anything that does not pass.
        process.arguments = ["-x", "-k", "--noqtn", archive.path, directory.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let detail = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.unpackFailed(detail.isEmpty ? "ditto exited \(process.terminationStatus)"
                                                      : detail)
        }
    }

    private func locateApp(in directory: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw Failure.noAppInArchive
        }
        return app
    }

    // MARK: - Relaunching

    /// Restarts into the freshly installed bundle.
    ///
    /// The helper waits for *this* process to be gone before opening the app,
    /// because `open` on a bundle whose application is still running just
    /// activates the old instance and the update appears not to have happened.
    @MainActor
    func relaunch() {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            // Bounded: if this process somehow never exits, the helper gives up
            // rather than living forever waiting for it.
            #"for _ in $(seq 1 100); do kill -0 \#(getpid()) 2>/dev/null || break; sleep 0.1; done; "#
                + #"exec /usr/bin/open "$1""#,
            "sh",
            installedURL.path,
        ]
        do {
            try helper.run()
        } catch {
            logger.error("relaunch helper failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }
}
