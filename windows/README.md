# CodeStatus for Windows

A second implementation of CodeStatus, for the Windows system tray. It answers
the same single question as the macOS app: **is a session waiting for me?**

Everything under `windows/` is this app. Everything outside it — `Sources/`,
`Tests/`, `Package.swift`, `scripts/` — is the macOS app, and the two share no
build, no dependency, and no runtime. See [Two apps, one repository](#two-apps-one-repository).

## Credit

The original port was written by **Ricardo Mone**, from scratch, against the
macOS source. The state machine, the event ordering, the deduplicator, the
installer's ownership rules, the named-pipe transport, and the discovery that
Claude Code's hook entries must use the exec form on Windows are all theirs.

What this version adds: the state-machine changes upstream landed after that
port was written, a process scanner so the app can explain a silent agent, a
Fluent-styled interface, and three fixes noted in the history.

## Install

Download **CodeStatus-Setup.exe** from the
[latest release](https://github.com/henriquegpb/codestatus/releases/latest)
— or the `-arm64` one on Windows on Arm, which is also what a Windows VM on an
Apple Silicon Mac runs. Nothing needs to be installed first: the app carries its
own runtime, including the one the hook runs on.

The installer is **not code-signed yet**, so SmartScreen shows a blue panel
saying the publisher is unrecognised. *More info* → *Run anyway*. There is no
way around that short of an Authenticode certificate, and pretending otherwise
would be worse than saying it.

Then:

1. **Open CodeStatus.** It goes straight to the tray. Windows 11 hides new tray
   icons behind the `^` arrow — drag it out once and it stays out.
2. **Choose Connect Claude Code.** This writes the hooks into
   `~/.claude/settings.json`, with an automatic backup.
3. **Start a new Claude Code session.** Sessions that were already open will
   never appear: Claude Code reads its hook configuration once, at session start.

Uninstalling through Windows removes the hook entries first, so the app does not
leave entries behind pointing at files it took with it.

### From source

For working on the app, or trying a branch. This is the path that still needs
[Node.js 18+](https://nodejs.org) — to fetch dependencies and run the tests, not
to run the hook.

```powershell
cd windows
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```

Add `-StartWithWindows` to have it come up with Windows. The script fetches
dependencies, runs the tests on the target machine, and creates the shortcuts.
It does **not** touch your `settings.json`.

`scripts\package.ps1` produces a ~200 KB zip of the source, for a machine
without git.

## Reading the tray icon

macOS lets an app write text into the menu bar, so the mac build shows
`● 1 free  ● 2 busy`. The Windows tray takes an icon and nothing else, so the
count is drawn inside it, and the colour carries the same question the whole app
answers:

| Colour | Meaning |
|---|---|
| red | a session needs you — approval, a reply, or a failure |
| amber | sessions working |
| green | sessions free, waiting for a prompt |
| grey | no active sessions |

The number is the count of the most urgent situation present; `+` means more
than nine. The full breakdown lives in the tooltip, and at the top of the
popover — that summary line exists on Windows precisely because the tray cannot
show it.

## States

The vocabulary is the macOS app's, and so is the logic that keeps it honest:

- **Busy** — has a prompt: thinking, generating, or running tools
- **Free** — the turn ended and the session is still open, ready for another
- **Needs approval** — blocked waiting for you to approve a tool
- **Needs a reply** — blocked waiting for you to answer a question
- **Failed** — the turn ended in an error, and is never shown as free
- **Reconnecting** — the app restarted and the state is not yet trustworthy

Absence of evidence is represented explicitly, never guessed. A session quiet
for ten minutes in the middle of a tool call is still *busy* — only the
confidence in that drops. Elapsed time never changes a state on its own.

## Privacy

All processing is local. There is no server, no telemetry, and no network code.

The hook reads the payload Claude Code sends and extracts **only** an allowlist
of metadata (`session_id`, `hook_event_name`, `cwd`, `tool_name`, `model`, and a
few others). The prompt, the response, tool input and output, messages, and the
transcript path never cross the transport. That is tested: see
`test/transport.test.js`, which injects real sensitive content and fails if any
part of it reaches the wire.

## What differs from macOS

The core — state machine, event ordering, deduplication, session registry — is a
faithful port with the same invariants and the same tests. What had to change is
everything that touched the operating system:

| macOS | Windows |
|---|---|
| Swift 6 + AppKit/SwiftUI | Node.js + Electron |
| Unix domain socket | Named pipe (`\\.\pipe\codestatus-<user>`) |
| Compiled `codestatus-hook` binary | `hook/hook.js` on the app's own Electron |
| `~/Library/Application Support/CodeStatus` | `%LOCALAPPDATA%\CodeStatus` |
| Text in the menu bar | Count drawn inside the tray icon |
| `TERM_PROGRAM` names the terminal | Environment, then the process tree |
| AppleScript selects the exact tab | Raises the window hosting the process |
| Process exit via kqueue | Polled pid liveness |
| `libproc` lists running agents | One PowerShell pass over `Win32_Process` |

The whole `sun_path` mechanism from the original is gone: named pipes live in
their own namespace and have no path limit, so the `/tmp` fallback and the
directory validation have no equivalent here.

**Codex is not ported.** The Codex installer on macOS exists almost entirely to
work around a path-parsing bug in Codex on that platform, which does not apply
here. The hook already accepts `--provider codex` if it is ever wanted.

### The gotcha that cost the most: exec form vs shell form

The hook entry **must** use `args`:

```json
{
  "type": "command",
  "command": "C:\\Program Files\\nodejs\\node.exe",
  "args": ["C:\\Users\\you\\CodeStatus\\windows\\hook\\hook.js", "--provider", "claude-code"],
  "timeout": 5,
  "async": true
}
```

With `args` present, Claude Code spawns the binary directly. With it omitted, it
passes the line through a shell — and on Windows that shell can be **PowerShell**,
where a line starting with a quoted path is merely a *string literal* it echoes.
Without the `&` operator, nothing runs. The first version of this port wrote one
command line, and the hook never fired: no error, no log, nothing in the spool.
Just silence.

There is a regression test for it, and the ownership detector recognises both
formats so anyone who installed before the fix does not end up with duplicate
entries firing the hook twice.

### How the hook gets a runtime

Claude Code's hook schema has `command`, `args`, `timeout`, `async` and `shell`,
and no field that sets an environment variable. That one gap decides the shape
of `src/platform/runtime.js`.

The app ships an Electron binary, and an Electron binary *is* Node when
`ELECTRON_RUN_AS_NODE` is set. With no way to set it in the hook entry, the
installer would otherwise have to carry a second runtime to run 250 lines of
JavaScript — `node.exe` alone is 78 MB, which is most of an installer, for a job
the binary next to it can already do.

So the installer writes a four-line `.cmd` that sets the variable and hands
over, and registers `cmd.exe /c <shim>`. Still the exec form: the executable is
cmd.exe, with an argument vector we control. It costs one cmd.exe per event,
around ten milliseconds.

The shim takes no arguments, and that is load-bearing. Its path contains the
user's profile name, which may contain a space, so Windows quotes it — and
`cmd /c` preserves those quotes only when nothing follows the closing one. Put
`--provider claude-code` after it and cmd strips the pair instead, then tries to
run `C:\Users\John`. The provider is baked into the shim for that reason, and a
second agent would get a second shim.

### The cost this build still carries

The macOS hook is a compiled, deliberately Foundation-free binary, because it
runs on every agent tool call. Here it is a Node cold start plus a cmd.exe —
tens of milliseconds of real work per event, times fourteen registered events.
`async: true` keeps it off the agent's critical path; it does not make it free.

A compiled hook would remove the cold start and the runtime question together,
and it is the next thing worth doing. Nothing in the design depends on the
hook's language: it writes one NDJSON line to a named pipe.

## Known limitations

- **Windows does not expose terminal tabs**, not even in Windows Terminal.
  Clicking a session raises the *window* hosting the agent's process, walking up
  the process tree until one has a window. If none does, it opens the project
  folder.
- **New tray icons are hidden by default** on Windows 11, behind the `^` arrow.
  There is no API to pin one — Microsoft removed it deliberately. The user has
  to drag it out once.
- **No acrylic on Windows 10.** The DWM materials arrived in Windows 11 (build
  22000); below that the windows paint a solid Fluent surface instead.
- **The installer is unsigned.** SmartScreen warns once, per the note above.

## Layout

```
windows/
├── hook/hook.js         the observer Claude Code invokes; no imports from src/
├── src/
│   ├── core/            platform-free: the state machine and everything it needs
│   ├── platform/        the Windows seam: paths, pipe name, process scan, focus
│   ├── install/         writing and removing our hook entries
│   ├── daemon/          the transport, the spool, liveness, persistence
│   ├── ui/              tray icon, popover, settings window
│   └── main.js          the Electron main process, wiring the above together
├── test/
├── scripts/             source install, packaging, console launcher
└── build/               NSIS hooks for the published installer
```

`src/core/` has no Windows in it and no Electron in it — it is the part that
ports again if this ever moves to Tauri, or to Linux. `src/platform/` is the
part that does not: three files and a process scan. That split is deliberate,
and it is why the Linux question is a matter of rewriting those files rather
than the app.

## Tests

```powershell
npm test           # everything; needs the app CLOSED
npm run test:unit  # reducer, installer, platform — runs on any OS, app or no app
```

`npm test` includes the transport suite, which starts its own daemon, so the app
has to be closed: only one process can hold the named pipe. The unit suites have
no such constraint and run on macOS and Linux too, which is most of the loop.

- `test/reducer.test.js` — the state machine's invariants, ported case for case
  from `StateReducerTests.swift`. A late `PreToolUse` does not pull a session out
  of "needs approval"; nothing revives an ended session; a failed turn is never
  counted as free; replay is idempotent.
- `test/installer.test.js` — installing preserves your settings and third-party
  hooks, reinstalling does not duplicate, uninstalling removes only ours, an
  invalid `settings.json` stops the install rather than overwriting it.
- `test/platform.test.js` — the Windows-only parts: why a session is silent,
  which terminal it is in, which processes count as agents, what the tray says.
- `test/transport.test.js` — real integration: starts the daemon, invokes the
  hook the way Claude Code would, and checks state, privacy, delivery, and the
  spool.

Two things here are eyes, not assertions:

```powershell
npm run preview             # popover and settings, filled with made-up sessions
npm run preview -- --shots  # the same, captured to test/shots/ in both themes
npm run icons               # the tray icon at every size and state, to test/icons/
```

Both matter more than usual on this platform. Half the states worth checking —
a failed turn, a blocked session, an agent running with no hooks — need a real
session to be sitting in them, and whether a digit is legible at 16 pixels is a
judgement nothing can assert.

`--shots` runs anywhere Electron does, a Mac included. It cannot show the
acrylic, and the Segoe icon glyphs come out as empty boxes because those fonts
ship with Windows — but layout, spacing, hierarchy and both palettes are all
checkable without booting a VM, which is where most of the mistakes are.

## Two apps, one repository

They are separate implementations of the same product, deliberately. The macOS
app is Swift and native; this one is Node and Electron. Nothing is shared at
build time.

What *is* shared is the design, and that is the thing that can drift. This port
was written against the macOS source as it stood on 24 August; three commits on
27 August changed the state machine, and by the time it was read back it had
five divergences — an event that marks a session free because a *different*
agent finished, a notification rank that made "needs a reply" unreachable, and
three events Claude Code 2.1.247 added that were not registered. None of that
was visible from either side.

So the test suites are the contract. `test/reducer.test.js` is kept case for
case with `Tests/CodeStatusCoreTests/StateReducerTests.swift`, and
`test/installer.test.js` asserts the registered event list against the count in
`ClaudeHookInstaller.events`. When a case is added on one side, add it on the
other — that is the whole mechanism, and without it the next drift is found the
same way this one was.
