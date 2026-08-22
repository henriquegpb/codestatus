import Foundation

/// Listens on the local Unix socket that `codestatus-hook` writes to.
///
/// Stream sockets, one short-lived connection per event, newline-delimited JSON.
/// The hook connects, writes one line, and closes; nothing is ever sent back, so
/// a slow or crashed daemon can only ever cost the hook its 50 ms timeout.
///
/// Local only by construction: `AF_UNIX` has no network surface at all, and the
/// socket sits in a directory only this user can traverse.
public final class EventSocketServer: @unchecked Sendable {

    public enum ServerError: Error, Equatable {
        case socketPathTooLong(String)
        case unsafeFallbackDirectory(String)
        case bindFailed(Int32)
        case listenFailed(Int32)
    }

    /// What the server saw, so diagnostics can show it without the caller
    /// needing to reach into internals.
    public struct Stats: Sendable, Equatable {
        public var accepted = 0
        public var decoded = 0
        public var rejected = 0
    }

    private let paths: RuntimePaths
    private let queue = DispatchQueue(label: "co.codestatus.socket", qos: .utility)
    private var listenerFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var stats = Stats()

    private let onEvent: @Sendable (AgentEvent) -> Void
    private let onDecodeFailure: @Sendable (Error) -> Void

    public private(set) var socketURL: URL?

    public init(
        paths: RuntimePaths = RuntimePaths(),
        onEvent: @escaping @Sendable (AgentEvent) -> Void,
        onDecodeFailure: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.paths = paths
        self.onEvent = onEvent
        self.onDecodeFailure = onDecodeFailure
    }

    public func currentStats() -> Stats {
        queue.sync { stats }
    }

    // MARK: - Lifecycle

    public func start() throws {
        try paths.createDirectories()

        let location = paths.resolveSocketPath()
        if location.isFallback {
            guard RuntimePaths.prepareFallbackDirectory(location.directory) else {
                throw ServerError.unsafeFallbackDirectory(location.directory.path)
            }
        }

        let path = location.url.path
        guard path.utf8.count <= RuntimePaths.socketPathLimit else {
            throw ServerError.socketPathTooLong(path)
        }

        // A socket file left behind by a crash would make bind fail with EADDRINUSE.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.bindFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, byte) in bytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
                dst[bytes.count] = 0
            }
        }

        // Create the socket owner-only: umask could otherwise widen it.
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)

        guard bound == 0 else {
            let code = errno
            close(fd)
            throw ServerError.bindFailed(code)
        }
        guard listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            throw ServerError.listenFailed(code)
        }
        chmod(path, 0o600)

        // The listener must be non-blocking: `acceptPending` drains every queued
        // connection in a loop, and on a blocking socket the accept that finds
        // the queue empty would park the dispatch queue forever.
        let listenerFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, listenerFlags | O_NONBLOCK)

        listenerFD = fd
        socketURL = location.url

        // Publish the resolved path for the hook to read.
        try? Data(path.utf8).write(to: paths.socketPointer, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: paths.socketPointer.path
        )

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        acceptSource = source
        source.resume()
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenerFD = -1
        if let url = socketURL { unlink(url.path) }
        try? FileManager.default.removeItem(at: paths.socketPointer)
        socketURL = nil
    }

    /// Records that the daemon is alive, which is what permits the hook to spool.
    public func writeHeartbeat() {
        let now = Date()
        let path = paths.heartbeat.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(
                atPath: path, contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
        }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path)
    }

    // MARK: - Accepting

    private func acceptPending() {
        while true {
            let client = accept(listenerFD, nil, nil)
            guard client >= 0 else { return }
            // Darwin can hand back a client that inherited the listener's
            // non-blocking flag; clear it so `read` waits for the hook's line
            // instead of returning EAGAIN immediately. The read is still bounded
            // by SO_RCVTIMEO below.
            let clientFlags = fcntl(client, F_GETFL, 0)
            _ = fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK)
            stats.accepted += 1
            readAll(from: client)
            close(client)
        }
    }

    /// Reads one connection to completion.
    ///
    /// Bounded so a misbehaving or hostile local writer cannot exhaust memory:
    /// the hook sends a single small line and closes immediately.
    private func readAll(from fd: Int32) {
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let maxBytes = 1024 * 1024
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        while buffer.count < maxBytes {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 64 * 1024) }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])

            for line in EventWireDecoder.splitLines(&buffer) {
                dispatch(line)
            }
        }
        // A final line without a trailing newline still counts.
        if !buffer.isEmpty { dispatch(buffer) }
    }

    private func dispatch(_ line: Data) {
        do {
            let event = try EventWireDecoder.decode(line: line)
            stats.decoded += 1
            onEvent(event)
        } catch {
            stats.rejected += 1
            onDecodeFailure(error)
        }
    }
}
