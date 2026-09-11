<div align="center">

# CodeStatus

**Stop watching AI work.**

A menu bar, tray and panel app that tracks every Claude Code and Codex session on your machine
and tells you the moment one finishes, needs approval, or is waiting on you. A native presence
layer for coding agents: start several, keep working, and come back only when one is actually
done or actually needs you.

<img src="website/public/DemoMenubar.png" width="640" alt="The CodeStatus menu bar popover: three sessions with their provider, state, and elapsed time, a note that three more are not reporting yet, and Refresh, Settings and Quit along the bottom.">

[**Download for macOS**](https://github.com/henriquegpb/codestatus/releases/latest/download/CodeStatus.dmg) ·
[Download for Windows](https://github.com/henriquegpb/codestatus/releases/latest/download/CodeStatus-Setup.exe) ·
[Download for Linux](https://github.com/henriquegpb/codestatus/releases/latest/download/CodeStatus.deb) ·
[codestatus.dev](https://codestatus.dev)

macOS 14 or later · Windows 10 or later · Linux · MIT · no account, no server, no telemetry

</div>

---

## What it is

You run Claude Code in one terminal, Codex in another, maybe a third in VS Code. Then you spend
the next twenty minutes tabbing between them asking "is it done yet?".

CodeStatus answers that without you looking. It tracks every Claude Code and Codex session on
your machine, works out whether each one is *working*, *free*, *waiting for your approval*,
*waiting for an answer*, or *failed*, and shows the counts in the menu bar — with a
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

## Platforms

Two apps, one repository. The macOS app is Swift and native; the other is Node and Electron and
serves both Windows and Linux. The two share no build, no dependency, and no runtime.

| | macOS | Windows | Linux |
|---|---|---|---|
| Where | repository root | [`desktop/`](desktop/) | [`desktop/`](desktop/) |
| Built with | Swift 6, AppKit/SwiftUI | Node.js, Electron | Node.js, Electron |
| Status | in daily use | ported, needs hardware verification | installs and runs in CI; the tray needs eyes |
| Agents | Claude Code, Codex | Claude Code | Claude Code |

```
Package.swift  Sources/  Tests/  scripts/  Resources/   ← macOS
desktop/                                                ← Windows and Linux
website/  docs/                                         ← shared
```

The macOS app is the reference implementation: the state machine, the event vocabulary, and the
honesty rules are defined there and ported. What keeps the two from drifting is that the test
suites are written as the same cases in both languages — see
[desktop/README.md](desktop/README.md#two-apps-one-repository), which explains how that drift
happened once already and what it cost.

Windows and Linux are one app rather than two because they are the same language and the same
runtime: a fork would mean a third copy of the state machine, and the second copy is what caused
the drift that section describes. What differs between them lives in `desktop/src/platform/`,
seven small files per platform, and CI fails the build if a `process.platform` check appears
outside it.

### What Linux costs

The engine ports cleanly — `/proc` is a better process table than either of the others, and a
Unix socket is what the macOS app already uses. Two things do not, and both are stated in the app
rather than discovered:

- **GNOME has no system tray.** It was removed from the shell in 3.26. Ubuntu ships the
  AppIndicator extension enabled and the icon appears; on Fedora or vanilla GNOME you install it
  or you see nothing. KDE, XFCE, Cinnamon, MATE and Budgie all have one.
- **Wayland cannot raise another application's window.** Deliberately — it is how it stops apps
  stealing focus. Terminals running through XWayland still can be, which is most of them, and
  the rest fall back to opening the project folder.

So on Ubuntu, KDE or XFCE under X11 it is the Windows build's equal. On Fedora GNOME under
Wayland it is a notifier that cannot always take you back. See
[the matrix](desktop/README.md#what-works-on-which-desktop).

## Privacy

Everything happens on your own machine. There is no account, no server, no telemetry, and no network
code in the product at all.

The privacy guarantee is structural rather than a promise. The hook binary that agents invoke
never parses your payload into a general structure — it walks past everything that is not on a
metadata allowlist without ever copying those bytes. Your prompts, the agent's responses, tool
inputs and outputs, and transcript paths are *incapable* of reaching the socket, the logs, or
the crash reporter, and there is a test that asserts exactly that.

What we do read through the hook: session id, provider, event name, timestamp, pid, tty, working
directory, git root, workspace name, and host application.

One thing is read outside that channel, and it is worth being precise about. To label a row with
the name a session actually has — `Calendar fix` rather than a third row reading `backend` — the
app reads the name Claude Code has for the session and `thread_name` from Codex's session index.

Claude Code keeps that name in more than one place, and all three are read in this order: the
desktop app's own session list, which is the only place a rename typed into that list is stored;
then the newest `custom-title` record in the transcript; then `ai-title`, which is what a machine
driven from the CLI has instead. That happens in the app, not in the hook: `transcript_path` stays off
the hook's allowlist, and nothing about it crosses the socket. Only the title is kept; the bytes
read to find it are searched and dropped.

Because that title is written by a model out of your conversation, it is treated as content
rather than as metadata everywhere it could travel. It is never persisted — `sessions.json` has
no field for it, and there is a test that fails if one appears — and it is never included in the
diagnostics report you paste into a bug report.

It does appear in notifications, on the second line. Three sessions in one repository otherwise
send three identical banners, and a banner is the thing that makes you stop what you are doing,
so it is the surface where being unable to tell them apart costs most. The first line stays the
repository: it reads as a sentence, and it is what survives when the system stacks or truncates
banners.

It is also the one thing here read from a store the agents do not document. Every failure to read
it falls back to the working directory, which is what the row said before.

## Status

**In development.** The engine is built and covered by 184 tests. The interface works and is in daily use; its appearance has not been reviewed on hardware other than one machine.

| Area | State |
|---|---|
| State machine, event ordering, de-duplication | done, tested |
| Hook binary, Unix socket transport, spool fallback | done, tested |
| Session registry, persistence, sleep/wake reconciliation | done, tested |
| Config installers (byte-preserving), process watcher | done, tested |
| Menu bar item, notifications, session opening | built, needs visual verification on hardware |
| Diagnostics report and sanitised export | done, tested |
| Onboarding flow, settings window | done |
| Signed and notarised release pipeline | scripted; notarisation not yet exercised |

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
- **A session you interrupt keeps its last state until you type again.** Claude Code's `Stop`
  hook deliberately does not run when *you* stop a turn, and no other event takes its place —
  verified across every shape of cancel, with all 31 of its hook events registered. So pressing
  Esc on a question leaves CodeStatus showing "needs a reply" until your next prompt. We would
  rather be briefly wrong than guess a session went free while its question is still on screen.
  See [spike 13](docs/spikes/07-blocking-questions.md).
- **Codex sees only the first tool use of each turn.** Its hook payloads carry no `tool_name` or
  `tool_use_id`, so tool uses cannot be told apart and the ones after the first are dropped as
  out-of-order — which means an approval Codex asks for late in a turn is missed. Claude Code
  supplies both and does not have this problem.
- **Codex in VS Code is unverified.** It runs as `app-server` rather than the TUI, and it has
  not yet been confirmed that `hooks.json` events are delivered in that mode.
- **"Send prompt" is no everywhere, for now.** Typing into a session we did not launch would
  mean writing to a TTY or faking keystrokes, which can land your text in the wrong place. It
  will be enabled only for sessions CodeStatus starts itself through a PTY.

## Keeping the Mac awake

Off by default. Turned on in Settings › Sleep, CodeStatus holds a
`PreventUserIdleSystemSleep` assertion while an agent is mid-turn, so a long turn is not
interrupted by the Mac idling out from under it. It releases the moment the turn ends.

It also releases while an agent is **waiting on you**. An agent blocked on an approval or a
question is making no progress, so holding the machine awake spends battery for nothing. This is
the one part that needs a real lifecycle state to get right: anything watching CPU or process
liveness cannot tell "working" from "waiting for a human", and so stays awake through every
approval prompt. On battery it also releases below a floor you set, and it honours Low Power Mode.

**Closing the lid still sleeps the Mac, and we do not pretend otherwise.** Lid close is a
separate path that ignores every assertion an unprivileged process can hold — Apple's own
documentation for the idle-sleep assertion says the system "may still sleep for lid close". Two
assertion types look like they would cover it and neither does: `PreventSystemSleep` and the
private `InternalPreventSleep` are both *accepted* from an app like this one and then not counted
in `powerd`'s aggregate, so they have no effect. Suppressing lid close needs `pmset disablesleep`,
which needs root and sets a persistent system-wide flag — a different feature with a different
risk profile, and not one to hide behind a checkbox.

Display sleep is deliberately not held: the screen is the biggest draw on the machine, and
nobody is looking at it.

## What your agents are costing

The popover carries one line — today's spend, and how much of the plan's quota is gone — and
clicking it opens the breakdown by day and by model.

**The numbers come from your own machine.** Agents already write a transcript of every session,
and each assistant message in it carries the token counts the request was billed for. CodeStatus
reads those counts and prices them at published list API rates. Nothing is uploaded, and no
account is involved — the "no server, no telemetry" promise above is unchanged.

**Only the token counts are read.** Those transcripts also contain your prompts, the model's
replies, tool inputs and file contents. The scanner walks past every key it was not asked for
without copying its bytes, so conversation content is structurally incapable of reaching the
screen, a log, or the snapshot — the same construction as the hook's scanner, and tested the same
way. It can be switched off in Settings › Usage.

**It is an estimate, not an invoice.** A subscription, pay-as-you-go overage, batch pricing, or a
negotiated rate all differ from list rates, and none of them are observable from a transcript.
What it is good for is comparison: which day cost four times the others, which model the spend is
actually in, and whether caching is working.

Two limits worth stating:

- **Only Codex reports how much quota is left.** Its rollout files carry the used percentage for
  the 5-hour and weekly windows, with reset times. Claude Code publishes no equivalent anywhere
  on disk — searched across every transcript and configuration file — so that row simply does not
  appear for a Claude-only machine rather than showing a bar we cannot fill honestly.
- **Codex tokens are counted but not priced.** Its models' rates are not ours to publish and were
  not verified against a source, and an invented rate in a table that looks authoritative is worse
  than a stated gap. Any model without a known rate is named in the breakdown rather than folded
  silently into the total.

The full pass reads every transcript once — 213 files and 83,000 lines took 5.2 seconds on the
machine it was developed on — and every pass after that reads only the bytes appended since,
which takes about 15 milliseconds. A line still being written is left for the next pass rather
than parsed in half.

## Updates

CodeStatus updates itself, and tries hard not to be noticed doing it.

Once a day it asks GitHub what the latest release is. If there is a newer one it
downloads it, checks that the bundle declares the version it promised, and verifies the
signature against the Developer ID team of the app that is *running* — nested code included, so a
tampered `codestatus-hook` cannot ride along. Only after all of that passes does anything on disk
change.

Then it waits. The swap happens when no agent is working or waiting on you, and the app restarts
into the new version. That costs nothing: sessions live in the agents, their hooks point at a
binary staged outside the bundle, and the snapshot is reloaded on launch. If your machine is
never quiet, the menu bar offers a Restart button and you pick the moment.

It disables itself, visibly, when it cannot do this safely: a build that is not Developer ID
signed, or an app running from a disk image or a translocated path. Turn the whole thing off in
Settings.

## How it works

```
Claude Code / Codex
        │  official lifecycle hook (async, never blocking)
        ▼
codestatus-hook          ← metadata allowlist applied here, 225 KB universal, no Foundation
        │  one NDJSON line over a Unix domain socket
        ▼
CodeStatus daemon
        │
        ├── StateReducer      pure, idempotent, tolerant of out-of-order delivery
        ├── SessionRegistry   the single source of truth
        └── ProcessWatcher    kqueue NOTE_EXIT — discovery and death, never state
                │
                ▼
        menu bar · sound · notification
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
