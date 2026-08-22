// Builds the NDJSON line the hook sends to the daemon.
//
// Kept separate from the syscall layer so the privacy guarantee — that only
// allowlisted metadata can appear on the wire — is a unit-testable property of
// a pure function rather than something you have to spawn a process to check.

import Darwin

/// The envelope and enrichment the hook adds to the scanned payload fields.
public struct EventEnvelope {
    public var version: Int
    public var provider: String
    public var eventID: [UInt8]
    public var timestampSeconds: Int
    public var timestampMicroseconds: Int
    public var parentPID: Int
    public var termProgram: [UInt8]?
    public var termSessionID: [UInt8]?

    public init(
        version: Int = 1,
        provider: String,
        eventID: [UInt8],
        timestampSeconds: Int,
        timestampMicroseconds: Int,
        parentPID: Int,
        termProgram: [UInt8]? = nil,
        termSessionID: [UInt8]? = nil
    ) {
        self.version = version
        self.provider = provider
        self.eventID = eventID
        self.timestampSeconds = timestampSeconds
        self.timestampMicroseconds = timestampMicroseconds
        self.parentPID = parentPID
        self.termProgram = termProgram
        self.termSessionID = termSessionID
    }
}

/// Serialises one event line, newline included.
///
/// `fields` must come from ``JSONScanner/scan()``, which only ever yields
/// allowlisted keys. Nothing here re-reads the original payload, so there is no
/// path by which prompt or tool content could reach the output.
public func buildEventLine(
    envelope: EventEnvelope,
    fields: [(key: [UInt8], value: ScannedValue)]
) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(512)
    out.append(UInt8(ascii: "{"))

    var isFirst = true
    func separate(into out: inout [UInt8]) {
        if isFirst { isFirst = false } else { out.append(UInt8(ascii: ",")) }
    }
    func appendKey(_ key: String, into out: inout [UInt8]) {
        separate(into: &out)
        appendJSONString(bytes(of: key), to: &out)
        out.append(UInt8(ascii: ":"))
    }

    appendKey("v", into: &out)
    appendInt(envelope.version, to: &out)

    appendKey("id", into: &out)
    appendJSONString(envelope.eventID, to: &out)

    appendKey("provider", into: &out)
    appendJSONString(bytes(of: envelope.provider), to: &out)

    appendKey("ts", into: &out)
    appendInt(envelope.timestampSeconds, to: &out)
    out.append(UInt8(ascii: "."))
    appendPadded(envelope.timestampMicroseconds, width: 6, to: &out)

    // Our parent is the agent. The daemon resolves it to tty, cwd, and start
    // time via proc_pidinfo — more reliable than anything determinable here,
    // since our stdin is the payload pipe rather than a terminal.
    appendKey("ppid", into: &out)
    appendInt(envelope.parentPID, to: &out)

    if let value = envelope.termProgram, !value.isEmpty {
        appendKey("term_program", into: &out)
        appendJSONString(value, to: &out)
    }
    if let value = envelope.termSessionID, !value.isEmpty {
        appendKey("term_session_id", into: &out)
        appendJSONString(value, to: &out)
    }

    for (key, value) in fields {
        separate(into: &out)
        appendJSONString(key, to: &out)
        out.append(UInt8(ascii: ":"))
        switch value.kind {
        case .string: appendJSONString(value.bytes, to: &out)
        case .number, .boolean: out.append(contentsOf: value.bytes)
        case .null: out.append(contentsOf: bytes(of: "null"))
        }
    }

    out.append(UInt8(ascii: "}"))
    out.append(0x0A)
    return out
}
