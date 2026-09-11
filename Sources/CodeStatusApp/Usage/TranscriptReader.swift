import CodeStatusCore
import Foundation
import os

/// Reads agent transcripts incrementally, handing each new line to a parser.
///
/// Incremental because a full pass is not cheap: measured on a real machine,
/// 213 files and 83,000 lines took 5.2 seconds. That is fine once at launch and
/// unacceptable on every turn boundary, so each file is remembered by the offset
/// we stopped at and only the bytes appended since are read.
///
/// Nothing here interprets the bytes. Extraction is ``PathScanner``'s job, and
/// keeping the split means the privacy guarantee is a property of one small
/// tested type rather than of this file's discipline.
struct TranscriptReader {

    /// Where we stopped in one file, and what proves it is still the same file.
    private struct Cursor {
        var offset: UInt64
        /// Inode and creation date together catch a file replaced rather than
        /// appended to — a session id reused, or a transcript rewritten wholesale
        /// — which a size comparison alone would read as "nothing new".
        var inode: UInt64
        var createdAt: Date?
    }

    private var cursors: [URL: Cursor] = [:]
    private let logger = Logger(subsystem: "co.codestatus", category: "usage")

    /// Reads everything appended since the last pass under `root`.
    ///
    /// `handle` is called once per complete line. A partial trailing line — the
    /// agent is writing as we read — is left unconsumed, and the offset stays
    /// before it so the next pass sees it whole.
    /// `handle` receives the line and the file it came from — Codex reports a
    /// running total per session rather than per-message deltas, so its caller
    /// has to know which session a reading belongs to in order to replace rather
    /// than accumulate.
    mutating func readNewLines(
        under root: URL,
        matching extension: String = "jsonl",
        handle: (Data, URL) -> Void
    ) {
        let keys: [URLResourceKey] = [.fileSizeKey, .fileResourceIdentifierKey, .creationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in walker where url.pathExtension == `extension` {
            readNewLines(in: url, handle: handle)
        }
    }

    mutating func readNewLines(in url: URL, handle: (Data, URL) -> Void) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64
        else { return }
        let inode = (attributes[.systemFileNumber] as? UInt64) ?? 0
        let createdAt = attributes[.creationDate] as? Date

        var cursor = cursors[url] ?? Cursor(offset: 0, inode: inode, createdAt: createdAt)
        // Replaced or truncated: start over rather than read from an offset that
        // now points into the middle of different content.
        if cursor.inode != inode || cursor.createdAt != createdAt || size < cursor.offset {
            cursor = Cursor(offset: 0, inode: inode, createdAt: createdAt)
        }
        guard size > cursor.offset else {
            cursors[url] = cursor
            return
        }

        guard let handleFile = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handleFile.close() }
        do {
            try handleFile.seek(toOffset: cursor.offset)
            guard let data = try handleFile.readToEnd(), !data.isEmpty else { return }

            // Stop at the last newline. Anything after it is a line still being
            // written, and parsing half a record would either drop usage or,
            // worse, count a truncated number.
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
                cursors[url] = cursor
                return
            }
            let complete = data[data.startIndex...lastNewline]
            for line in complete.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                handle(Data(line), url)
            }
            cursor.offset += UInt64(complete.count)
            cursors[url] = cursor
        } catch {
            logger.error("could not read \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forgets every cursor, so the next pass re-reads from the start.
    mutating func reset() {
        cursors.removeAll()
    }

    var trackedFileCount: Int { cursors.count }
}
