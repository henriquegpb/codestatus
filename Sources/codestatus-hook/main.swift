// codestatus-hook — the observer that agents invoke on lifecycle events.
//
// Contract with the agent, in priority order:
//
//   1. Never block it.  Every wait is bounded; there is no unbounded read,
//      connect, or write anywhere in this binary.
//   2. Never fail it.   The process always exits 0, on every path, including
//      malformed input, a missing daemon, and a full disk.
//   3. Never leak.      Only allowlisted metadata is read out of the payload.
//
// It is registered with `async: true` in both Claude Code and Codex, so even
// this bounded work happens off the agent's critical path.

import Darwin
import HookCore

// MARK: - Configuration

let socketTimeoutMilliseconds: Int32 = 50
let maxPayloadBytes = 4 * 1024 * 1024
/// Spool only while the daemon has been seen recently; see `writeToSpool`.
let spoolMaxHeartbeatAgeSeconds = 24 * 60 * 60
let spoolMaxFiles = 512

// MARK: - Arguments

/// Which agent invoked us. The payload alone cannot tell us: Claude Code and
/// Codex both send `hook_event_name` with overlapping values, so the installer
/// passes the provider explicitly.
func providerArgument() -> String {
    var iterator = CommandLine.arguments.makeIterator()
    _ = iterator.next()
    while let argument = iterator.next() {
        if argument == "--provider", let value = iterator.next() {
            switch value {
            case "claude-code", "claudeCode": return "claudeCode"
            case "codex": return "codex"
            default: return "generic"
            }
        }
    }
    return "generic"
}

func runtimeDirectory() -> String? {
    guard let home = environmentValue("HOME") else { return nil }
    return string(from: home) + "/Library/Application Support/CodeStatus/run"
}

// MARK: - Read and reduce

// Always drain stdin fully, so the agent's write to us cannot fail with EPIPE.
var payload = readAllDraining(0, limit: maxPayloadBytes)

var scanner = JSONScanner(payload)
let fields = scanner.scan()

// The payload is now reduced to allowlisted scalars. Release the original bytes,
// overwriting first so prompt and tool content does not linger in this process's
// memory any longer than it must.
for i in payload.indices { payload[i] = 0 }
payload = []

let clock = wallClock()
let line = buildEventLine(
    envelope: EventEnvelope(
        provider: providerArgument(),
        eventID: makeEventID(counter: 0),
        timestampSeconds: clock.seconds,
        timestampMicroseconds: clock.microseconds,
        parentPID: Int(getppid()),
        termProgram: environmentValue("TERM_PROGRAM"),
        termSessionID: environmentValue("TERM_SESSION_ID")
    ),
    fields: fields
)

// MARK: - Deliver

var delivered = false

if let runDirectory = runtimeDirectory() {
    // The socket path lives in a pointer file rather than being compiled in, so
    // the daemon can relocate it — a long username can overflow sun_path's 104
    // bytes — without ever rewriting the agent's configuration.
    if let pointer = readSmallFile(runDirectory + "/socket-path") {
        let socketPath = trimmed(pointer)
        if !socketPath.isEmpty,
           let fd = connectUnixSocket(path: socketPath, timeoutMilliseconds: socketTimeoutMilliseconds) {
            delivered = writeAll(fd, line)
            close(fd)
        }
    }

    if !delivered {
        writeToSpool(
            directory: runDirectory + "/spool",
            heartbeat: runDirectory + "/heartbeat",
            line: line,
            maxAgeSeconds: spoolMaxHeartbeatAgeSeconds,
            maxFiles: spoolMaxFiles
        )
    }
}

// Success regardless of what happened above: a monitoring tool has no business
// turning its own outage into the agent's problem.
exit(0)
