# Spike 14 & 15 — the Linux desktop: a tray to draw in, and a window to raise

- **Spike 14 (a tray icon on the common desktops):** partial — the app runs on Linux and
  constructs its tray without dying, under a session bus with libayatana-appindicator present.
  Whether the icon then *appears* on GNOME, KDE or XFCE has still not been seen, because CI has
  no panel to draw it on.
- **Spike 15 (returning to a session):** done for X11 — verified end to end on Linux: the window
  is found by pid, activated through an EWMH window manager, and the foreground window afterwards
  is confirmed to belong to the target process. Wayland is settled by the protocol rather than by
  measurement, which is as settled as it can be.

The record below was originally written with nothing having run on Linux at all. That changed:
the CI `smoke` job now installs the .deb on Ubuntu, launches the app under Xvfb and a session
bus, and drives an event through the invocation it wrote into settings.json. What that job
proves is marked inline. What it still cannot reach is a panel and a compositor, so the tray
row of the capability matrix remains a prediction.

## Hypothesis

The Windows build's platform split — `src/core/` free of the operating system, `src/platform/`
holding everything that is not — is sufficient for Linux, so a third platform is a directory of
small files rather than a third application. And the two things Linux is known to be worse at,
the tray and raising a window, degrade into behaviour the app can state rather than into
behaviour that misleads.

## Method

Read against the protocols and the platform APIs, and implemented behind the seam. Every pure
part — the `/proc/<pid>/stat` parser, the terminal detection, the hook invocation shape, the
ownership rules, the AppImage refusal, the stale-socket handling — is unit-tested and those tests
run on any machine, so they ran here. The daemon, the socket, the pointer file and the whole
`/usr/bin/env` invocation chain were exercised end to end on macOS, which shares the AF_UNIX
semantics and `env(1)` behaviour that the Linux seam depends on.

What that method cannot reach: libappindicator, a panel, a compositor, `xdotool`, `/proc`, and
the packaging. Those are the gaps, and they are named again at the end.

## Result

### The seam held; the port is six files and a dispatcher

Nothing outside `src/platform/` needed a branch. The daemon, the installer, the registry, the
reducer, the notifications and the whole interface are byte-identical between the two platforms,
and CI now fails the build if a `process.platform` check appears in `src/core`, `src/daemon` or
`src/install` — because that is how a seam erodes, one reasonable-looking branch at a time.

Two things had to *move* into the seam that had drifted out of it. The hook invocation shape was
being built in `install/claude.js`, which meant the installer knew what a `.cmd` shim was; and
path-comparison case-folding was a `process.platform` check in the same file. Both are properties
of the platform and both now come from it.

### Three of the six files are simpler than their Windows counterparts

`transport.js` is a Unix socket, which is what the macOS app already uses and what the Windows
transport suite has always been exercised against off-Windows. `process-scan.js` reads `/proc`
directly: a few milliseconds of `readdir` and `readFile`, against a few hundred milliseconds of
`Get-CimInstance Win32_Process`. And `runtime.js` loses the entire shim mechanism, because the
gap it works around — Claude Code's hook schema has no field that sets an environment variable —
is precisely what `env(1)` is for:

```json
{"command": "/usr/bin/env",
 "args": ["ELECTRON_RUN_AS_NODE=1", "/opt/CodeStatus/codestatus",
          "/opt/CodeStatus/resources/hook/hook.js", "--provider", "claude-code"],
 "timeout": 5, "async": true}
```

Still the exec form, no shell, nothing to quote, and no generated file. The one rule it imposes
has a test: `env` applies leading `NAME=VALUE` arguments only up to the first one that is not, so
an assignment placed after the binary is passed *to* the binary rather than applied — silently,
which is the failure mode this whole project is organised against.

### The pointer file cannot live in `$XDG_RUNTIME_DIR`

This is the finding that changed the design, and it is not obvious from the spec.

XDG says durable data goes in `$XDG_DATA_HOME` and sockets in `$XDG_RUNTIME_DIR`, and the
tempting reading is to put everything written at runtime — the socket, the heartbeat, the spool
and the pointer — in the latter. The hook is what makes that wrong.

The hook finds the daemon by reading a pointer file, and it is a separate program with a separate
environment: Claude Code spawns it with whatever the terminal had, not with whatever the app had.
`$XDG_RUNTIME_DIR` is set by pam_systemd for a login session, but an agent started from a systemd
unit, a container, a cron job, or an ssh session without lingering enabled may have no such
variable. A hook in one of those computes a different directory, finds no pointer, and spools to
a place the daemon never drains. Events lost, no error, no log — the exact class of silent
failure the spool exists to prevent.

So the pointer, the heartbeat and the spool live under `$XDG_DATA_HOME`, which falls back to a
path derived from `$HOME` and is therefore identical for both programs. Only the socket goes in
the runtime directory, because the hook never has to guess where it is: it reads the pointer,
which holds the absolute path. Which is what the pointer was always for.

### A socket file outlives its daemon, and a pipe name does not

Verified end to end, on macOS, because AF_UNIX behaves the same there: `SIGKILL` the app and the
socket file remains on disk; the next `bind` then fails with `EADDRINUSE`, reported as though a
second copy were running. The Windows build has no equivalent — the kernel drops a pipe name when
its last handle closes — so the transport seam grew a `prepare`/`finalize` pair that is a no-op
on one platform.

Clearing the stale socket without probing it first is safe only because the caller has already
established it is the only instance, through Electron's single-instance lock. What is checked is
that the thing at the path is a socket, so a mistyped override cannot delete a file.

Also verified there: after `bind`, the socket is `srw-------`. The runtime directories are `0700`,
matching what the macOS app creates.

### AppImage cannot carry this app, and the installer says so

An AppImage is a squashfs image mounted on demand: its contents live under `/tmp/.mount_XXXXXX`
while the app runs and are gone when it exits. Both halves of a hook entry — the Electron binary
and `hook.js` — are inside it.

The consequence is worse than it first looks. The spool exists precisely so that events survive
the app being closed: the hook writes to disk and the daemon replays on the next launch. A hook
that cannot run while the app is down does not degrade that, it deletes exactly the events the
spool was built for. So `writeLauncher` refuses, before `settings.json` is touched, and the
settings screen reports the same refusal from the same function so the button and the explanation
beside it cannot disagree. No AppImage is published.

This is the rule the macOS updater already applies to itself when running from a disk image or a
translocated path: a component that cannot do its job safely disables itself visibly rather than
half-working.

### The tray: GNOME removed it, and Ubuntu put it back

GNOME dropped the system tray from its shell in 3.26 and did not restore it. What serves
StatusNotifierItem now is an extension — `gnome-shell-extension-appindicator` — which **Ubuntu
ships enabled by default** and vanilla GNOME and Fedora do not. On those, the icon does not
appear and there is no error to see. KDE, XFCE, Cinnamon, MATE, Budgie and LXQt each have a tray
of their own.

Two consequences follow that Windows does not have, and both are structural rather than
incidental:

- **`tray.getBounds()` returns zeros.** It is documented as macOS and Windows only, and
  StatusNotifierItem genuinely does not tell an application where the panel drew its icon — the
  host owns the drawing. There is no API to add. The popover's corner is therefore inferred from
  the only thing the display does report: a panel reserves space, so a gap between the display's
  bounds and its work area says where it is. Right-hand side either way.
- **The `click` event is not emitted.** With libappindicator the panel opens the menu the
  application supplied. So "Open CodeStatus" is the first item of that menu, and on this platform
  it is the only way in rather than a convenience.

### Raising a window: X11 can, Wayland will not, XWayland mostly does

Under X11 a window carries `_NET_WM_PID`, so the window belonging to an agent's process can be
found and activated — `xdotool search --pid` then `windowactivate`, with `wmctrl -l -p` as the
fallback, since neither tool is installed by default everywhere and between them the coverage is
most machines. `windowactivate` rather than `windowraise`: raising changes stacking without
moving focus, which puts the terminal on screen and leaves the user typing into CodeStatus.

Under Wayland it is not possible, and not for want of an API. There is no protocol by which one
client asks the compositor to raise another client's window, deliberately — it is the mechanism
that stops any application stealing focus. `xdg-activation` covers an app *handing over* focus it
already holds, which is a different situation: the agent never asked to be raised, so there is no
activation token to pass.

The nuance that makes the X11 path worth having anyway is that most terminals still run through
XWayland even on a Wayland session, and an XWayland window is a real X11 window with a real
`_NET_WM_PID`. So the attempt is made whenever there is a `DISPLAY`, and it succeeds more often
than the session type alone predicts. What it cannot do is raise a native Wayland window, and
those rows fall back to opening the project folder — the same fallback Windows already uses when
no ancestor process has a window.

`focusCapability()` exists so this is stated on the settings screen rather than discovered from a
row that quietly opens a folder.

### Starting with the session is a file, not an API

`app.setLoginItemSettings` is macOS and Windows only. On Linux it is a no-op that reports back
whatever was last set, which is worse than being absent: the toggle would appear to work. There
is no API because Linux has no login-item registry — it has the XDG autostart spec, honoured by
every desktop listed above, which is a `.desktop` file in `~/.config/autostart`. So the seam
writes one, and refuses when the only path it could name is inside an AppImage mount.

## What running it on Linux settled

The `smoke` job in `.github/workflows/desktop.yml` installs the package and drives the installed
app. It now covers, on Ubuntu:

- **The package installs.** `apt` resolves the dependencies electron-builder declared against a
  machine that has none of them, and puts the binary and the hook where the hook entry will name
  them. The first attempt at a Linux release failed here, for the most ordinary reason available:
  fpm needs a maintainer for a `.deb`, NSIS never did, so nothing had ever set one.
- **The app starts and stays up**, past the four periodic timers — the trap that once crashed
  every launch four seconds in.
- **The `$XDG_RUNTIME_DIR` split is real rather than theoretical.** The runner has that variable,
  so the socket goes to `/run/user/<uid>/CodeStatus/` while the pointer stays in the data
  directory, and the pointer resolves. The first version of the test guessed the socket path
  instead of reading the pointer and failed — making exactly the mistake the pointer exists to
  stop the hook from making.
- **An event survives the whole installed chain.** The command and argument vector are read back
  out of the `settings.json` the installer wrote, not written by the test, and the session
  appears in the running app's snapshot with the prompt that rode in on it absent.
- **A window can be raised by pid**, and it is the right one: the foreground window afterwards is
  confirmed to belong to the process asked for.

## Limitations

Restating the ones that decide whether to believe the rest:

1. **No panel, no compositor.** The app draws a tray icon and nothing in CI can display one, so
   "the icon appears on GNOME with the extension, and on KDE without it" is still read from
   documentation. This is the gap that most needs a person with a laptop.
2. **X11 only.** The focus path is verified under Xvfb, which is X11. The Wayland answer is a
   protocol fact rather than a measurement, and the XWayland middle case is untested.
3. **The popover corner is a heuristic.** Panel position inferred from reserved space is right on
   every configuration considered and is not something the platform confirms, unlike the Windows
   path where the tray reports its own bounds.
4. **No real agent.** The event delivered through the installed chain is a synthetic payload. A
   Claude Code session has never driven this build on Linux.
5. **Codex is not ported**, here as on Windows.

## Architectural decisions

- The Windows and Linux builds are **one app with a seam**, not two ports. They are the same
  language and the same runtime; a fork would mean a third copy of the state machine, and the
  second copy is what caused the drift recorded in `desktop/README.md`.
- **CI enforces the seam.** `process.platform` outside `src/platform/` and `src/main.js` fails
  the build.
- **Both seams are tested from either machine.** `platform.test.js` requires `win32/` and
  `linux/` directly; `installer.test.js` runs twice, once per seam. The Windows port learned once
  that code which only ever runs on its own operating system gets its first execution from a
  user.
- **The pointer file lives in `$XDG_DATA_HOME`**, and only the socket in `$XDG_RUNTIME_DIR`.
- **No AppImage is published**, and installing from one is refused rather than half-supported.
- **Focus degrades to opening the folder, and says why**, rather than failing silently or
  pretending a Wayland session can be asked.

## V1 impact

Linux moves from "not supported" to shipped-with-stated-limits. On Ubuntu, KDE or XFCE under X11
it is the Windows build's equal. On Fedora GNOME under Wayland it is a notifier that cannot
always take you back, and both halves of that are visible in the app rather than in a bug report.

The next thing worth doing is still not more Linux code. It is opening it on one machine per row
of the tray matrix — the one claim CI cannot reach — and pointing a real Claude Code session at
it.
