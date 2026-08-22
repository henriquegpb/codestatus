// A minimal, allocation-light JSON scanner that extracts *only* allowlisted
// top-level keys.
//
// This deliberately does not import Foundation. Two reasons:
//
//  1. Speed. This binary runs on every tool call of every agent session, so
//     process start time is the dominant cost and Foundation is the largest
//     part of it.
//
//  2. Privacy by construction. A general-purpose parser would materialise the
//     whole payload — prompts, responses, tool inputs and outputs — into memory
//     as a side effect of parsing. This scanner walks past any key that is not
//     on the allowlist without ever copying its bytes, so sensitive values are
//     structurally incapable of reaching the socket, a log, or the spool.

import Darwin

/// Top-level keys we are willing to read. Everything else is skipped in place.
///
/// Note what is absent and must stay absent: `prompt`, `last_assistant_message`,
/// `tool_input`, `tool_output`, `tool_response`, `message`, `error_message`,
/// `transcript_path`.
public let allowedKeys: [StaticString] = [
    "session_id",
    "hook_event_name",
    "cwd",
    "turn_id",
    "prompt_id",
    "tool_use_id",
    "tool_name",
    "notification_type",
    "source",
    "start_reason",
    "end_reason",
    "error_type",
    "permission_mode",
    "model",
]

/// A captured scalar value, kept as raw bytes with just enough type information
/// to re-emit it correctly.
public struct ScannedValue {
    public enum Kind { case string, number, boolean, null }
    public var kind: Kind
    /// Unescaped bytes for strings; literal bytes for numbers and booleans.
    public var bytes: [UInt8]
}

/// Extracts allowlisted top-level keys from a JSON object.
///
/// Tolerant by design: malformed or truncated input yields whatever was parsed
/// before the problem rather than an error, because failing to report an event
/// is worse than reporting a partial one, and the hook must never fail loudly.
public struct JSONScanner {
    private let bytes: [UInt8]
    private var index: Int = 0

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    private var isAtEnd: Bool { index >= bytes.count }
    private var current: UInt8 { bytes[index] }

    private mutating func skipWhitespace() {
        while !isAtEnd {
            switch current {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    /// Reads a JSON string starting at the opening quote, resolving escapes.
    private mutating func readString() -> [UInt8]? {
        guard !isAtEnd, current == UInt8(ascii: "\"") else { return nil }
        index += 1
        var out: [UInt8] = []
        while !isAtEnd {
            let byte = current
            index += 1
            if byte == UInt8(ascii: "\"") { return out }
            guard byte == UInt8(ascii: "\\") else {
                out.append(byte)
                continue
            }
            guard !isAtEnd else { return out }
            let escape = current
            index += 1
            switch escape {
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "u"):
                // Re-emit the escape verbatim; we never interpret payload text,
                // and every value we keep is an identifier or a path.
                out.append(UInt8(ascii: "\\"))
                out.append(UInt8(ascii: "u"))
                for _ in 0..<4 where !isAtEnd {
                    out.append(current)
                    index += 1
                }
            default: out.append(escape)
            }
        }
        return out
    }

    /// Walks past a value without copying it. This is the privacy-critical path:
    /// prompts and tool payloads are consumed here and never retained.
    private mutating func skipValue() {
        skipWhitespace()
        guard !isAtEnd else { return }
        switch current {
        case UInt8(ascii: "\""):
            _ = skipStringInPlace()
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            skipContainer()
        default:
            while !isAtEnd {
                switch current {
                case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
                     0x20, 0x09, 0x0A, 0x0D:
                    return
                default: index += 1
                }
            }
        }
    }

    private mutating func skipStringInPlace() -> Bool {
        guard !isAtEnd, current == UInt8(ascii: "\"") else { return false }
        index += 1
        while !isAtEnd {
            let byte = current
            index += 1
            if byte == UInt8(ascii: "\\") {
                if !isAtEnd { index += 1 }
                continue
            }
            if byte == UInt8(ascii: "\"") { return true }
        }
        return false
    }

    /// Skips a balanced object or array, honouring strings so that braces inside
    /// text cannot unbalance the count.
    private mutating func skipContainer() {
        var depth = 0
        while !isAtEnd {
            let byte = current
            if byte == UInt8(ascii: "\"") {
                _ = skipStringInPlace()
                continue
            }
            index += 1
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth <= 0 { return }
            default:
                break
            }
        }
    }

    private mutating func readValue() -> ScannedValue? {
        skipWhitespace()
        guard !isAtEnd else { return nil }
        switch current {
        case UInt8(ascii: "\""):
            guard let s = readString() else { return nil }
            return ScannedValue(kind: .string, bytes: s)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            // An allowlisted key is never expected to hold a container; skip it
            // rather than descend, so we cannot accidentally capture structure.
            skipContainer()
            return nil
        case UInt8(ascii: "t"), UInt8(ascii: "f"):
            let start = index
            while !isAtEnd, current >= UInt8(ascii: "a"), current <= UInt8(ascii: "z") { index += 1 }
            return ScannedValue(kind: .boolean, bytes: Array(bytes[start..<index]))
        case UInt8(ascii: "n"):
            while !isAtEnd, current >= UInt8(ascii: "a"), current <= UInt8(ascii: "z") { index += 1 }
            return ScannedValue(kind: .null, bytes: [])
        default:
            let start = index
            while !isAtEnd {
                switch current {
                case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
                     0x20, 0x09, 0x0A, 0x0D:
                    return ScannedValue(kind: .number, bytes: Array(bytes[start..<index]))
                default: index += 1
                }
            }
            return ScannedValue(kind: .number, bytes: Array(bytes[start..<index]))
        }
    }

    /// Scans the payload, returning allowlisted key/value pairs in input order.
    public mutating func scan() -> [(key: [UInt8], value: ScannedValue)] {
        var results: [(key: [UInt8], value: ScannedValue)] = []
        skipWhitespace()
        guard !isAtEnd, current == UInt8(ascii: "{") else { return results }
        index += 1

        while !isAtEnd {
            skipWhitespace()
            guard !isAtEnd else { break }
            if current == UInt8(ascii: "}") { break }
            if current == UInt8(ascii: ",") { index += 1; continue }

            guard let key = readString() else { break }
            skipWhitespace()
            guard !isAtEnd, current == UInt8(ascii: ":") else { break }
            index += 1

            if isAllowed(key) {
                if let value = readValue(), value.kind != .null {
                    results.append((key, value))
                }
            } else {
                skipValue()
            }
        }
        return results
    }

    private func isAllowed(_ key: [UInt8]) -> Bool {
        for candidate in allowedKeys {
            if matches(key, candidate) { return true }
        }
        return false
    }

    private func matches(_ key: [UInt8], _ literal: StaticString) -> Bool {
        guard literal.utf8CodeUnitCount == key.count else { return false }
        let buffer = UnsafeBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount)
        for (a, b) in zip(key, buffer) where a != b { return false }
        return true
    }
}
