import Foundation

/// Every path CodeStatus owns on disk, and the permissions they must carry.
///
/// Centralised because two independent binaries — the app and the hook — have to
/// agree on them exactly, and because the socket path has a hard length limit
/// that has to be resolved consistently in both.
public struct RuntimePaths: Sendable {
    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, including the terminator.
    /// We leave headroom rather than sizing to the exact limit.
    public static let socketPathLimit = 100

    public let base: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        base = home
            .appendingPathComponent("Library/Application Support/CodeStatus", isDirectory: true)
    }

    public var run: URL { base.appendingPathComponent("run", isDirectory: true) }
    public var bin: URL { base.appendingPathComponent("bin", isDirectory: true) }
    public var backups: URL { base.appendingPathComponent("backups", isDirectory: true) }
    public var state: URL { base.appendingPathComponent("state", isDirectory: true) }

    public var spool: URL { run.appendingPathComponent("spool", isDirectory: true) }
    public var heartbeat: URL { run.appendingPathComponent("heartbeat") }
    /// Points at the live socket, so the hook never needs the path compiled in
    /// and the daemon can relocate it without touching any agent's config.
    public var socketPointer: URL { run.appendingPathComponent("socket-path") }
    public var hookBinary: URL { bin.appendingPathComponent("codestatus-hook") }
    public var sessionsSnapshot: URL { state.appendingPathComponent("sessions.json") }

    /// The preferred socket location, inside our own Application Support tree.
    public var preferredSocket: URL { run.appendingPathComponent("e.sock") }

    /// Where the socket can actually live on this machine.
    ///
    /// A long username pushes the Application Support path past `sun_path`'s
    /// limit, so we fall back to a short, per-user directory under `/tmp`. That
    /// directory is world-writable ground, so callers must validate it with
    /// ``validateFallbackDirectory(_:)`` before trusting it.
    public func resolveSocketPath(uid: uid_t = getuid()) -> SocketLocation {
        let preferred = preferredSocket.path
        if preferred.utf8.count <= Self.socketPathLimit {
            return SocketLocation(url: preferredSocket, isFallback: false)
        }
        let fallback = URL(fileURLWithPath: "/tmp/codestatus-\(uid)/e.sock")
        return SocketLocation(url: fallback, isFallback: true)
    }

    public struct SocketLocation: Sendable, Equatable {
        public let url: URL
        /// True when we had to leave Application Support because of the path limit.
        public let isFallback: Bool
        public var directory: URL { url.deletingLastPathComponent() }
    }
}

public extension RuntimePaths {
    /// Creates our directories with owner-only permissions.
    func createDirectories(fileManager: FileManager = .default) throws {
        for directory in [base, run, bin, backups, state, spool] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // createDirectory only applies attributes to directories it creates,
            // so tighten anything that already existed with looser permissions.
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    /// Verifies that a fallback socket directory under `/tmp` is really ours.
    ///
    /// `/tmp` is world-writable, so another user could pre-create the directory
    /// or replace it with a symlink pointing somewhere sensitive. We refuse
    /// anything that is not a real directory, owned by us, with mode 0700.
    static func validateFallbackDirectory(_ url: URL, uid: uid_t = getuid()) -> Bool {
        var info = stat()
        // lstat, not stat: a symlink must fail rather than be followed.
        guard lstat(url.path, &info) == 0 else { return false }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard info.st_uid == uid else { return false }
        return (info.st_mode & 0o777) == 0o700
    }

    /// Creates the fallback directory safely, or confirms an existing one is ours.
    static func prepareFallbackDirectory(_ url: URL, uid: uid_t = getuid()) -> Bool {
        if mkdir(url.path, 0o700) == 0 {
            return validateFallbackDirectory(url, uid: uid)
        }
        guard errno == EEXIST else { return false }
        return validateFallbackDirectory(url, uid: uid)
    }
}
