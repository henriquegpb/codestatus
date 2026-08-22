# Spike 5 — PID → TTY → Terminal tab mapping

**Partial.** The public API surface is confirmed and the identifiers are in hand; activating a
specific tab and the Automation permission prompt still need to be exercised against a running
Terminal with several tabs open.

## Hypothesis

A session discovered through a hook can be mapped back to the exact Terminal.app tab it is
running in, using only public API — no Accessibility, no screen scraping, no private frameworks.

## Method

1. Dumped Terminal.app's scripting dictionary: `sdef /System/Applications/Utilities/Terminal.app`.
2. Inspected live agent processes with `ps` to see what identifiers are actually available.
3. Read how comparable tools do it (`bacongravy/your-turn`, `sokojh/ai-notifier-swift`).

## Result

### Terminal.app exposes exactly what we need, publicly

From the scripting dictionary:

```xml
<class name="tab" code="ttab">
  <property name="tty"       code="ttty" type="text"    access="r"/>
  <property name="processes" code="prcs"                access="r"/>
  <property name="selected"  code="tbsl" type="boolean"/>
  <property name="custom title" code="titl" type="text"/>
  <property name="busy"      code="busy" type="boolean" access="r"/>
</class>
```

`tab.tty` is a readable, public, scriptable property. Matching it against a session's TTY gives
an exact tab, and `selected` plus the window's `index`/`frontmost` bring it forward.

### Three independent identifier sources, which is fortunate

1. **`TERM_PROGRAM` / `TERM_SESSION_ID`** — the terminal exports these into the shell, the shell
   into the agent, and the agent into our hook. The hook captures both at effectively zero cost.
   `Apple_Terminal`, `iTerm.app`, `WarpTerminal`, `vscode` identify the host directly, without
   walking the process tree at all.
2. **`getppid()`** — the hook's parent is the agent process. The daemon resolves it to TTY, cwd,
   and start time via `proc_pidinfo`. This is more reliable than anything the hook could
   determine itself: calling `tty` in a hook returns nothing, because the hook's stdin is the
   payload pipe rather than the terminal.
3. **The process tree** — walking the ppid chain reaches `login` → shell → agent, and for editor
   sessions reaches VS Code's helper processes instead.

Observed live: VS Code-hosted agents have TTY `??` and a ppid pointing at the extension host,
which cleanly distinguishes them from terminal sessions without any special-casing.

### Automation permission is the real constraint

Reading `tab.tty` is an Apple Event to another application, so it requires the user's Automation
grant for Terminal. A denied grant surfaces as AppleScript error **`-1743`** — a specific code
worth checking for, because it lets "Open session" degrade gracefully to plain app activation
instead of appearing to do nothing.

### A dead end worth recording

`sokojh/ai-notifier-swift` offers Approve/Deny buttons directly on its notifications. It
implements them by sending the literal keystroke `"1"` into the tab matched by TTY:

```swift
static let approveResponse = "1"  // First option in all CLIs
```

This is rejected for CodeStatus. It assumes the approval prompt is still on screen and that
option 1 means approve; if the agent has moved on, `"1"` lands in the prompt box or the shell.
Their own comment notes the ordering was determined by "actual CLI testing", which is to say it
is unversioned and can change under them. The spec forbids writing to arbitrary TTYs and
simulating keystrokes, and this is a good illustration of why.

## Limitations

- Not yet exercised: selecting a tab across several windows, and the first-run permission
  prompt.
- Cross-Space behaviour on macOS 26 is a separate open question. `idonecc/Coding-Done-Alert`
  documents that Tahoe regressed programmatic Space switching and cross-Space window
  enumeration badly enough that they resorted to yabai, which requires disabling SIP. Our
  mechanism is different — we ask the *application* to activate and let macOS follow its window
  — but that needs verifying (spike 7).
- Terminal multiplexers (tmux, zellij) put a layer between the agent and the tab; the TTY will
  be the multiplexer's pane, not the tab. Out of scope for V1.

## Architectural decision

1. **Match on TTY, obtained from the agent process, not from the hook.**
2. **Request Automation permission lazily** — only on the first "Open session" click for a
   Terminal-hosted session, never during onboarding. The spec is explicit that invasive
   permissions are requested at the moment a feature needs them.
3. **Detect `-1743` explicitly** and fall back to `NSWorkspace.open` on Terminal.app. Right app,
   wrong tab is a fallback the spec accepts; a silent no-op is not.
4. **Never write to a TTY, never inject keystrokes.** Sessions we cannot control safely show
   `Open session` and nothing more.
5. **Use `TERM_PROGRAM` as the primary host signal**, with the process tree as corroboration —
   cheaper and more direct than tree-walking alone.

## V1 impact

- `ControlTarget` carries `tty`, `termSessionID`, `hostApplication`, and `workspacePath`, which
  between them cover Terminal tabs and VS Code workspaces.
- `Capability.canIdentifyExactWindow` is set only when a TTY match actually succeeded, so the
  UI can be honest about which sessions it can return the user to precisely.
