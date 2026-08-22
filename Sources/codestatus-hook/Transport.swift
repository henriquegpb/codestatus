// Delivery of a scanned event to the CodeStatus daemon.
//
// The overriding rule here is that the agent must never be harmed by us. Every
// path is bounded and every failure is silent: no blocking connect, no
// unbounded read, no unbounded spool, and exit status 0 whatever happens.

import Darwin
import HookCore

// MARK: - Environment and identity

func environmentValue(_ name: String) -> [UInt8]? {
    guard let raw = getenv(name) else { return nil }
    var out: [UInt8] = []
    var p = raw
    while p.pointee != 0 {
        out.append(UInt8(bitPattern: p.pointee))
        p += 1
    }
    return out.isEmpty ? nil : out
}

/// Wall-clock seconds and microseconds, for the event timestamp.
func wallClock() -> (seconds: Int, microseconds: Int) {
    var tv = timeval()
    gettimeofday(&tv, nil)
    return (Int(tv.tv_sec), Int(tv.tv_usec))
}

/// Mints an idempotency key that is unique without coordination.
///
/// Concurrent hook processes cannot collide: pids differ. Sequential runs of the
/// same pid cannot collide: the monotonic clock differs. No random source and no
/// shared counter is required.
func makeEventID(counter: Int) -> [UInt8] {
    var out: [UInt8] = []
    appendInt(Int(getpid()), to: &out)
    out.append(UInt8(ascii: "-"))
    appendInt(Int(mach_absolute_time() & 0x7FFF_FFFF_FFFF_FFFF), to: &out)
    out.append(UInt8(ascii: "-"))
    appendInt(counter, to: &out)
    return out
}

// MARK: - Files

/// Reads a small file completely. Used for the socket-path pointer only.
func readSmallFile(_ path: String, limit: Int = 4096) -> [UInt8]? {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var buffer = [UInt8](repeating: 0, count: limit)
    let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, limit) }
    guard n > 0 else { return nil }
    return Array(buffer[0..<n])
}

func trimmed(_ input: [UInt8]) -> [UInt8] {
    var start = 0
    var end = input.count
    while start < end, input[start] == 0x20 || input[start] == 0x0A || input[start] == 0x0D || input[start] == 0x09 {
        start += 1
    }
    while end > start, input[end - 1] == 0x20 || input[end - 1] == 0x0A || input[end - 1] == 0x0D || input[end - 1] == 0x09 {
        end -= 1
    }
    return Array(input[start..<end])
}

/// Age of a file in seconds, or `nil` if it does not exist.
func fileAgeSeconds(_ path: String) -> Int? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    let now = wallClock().seconds
    return now - Int(info.st_mtimespec.tv_sec)
}

/// Reads all of a descriptor, keeping at most `limit` bytes but always draining
/// the rest.
///
/// Draining matters: if we stopped reading early the agent's write would fail
/// with EPIPE, which is precisely the kind of interference this project forbids.
func readAllDraining(_ fd: Int32, limit: Int) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(16 * 1024)
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 64 * 1024) }
        if n <= 0 { break }
        if out.count < limit {
            let take = min(n, limit - out.count)
            out.append(contentsOf: chunk[0..<take])
        }
        // Anything past the limit is read and dropped on the floor.
    }
    return out
}

// MARK: - Socket

/// Connects to a Unix socket without ever blocking indefinitely.
///
/// A plain blocking `connect()` would hang this process — and therefore delay
/// the agent — if the daemon were wedged. We use a non-blocking connect plus
/// `poll()` so the worst case is bounded by `timeoutMilliseconds`.
///
/// The `sun_path` tuple handling is adapted from agentbuddy (MIT); the timeout
/// behaviour is ours.
func connectUnixSocket(path: [UInt8], timeoutMilliseconds: Int32) -> Int32? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard path.count < capacity else { return nil }

    withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
        tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
            for (i, byte) in path.enumerated() { dst[i] = CChar(bitPattern: byte) }
            dst[path.count] = 0
        }
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
    }

    if result != 0 {
        guard errno == EINPROGRESS else { close(fd); return nil }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMilliseconds) > 0 else { close(fd); return nil }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
            close(fd)
            return nil
        }
    }

    // Back to blocking, with a send timeout so a stalled reader cannot pin us.
    _ = fcntl(fd, F_SETFL, flags)
    var timeout = timeval(tv_sec: 0, tv_usec: Int32(timeoutMilliseconds) * 1000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

func writeAll(_ fd: Int32, _ data: [UInt8]) -> Bool {
    var offset = 0
    return data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        while offset < raw.count {
            let n = write(fd, base.advanced(by: offset), raw.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

// MARK: - Spool

/// Writes an event to the on-disk spool so a restarting daemon can replay it.
///
/// Gated on daemon liveness: if CodeStatus was deleted without running the
/// uninstaller, the hook entries survive in the agent's config and would
/// otherwise spool forever, filling the disk of a user who no longer has the
/// app. A stale heartbeat means we drop the event instead.
func writeToSpool(directory: String, heartbeat: String, line: [UInt8], maxAgeSeconds: Int, maxFiles: Int) {
    guard let age = fileAgeSeconds(heartbeat), age <= maxAgeSeconds else { return }
    guard mkdirIfNeeded(directory) else { return }
    guard spoolFileCount(directory) < maxFiles else { return }

    var name: [UInt8] = []
    let clock = wallClock()
    appendInt(clock.seconds, to: &name)
    name.append(UInt8(ascii: "-"))
    appendInt(Int(getpid()), to: &name)
    appendInt(Int(mach_absolute_time() & 0xFFFFFF), to: &name)

    let finalPath = directory + "/" + string(from: name) + ".ndjson"
    let tempPath = finalPath + ".tmp"

    // Atomic publish: a partially written file must never be visible to the
    // daemon under its real name.
    let fd = open(tempPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else { return }
    let wrote = writeAll(fd, line)
    close(fd)
    if wrote {
        if rename(tempPath, finalPath) != 0 { unlink(tempPath) }
    } else {
        unlink(tempPath)
    }
}

func mkdirIfNeeded(_ path: String) -> Bool {
    var info = stat()
    if stat(path, &info) == 0 { return (info.st_mode & S_IFMT) == S_IFDIR }
    return mkdir(path, 0o700) == 0
}

func spoolFileCount(_ path: String) -> Int {
    guard let dir = opendir(path) else { return 0 }
    defer { closedir(dir) }
    var count = 0
    while readdir(dir) != nil { count += 1 }
    return max(0, count - 2) // "." and ".."
}
