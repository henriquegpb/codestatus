// Writes the scanned status line metrics where the app can find them, and
// renders the one-line summary.
//
// A file per session rather than the event socket. The socket carries the state
// machine's vocabulary, and these are neither events nor state transitions —
// they are a gauge that the agent overwrites on every render. Putting them on
// the wire would mean a new event kind that the reducer must then be taught to
// ignore, and a reading would be lost whenever the app happened to be down.
// A file is last-writer-wins, which is exactly the semantics of a gauge.

import Darwin

/// Serialises the metrics as a small JSON object.
///
/// Hand-rolled rather than via a library for the same reason the rest of this
/// target is: no Foundation, because this runs on every status line render.
public func buildStatusMetricsJSON(_ metrics: StatusMetrics) -> [UInt8] {
    var out: [UInt8] = []
    out.append(UInt8(ascii: "{"))
    var first = true

    func comma() {
        if !first { out.append(UInt8(ascii: ",")) }
        first = false
    }

    func appendKey(_ key: StaticString) {
        comma()
        out.append(UInt8(ascii: "\""))
        let pointer = key.utf8Start
        for i in 0..<key.utf8CodeUnitCount { out.append(pointer[i]) }
        out.append(contentsOf: [UInt8(ascii: "\""), UInt8(ascii: ":")])
    }

    func appendString(_ key: StaticString, _ value: [UInt8]?) {
        guard let value else { return }
        appendKey(key)
        out.append(UInt8(ascii: "\""))
        for byte in value {
            // Ids and enum values, so the only escapes that can arise are these.
            switch byte {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"):
                out.append(UInt8(ascii: "\\")); out.append(byte)
            case 0x00...0x1F:
                continue
            default:
                out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    func appendNumber(_ key: StaticString, _ value: Double?) {
        guard let value, value.isFinite else { return }
        appendKey(key)
        var buffer = [CChar](repeating: 0, count: 32)
        _ = buffer.withUnsafeMutableBufferPointer { pointer in
            snprintf(ptr: pointer.baseAddress!, 32, "%.4f", value)
        }
        for character in buffer where character != 0 { out.append(UInt8(bitPattern: character)) }
    }

    appendString("session_id", metrics.sessionID)
    appendString("model", metrics.modelID)
    appendString("effort", metrics.effortLevel)
    appendNumber("five_hour_percent", metrics.fiveHourPercent)
    appendNumber("five_hour_resets_at", metrics.fiveHourResetsAt)
    appendNumber("seven_day_percent", metrics.sevenDayPercent)
    appendNumber("seven_day_resets_at", metrics.sevenDayResetsAt)
    appendNumber("context_percent", metrics.contextPercent)
    appendNumber("context_size", metrics.contextSize)
    appendNumber("context_input_tokens", metrics.contextInputTokens)
    appendNumber("observed_at", Double(time(nil)))

    out.append(UInt8(ascii: "}"))
    return out
}

/// Writes one session's metrics, replacing whatever was there.
///
/// Written to a temporary name and renamed, so a reader never sees a half-file.
/// Every failure is silent: a monitoring tool has no business turning its own
/// outage into a broken status line.
public func writeStatusMetrics(directory: String, metrics: StatusMetrics) {
    guard let sessionID = metrics.sessionID, !sessionID.isEmpty else { return }
    _ = mkdirRecursive(directory)

    var name = directory + "/"
    for byte in sessionID {
        // The session id becomes a file name, so anything that could escape the
        // directory is replaced rather than trusted.
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            name.append(Character(UnicodeScalar(byte)))
        default:
            name.append("_")
        }
    }
    let final = name + ".json"
    let temporary = name + ".tmp"

    let bytes = buildStatusMetricsJSON(metrics)
    let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else { return }
    _ = bytes.withUnsafeBufferPointer { buffer -> Int in
        guard let base = buffer.baseAddress else { return 0 }
        return write(fd, base, buffer.count)
    }
    close(fd)
    if rename(temporary, final) != 0 { unlink(temporary) }
}

/// Creates a directory and its parents, tolerating ones that already exist.
private func mkdirRecursive(_ path: String) -> Bool {
    var built = ""
    for component in path.split(separator: "/") {
        built += "/" + component
        if mkdir(built, 0o700) != 0 && errno != EEXIST { return false }
    }
    return true
}

/// Prints the compact summary that becomes the status line.
///
/// Only drawn when the user had no status line of their own — see the chaining
/// path in the hook. Percentages are rounded down deliberately: a plan reported
/// as less spent than it is would be the one error that matters here.
public func writeStatusSummary(_ metrics: StatusMetrics) {
    var parts: [String] = []
    if let five = metrics.fiveHourPercent { parts.append("5h " + percent(five)) }
    if let seven = metrics.sevenDayPercent { parts.append("7d " + percent(seven)) }
    if let context = metrics.contextPercent { parts.append("ctx " + percent(context)) }
    guard !parts.isEmpty else { return }
    var line = parts.joined(separator: " · ")
    line.append("\n")
    _ = line.withCString { pointer in write(1, pointer, strlen(pointer)) }
}

private func percent(_ value: Double) -> String {
    let clamped = value < 0 ? 0 : (value > 100 ? 100 : value)
    return "\(Int(clamped))%"
}
