# Contributing to CodeStatus

Thanks for taking an interest. This document covers the things that are specific to this
project — the constraints that are not negotiable, and the two macOS gotchas that will otherwise
cost you an afternoon.

## Getting set up

```sh
git clone https://github.com/<owner>/codestatus.git
cd codestatus
swift build
swift test
```

Requires macOS 14+ and Swift 6 (Xcode 16 or newer). There are no third-party dependencies and
there never will be — see below.

To build the actual app bundle:

```sh
scripts/build-app.sh --sign     # ad-hoc signed, for local development
```

## Two things that will waste your time if you do not know them

### 1. Notifications need a signed bundle on macOS 26

`UNUserNotificationCenter` does **not** deliver from an unsigned bundle on Tahoe. It does not
error — it silently does nothing, which is the worst possible failure mode to debug.

Always test notifications from `scripts/build-app.sh --sign` (ad-hoc is enough), never from
`swift run`. The Diagnostics screen reports notification authorisation status precisely so you
can see *why* nothing arrived.

### 2. Unix socket paths are limited to 104 bytes

`sockaddr_un.sun_path` is 104 bytes on Darwin, and
`~/Library/Application Support/CodeStatus/run/e.sock` can exceed it for a long username. This is
why the hook reads the socket path from a pointer file instead of having it compiled in, and why
there is a `/tmp/codestatus-<uid>/` fallback with strict ownership validation.

If you write a test that binds a socket under a temp directory, it will fail with
`AF_UNIX path too long` — macOS temp directories are long. Use a short path.

## The five rules

These come from the product spec and are not up for negotiation in a PR. A change that breaks
one of them will be declined regardless of how good it is otherwise.

### 1. No conversation content, ever

Prompts, agent responses, tool inputs, tool outputs, file contents, and transcript paths must
never be read, logged, persisted, or transmitted. Not even temporarily, not even in a debug
build, not even behind a flag.

The hook enforces this structurally: its scanner walks past every non-allowlisted key without
copying the bytes. If you need a new field, add it to `allowedKeys` in
`Sources/HookCore/JSONScan.swift` and justify it in the PR — and it had better be metadata.

`Tests/CodeStatusCoreTests/HookWireTests.swift` asserts this. Do not weaken those tests.

### 2. Never infer state from time, CPU, or focus

Low CPU, a quiet process, a few seconds without output, a backgrounded window, and "a `node`
process exists" are all *forbidden* as evidence of what an agent is doing.

Hooks are the source of truth. Process observation may only do four things: discover sessions,
enrich them with metadata, reconcile after a gap, and detect that a process exited.

Elapsed silence may lower `stateConfidence`. It may never change `state`. If you find yourself
adding a timer that flips a session to `free`, stop — the closest prior art does exactly that
and misclassifies any tool call longer than five minutes.

### 3. Never interfere with the agent

CodeStatus must not be able to block, delay, break, or alter Claude Code or Codex — even when it
is broken itself.

- All hooks are registered `async: true`.
- The hook exits `0` on every path, including malformed input and a full disk.
- Every wait is bounded. No unbounded read, connect, or write anywhere in the hook.
- The hook never approves, denies, modifies, or adds context to anything.

### 4. Never damage a user's configuration

Config edits are byte-preserving text splices via `JSONSurgeon`, not `JSONSerialization`
round-trips. Every byte outside the inserted entry stays identical.

- Back up before writing, write atomically, validate after, restore on failure.
- Identify our own entries by resolved path, never by substring matching on the command.
- Never touch `~/.codex/config.toml`. Codex hooks go in `~/.codex/hooks.json`.
- Never write a Codex `trusted_hash`. Automating hook trust would defeat a security control.

### 5. Native, and dependency-free

Swift, SwiftUI, and AppKit. `Package.swift` declares zero dependencies and the shipped binaries
link only libSystem and the Swift runtime. No Electron, no web view, no package that would add a
supply chain to a tool that watches your development environment.

No private API, no Accessibility as a load-bearing mechanism, no screen scraping, no reading
another extension's internal database. If a feature can only work through a fragile technique,
it is optional and clearly labelled — and the core keeps working without it.

## Code style

Read a few existing files before writing new ones; match what you find.

- **Comments explain why, not what.** Reference the actual constraint — a byte limit, a macOS
  behaviour, a spec rule, a bug that was caught. If a comment restates the code, delete it.
- Prefer pure functions and value types, so behaviour is testable without IO. The state machine,
  the notch geometry, and the sleep/wake policy are all pure for this reason.
- Sendable correctness matters; the package builds under Swift 6 strict concurrency.
- `CodeStatusCore` must not import AppKit. UI concerns live in `CodeStatusApp`.

## Tests

We use [swift-testing](https://github.com/swiftlang/swift-testing) (`import Testing`), not
XCTest.

Test names read as sentences describing the guarantee:

```swift
@Test("A late PreToolUse cannot knock a session out of waitingForApproval")
@Test("Conversation and tool content never reach the wire")
@Test("With no daemon listening the hook still succeeds and stays silent")
```

A new behaviour needs a test named for the property it guarantees, not for the method it calls.
Bound every wait — a test that can hang is worse than a test that fails.

Note: `#expect` cannot call a mutating method directly. Assign to a `let` first.

## Adding support for another agent

The architecture is ready for more adapters, but Claude Code and Codex must stay excellent
first. If you want to add one, open an issue before writing code, and be ready to answer:

- Which **official, documented** events does it emit? (Not "what could we scrape".)
- Which of the nine `AgentState` cases can be determined, and which genuinely cannot?
- Where does its configuration live, and what else lives in that file that we might damage?

Then add an honest row to the capability matrix, gaps and all. Overstating support is worse than
not supporting something.

## Pull requests

- One concern per PR.
- `swift build` and `swift test` must pass.
- Say which of the five rules your change touches, if any, and how you kept it.
- If you adapted code from another project, add it to `NOTICE` with the licence and what you
  changed.
