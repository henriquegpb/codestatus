import Foundation

/// A JSON editor that rewrites only the bytes it has to.
///
/// The files we edit — `~/.claude/settings.json` and `~/.codex/hooks.json` —
/// belong to the user and are shared with the CLI and the VS Code extension.
/// Prior art round-trips them through `JSONSerialization`, which reorders keys
/// and reformats the entire document (one such tool writes back with
/// `.sortedKeys`, permanently destroying the author's layout). That is a
/// destructive side effect of an install step, so it is forbidden here.
///
/// Instead this type tokenises the source, records the source byte range of
/// every value, and performs each edit as a text splice. Every region we did not
/// deliberately touch is byte-for-byte identical afterwards: comments cannot
/// exist in JSON, but odd whitespace, key order, CRLF line endings, and the
/// exact escaping of every string all survive.
///
/// Edits re-parse the whole document rather than adjusting cached offsets. Agent
/// config files are a few kilobytes, so the cost is irrelevant, and it removes
/// the entire class of bug where a stale range points into text that moved.
public struct JSONSurgeon: Sendable {

    /// Every way this can refuse to touch a file. Refusing is always correct:
    /// a config we cannot model exactly is a config we must not rewrite.
    public enum Failure: Error, Equatable {
        case documentTooLarge(bytes: Int)
        case unexpectedEnd
        case unexpectedByte(offset: Int)
        case trailingContent(offset: Int)
        case invalidNumber(offset: Int)
        case invalidEscape(offset: Int)
        case tooDeeplyNested(offset: Int)
        case rootIsNotAnObject
        case notAnObject(path: String)
        case notAnArray(path: String)
        case elementIsNotValidJSON
    }

    /// The layout conventions detected in the source, used only for text we add.
    public struct Style: Sendable, Equatable {
        /// One level of indentation: some number of spaces, or a single tab.
        public var indentUnit: String
        /// `\r\n` when the file already uses CRLF, so we do not mix endings.
        public var newline: String
        /// Whether containers in this file are broken across lines at all.
        public var isMultiline: Bool
        public var spaceAfterColon: Bool
        public var spaceAfterComma: Bool
    }

    /// 8 MiB. Orders of magnitude above any real agent config, and low enough
    /// that a pathological file cannot make us allocate without bound.
    public static let maximumDocumentBytes = 8 * 1024 * 1024

    private var bytes: [UInt8]
    private var root: JSONNode

    public private(set) var style: Style
    /// True when the source was empty or whitespace only, so we started from `{}`.
    /// Callers use this to distinguish "created" from "edited" for backups.
    public private(set) var wasSynthesized: Bool

    public init(_ source: String) throws {
        var raw = Array(source.utf8)
        guard raw.count <= Self.maximumDocumentBytes else {
            throw Failure.documentTooLarge(bytes: raw.count)
        }

        // An empty settings file is legal on disk and means "no settings", but
        // it is not parseable JSON. Treat it as the empty object it stands for.
        let synthesized = raw.allSatisfy(Self.isWhitespace)
        if synthesized { raw = Array("{}".utf8) }

        var parser = JSONParser(raw)
        let node = try parser.parseDocument()
        guard case .object = node.kind else { throw Failure.rootIsNotAnObject }

        bytes = raw
        self.root = node
        wasSynthesized = synthesized
        style = Self.detectStyle(in: raw, root: node, synthesized: synthesized)
    }

    /// The current document text. Identical to the input until an edit succeeds.
    public var text: String { String(decoding: bytes, as: UTF8.self) }

    // MARK: - Reading

    /// The raw source text of each element of the array at `path`, or nil when
    /// `path` is absent or is not an array.
    ///
    /// Raw text rather than a decoded model, because callers match on entries
    /// they may not fully understand and must be able to hand the exact original
    /// bytes back to ``removeFromArray(atPath:where:)``.
    public func arrayElements(atPath path: [String]) -> [String]? {
        guard let node = node(atPath: path), case .array(let elements) = node.kind else { return nil }
        return elements.map { text(of: $0.range) }
    }

    /// The decoded string at `path`, with escapes resolved.
    public func string(atPath path: [String]) -> String? {
        guard let node = node(atPath: path), case .string(let value) = node.kind else { return nil }
        return value
    }

    public func contains(path: [String]) -> Bool { node(atPath: path) != nil }

    /// Whether `path` is an object or array with no members. An empty path asks
    /// about the document root.
    public func isEmptyContainer(atPath path: [String]) -> Bool {
        switch node(atPath: path)?.kind {
        case .object(let members): return members.isEmpty
        case .array(let elements): return elements.isEmpty
        default: return false
        }
    }

    // MARK: - Editing

    /// Appends `element` to the array at `path`, creating the path if needed.
    ///
    /// `element` is parsed and re-rendered using the indentation, line ending,
    /// and spacing detected in the target file, so the result reads as though
    /// the user had typed it. Its key order and the exact text of every scalar
    /// are preserved from the caller's string.
    public mutating func appendToArray(atPath path: [String], element: String) throws {
        try ensurePath(path, terminalIsArray: true)

        guard let array = node(atPath: path), case .array(let elements) = array.kind else {
            throw Failure.notAnArray(path: path.joined(separator: "."))
        }

        // A container already broken across lines stays that way; a minified
        // file stays minified. Only a container we are creating from nothing
        // falls back to the document's prevailing style.
        let multiline = text(of: array.range).utf8.contains(0x0A)
            || (elements.isEmpty && style.isMultiline)
        let closingPrefix = lineIndent(at: array.range.lowerBound)
        var elementPrefix = closingPrefix + style.indentUnit
        if let last = elements.last, startsLine(at: last.range.lowerBound) {
            // Match the user's own elements exactly, even if they indent oddly.
            elementPrefix = lineIndent(at: last.range.lowerBound)
        }

        let rendered = try render(element: element, prefix: elementPrefix, multiline: multiline)

        if let last = elements.last {
            let separator = multiline
                ? "," + style.newline + elementPrefix
                : "," + (style.spaceAfterComma ? " " : "")
            try splice(last.range.upperBound..<last.range.upperBound, with: separator + rendered)
        } else {
            let interior = (array.range.lowerBound + 1)..<(array.range.upperBound - 1)
            let replacement = multiline
                ? style.newline + elementPrefix + rendered + style.newline + closingPrefix
                : rendered
            try splice(interior, with: replacement)
        }
    }

    /// Removes every element of the array at `path` for which `predicate` holds,
    /// as a pure text splice, and returns how many were removed.
    ///
    /// A missing path is not an error: nothing of ours can be in a place that
    /// does not exist, which is exactly what uninstall needs.
    @discardableResult
    public mutating func removeFromArray(
        atPath path: [String],
        where predicate: (String) -> Bool
    ) throws -> Int {
        var removed = 0
        while true {
            guard let array = node(atPath: path) else { return removed }
            guard case .array(let elements) = array.kind else {
                throw Failure.notAnArray(path: path.joined(separator: "."))
            }
            guard let index = elements.firstIndex(where: { predicate(text(of: $0.range)) }) else {
                return removed
            }
            let ranges = elements.map(\.range)
            try splice(removalRange(at: index, in: ranges, container: array), with: "")
            removed += 1
        }
    }

    /// Removes the key at `path` from its parent object. Returns false when it
    /// was already absent.
    ///
    /// When the parent carries the key more than once it is the *last*
    /// occurrence that goes, matching ``node(atPath:)`` and therefore the agent's
    /// own parser. Taking the first instead would delete a member nobody had
    /// looked at: uninstall asks ``isEmptyContainer(atPath:)`` whether the
    /// container it created is now empty and removes it if so, and if the two
    /// resolved different duplicates it would answer for the empty one and
    /// delete the user's populated one.
    @discardableResult
    public mutating func removeKey(atPath path: [String]) throws -> Bool {
        guard let key = path.last else { return false }
        let parentPath = Array(path.dropLast())
        guard let parent = node(atPath: parentPath), case .object(let members) = parent.kind else {
            return false
        }
        guard let index = members.lastIndex(where: { $0.key == key }) else { return false }
        let ranges = members.map(\.range)
        try splice(removalRange(at: index, in: ranges, container: parent), with: "")
        return true
    }

    /// Quotes and escapes a Swift string as a JSON string literal.
    ///
    /// Exposed because callers building an element — an absolute path to our
    /// hook binary, which may contain a quote or a backslash on a hostile home
    /// directory name — must not hand-roll this.
    public static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - Path creation

    /// Walks `path`, creating any missing object along the way and the terminal
    /// container at the end. Throws rather than replacing a value of the wrong
    /// shape — a user whose `hooks` is a string has a broken config, and
    /// silently overwriting it would lose their data.
    private mutating func ensurePath(_ path: [String], terminalIsArray: Bool) throws {
        guard !path.isEmpty else { throw Failure.rootIsNotAnObject }
        for depth in 1...path.count {
            let subPath = Array(path.prefix(depth))
            let isTerminal = depth == path.count

            if let existing = node(atPath: subPath) {
                switch existing.kind {
                case .array where isTerminal && terminalIsArray: continue
                case .object where !isTerminal: continue
                default:
                    throw isTerminal && terminalIsArray
                        ? Failure.notAnArray(path: subPath.joined(separator: "."))
                        : Failure.notAnObject(path: subPath.joined(separator: "."))
                }
            }

            let parentPath = Array(subPath.dropLast())
            guard let parent = node(atPath: parentPath), case .object(let members) = parent.kind else {
                throw Failure.notAnObject(path: parentPath.joined(separator: "."))
            }
            try insertMember(
                key: path[depth - 1],
                valueText: isTerminal && terminalIsArray ? "[]" : "{}",
                into: parent,
                members: members
            )
        }
    }

    private mutating func insertMember(
        key: String,
        valueText: String,
        into object: JSONNode,
        members: [JSONMember]
    ) throws {
        let multiline = text(of: object.range).utf8.contains(0x0A)
            || (members.isEmpty && style.isMultiline)
        let closingPrefix = lineIndent(at: object.range.lowerBound)
        var memberPrefix = closingPrefix + style.indentUnit
        if let last = members.last, startsLine(at: last.range.lowerBound) {
            memberPrefix = lineIndent(at: last.range.lowerBound)
        }

        let entry = Self.quoted(key) + (style.spaceAfterColon ? ": " : ":") + valueText

        if let last = members.last {
            let separator = multiline
                ? "," + style.newline + memberPrefix
                : "," + (style.spaceAfterComma ? " " : "")
            try splice(last.range.upperBound..<last.range.upperBound, with: separator + entry)
        } else {
            let interior = (object.range.lowerBound + 1)..<(object.range.upperBound - 1)
            let replacement = multiline
                ? style.newline + memberPrefix + entry + style.newline + closingPrefix
                : entry
            try splice(interior, with: replacement)
        }
    }

    // MARK: - Splicing

    /// Replaces a source range and re-parses.
    ///
    /// If a splice ever produced invalid JSON the re-parse throws here, leaving
    /// the in-memory document unusable — but nothing has been written to disk,
    /// because callers only persist ``text`` after every edit has succeeded.
    private mutating func splice(_ range: Range<Int>, with replacement: String) throws {
        bytes.replaceSubrange(range, with: Array(replacement.utf8))
        var parser = JSONParser(bytes)
        let node = try parser.parseDocument()
        guard case .object = node.kind else { throw Failure.rootIsNotAnObject }
        root = node
    }

    /// The span to cut so that removing one child leaves the container's layout
    /// intact: the separating comma goes with it, and the surviving neighbour
    /// slides into the indentation that is already there.
    private func removalRange(
        at index: Int,
        in ranges: [Range<Int>],
        container: JSONNode
    ) -> Range<Int> {
        if ranges.count == 1 {
            return (container.range.lowerBound + 1)..<(container.range.upperBound - 1)
        }
        if index < ranges.count - 1 {
            return ranges[index].lowerBound..<ranges[index + 1].lowerBound
        }
        return ranges[index - 1].upperBound..<ranges[index].upperBound
    }

    // MARK: - Rendering

    private func render(element: String, prefix: String, multiline: Bool) throws -> String {
        let source = Array(element.utf8)
        var parser = JSONParser(source)
        guard let node = try? parser.parseDocument() else { throw Failure.elementIsNotValidJSON }
        return render(node, source: source, prefix: prefix, multiline: multiline)
    }

    private func render(
        _ node: JSONNode,
        source: [UInt8],
        prefix: String,
        multiline: Bool
    ) -> String {
        let colon = style.spaceAfterColon ? ": " : ":"
        switch node.kind {
        case .object(let members):
            if members.isEmpty { return "{}" }
            let inner = prefix + style.indentUnit
            if multiline {
                let parts = members.map { member in
                    inner + Self.slice(source, member.keyRange) + colon
                        + render(member.value, source: source, prefix: inner, multiline: true)
                }
                return "{" + style.newline
                    + parts.joined(separator: "," + style.newline)
                    + style.newline + prefix + "}"
            }
            let parts = members.map { member in
                Self.slice(source, member.keyRange) + colon
                    + render(member.value, source: source, prefix: prefix, multiline: false)
            }
            return "{" + parts.joined(separator: style.spaceAfterComma ? ", " : ",") + "}"

        case .array(let elements):
            if elements.isEmpty { return "[]" }
            // An array of scalars stays on one line even inside a pretty-printed
            // document; that is how people write `"args": ["--provider", "codex"]`,
            // and exploding it adds four lines of noise to the user's config.
            let hasContainer = elements.contains { element in
                switch element.kind {
                case .object, .array: return true
                default: return false
                }
            }
            if multiline, hasContainer {
                let inner = prefix + style.indentUnit
                let parts = elements.map {
                    inner + render($0, source: source, prefix: inner, multiline: true)
                }
                return "[" + style.newline
                    + parts.joined(separator: "," + style.newline)
                    + style.newline + prefix + "]"
            }
            let parts = elements.map { render($0, source: source, prefix: prefix, multiline: false) }
            return "[" + parts.joined(separator: style.spaceAfterComma ? ", " : ",") + "]"

        case .string, .number, .boolean, .null:
            // Verbatim: a number's exact spelling and a string's exact escaping
            // are the caller's to decide, not ours to normalise.
            return Self.slice(source, node.range)
        }
    }

    // MARK: - Source helpers

    private func node(atPath path: [String]) -> JSONNode? {
        var current = root
        for key in path {
            guard case .object(let members) = current.kind,
                  // `last`, not `first`. JSON permits duplicate keys, and the
                  // parsers that matter here resolve them to the last
                  // occurrence: JavaScript's `JSON.parse`, which is what Claude
                  // Code's Node binary uses, and serde_json, which is what Codex
                  // uses. Both were checked rather than assumed.
                  //
                  // Note this is the opposite of Foundation's
                  // `JSONSerialization`, which keeps the *first* — so a test
                  // that validates through Apple's parser will assert the wrong
                  // thing. Editing the first occurrence would write our hooks
                  // into the object the agent throws away, while `isInstalled()`
                  // reported success.
                  let member = members.last(where: { $0.key == key }) else { return nil }
            current = member.value
        }
        return current
    }

    private func text(of range: Range<Int>) -> String { Self.slice(bytes, range) }

    private static func slice(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    /// The leading whitespace of the line containing `offset`.
    private func lineIndent(at offset: Int) -> String {
        var start = offset
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < offset, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// Whether only whitespace separates `offset` from the start of its line.
    private func startsLine(at offset: Int) -> Bool {
        var index = offset
        while index > 0 {
            let byte = bytes[index - 1]
            if byte == 0x0A { return true }
            guard byte == 0x20 || byte == 0x09 else { return false }
            index -= 1
        }
        return true
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    // MARK: - Style detection

    private static func detectStyle(in bytes: [UInt8], root: JSONNode, synthesized: Bool) -> Style {
        var usesTabs = false
        var widths: Set<Int> = []
        var index = 0
        var atLineStart = true
        var run = 0
        var runIsTabs = false
        while index < bytes.count {
            let byte = bytes[index]
            if atLineStart {
                if byte == 0x09 { runIsTabs = true; run += 1; index += 1; continue }
                if byte == 0x20 { run += 1; index += 1; continue }
                if byte != 0x0A && byte != 0x0D {
                    // A line with content: its indent is a real sample.
                    if run > 0 {
                        if runIsTabs { usesTabs = true } else { widths.insert(run) }
                    }
                }
                atLineStart = false
                run = 0
                runIsTabs = false
            }
            if byte == 0x0A { atLineStart = true; run = 0; runIsTabs = false }
            index += 1
        }

        // The smallest indent seen is one level; four-space files sample {4, 8},
        // two-space files sample {2, 4, 6}. Two spaces is the JSON default when
        // there is nothing to learn from.
        let indentUnit = usesTabs ? "\t" : String(repeating: " ", count: widths.min() ?? 2)

        var newline = "\n"
        for index in 1..<max(bytes.count, 1) where bytes[index] == 0x0A && bytes[index - 1] == 0x0D {
            newline = "\r\n"
            break
        }

        var isMultiline = synthesized
        var spaceAfterColon = true
        var spaceAfterComma = true
        if case .object(let members) = root.kind {
            isMultiline = isMultiline || bytes[root.range].contains(0x0A)
            if let first = members.first {
                spaceAfterColon = bytes[first.keyRange.upperBound..<first.value.range.lowerBound]
                    .contains(0x20)
            }
            if members.count >= 2 {
                let gap = members[0].range.upperBound..<members[1].range.lowerBound
                spaceAfterComma = bytes[gap].contains(0x20) || bytes[gap].contains(0x0A)
            }
        }

        return Style(
            indentUnit: indentUnit,
            newline: newline,
            isMultiline: isMultiline,
            spaceAfterColon: spaceAfterColon,
            spaceAfterComma: spaceAfterComma
        )
    }
}

// MARK: - Parse tree

/// A parsed value plus the exact source range it occupies. The range is the
/// whole point: it is what lets every edit be a splice instead of a rewrite.
private struct JSONNode: Sendable {
    enum Kind: Sendable {
        case object([JSONMember])
        case array([JSONNode])
        /// Carries the decoded value; the source spelling stays in `range`.
        case string(String)
        case number
        case boolean
        case null
    }
    var kind: Kind
    var range: Range<Int>
}

private struct JSONMember: Sendable {
    var key: String
    /// Includes the quotes, so it can be re-emitted verbatim.
    var keyRange: Range<Int>
    var value: JSONNode
    /// From the opening quote of the key through the end of the value.
    var range: Range<Int>
}

/// A strict recursive-descent JSON parser that records source ranges.
///
/// Strict on structure — a trailing comma, an unquoted key, or trailing content
/// is rejected — because the alternative is splicing into a file we have
/// misunderstood. Lenient on one point only: raw control characters inside
/// strings are accepted, since a file the agent already reads must not become
/// un-installable over a byte we would never touch.
private struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0

    /// Deep enough for any real config, shallow enough that a crafted file
    /// cannot exhaust the stack through recursion.
    private static let maximumDepth = 64

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func parseDocument() throws -> JSONNode {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw JSONSurgeon.Failure.trailingContent(offset: index) }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> JSONNode {
        guard depth < Self.maximumDepth else {
            throw JSONSurgeon.Failure.tooDeeplyNested(offset: index)
        }
        guard index < bytes.count else { throw JSONSurgeon.Failure.unexpectedEnd }
        let start = index

        switch bytes[index] {
        case UInt8(ascii: "{"):
            index += 1
            var members: [JSONMember] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return JSONNode(kind: .object(members), range: start..<index)
            }
            while true {
                skipWhitespace()
                let keyStart = index
                let key = try parseStringLiteral()
                let keyRange = keyStart..<index
                skipWhitespace()
                guard index < bytes.count else { throw JSONSurgeon.Failure.unexpectedEnd }
                guard bytes[index] == UInt8(ascii: ":") else {
                    throw JSONSurgeon.Failure.unexpectedByte(offset: index)
                }
                index += 1
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                members.append(
                    JSONMember(
                        key: key,
                        keyRange: keyRange,
                        value: value,
                        range: keyStart..<value.range.upperBound
                    )
                )
                skipWhitespace()
                guard index < bytes.count else { throw JSONSurgeon.Failure.unexpectedEnd }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; break }
                throw JSONSurgeon.Failure.unexpectedByte(offset: index)
            }
            return JSONNode(kind: .object(members), range: start..<index)

        case UInt8(ascii: "["):
            index += 1
            var elements: [JSONNode] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return JSONNode(kind: .array(elements), range: start..<index)
            }
            while true {
                skipWhitespace()
                elements.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw JSONSurgeon.Failure.unexpectedEnd }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; break }
                throw JSONSurgeon.Failure.unexpectedByte(offset: index)
            }
            return JSONNode(kind: .array(elements), range: start..<index)

        case UInt8(ascii: "\""):
            let value = try parseStringLiteral()
            return JSONNode(kind: .string(value), range: start..<index)

        case UInt8(ascii: "t"):
            try expect("true")
            return JSONNode(kind: .boolean, range: start..<index)

        case UInt8(ascii: "f"):
            try expect("false")
            return JSONNode(kind: .boolean, range: start..<index)

        case UInt8(ascii: "n"):
            try expect("null")
            return JSONNode(kind: .null, range: start..<index)

        default:
            try parseNumber()
            return JSONNode(kind: .number, range: start..<index)
        }
    }

    private mutating func expect(_ literal: StaticString) throws {
        let start = index
        let buffer = UnsafeBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount)
        for expected in buffer {
            guard index < bytes.count else { throw JSONSurgeon.Failure.unexpectedEnd }
            guard bytes[index] == expected else {
                throw JSONSurgeon.Failure.unexpectedByte(offset: start)
            }
            index += 1
        }
    }

    private mutating func parseNumber() throws {
        let start = index
        guard index < bytes.count else { throw JSONSurgeon.Failure.unexpectedEnd }
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count, isDigit(bytes[index]) else {
            throw JSONSurgeon.Failure.unexpectedByte(offset: start)
        }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else {
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else {
                throw JSONSurgeon.Failure.invalidNumber(offset: start)
            }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count,
               bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index < bytes.count, isDigit(bytes[index]) else {
                throw JSONSurgeon.Failure.invalidNumber(offset: start)
            }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        // `01` and `1x` are not JSON; catching them here stops us treating the
        // rest of the file as something we understand.
        if index < bytes.count, isDigit(bytes[index]) || isIdentifier(bytes[index]) {
            throw JSONSurgeon.Failure.invalidNumber(offset: start)
        }
    }

    private mutating func parseStringLiteral() throws -> String {
        guard index < bytes.count else { throw JSONSurgeon.Failure.unexpectedEnd }
        guard bytes[index] == UInt8(ascii: "\"") else {
            throw JSONSurgeon.Failure.unexpectedByte(offset: index)
        }
        index += 1
        var out: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
            guard byte == UInt8(ascii: "\\") else { out.append(byte); continue }
            guard index < bytes.count else { throw JSONSurgeon.Failure.unexpectedEnd }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"): out.append(contentsOf: Array(String(try parseEscapedScalar()).utf8))
            default: throw JSONSurgeon.Failure.invalidEscape(offset: index - 1)
            }
        }
        throw JSONSurgeon.Failure.unexpectedEnd
    }

    /// Decodes a `\u` escape, joining a surrogate pair when one follows.
    ///
    /// A lone surrogate decodes to U+FFFD. That only affects the *decoded*
    /// string we compare against; the source bytes are re-emitted verbatim, so
    /// nothing in the user's file changes because of it.
    private mutating func parseEscapedScalar() throws -> Unicode.Scalar {
        let first = try parseHexQuad()
        if (0xD800...0xDBFF).contains(first),
           index + 1 < bytes.count,
           bytes[index] == UInt8(ascii: "\\"),
           bytes[index + 1] == UInt8(ascii: "u") {
            let resume = index
            index += 2
            let second = try parseHexQuad()
            if (0xDC00...0xDFFF).contains(second) {
                let value = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                return Unicode.Scalar(value) ?? Unicode.Scalar(0xFFFD)!
            }
            index = resume
        }
        return Unicode.Scalar(first) ?? Unicode.Scalar(0xFFFD)!
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard index < bytes.count else { throw JSONSurgeon.Failure.unexpectedEnd }
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A")) + 10
            default: throw JSONSurgeon.Failure.invalidEscape(offset: index)
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private func isIdentifier(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: ".")
    }
}
