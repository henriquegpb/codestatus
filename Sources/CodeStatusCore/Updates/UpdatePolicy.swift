import Foundation

/// One published release, reduced to what deciding on it requires.
public struct ReleaseInfo: Sendable, Equatable {
    public let version: ReleaseVersion
    /// The archive to download. A zip rather than the disk image, because
    /// unpacking a zip is one `ditto` call while a `.dmg` needs attach/detach —
    /// two more failure modes in the one place we can least afford them.
    public let archiveURL: URL

    public init(version: ReleaseVersion, archiveURL: URL) {
        self.version = version
        self.archiveURL = archiveURL
    }
}

/// Reads the GitHub Releases payload.
///
/// Hand-decoded rather than `Codable` over the whole document: the response
/// carries around fifty fields we have no business modelling, and a schema
/// change in any of them must not stop updates working.
public enum ReleaseFeed {

    public enum DecodeError: Error, Equatable {
        case notJSON
        case unreadableTag
        case noArchiveAsset(String)
        case draftOrPrerelease
    }

    /// The asset name the release workflow publishes under a fixed name.
    public static let archiveAssetName = "CodeStatus.zip"

    public static func decodeLatest(
        _ data: Data,
        assetName: String = archiveAssetName
    ) throws -> ReleaseInfo {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.notJSON
        }
        // `/releases/latest` never returns a draft, but `/releases` does and a
        // future caller may pass one element of it. Refuse rather than ship a
        // build that was not meant to be public.
        if root["draft"] as? Bool == true || root["prerelease"] as? Bool == true {
            throw DecodeError.draftOrPrerelease
        }
        guard let tag = root["tag_name"] as? String,
              let version = ReleaseVersion(tag) else {
            throw DecodeError.unreadableTag
        }

        let assets = root["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { $0["name"] as? String == assetName }),
              let link = asset["browser_download_url"] as? String,
              let url = URL(string: link),
              // The download is validated by signature after it arrives, but a
              // plaintext URL is not worth starting: it would let a network
              // attacker choose which of our real releases you receive.
              url.scheme == "https" else {
            throw DecodeError.noArchiveAsset(assetName)
        }
        return ReleaseInfo(version: version, archiveURL: url)
    }
}

/// When to check, and when it is safe to swap the app underneath the user.
///
/// Pure, because this is the part that has to be obviously right: an installer
/// that fires at the wrong moment is worse than no installer at all.
public enum UpdatePolicy {

    /// Matches Sparkle's default. Long enough that the release API is never a
    /// burden, short enough that a fix reaches people the day it ships.
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    /// A launch is the one moment we know the app is not mid-anything, so the
    /// first check happens shortly after it rather than a day later.
    public static let checkDelayAfterLaunch: TimeInterval = 60

    public static func shouldCheck(
        now: Date,
        lastCheckedAt: Date?,
        interval: TimeInterval = checkInterval
    ) -> Bool {
        guard let lastCheckedAt else { return true }
        // A clock that moved backwards — a timezone fix, a restored backup —
        // must not park updates until it catches up.
        guard now >= lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= interval
    }

    /// Whether a fetched release is worth installing over what is running.
    ///
    /// Strictly greater: a re-run of the same version is not an update, and a
    /// lower one is either a yanked release or someone else's answer to our
    /// request. Neither is something to install unattended.
    public static func isUpgrade(from current: ReleaseVersion, to candidate: ReleaseVersion) -> Bool {
        candidate > current
    }

    /// Why an update is being held rather than applied.
    public enum Hold: Equatable, Sendable {
        /// An agent is mid-turn, or waiting on the user. Relaunching now would
        /// blank the menu bar at the exact moment someone is reading it.
        case sessionsAreActive
        /// The app cannot replace itself where it is: running from a disk image,
        /// from a translocated path, or from a directory it cannot write.
        case bundleNotReplaceable
    }

    /// Restarting CodeStatus costs almost nothing — sessions live in the agents,
    /// their hooks point at a staged binary outside the bundle, and the snapshot
    /// is reloaded on launch. So the only question worth asking is whether
    /// anyone is looking, and idle is a moment we can recognise exactly.
    public static func holdReason(
        hasActiveSessions: Bool,
        bundleIsReplaceable: Bool
    ) -> Hold? {
        if !bundleIsReplaceable { return .bundleNotReplaceable }
        if hasActiveSessions { return .sessionsAreActive }
        return nil
    }
}
