import Foundation

/// Replays the events `codestatus-hook` wrote to disk while nothing was
/// listening on the socket.
///
/// The hook publishes one NDJSON file per event with temp-then-rename, so a file
/// visible under its final `.ndjson` name is complete by construction. Anything
/// still named `.tmp` is a write in flight and must be left alone — the hook owns
/// it, and stealing it would be exactly the interference this project forbids.
///
/// Delivery is at-least-once on purpose: a file is unlinked only after its events
/// have been handed to the caller, so a crash mid-drain re-delivers rather than
/// loses. ``SessionRegistry`` de-duplicates by ``EventID``, which makes the
/// duplicate free and the loss unacceptable.
public struct EventSpool: Sendable {

    /// What one drain is allowed to cost.
    ///
    /// The hook already caps the spool at 512 files, so a backlog beyond that can
    /// only come from a bug or a build with different limits. These bounds exist
    /// so that case degrades into "several drains" instead of a stalled launch.
    public struct Limits: Sendable, Equatable {
        public var maxFiles: Int
        public var maxTotalBytes: Int
        /// A single event line is a few hundred bytes; anything near this is not
        /// something we wrote, and reading it would be the only unbounded
        /// allocation on the startup path.
        public var maxFileBytes: Int

        public init(
            maxFiles: Int = 1024,
            maxTotalBytes: Int = 4 * 1024 * 1024,
            maxFileBytes: Int = 64 * 1024
        ) {
            self.maxFiles = maxFiles
            self.maxTotalBytes = maxTotalBytes
            self.maxFileBytes = maxFileBytes
        }
    }

    /// The outcome of one drain, in enough detail that a diagnostics screen can
    /// explain every file that entered the directory and did not come out.
    ///
    /// Nothing is ever removed silently: a file is either delivered, counted in
    /// one of the failure buckets, or still on disk and counted in ``deferred``.
    public struct DrainReport: Sendable, Equatable {
        /// Events handed to the caller.
        public var delivered = 0
        /// Files that were readable but held nothing this build can decode.
        /// Deleted: a line that fails to decode now will fail forever.
        public var undecodable = 0
        /// Files we could not read as a regular file — a symlink, a directory, or
        /// a permissions problem. Deleted so they cannot occupy the spool forever.
        public var unreadable = 0
        /// Files larger than ``Limits/maxFileBytes``, deleted unread.
        public var oversized = 0
        /// Entries skipped without being touched, including the hook's in-flight
        /// `.tmp` files.
        public var ignored = 0
        public var bytesRead = 0
        /// Files left on disk because this drain hit its caps. They are not lost;
        /// the caller drains again.
        public var deferred = 0

        /// Whether the spool was emptied, or another pass is owed.
        public var isComplete: Bool { deferred == 0 }

        public init() {}
    }

    private static let fileSuffix = ".ndjson"

    private let directory: URL
    private let limits: Limits

    public init(paths: RuntimePaths = RuntimePaths(), limits: Limits = Limits()) {
        directory = paths.spool
        self.limits = limits
    }

    /// Hands every spooled event to `deliver`, oldest first, and cleans up.
    ///
    /// Ordering matters because these events go through the same reducer as live
    /// ones: a `Stop` applied before the `UserPromptSubmit` it answers would be
    /// rejected as out of order and the session would be left mid-turn.
    @discardableResult
    public func drain(deliver: (AgentEvent) -> Void) -> DrainReport {
        var report = DrainReport()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return report
        }

        var pending: [(order: Int, name: String)] = []
        pending.reserveCapacity(names.count)
        for name in names {
            guard name.hasSuffix(Self.fileSuffix) else {
                report.ignored += 1
                continue
            }
            pending.append((Self.timestampPrefix(of: name), name))
        }
        // The name carries unix seconds, so it orders files written by different
        // hook processes without any of them coordinating. Ties fall back to the
        // full name purely so the order is deterministic.
        pending.sort { $0.order == $1.order ? $0.name < $1.name : $0.order < $1.order }

        var processed = 0
        for entry in pending {
            // Checked before the file rather than after, so a drain always makes
            // progress: the budget can be exceeded by at most one file, and a
            // spool that is over budget can never wedge itself.
            guard processed < limits.maxFiles, report.bytesRead < limits.maxTotalBytes else {
                report.deferred += 1
                continue
            }
            processed += 1

            let path = directory.appendingPathComponent(entry.name).path
            switch read(path) {
            case .unreadable:
                report.unreadable += 1
                unlink(path)

            case .oversized:
                report.oversized += 1
                unlink(path)

            case .contents(let data):
                report.bytesRead += data.count
                var buffer = data
                var lines = EventWireDecoder.splitLines(&buffer)
                // The hook writes one line and may or may not terminate it.
                if !buffer.isEmpty { lines.append(buffer) }

                if lines.isEmpty {
                    report.undecodable += 1
                }
                for line in lines {
                    guard let event = try? EventWireDecoder.decode(line: line) else {
                        report.undecodable += 1
                        continue
                    }
                    deliver(event)
                    report.delivered += 1
                }
                // After hand-off, never before: see the at-least-once note above.
                unlink(path)
            }
        }
        return report
    }

    private enum ReadResult {
        case contents(Data)
        case oversized
        case unreadable
    }

    /// Reads one spool file without ever leaving the spool directory.
    ///
    /// `O_NOFOLLOW` plus the `S_IFREG` check is the whole guard: a symlink named
    /// `1-x.ndjson` pointing at a private file would otherwise be read, decoded,
    /// and counted, which is a read of something we have no business touching.
    private func read(_ path: String) -> ReadResult {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return .unreadable }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return .unreadable
        }

        let size = Int(info.st_size)
        guard size <= limits.maxFileBytes else { return .oversized }
        guard size > 0 else { return .contents(Data()) }

        var bytes = [UInt8](repeating: 0, count: size)
        var offset = 0
        while offset < size {
            let n = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(fd, base.advanced(by: offset), size - offset)
            }
            if n <= 0 { break }
            offset += n
        }
        return .contents(Data(bytes[0..<offset]))
    }

    /// The unix-seconds prefix the hook puts in front of every spool file name.
    ///
    /// A name we did not write has no prefix and sorts as zero; it will fail to
    /// decode a moment later anyway, so guessing an order for it is pointless.
    private static func timestampPrefix(of name: String) -> Int {
        Int(name.prefix { $0.isASCII && $0.isNumber }) ?? 0
    }
}
