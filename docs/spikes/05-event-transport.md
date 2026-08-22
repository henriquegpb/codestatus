# Spike 8 & 9 — event transport, spool fallback, and reconciliation

- **Spike 8 (Unix socket + spool):** done
- **Spike 9 (sleep/wake reconciliation):** partial — the policy is implemented and unit-tested;
  a real sleep/wake cycle on hardware has not yet been exercised.

## Hypothesis

A hook can deliver an event to a local daemon fast enough to be invisible on every tool call,
survive the daemon being absent, and never leak conversation content — using only a Unix domain
socket and plain files.

## Method

Built `codestatus-hook` and measured it. Fed it real Claude Code payload shapes, including
`last_assistant_message`, `tool_input` with nested objects and arrays, and `transcript_path`.
Ran it against a listening socket, against no socket, and against a socket path deliberately
made too long. Measured 100 sequential invocations with a 20 KB payload.

## Result

### Content cannot reach the wire

The hook never parses the payload into a general structure. Its scanner walks the top-level
object and copies out only allowlisted keys, skipping every other value in place. Feeding it:

```json
{"session_id":"abc-123","transcript_path":"/Users/x/.claude/projects/p/t.jsonl",
 "cwd":"/Users/x/proj","hook_event_name":"Stop",
 "last_assistant_message":"SECRET","stop_reason":"end_turn","prompt_id":"pid-9"}
```

produces exactly:

```json
{"v":1,"id":"82927-2118279169039-0","provider":"claudeCode","ts":1787433869.241195,
 "ppid":82918,"term_program":"Apple_Terminal","term_session_id":"tsid-42",
 "session_id":"abc-123","cwd":"/Users/x/proj","permission_mode":"default",
 "hook_event_name":"Stop","prompt_id":"pid-9"}
```

`last_assistant_message`, `transcript_path`, and `stop_reason` are absent — as are nested
`tool_input` values at any depth, and content crafted to look like JSON structure in an attempt
to break out of the skipper. This is verified by unit tests on a pure function, not only end to
end.

### It is fast, and Foundation is genuinely absent

| Measurement | Value |
|---|---|
| Wall time per invocation, 20 KB payload, no daemon | **7.0 ms** |
| Binary size | **83 KB** |
| Linked libraries | `libSystem.B.dylib`, `libswiftCore.dylib`, `libswiftDarwin.dylib` |

The 7 ms includes shell `echo`, a pipe, and full process spawn — the hook's own share is a
fraction of it. `otool -L` confirms Foundation is not linked, so the "Foundation-free" claim is
verified rather than assumed. For comparison, the closest prior art ships a bash script that
spawns `bash`, `jq`, and `nc` for every event.

### `sun_path` is a real constraint, and it bit immediately

The very first integration test failed with `AF_UNIX path too long`. `sockaddr_un.sun_path` is
104 bytes on Darwin, and a long home directory pushes
`~/Library/Application Support/CodeStatus/run/e.sock` past it.

The design already anticipated this: the hook does not have the socket path compiled in. It
reads a pointer file at `run/socket-path`, so the daemon can place the socket wherever it fits —
falling back to `/tmp/codestatus-<uid>/e.sock` — without ever rewriting an agent's config.
Because `/tmp` is world-writable, that directory is created with `mkdir(0700)` and validated
with `lstat` for "not a symlink, owned by us, mode 0700" before either side will use it.

### Failure paths are all silent and bounded

- No daemon, no heartbeat → exit 0, nothing written. Verified.
- Daemon recently alive but unreachable → one `.ndjson` file in the spool, written atomically
  (temp + rename), decodable afterwards. Verified.
- Garbage on the socket → rejected and counted; the server keeps serving. Verified.
- 12 concurrent invocations → 12 distinct event ids, correctly grouped into 3 sessions. Verified.

### One real bug this spike caught

The listening socket was left in blocking mode while `acceptPending()` drained connections in a
loop. The first `accept()` succeeded; the second blocked forever on an empty queue, wedging the
dispatch queue and hanging the test suite. Fixed by setting `O_NONBLOCK` on the listener and
explicitly clearing it on each accepted client (Darwin can hand back a client that inherited the
flag, which would otherwise make `read` return `EAGAIN` and drop the event).

## Limitations

- Sleep/wake is verified only as policy logic, not against real hardware sleep.
- The spool is capped by file count and bytes; a pathological backlog is dropped rather than
  replayed, and the drop is reported rather than hidden.
- Measurements are from one machine; they are indicative, not a guarantee across hardware.

## Architectural decision

1. **Allowlist in the hook, not in the daemon.** Applying it at the earliest point makes the
   privacy property structural: content is never copied into a variable, so it cannot leak into
   a log, the spool, or a crash report.
2. **Bounded everything.** Non-blocking `connect` + `poll` with a 50 ms cap, `SO_SNDTIMEO` on
   writes, a payload read cap that still drains stdin so the agent's write cannot fail with
   `EPIPE`, and a capped spool.
3. **Heartbeat-gated spool.** If CodeStatus is deleted without running the uninstaller, its hook
   entries survive in the agent's config. Without a gate the hook would spool forever and fill
   the disk of a user who no longer has the app. It spools only if the daemon's heartbeat is
   younger than 24 hours.
4. **Exit 0 on every path.** A monitoring tool has no business turning its own outage into the
   agent's problem.

## V1 impact

- The transport is done and covered by 37 passing tests, including a full hook-binary →
  socket → registry integration path.
- Diagnostics can surface accepted / decoded / rejected counts from `EventSocketServer.Stats`.
- The socket-path pointer indirection is now load-bearing and must not be "simplified" away.
