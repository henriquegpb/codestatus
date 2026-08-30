# CodeStatus for Windows

Session monitor for Claude Code that lives in the system tray. A port of the
macOS app at the root of this repository, which is native Swift.

It answers one question: **is a session waiting for me?** The tray icon shows
the count, and you get a notification when a session starts needing you.

## Install

**Prerequisite:** Node.js 18+ ([nodejs.org](https://nodejs.org)). Not only to
assemble the app — every hook firing is a `node hook.js`, so without Node the
app starts and stays permanently empty. The installer checks and stops with a
clear message.

```powershell
cd windows
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```

Add `-StartWithWindows` to have it come up with Windows.

The installer checks Node and Claude Code, fetches the dependencies, **runs the
tests on the target machine**, and creates the Start Menu and desktop shortcuts.
It does not touch your `settings.json` — connecting the hooks stays an explicit
action, from the tray menu.

To hand the app to a machine without git, `scripts\package.ps1` produces a small
zip of the source. `node_modules` is left out: it is ~370 MB, and the Electron
binary is specific to platform and architecture, so copying it saves nothing and
can break on the target.

One thing the installer covers: `npm install` installs the electron *package*,
but what downloads the binary is its postinstall, which fails often and lets npm
carry on as though it had succeeded. The script checks and, if it is missing,
runs `node node_modules/electron/install.js` by hand.

Then:

1. **Open the app** — double-click `CodeStatus.vbs`. It goes straight to the
   tray, with no terminal window. A grey icon appears near the clock.
2. **Connect Claude Code** — right-click the icon and choose *Connect Claude
   Code*. That writes the hooks into your `~/.claude/settings.json`, with an
   automatic backup.
3. **Open a new Claude Code session.** Sessions that were already open will not
   appear: Claude Code reads its hook configuration once, at session start.

If you need to see error messages, use `scripts\start.cmd` instead of the
`.vbs` — same app, with the console visible.

## Reading the icon

macOS lets an app write text into the menu bar; the Windows tray does not, so
the count is drawn inside the icon. The colour answers the same question the
whole app answers:

| Colour | Meaning |
|---|---|
| amber | a session needs you — approval, a reply, or a failure |
| blue | sessions working |
| green | sessions free, waiting for a prompt |
| grey | no active sessions |

The number is the count of the most urgent situation present; `+` means more
than nine. Hover for the full text, or click to open the panel.

In the panel, clicking a session brings its terminal window to the front.

## States

The vocabulary is the original's — it is the logic that stops the app lying
about what a session is doing:

- **Busy** — has a prompt: thinking, generating, or running tools
- **Free** — the turn ended and the session is still open, ready for another
- **Needs approval** — blocked waiting for you to approve a tool
- **Needs a reply** — blocked waiting for you to answer something
- **Failed** — the turn ended in an error, and is never shown as free
- **Reconnecting** — the app restarted and the state is not yet trustworthy

Absence of evidence is represented explicitly, never guessed. A session quiet
for ten minutes in the middle of a tool call is still *busy* — only the
confidence in that drops. Elapsed time never changes a state on its own.

## Notifications

Three switches in the tray menu, all on by default:

- **Tell me when a turn finishes** — a toast when a turn ends, with how long the
  session took (*"Finished. 4m in this session."*).
- **Tell me when a session needs me** — approval, a reply, or a failure.
- **Play a sound.**

Clicking the notification brings that session's window to the front.

The original app does **not** announce completion — it interrupts only when
there is something to do. Here it became an option rather than an imposition,
but the design decision behind it matters: "arrived at free" is not the same as
"finished". A `SessionStart` also arrives at free, because a freshly opened
session is idle waiting for a prompt. Announcing there would say *"finished"* at
the exact moment nothing has started.

So the rule looks at the **origin** of the transition, not the destination: only
something that was in progress can finish — working, or stopped waiting for you
to unblock it. A `reconnecting → free` after an app restart does not count
either. There is a test for each of those cases, including one that walks a
whole turn and checks it produces exactly **one** notification, at the `Stop`.

Preferences live in `%LOCALAPPDATA%\CodeStatus\state\prefs.json`.

## Privacy

All processing is local. There is no server, no telemetry, and no network.

The hook reads the payload Claude Code sends and extracts **only** an allowlist
of metadata (`session_id`, `hook_event_name`, `cwd`, `tool_name`, `model`, and a
few others). The prompt, the response, tool input and output, messages, and the
transcript path never cross the transport. That is tested: see the case "no
sensitive content crossed the transport" in `test/transport.test.js`, which
injects real sensitive content and fails if any part of it leaks.

## What changed from the original

The core — state machine, event ordering, deduplication, session registry — is a
faithful port with the same invariants and the same tests. What had to change is
everything that touched the operating system:

| macOS (original) | Windows (here) |
|---|---|
| Swift 6 + AppKit/SwiftUI | Node.js + Electron |
| Unix domain socket | Named pipe (`\\.\pipe\codestatus-<user>`) |
| Compiled `codestatus-hook` binary | `hook/hook.js` run through `node` |
| `~/Library/Application Support/CodeStatus` | `%LOCALAPPDATA%\CodeStatus` |
| Text in the menu bar | Count drawn inside the tray icon |
| `TERM_PROGRAM` names the terminal | `WT_SESSION` / `VSCODE_INJECTION` |
| AppleScript selects the exact tab | Raises the window hosting the process |
| Process exit via kqueue | Periodic pid check |

The whole `sun_path` mechanism from the original is gone: named pipes live in
their own namespace and have no path limit, so the `/tmp` fallback and the
directory validation have no equivalent here.

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
command line. The result: the hook never fired — no error, no log, nothing in
the spool. Just silence. The exec form also disposes of quoting paths that
contain spaces (`C:\Program Files`).

There is a regression test for it, and the ownership detector recognises both
formats so anyone who installed before the fix does not end up with duplicate
entries firing the hook twice.

**Codex is not ported.** The Codex installer in the original exists almost
entirely to work around a path-parsing bug in Codex on macOS, which does not
apply here. The hook already accepts `--provider codex` if it is ever wanted.

**Known limitation:** Windows does not expose terminal tabs individually, not
even in Windows Terminal. Clicking a session raises the *window* hosting the
agent's process, walking up the process tree until one has a window. If none
does, it opens the project folder.

## Layout

```
windows/
├── hook/hook.js         the observer Claude Code invokes; no imports from src/
├── src/
│   ├── core/            platform-free: the state machine and everything it needs
│   ├── platform/        the Windows seam: paths, pipe name, window focus
│   ├── install/         writing and removing our hook entries
│   ├── daemon/          the transport, the spool, liveness, persistence
│   ├── ui/              tray icon and the panel
│   └── main.js          the Electron main process, wiring the above together
├── test/
└── scripts/             install, package, and a console launcher for debugging
```

`src/core/` has no Windows in it and no Electron in it. `src/platform/` is the
part that does. That split is deliberate.

## Tests

```powershell
npm test           # everything; needs the app CLOSED
npm run test:unit  # reducer and installer — runs on any OS, app or no app
```

`npm test` includes the transport suite, which starts its own daemon, so the app
has to be closed: only one process can hold the named pipe.

- `test/reducer.test.js` — the state machine's invariants, ported case for case
  from `StateReducerTests.swift`. A late `PreToolUse` does not pull a session out
  of "needs approval"; nothing revives an ended session; a failed turn is never
  counted as free; replay is idempotent.
- `test/installer.test.js` — installing preserves your settings and third-party
  hooks, reinstalling does not duplicate, uninstalling removes only ours, an
  invalid `settings.json` stops the install rather than overwriting it.
- `test/transport.test.js` — real integration: starts the daemon, invokes the
  hook the way Claude Code would, and checks state, privacy, and the spool.
- `npm run icons` writes the tray artwork to `test/icons/` so it can be checked
  by eye.

## Uninstall

From the tray menu: *Disconnect Claude Code* (removes the hooks from
`settings.json`), then *Quit*. Backups of your `settings.json` stay in
`%LOCALAPPDATA%\CodeStatus\backups`.
