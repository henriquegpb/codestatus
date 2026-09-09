# CodeStatus for Windows and Linux

A second implementation of CodeStatus, for the Windows system tray and the Linux
panel. It answers the same single question as the macOS app: **is a session
waiting for me?**

Everything under `desktop/` is this app. Everything outside it — `Sources/`,
`Tests/`, `Package.swift`, `scripts/` — is the macOS app, and the two share no
build, no dependency, and no runtime. See [Two apps, one repository](#two-apps-one-repository).

## Credit

The original Windows port was written by **Ricardo Mone**, from scratch, against
the macOS source. The state machine, the event ordering, the deduplicator, the
installer's ownership rules, the named-pipe transport, and the discovery that
Claude Code's hook entries must use the exec form on Windows are all theirs.

What this version adds: the state-machine changes upstream landed after that
port was written, a process scanner so the app can explain a silent agent, a
Fluent-styled interface, three fixes noted in the history, and the Linux
platform seam.

## Install

### Windows

Download **CodeStatus-Setup.exe** from the
[latest release](https://github.com/henriquegpb/codestatus/releases/latest)
— or the `-arm64` one on Windows on Arm, which is also what a Windows VM on an
Apple Silicon Mac runs. Nothing needs to be installed first: the app carries its
own runtime, including the one the hook runs on.

The installer is **not code-signed yet**, so SmartScreen shows a blue panel
saying the publisher is unrecognised. *More info* → *Run anyway*. There is no
way around that short of an Authenticode certificate, and pretending otherwise
would be worse than saying it.

### Linux

Download **CodeStatus.deb** or **CodeStatus.rpm** from the
[latest release](https://github.com/henriquegpb/codestatus/releases/latest),
and install it the usual way:

```sh
sudo apt install ./CodeStatus.deb     # Debian, Ubuntu, Mint, Pop!_OS
sudo dnf install ./CodeStatus.rpm     # Fedora, RHEL, openSUSE
```

Read [What works on which desktop](#what-works-on-which-desktop) first, because
on GNOME there is one thing to install alongside it.

**There is deliberately no AppImage.** An AppImage is a squashfs image mounted
on demand: its files exist under `/tmp/.mount_XXXXXX` while the app is open and
are gone the moment it quits. Both halves of a hook entry live in there, so an
entry written from one names paths that disappear — and the spool, which exists
precisely so events survive the app being closed, would lose exactly the events
it was built to keep. The installer refuses rather than writing a configuration
that works in testing and fails in the one case it exists for. If you have no
other option, `--appimage-extract` it and run `AppRun` from where you put it.

### Then

1. **Open CodeStatus.** It goes straight to the tray. Windows 11 hides new tray
   icons behind the `^` arrow — drag it out once and it stays out.
2. **Choose Connect Claude Code.** This writes the hooks into
   `~/.claude/settings.json`, with an automatic backup.
3. **Start a new Claude Code session.** Sessions that were already open will
   never appear: Claude Code reads its hook configuration once, at session start.

Uninstalling through Windows removes the hook entries first, so the app does not
leave entries behind pointing at files it took with it. **The Linux packages
deliberately do not**: `apt remove` runs its scripts as root, and the entries
live in each user's `~/.claude/settings.json` — a root script cannot know which
users have them and has no business rewriting the configuration of the ones it
guesses. Choose Disconnect first. An entry left behind is handled the way the
design already handles one: the hook finds a stale heartbeat and drops the
event.

### From source

For working on the app, or trying a branch. This is the path that still needs
[Node.js 18+](https://nodejs.org) — to fetch dependencies and run the tests, not
to run the hook.

```powershell
cd desktop
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```

```sh
cd desktop
bash scripts/install.sh
```

Add `-StartWithWindows` or `--start-with-session` to have it come up with the
session. Both scripts fetch dependencies, run the tests on the target machine,
and create the launcher. Neither touches your `settings.json`. The Linux one
also reports what your desktop can and cannot do before installing anything,
rather than leaving you to work it out from a row that quietly opens a folder.

`scripts\package.ps1` produces a ~200 KB zip of the source, for a machine
without git.

## What works on which desktop

Two things about Linux are not the app's to fix, and both are stated here rather
than discovered.

**The tray.** GNOME removed the system tray from its shell in 3.26 and did not
bring it back. What replaced it is the StatusNotifierItem protocol served by an
extension, which **Ubuntu ships enabled by default** and vanilla GNOME and
Fedora do not — so on those the icon does not appear at all, with no error. KDE,
XFCE, Cinnamon, MATE, Budgie and LXQt all have a tray of their own.

**Clicking a session.** Under X11 a window carries `_NET_WM_PID`, so the window
belonging to an agent can be found and activated. Under Wayland it cannot:
there is no protocol by which one client asks the compositor to raise another
client's window, and that is the point — it is how Wayland stops any application
from stealing focus. `xdg-activation` covers an app *handing over* focus it
already has, which is not this: the agent never asked to be raised, so there is
no token to pass.

The nuance worth knowing is that most terminals still run through XWayland even
on a Wayland session, and an XWayland window is a real X11 window. So the app
tries anyway whenever there is a `DISPLAY`, and it succeeds more often than the
session type alone suggests. What it cannot do is raise a native Wayland window,
and those rows open the project folder instead.

| | Tray icon | Click to raise a terminal |
|---|---|---|
| Ubuntu (GNOME), X11 | yes | yes |
| Ubuntu (GNOME), Wayland | yes | XWayland terminals only |
| Fedora / vanilla GNOME | needs `gnome-shell-extension-appindicator` | as above, by session type |
| KDE, XFCE, Cinnamon, MATE, Budgie | yes | X11 yes; Wayland, XWayland only |

Raising a window needs **`xdotool` or `wmctrl`** installed. The .deb recommends
`xdotool`; neither is a hard dependency, because the app is useful without one
and refusing to install over a focus convenience would be the wrong trade.

## Reading the tray icon

macOS lets an app write text into the menu bar, so the mac build shows
`● 1 free  ● 2 busy`. Neither tray here takes any — the Windows notification
area and StatusNotifierItem both accept one icon and a tooltip — so the count is
drawn inside it, and the colour carries the same question the whole app answers:

| Colour | Meaning |
|---|---|
| red | a session needs you — approval, a reply, or a failure |
| amber | sessions working |
| green | sessions free, waiting for a prompt |
| grey | no active sessions |

The number is the count of the most urgent situation present; `+` means more
than nine. The full breakdown lives in the tooltip, and at the top of the
popover — that summary line exists on these platforms precisely because the tray
cannot show it.

On Windows a left click opens the popover. **On Linux there is no left click to
bind**: with libappindicator the panel owns the icon and a click opens the menu
the application supplied, and Electron documents the `click` event as not
emitted there. So "Open CodeStatus" is the first item of that menu, and on this
platform it is the only way in.

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

On Linux the runtime directories are created `0700` and the socket `0600`,
matching what the macOS app does. On a single-user Windows profile the default
ACL already amounts to the same thing.

## What differs from macOS

The core — state machine, event ordering, deduplication, session registry — is a
faithful port with the same invariants and the same tests. What had to change is
everything that touched the operating system:

| macOS | Windows | Linux |
|---|---|---|
| Swift 6 + AppKit/SwiftUI | Node.js + Electron | Node.js + Electron |
| Unix domain socket | Named pipe (`\\.\pipe\codestatus-<user>`) | Unix domain socket |
| Compiled `codestatus-hook` binary | `hook/hook.js` on the app's own Electron | same |
| `~/Library/Application Support/CodeStatus` | `%LOCALAPPDATA%\CodeStatus` | `$XDG_DATA_HOME/CodeStatus` |
| Text in the menu bar | Count drawn inside the tray icon | same |
| `TERM_PROGRAM` names the terminal | Environment, then the process tree | same, with a much longer list |
| AppleScript selects the exact tab | Raises the window hosting the process | X11: same. Wayland: cannot |
| Process exit via kqueue | Polled pid liveness | same |
| `libproc` lists running agents | One PowerShell pass over `Win32_Process` | a walk over `/proc` |
| Login item API | Login item API | XDG `.desktop` file in `~/.config/autostart` |

Linux is the one platform where a piece of this is cheaper than the original:
`/proc` *is* the process table, so the scan is a few milliseconds of `readdir`
and `readFile` with no subprocess to spawn, against a few hundred milliseconds
of PowerShell on Windows.

**Codex is not ported.** The Codex installer on macOS exists almost entirely to
work around a path-parsing bug in Codex on that platform, which does not apply
here. The hook already accepts `--provider codex` if it is ever wanted.

### The gotcha that cost the most: exec form vs shell form

On Windows the hook entry **must** use `args`:

```json
{
  "type": "command",
  "command": "C:\\Windows\\System32\\cmd.exe",
  "args": ["C:\\Users\\you\\AppData\\Local\\CodeStatus\\bin\\hook-claude-code.cmd"],
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
of both `runtime.js` files, and it is the clearest place the two platforms
diverge.

The app ships an Electron binary, and an Electron binary *is* Node when
`ELECTRON_RUN_AS_NODE` is set. With no way to set it in the hook entry, the
installer would otherwise have to carry a second runtime to run 250 lines of
JavaScript — `node.exe` alone is 78 MB, which is most of an installer, for a job
the binary next to it can already do.

**On Windows** the installer writes a four-line `.cmd` that sets the variable and
hands over, and registers `cmd.exe /c <shim>`. Still the exec form: the
executable is cmd.exe, with an argument vector we control. It costs one cmd.exe
per event, around ten milliseconds.

The shim takes no arguments, and that is load-bearing. Its path contains the
user's profile name, which may contain a space, so Windows quotes it — and
`cmd /c` preserves those quotes only when nothing follows the closing one. Put
`--provider claude-code` after it and cmd strips the pair instead, then tries to
run `C:\Users\John`. The provider is baked into the shim for that reason, and a
second agent would get a second shim.

**On Linux none of that exists**, because setting a variable for one command is
exactly what `env(1)` is:

```json
{
  "type": "command",
  "command": "/usr/bin/env",
  "args": [
    "ELECTRON_RUN_AS_NODE=1",
    "/opt/CodeStatus/codestatus",
    "/opt/CodeStatus/resources/hook/hook.js",
    "--provider", "claude-code"
  ],
  "timeout": 5,
  "async": true
}
```

No shim file, no shell cold start, and nothing to quote — `/usr/bin/env` is one
of the two absolute paths present on essentially every Linux, NixOS included.
The one rule it does impose has a test of its own: `env` applies leading
`NAME=VALUE` arguments only up to the first one that is not, so an assignment
placed after the binary is passed *to* the binary instead of applied, silently.

### Where the socket goes, and why the pointer does not go with it

The XDG spec puts sockets in `$XDG_RUNTIME_DIR`, and the tempting reading is to
move everything written at runtime there. The daemon does not, and the reason is
the hook.

The hook finds the daemon by reading a pointer file, and it can only do that if
it computes the same directory the daemon wrote it to. `$XDG_RUNTIME_DIR` is set
by pam_systemd for a login session — but an agent started from a systemd unit, a
container, a cron job, or an ssh session without lingering may not have it. A
hook in one of those would compute a different directory, find no pointer, and
spool to a place nothing drains: events lost, silently, which is the exact
failure this app exists not to have.

So the pointer, the heartbeat and the spool live under `$XDG_DATA_HOME`, which
falls back to a path derived from `$HOME` and is therefore always the same for
both programs. Only the socket goes in the runtime directory, because the hook
never has to guess where it is — it reads the pointer, which holds the absolute
path. Which is what the pointer was always for.

### The cost this build still carries

The macOS hook is a compiled, deliberately Foundation-free binary, because it
runs on every agent tool call. Here it is a Node cold start — plus a cmd.exe on
Windows — tens of milliseconds of real work per event, times fourteen registered
events. `async: true` keeps it off the agent's critical path; it does not make
it free.

A compiled hook would remove the cold start and the runtime question together,
and it is the next thing worth doing. Nothing in the design depends on the
hook's language: it writes one NDJSON line to a socket.

## Known limitations

- **Windows does not expose terminal tabs**, not even in Windows Terminal.
  Clicking a session raises the *window* hosting the agent's process, walking up
  the process tree until one has a window. If none does, it opens the project
  folder. Linux has the same limit, plus the Wayland one above.
- **New tray icons are hidden by default** on Windows 11, behind the `^` arrow.
  There is no API to pin one — Microsoft removed it deliberately. The user has
  to drag it out once.
- **The popover cannot be anchored to the tray icon on Linux.**
  `tray.getBounds()` is macOS and Windows only, and StatusNotifierItem genuinely
  does not tell an application where the panel drew its icon. The corner is
  inferred from where the panel reserved space — a gap above the work area means
  a top panel — which is right on every desktop tested and is a guess in a way
  the Windows path is not.
- **No acrylic anywhere but Windows 11.** The DWM materials arrived in build
  22000; below that, and on Linux, the windows paint a solid Fluent surface.
  A blurred background on Linux is the compositor's to grant and Electron has no
  way to request one.
- **The installers are unsigned.** SmartScreen warns once on Windows, per the
  note above. Debian and RPM signing is a repository-level concern and there is
  no repository yet.

## Layout

```
desktop/
├── hook/hook.js         the observer Claude Code invokes; no imports from src/
├── src/
│   ├── core/            platform-free: the state machine and everything it needs
│   ├── platform/        the seam
│   │   ├── which.js     picks a directory from process.platform
│   │   ├── paths.js     …and five more files that only forward
│   │   ├── win32/       named pipe, PowerShell scan, the .cmd shim, SetForegroundWindow
│   │   └── linux/       Unix socket, /proc scan, env(1), xdotool, XDG autostart
│   ├── install/         writing and removing our hook entries
│   ├── daemon/          the transport, the spool, liveness, persistence
│   ├── ui/              tray icon, popover, settings window
│   └── main.js          the Electron main process, wiring the above together
├── test/
├── scripts/             source install, packaging, console launcher
└── build/               icons, and the NSIS hooks for the published installer
```

`src/core/` has no operating system in it and no Electron in it. `src/platform/`
is the part that does: seven files per platform, of which six are under 150
lines. Everything else — the daemon, the installer, the whole interface — reads
identically on both, and **CI enforces that**: a `process.platform` check
appearing in `src/core`, `src/daemon` or `src/install` fails the build, because
that is how a seam erodes, one reasonable-looking branch at a time.

`src/main.js` is exempt. It draws the tray and the windows, and those genuinely
differ.

## Tests

```sh
npm test           # everything; on Windows, needs the app CLOSED
npm run test:unit  # reducer, installer, platform — no daemon, no app
```

Everything runs on any OS, and **both platform seams are exercised wherever the
suite runs**. Almost everything in `src/platform/` is a pure function or a
filesystem call against a temporary directory, so `platform.test.js` requires
`win32/` and `linux/` directly rather than through the dispatcher, and
`installer.test.js` runs twice — `--seam win32` and `--seam linux` — so the
Windows entry format is checked on a Linux runner and the Linux one on a Mac.

That any of this runs off its own platform is deliberate. The daemon schedules
four periodic tasks, and while the suite only ran on a CI runner one of them
called a method that did not exist — a crash four seconds into every launch,
invisible to every other test and to the app's own screenshots.

- `test/reducer.test.js` — the state machine's invariants, ported case for case
  from `StateReducerTests.swift`. A late `PreToolUse` does not pull a session out
  of "needs approval"; nothing revives an ended session; a failed turn is never
  counted as free; replay is idempotent.
- `test/installer.test.js` — installing preserves your settings and third-party
  hooks, reinstalling does not duplicate, uninstalling removes only ours, an
  invalid `settings.json` stops the install rather than overwriting it. Then,
  per seam: the cmd.exe quoting rule, and the `env` argument order.
- `test/platform.test.js` — both seams: why a session is silent, which terminal
  a session is in, which processes count as agents, `/proc/<pid>/stat` parsing,
  the AppImage refusal, stale socket handling, and what the tray says.
- `test/transport.test.js` — real integration: starts the daemon, invokes the
  hook, and checks state, privacy, delivery, the scheduled tasks and the spool.
  It also walks the chain Claude Code actually uses — on Windows cmd.exe, the
  generated shim and the Electron binary as a Node interpreter, including from a
  directory whose name contains a space; elsewhere `/usr/bin/env`, the variable,
  the interpreter and the hook, including a hook path containing a space.

Two things here are eyes, not assertions:

```sh
npm run preview             # popover and settings, filled with made-up sessions
npm run preview -- --shots  # the same, captured to test/shots/ in both themes
npm run icons               # the tray icon at every size and state, to test/icons/
```

Both matter more than usual on these platforms. Half the states worth checking —
a failed turn, a blocked session, an agent running with no hooks — need a real
session to be sitting in them, and whether a digit is legible at 16 pixels is a
judgement nothing can assert. The preview renders the settings screen as the
platform it is running on, so the wording that changes with the seam is looked
at rather than assumed.

`--shots` runs anywhere Electron does, a Mac included. It cannot show the
acrylic, and the Segoe icon glyphs come out as empty boxes because those fonts
ship with Windows — but layout, spacing, hierarchy and both palettes are all
checkable without booting a VM, which is where most of the mistakes are.

## Two apps, one repository

They are separate implementations of the same product, deliberately. The macOS
app is Swift and native; this one is Node and Electron. Nothing is shared at
build time.

Windows and Linux are *not* separate that way, and that is a considered
decision rather than a shortcut. They are the same language and the same
runtime, so a fork would mean a third copy of the state machine — and the
history below is what a second copy already cost. One app with a seam is the
arrangement where a platform difference has to be written down in the file named
after that platform, instead of accumulating as branches everywhere.

What *is* shared with macOS is the design, and that is the thing that can drift.
This port was written against the macOS source as it stood on 24 August; three
commits on 27 August changed the state machine, and by the time it was read back
it had five divergences — an event that marks a session free because a
*different* agent finished, a notification rank that made "needs a reply"
unreachable, and three events Claude Code 2.1.247 added that were not registered.
None of that was visible from either side.

So the test suites are the contract. `test/reducer.test.js` is kept case for
case with `Tests/CodeStatusCoreTests/StateReducerTests.swift`, and
`test/installer.test.js` asserts the registered event list against the count in
`ClaudeHookInstaller.events`. When a case is added on one side, add it on the
other — that is the whole mechanism, and without it the next drift is found the
same way this one was.
