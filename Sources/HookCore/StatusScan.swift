// Extracts the plan-quota and context-window numbers out of a Claude Code
// status line payload.
//
// A second scanner rather than an extension of `JSONScanner`, because the shape
// of the problem is different: that one answers "which allowlisted top-level
// keys are present", and here the same key name appears three times under
// different parents — `used_percentage` belongs to the five-hour window, the
// seven-day window, and the context window, and confusing them would report a
// full plan as an empty one.
//
// Same two properties as its sibling, for the same reasons: no Foundation, so
// process start stays cheap on a binary the agent invokes on every status line
// render; and values are read only at named paths, so nothing else in the
// payload is ever copied.

import Darwin

/// Everything we are willing to read out of a status line payload.
///
/// Note what is absent and must stay absent: `transcript_path`, `cwd`,
/// `workspace`, `session_name`, and the repo identity. The quota is not a reason
/// to start collecting where someone works.
public struct StatusMetrics {
    public var sessionID: [UInt8]?
    public var modelID: [UInt8]?

    /// Percentage of the rolling five-hour plan window already spent, 0–100.
    public var fiveHourPercent: Double?
    /// Unix epoch seconds at which that window resets.
    public var fiveHourResetsAt: Double?
    public var sevenDayPercent: Double?
    public var sevenDayResetsAt: Double?

    /// Percentage of this session's context window in use, 0–100.
    public var contextPercent: Double?
    public var contextSize: Double?
    public var contextInputTokens: Double?

    public var effortLevel: [UInt8]?

    public init() {}

    /// Whether anything at all was found worth sending.
    ///
    /// `rate_limits` is documented as present only for subscribers, and only
    /// after the first API response — so an empty result is an ordinary state,
    /// not a failure, and must not be reported as a plan at 0%.
    public var isEmpty: Bool {
        fiveHourPercent == nil && sevenDayPercent == nil && contextPercent == nil
    }
}

/// The paths we read, as parent/child pairs.
///
/// Depth two is all the payload needs, and refusing to go deeper keeps the walk
/// small enough to audit by eye.
private let wantedPaths: [(parent: StaticString?, key: StaticString)] = [
    (nil, "session_id"),
    ("model", "id"),
    ("effort", "level"),
    ("context_window", "used_percentage"),
    ("context_window", "context_window_size"),
    ("context_window", "total_input_tokens"),
    ("five_hour", "used_percentage"),
    ("five_hour", "resets_at"),
    ("seven_day", "used_percentage"),
    ("seven_day", "resets_at"),
]

public struct StatusScanner {
    private let bytes: [UInt8]
    private var index = 0
    private var metrics = StatusMetrics()

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public static func scan(_ bytes: [UInt8]) -> StatusMetrics {
        var scanner = StatusScanner(bytes)
        scanner.skipWhitespace()
        guard scanner.peek() == UInt8(ascii: "{") else { return StatusMetrics() }
        scanner.walk(parent: nil, grandparent: nil)
        return scanner.metrics
    }

    /// Walks one object.
    ///
    /// `rate_limits` is transparent: its children `five_hour` and `seven_day`
    /// are addressed directly, so the grandparent is passed through rather than
    /// becoming the parent. That keeps ``wantedPaths`` two deep without losing
    /// the disambiguation the nesting exists to provide.
    private mutating func walk(parent: [UInt8]?, grandparent: [UInt8]?) {
        advance() // '{'
        skipWhitespace()
        if peek() == UInt8(ascii: "}") { advance(); return }

        while !isAtEnd {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") , let key = readString() else { return }
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else { return }
            advance()
            skipWhitespace()

            if peek() == UInt8(ascii: "{") {
                let transparent = matches(key, "rate_limits")
                walk(parent: transparent ? parent : key, grandparent: transparent ? grandparent : parent)
            } else if let slot = slotFor(key: key, parent: parent) {
                capture(into: slot)
            } else {
                skipValue()
            }

            skipWhitespace()
            if peek() == UInt8(ascii: ",") { advance(); continue }
            if peek() == UInt8(ascii: "}") { advance(); return }
            return
        }
    }

    private enum Slot {
        case sessionID, modelID, effort
        case contextPercent, contextSize, contextTokens
        case fiveHourPercent, fiveHourReset
        case sevenDayPercent, sevenDayReset
    }

    private func slotFor(key: [UInt8], parent: [UInt8]?) -> Slot? {
        if parent == nil, matches(key, "session_id") { return .sessionID }
        guard let parent else { return nil }
        if matches(parent, "model"), matches(key, "id") { return .modelID }
        if matches(parent, "effort"), matches(key, "level") { return .effort }
        if matches(parent, "context_window") {
            if matches(key, "used_percentage") { return .contextPercent }
            if matches(key, "context_window_size") { return .contextSize }
            if matches(key, "total_input_tokens") { return .contextTokens }
        }
        if matches(parent, "five_hour") {
            if matches(key, "used_percentage") { return .fiveHourPercent }
            if matches(key, "resets_at") { return .fiveHourReset }
        }
        if matches(parent, "seven_day") {
            if matches(key, "used_percentage") { return .sevenDayPercent }
            if matches(key, "resets_at") { return .sevenDayReset }
        }
        return nil
    }

    private mutating func capture(into slot: Slot) {
        switch slot {
        case .sessionID: metrics.sessionID = readString()
        case .modelID: metrics.modelID = readString()
        case .effort: metrics.effortLevel = readString()
        case .contextPercent: metrics.contextPercent = readNumber()
        case .contextSize: metrics.contextSize = readNumber()
        case .contextTokens: metrics.contextInputTokens = readNumber()
        case .fiveHourPercent: metrics.fiveHourPercent = readNumber()
        case .fiveHourReset: metrics.fiveHourResetsAt = readNumber()
        case .sevenDayPercent: metrics.sevenDayPercent = readNumber()
        case .sevenDayReset: metrics.sevenDayResetsAt = readNumber()
        }
    }

    // MARK: - Primitives

    private var isAtEnd: Bool { index >= bytes.count }
    private func peek() -> UInt8? { isAtEnd ? nil : bytes[index] }
    private mutating func advance() { index += 1 }

    private func matches(_ bytes: [UInt8], _ literal: StaticString) -> Bool {
        guard bytes.count == literal.utf8CodeUnitCount else { return false }
        let pointer = literal.utf8Start
        for i in 0..<bytes.count where bytes[i] != pointer[i] { return false }
        return true
    }

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
        case UInt8(ascii: "{"), UInt8(ascii: "["): skipNested()
        case UInt8(ascii: "\""): skipString()
        default:
            while let byte = peek(), byte != UInt8(ascii: ","), byte != UInt8(ascii: "}"),
                  byte != UInt8(ascii: "]") { advance() }
        }
    }

    /// Iterative, so a deeply nested payload cannot overflow the stack of a
    /// process whose whole job is to stay out of the agent's way.
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
        advance()
        while let byte = peek() {
            if byte == UInt8(ascii: "\\") { advance(); advance(); continue }
            advance()
            if byte == UInt8(ascii: "\"") { return }
        }
    }

    private mutating func readString() -> [UInt8]? {
        guard peek() == UInt8(ascii: "\"") else { skipValue(); return nil }
        advance()
        var out: [UInt8] = []
        while let byte = peek() {
            if byte == UInt8(ascii: "\"") { advance(); return out }
            if byte == UInt8(ascii: "\\") {
                advance()
                guard let escape = peek() else { return out }
                advance()
                // Only ids and enum-ish values are read here, none of which
                // carry escapes worth decoding. Consumed so the walk stays
                // aligned with the bytes.
                if escape == UInt8(ascii: "u") { for _ in 0..<4 where !isAtEnd { advance() } }
                else { out.append(escape) }
                continue
            }
            out.append(byte)
            advance()
        }
        return out
    }

    private mutating func readNumber() -> Double? {
        var out: [UInt8] = []
        while let byte = peek() {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "+"),
                 UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
                out.append(byte); advance()
            default:
                return parseDouble(out)
            }
        }
        return parseDouble(out)
    }

    /// `strtod` rather than `Double(String(...))`: constructing a Swift `String`
    /// here would pull in the very machinery this binary avoids.
    private func parseDouble(_ bytes: [UInt8]) -> Double? {
        guard !bytes.isEmpty else { return nil }
        var terminated = bytes
        terminated.append(0)
        return terminated.withUnsafeBufferPointer { buffer -> Double? in
            guard let base = buffer.baseAddress else { return nil }
            return base.withMemoryRebound(to: CChar.self, capacity: buffer.count) { pointer in
                var end: UnsafeMutablePointer<CChar>?
                let value = strtod(pointer, &end)
                guard let end, end != pointer else { return nil }
                return value
            }
        }
    }
}
