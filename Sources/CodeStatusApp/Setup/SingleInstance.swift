import AppKit

/// Refuses to run a second copy of CodeStatus, and hands the launch to the one
/// already running.
///
/// LaunchServices already stops you opening the *same* bundle twice. It does
/// nothing about two copies at different paths — one in `/Applications`, one
/// still in `~/Downloads` — which is precisely what someone does when the app
/// seems broken and they try downloading it again.
///
/// That state is worse than it looks, because the second copy silently wins.
/// ``EventSocketServer`` unlinks the socket path before binding, so it can
/// recover from a socket left behind by a crash; the same unlink takes the live
/// socket away from a running instance. The first copy keeps its listening
/// descriptor, but nothing can reach it by name any more: every hook connects to
/// the newcomer. The user is left with two menu bar items, two notification
/// streams, two daemons writing one snapshot file, and an older one that has
/// gone permanently deaf without saying so.
enum SingleInstance {

    /// Posted by a second launch, so the running copy can show itself rather
    /// than leave the user staring at a Dock bounce that produced nothing.
    static let showRequest = Notification.Name("co.codestatus.showExistingInstance")

    /// Another running copy of this app, if there is one.
    ///
    /// Nil for a development build run straight from `swift run`: it has no
    /// bundle identifier, so there is nothing to compare against and nothing to
    /// take over from.
    static func otherInstance() -> NSRunningApplication? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .first { $0.processIdentifier != mine && !$0.isTerminated }
    }

    /// Asks the running copy to come forward, then leaves.
    ///
    /// The notification travels through `DistributedNotificationCenter` because
    /// the two processes share nothing else. It is a request to show a window,
    /// carries no data, and is ignored if the other copy is too old to know
    /// about it — in which case the activation alone is still the right outcome.
    static func handOff(to existing: NSRunningApplication) {
        DistributedNotificationCenter.default().postNotificationName(
            showRequest, object: nil, userInfo: nil, deliverImmediately: true
        )
        existing.activate()
    }
}
