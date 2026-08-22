<div align="center">

# CodeStatus

**Stop watching AI work.**

A native macOS presence layer for coding agents. Start several, keep working, and come back only
when one is actually done or actually needs you.

</div>

---

## What it is

You run Claude Code in one terminal, Codex in another, maybe a third in VS Code. Then you spend
the next twenty minutes tabbing between them asking "is it done yet?".

CodeStatus answers that without you looking. It tracks every Claude Code and Codex session on
your Mac, works out whether each one is *working*, *free*, *waiting for your approval*,
*waiting for an answer*, or *failed*, and shows the counts in a HUD around the notch — with a
sound and a notification the moment one needs you.

```
● 1 free            ● 2 busy            ● 1 needs you
```

Click a session and you land back in the right terminal tab or the right workspace.

## What it is not

It is not a prettier Activity Monitor, and it is not a wrapper around notifications.

Watching whether `claude`, `codex`, or `node` is burning CPU tells you nothing about whether the
agent is thinking, running a tool, or sitting idle waiting for you. CodeStatus uses the agents'
**official lifecycle hooks** as the source of truth. Process observation is used only for
discovery, enrichment, and knowing when a session genuinely died.

If we cannot determine a state, we show `Unknown` or `Reconnecting`. We never announce that a
session finished because it went quiet.

## Privacy

Everything happens on your Mac. There is no account, no server, no telemetry, and no network
code in the product at all.

The privacy guarantee is structural rather than a promise. The hook binary that agents invoke
never parses your payload into a general structure — it walks past everything that is not on a
metadata allowlist without ever copying those bytes. Your prompts, the agent's responses, tool
inputs and outputs, and transcript paths are *incapable* of reaching the socket, the logs, or
the crash reporter, and there is a test that asserts exactly that.

What we do read: session id, provider, event name, timestamp, pid, tty, working directory, git
root, workspace name, and host application.

## Status

**In development.** The engine is built and covered by 151 tests; onboarding and settings are not written yet.

| Area | State |
|---|---|
| State machine, event ordering, de-duplication | done, tested |
| Hook binary, Unix socket transport, spool fallback | done, tested |
| Session registry, persistence, sleep/wake reconciliation | done, tested |
| Config installers (byte-preserving), process watcher | done, tested |
| Notch HUD, menu bar item, notifications, session opening | built, needs visual verification on hardware |
| Diagnostics report and sanitised export | done, tested |
| Onboarding flow, settings window | not started |
| Signed and notarised release pipeline | scripted, not yet exercised end to end |

Verified working end to end on a real machine: the app launches as a menu bar
companion, creates its runtime directories `0700`, listens on the socket, installs
its hook binary, and correctly takes a session from `busy` to `free` from real hook
invocations — while leaving `~/.claude/settings.json` and `~/.codex/config.toml`
untouched and keeping prompt and response text out of every artefact it writes.

In the same run the process watcher independently found the Claude Code and Codex
processes already running on the machine and reported them as `unknown` rather than
guessing — which is the behaviour this project exists to get right.

## Capability matrix

Limitations are stated, not hidden. This is what we can actually do per environment.

| Environment | Discovery | Busy/free | Approval | Input | Open | Send prompt |
|---|---|---|---|---|---|---|
| Claude Code CLI | yes | yes | yes | yes | yes (tab) | no |
| Claude Code in VS Code | yes | yes | yes | yes | yes (workspace) | no |
| Codex CLI | yes | yes | yes | **no** | yes (tab) | no |
| Codex in VS Code | yes | *unverified* | *unverified* | **no** | yes (workspace) | no |

Why the gaps:

- **Codex "Input" is no.** Codex has no `Notification` event, so "the agent is waiting for you
  to answer a question" is not observable through any official channel. Approval requests *are*,
  via `PermissionRequest`.
- **Codex in VS Code is unverified.** It runs as `app-server` rather than the TUI, and it has
  not yet been confirmed that `hooks.json` events are delivered in that mode.
- **"Send prompt" is no everywhere, for now.** Typing into a session we did not launch would
  mean writing to a TTY or faking keystrokes, which can land your text in the wrong place. It
  will be enabled only for sessions CodeStatus starts itself through a PTY.

## How it works

```
Claude Code / Codex
        │  official lifecycle hook (async, never blocking)
        ▼
codestatus-hook          ← metadata allowlist applied here, 83 KB, no Foundation
        │  one NDJSON line over a Unix domain socket
        ▼
CodeStatus daemon
        │
        ├── StateReducer      pure, idempotent, tolerant of out-of-order delivery
        ├── SessionRegistry   the single source of truth
        └── ProcessWatcher    kqueue NOTE_EXIT — discovery and death, never state
                │
                ▼
        HUD · sound · notification
```

Three design choices carry most of the weight:

1. **Hooks are registered with `async: true`.** An async hook cannot block, approve, deny, or
   alter the agent's flow — so "CodeStatus never interferes" is enforced by the agent, not by us
   being careful.
2. **Config edits are byte-preserving text splices.** Installing hooks does not re-serialise
   `settings.json`; every byte outside the inserted entry stays identical, so your formatting and
   key order survive and your own hooks are never touched.
3. **Nothing infers state from time.** A session quiet for ten minutes in the middle of one long
   tool call is still `busy`. Only our *confidence* decays.

## Building

Requires macOS 14+ and Swift 6.

```sh
swift build
swift test
```

Note for contributors: on macOS 26, `UNUserNotificationCenter` will not deliver from an unsigned
bundle — it fails silently. A local build needs at least an ad-hoc signed `.app` before
notifications appear. See `CONTRIBUTING.md`.

## Documentation

- [`docs/spikes/`](docs/spikes/) — the experiments behind every architectural decision, with
  results, limitations, and what each one changed. Start with the
  [index](docs/spikes/README.md).
- [`NOTICE`](NOTICE) — projects whose code we adapted, and what we changed.

## License

MIT. See [`LICENSE`](LICENSE).
