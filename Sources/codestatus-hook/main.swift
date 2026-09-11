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
///
/// Two channels, because one agent does not offer the first. Claude Code passes
/// `--provider` from the entry's `args`; Codex ignores `args` entirely, so
/// nothing after `argv[0]` ever reaches us there. The installer therefore stages
/// a per-provider copy of this binary and the name carries the answer.
func providerArgument() -> String {
    var iterator = CommandLine.arguments.makeIterator()
    let executable = iterator.next()
    while let argument = iterator.next() {
        if argument == "--provider", let value = iterator.next() {
            return normalisedProvider(value)
        }
    }
    return providerFromExecutableName(executable)
}

func normalisedProvider(_ value: String) -> String {
    switch value {
    case "claude-code", "claudeCode": return "claudeCode"
    case "codex": return "codex"
    default: return "generic"
    }
}

/// The provider encoded in our own file name, e.g. `codestatus-hook-codex`.
///
/// Suffix-matched rather than parsed, so a copy staged under a directory whose
/// name happens to contain a provider cannot change the answer.
func providerFromExecutableName(_ path: String?) -> String {
    guard let path, !path.isEmpty else { return "generic" }
    var name = path
    if let slash = path.lastIndex(of: "/") {
        name = String(path[path.index(after: slash)...])
    }
    if name.hasSuffix("-codex") { return "codex" }
    if name.hasSuffix("-claude-code") { return "claudeCode" }
    return "generic"
}

func runtimeDirectory() -> String? {
    guard let home = environmentValue("HOME") else { return nil }
    return string(from: home) + "/Library/Application Support/CodeStatus/run"
}

// MARK: - Status line mode

/// Claude Code's status line is the only channel that carries plan quota.
///
/// `rate_limits` — how much of the five-hour and weekly windows is spent — and
/// `context_window.used_percentage` are pushed to the status line command on
/// every render and are never written to disk by the agent. No hook event
/// carries them, which is why this mode exists at all.
///
/// It is a separate path from the event hook because the contract differs: this
/// one must also *print*, since whatever it writes to stdout becomes the user's
/// status line.
func runStatusLineMode(chain: String?) -> Never {
    var payload = readAllDraining(0, limit: maxPayloadBytes)
    let metrics = StatusScanner.scan(payload)

    // Written before the chained command runs, so a slow or broken status line
    // of the user's own cannot cost us the reading.
    if !metrics.isEmpty, let runDirectory = runtimeDirectory() {
        writeStatusMetrics(directory: runDirectory + "/metrics", metrics: metrics)
    }

    // Hand the untouched payload to whatever status line the user already had,
    // and let its output be the status line. Claiming this slot must not cost
    // anyone the configuration they came with — it is a single slot, unlike
    // hooks, so there is no way to simply add ourselves alongside.
    if let chain, !chain.isEmpty {
        runChainedStatusLine(command: chain, payload: payload)
    } else {
        // Nobody else is drawing it, so draw the thing we just read. A status
        // line that reports the quota is more use than an empty one, and it is
        // the user's own number.
        writeStatusSummary(metrics)
    }

    for i in payload.indices { payload[i] = 0 }
    payload = []
    exit(0)
}

/// Runs the status line the user already had, feeding it the same payload.
///
/// Its stdout is inherited, so whatever it prints becomes the status line and
/// ours never appears — the user sees exactly what they configured. `posix_spawn`
/// rather than `popen`, which Swift does not expose.
///
/// Bounded like everything else here: if the child hangs, we stop waiting and
/// leave. A status line that renders late is a nuisance; one that wedges the
/// agent's render loop is a bug we would have introduced.
func runChainedStatusLine(command: String, payload: [UInt8]) {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { return }
    let (readEnd, writeEnd) = (fds[0], fds[1])

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, readEnd, 0)
    posix_spawn_file_actions_addclose(&actions, writeEnd)
    defer { posix_spawn_file_actions_destroy(&actions) }

    var pid: pid_t = 0
    let spawned = "/bin/sh".withCString { shell -> Int32 in
        "-c".withCString { dashC -> Int32 in
            command.withCString { body -> Int32 in
                var argv: [UnsafeMutablePointer<CChar>?] = [
                    strdup(shell), strdup(dashC), strdup(body), nil,
                ]
                defer { for argument in argv where argument != nil { free(argument) } }
                return posix_spawn(&pid, shell, &actions, nil, &argv, environ)
            }
        }
    }
    close(readEnd)
    guard spawned == 0 else { close(writeEnd); return }

    // SIGPIPE would kill us outright if the child exits without reading.
    signal(SIGPIPE, SIG_IGN)
    _ = payload.withUnsafeBufferPointer { buffer -> Int in
        guard let base = buffer.baseAddress else { return 0 }
        var written = 0
        while written < buffer.count {
            let n = write(writeEnd, base + written, buffer.count - written)
            if n <= 0 { break }
            written += n
        }
        return written
    }
    close(writeEnd)

    var status: Int32 = 0
    waitpid(pid, &status, 0)
}

// MARK: - Dispatch

/// The value of `--chain`, if the installer wrapped an existing status line.
func argumentValue(_ name: String) -> String? {
    var iterator = CommandLine.arguments.makeIterator()
    _ = iterator.next()
    while let argument = iterator.next() {
        if argument == name { return iterator.next() }
    }
    return nil
}

if CommandLine.arguments.contains("--status-line") {
    runStatusLineMode(chain: argumentValue("--chain"))
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
