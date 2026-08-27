import AppKit
import CodeStatusCore
import Foundation
import Observation
import os

/// Keeps CodeStatus current without ever being the reason someone lost their
/// place.
///
/// The shape of this is set by one property of the app: restarting it costs
/// nothing. Sessions live in the agents, their hooks point at a binary staged
/// outside the bundle, and the snapshot is reloaded on launch. So rather than
/// Sparkle's "install when the user quits" — which for a menu bar app that runs
/// for weeks means never, and eventually a nagging dialog — this waits for a
/// moment when no agent is working or waiting, and takes it.
///
/// Nothing on disk is touched until that moment: the download, the version
/// check, and the signature check all happen first, and any failure leaves the
/// installation untouched and tries again tomorrow.
@MainActor
@Observable
final class UpdateCoordinator {

    enum State: Equatable {
        case idle
        case checking
        /// Verified as newer, waiting for the machine to go quiet.
        case available(ReleaseVersion)
        case installing(ReleaseVersion)
        /// Why updating is impossible here — running from a disk image, or an
        /// unsigned local build. Reported once, then left alone.
        case unavailable(String)
        case failed(String)
    }

    private enum Key {
        static let enabled = "co.codestatus.automaticUpdates"
        static let lastCheckedAt = "co.codestatus.updateLastCheckedAt"
    }

    /// Where the release metadata comes from. The repository is the same one the
    /// website links to for downloads.
    static let feedURL = URL(
        string: "https://api.github.com/repos/henriquegpb/codestatus/releases/latest"
    )!

    private(set) var state: State = .idle

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Key.enabled)
            if isEnabled { scheduleTimer() } else { timer?.invalidate(); timer = nil }
        }
    }

    /// True while any agent is working or waiting on the user. Injected rather
    /// than reached for, so the policy stays testable and this class keeps one
    /// reason to exist.
    var isBusy: () -> Bool = { false }

    private let logger = Logger(subsystem: "co.codestatus", category: "updates")
    private let installer: UpdateInstaller
    private let session: URLSession
    private var timer: Timer?
    private var working = false

    init(installer: UpdateInstaller = UpdateInstaller(), session: URLSession = .shared) {
        self.installer = installer
        self.session = session
        UserDefaults.standard.register(defaults: [Key.enabled: true])
        isEnabled = UserDefaults.standard.bool(forKey: Key.enabled)
    }

    // MARK: - Lifecycle

    func start() {
        guard isEnabled else { return }
        if let why = installer.immovability() {
            // Not a failure to retry: it is a fact about where the app lives,
            // and it will not change until the user moves it.
            state = .unavailable(why.description)
            logger.notice("updates disabled: \(why.description, privacy: .public)")
            return
        }
        guard let team = try? BundleSignature.runningTeamIdentifier() else {
            // A local `--sign` build is ad-hoc and has no team, so it can never
            // verify a release against itself. Refusing here is the point: a
            // development build must not replace itself from the internet.
            state = .unavailable("this build is not Developer ID signed")
            logger.notice("updates disabled: no Developer ID team on the running build")
            return
        }
        logger.info("updates enabled for team \(team, privacy: .public)")
        scheduleTimer()
        // A launch is a known-quiet moment, but not instantly: the daemon is
        // still discovering sessions, so "nothing is running" is not yet true.
        Timer.scheduledTimer(
            withTimeInterval: UpdatePolicy.checkDelayAfterLaunch, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        // Polls far more often than it checks: the timer's job is to notice that
        // the machine went quiet, not to hit the network.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - The loop

    private func tick() {
        guard isEnabled, !working else { return }
        switch state {
        case .available(let version):
            applyIfQuiet(version)
        case .idle, .failed:
            let defaults = UserDefaults.standard
            let last = defaults.object(forKey: Key.lastCheckedAt) as? Date
            guard UpdatePolicy.shouldCheck(now: Date(), lastCheckedAt: last) else { return }
            Task { await check() }
        case .checking, .installing, .unavailable:
            return
        }
    }

    /// Asks the release feed what the newest version is.
    func check() async {
        guard !working else { return }
        working = true
        state = .checking
        defer { working = false }

        do {
            let release = try await fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Key.lastCheckedAt)

            guard let current = Self.runningVersion() else {
                state = .unavailable("this build has no version to compare against")
                return
            }
            guard UpdatePolicy.isUpgrade(from: current, to: release.version) else {
                logger.info("up to date at \(current.description, privacy: .public)")
                state = .idle
                return
            }
            logger.notice("update available: \(release.version.description, privacy: .public)")
            pending = release
            state = .available(release.version)
        } catch {
            // Deliberately quiet. A failed check is the network being the
            // network; the user has nothing to do about it and does not need a
            // banner. It retries on the next interval.
            logger.info("update check failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(String(describing: error))
        }
    }

    private var pending: ReleaseInfo?

    private func applyIfQuiet(_ version: ReleaseVersion) {
        guard let pending, pending.version == version else { return }
        let hold = UpdatePolicy.holdReason(
            hasActiveSessions: isBusy(),
            bundleIsReplaceable: installer.isReplaceable
        )
        guard hold == nil else { return }
        Task { await install(pending, relaunch: true) }
    }

    /// Installs now, whatever the machine is doing. Reached from the menu, so
    /// the interruption is the user's own decision.
    func installNow() {
        guard case .available(let version) = state, let pending, pending.version == version else {
            return
        }
        Task { await install(pending, relaunch: true) }
    }

    private func install(_ release: ReleaseInfo, relaunch: Bool) async {
        guard !working else { return }
        working = true
        state = .installing(release.version)
        defer { working = false }

        do {
            let team = try BundleSignature.runningTeamIdentifier()
            try await installer.install(release, team: team)
            if relaunch { installer.relaunch() }
        } catch {
            // Spelled out rather than reached for via `CustomStringConvertible`,
            // whose conditional cast always succeeds and would have printed the
            // struct rather than the sentence written for the user.
            let detail: String
            switch error {
            case let failure as UpdateInstaller.Failure: detail = failure.description
            case let failure as BundleSignature.Failure: detail = failure.description
            default: detail = error.localizedDescription
            }
            logger.error("update failed: \(detail, privacy: .public)")
            state = .failed(detail)
        }
    }

    // MARK: - Pieces

    private func fetchLatest() async throws -> ReleaseInfo {
        var request = URLRequest(url: Self.feedURL)
        // Asking for the versioned media type keeps a future default change on
        // GitHub's side from silently reshaping the response.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodeStatus", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, _) = try await session.data(for: request)
        return try ReleaseFeed.decodeLatest(data)
    }

    static func runningVersion() -> ReleaseVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(ReleaseVersion.init)
    }
}
