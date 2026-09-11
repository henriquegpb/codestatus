import Foundation

/// Extracts *only* allowlisted paths from a JSON object, skipping everything
/// else in place.
///
/// This is the privacy guarantee for usage reading, and it is structural rather
/// than a promise. The files this reads — agent transcripts — contain entire
/// conversations: prompts, responses, tool inputs, file contents. A
/// general-purpose parser would materialise all of that into memory as a side
/// effect of finding four integers. This walks past any key that is not on the
/// requested path without ever copying its bytes, so conversation content is
/// structurally incapable of reaching a log, the snapshot, or the screen.
///
/// The same reasoning, and the same shape, as ``HookCore``'s scanner — extended
/// to nested paths because `usage` lives under `message`, where that one only
/// ever needed top-level keys.
public struct PathScanner {

    /// A value we were willing to read.
    public enum Value: Equatable, Sendable {
        case number(Double)
        case string(String)

        public var intValue: Int? {
            if case .number(let value) = self { return Int(value) }
            return nil
        }

        /// Kept separate from ``intValue`` because `used_percent` is fractional
        /// and truncating it reports a quota as less spent than it is.
        public var doubleValue: Double? {
            if case .number(let value) = self { return value }
            return nil
        }

        public var stringValue: String? {
            if case .string(let value) = self { return value }
            return nil
        }
    }

    private let bytes: [UInt8]
    private var index = 0
    /// Paths we want, as component arrays: `["message", "usage", "output_tokens"]`.
    private let wanted: [[String]]
    private var found: [String: Value] = [:]

    private init(bytes: [UInt8], wanted: [[String]]) {
        self.bytes = bytes
        self.wanted = wanted
    }

    /// Reads `paths` (dot-separated) out of one JSON object.
    ///
    /// Tolerant like the hook's scanner: malformed or truncated input yields
    /// whatever was read before the problem rather than throwing. A transcript
    /// being appended to while we read it will hand us a half-written last line,
    /// and that must cost nothing.
    public static func scan(_ data: Data, paths: [String]) -> [String: Value] {
        var scanner = PathScanner(
            bytes: [UInt8](data),
            wanted: paths.map { $0.split(separator: ".").map(String.init) }
        )
        scanner.skipWhitespace()
        guard scanner.peek() == UInt8(ascii: "{") else { return [:] }
        scanner.scanObject(at: [])
        return scanner.found
    }

    // MARK: - Walking

    /// Whether any wanted path continues through `path`, and whether one ends there.
    private func interest(in path: [String]) -> (descend: Bool, capture: Bool) {
        var descend = false, capture = false
        for want in wanted where want.count >= path.count {
            guard Array(want.prefix(path.count)) == path else { continue }
            if want.count == path.count { capture = true } else { descend = true }
        }
        return (descend, capture)
    }

    private mutating func scanObject(at path: [String]) {
        advance() // past '{'
        skipWhitespace()
        if peek() == UInt8(ascii: "}") { advance(); return }

        while !isAtEnd {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else { return }
            guard let key = readString() else { return }
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else { return }
            advance()
            skipWhitespace()

            let childPath = path + [key]
            let (descend, capture) = interest(in: childPath)

            if capture {
                captureValue(at: childPath)
            } else if descend, peek() == UInt8(ascii: "{") {
                scanObject(at: childPath)
            } else {
                // The whole point: not on any wanted path, so its bytes are
                // stepped over and never copied.
                skipValue()
            }

            skipWhitespace()
            if peek() == UInt8(ascii: ",") { advance(); continue }
            if peek() == UInt8(ascii: "}") { advance(); return }
            return
        }
    }

    private mutating func captureValue(at path: [String]) {
        let key = path.joined(separator: ".")
        guard let byte = peek() else { return }
        switch byte {
        case UInt8(ascii: "\""):
            if let value = readString() { found[key] = .string(value) }
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            if let value = readNumber() { found[key] = .number(value) }
        default:
            // A wanted path landing on an object, array, or literal is not a
            // value we can use. Skipped rather than descended: capturing it
            // would mean copying whatever it contains.
            skipValue()
        }
    }

    // MARK: - Primitives

    private var isAtEnd: Bool { index >= bytes.count }
    private func peek() -> UInt8? { isAtEnd ? nil : bytes[index] }
    private mutating func advance() { index += 1 }

    private mutating func skipWhitespace() {
        while let byte = peek() {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D: advance()
            default: return
            }
        }
    }

    /// Steps over one value of any type without copying it.
    private mutating func skipValue() {
        switch peek() {
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            skipNested()
        case UInt8(ascii: "\""):
            skipString()
        default:
            while let byte = peek(), byte != UInt8(ascii: ","), byte != UInt8(ascii: "}"),
                  byte != UInt8(ascii: "]") {
                advance()
            }
        }
    }

    /// Skips a balanced object or array.
    ///
    /// Iterative rather than recursive: a transcript entry can nest arbitrarily
    /// deep, and recursion here would let a pathological file overflow the stack
    /// of a process whose job is to stay out of the way.
    private mutating func skipNested() {
        var depth = 0
        repeat {
            guard let byte = peek() else { return }
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1; advance()
            case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1; advance()
            case UInt8(ascii: "\""): skipString()
            default: advance()
            }
        } while depth > 0 && !isAtEnd
    }

    private mutating func skipString() {
        advance() // opening quote
        while let byte = peek() {
            if byte == UInt8(ascii: "\\") { advance(); advance(); continue }
            advance()
            if byte == UInt8(ascii: "\"") { return }
        }
    }

    private mutating func readString() -> String? {
        guard peek() == UInt8(ascii: "\"") else { return nil }
        advance()
        var out: [UInt8] = []
        while let byte = peek() {
            if byte == UInt8(ascii: "\"") { advance(); return String(decoding: out, as: UTF8.self) }
            if byte == UInt8(ascii: "\\") {
                advance()
                guard let escape = peek() else { return nil }
                advance()
                switch escape {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    // Only ids and model names are read as strings here, and
                    // neither contains escapes worth decoding. Consumed so the
                    // scan stays aligned; the value is left as-is.
                    for _ in 0..<4 where !isAtEnd { advance() }
                default: out.append(escape)
                }
                continue
            }
            out.append(byte)
            advance()
        }
        return nil
    }

    private mutating func readNumber() -> Double? {
        var out: [UInt8] = []
        while let byte = peek() {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "+"),
                 UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
                out.append(byte)
                advance()
            default:
                return Double(String(decoding: out, as: UTF8.self))
            }
        }
        return Double(String(decoding: out, as: UTF8.self))
    }
}
