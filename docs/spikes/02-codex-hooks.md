# Spike 3 & 4 — Codex lifecycle hooks

- **Spike 3 (Codex CLI):** done
- **Spike 4 (Codex in VS Code):** done — see "Spike 4 resolved" below
- **Follow-up (why nothing ever arrived):** done — see "The install was correct and still never ran"

## Hypothesis

Codex exposes lifecycle hooks comparable to Claude Code's, sufficient to drive the state machine
without falling back to the older `notify` / `agent-turn-complete` mechanism.

## Method

1. Located the CLI. `codex` is not on `PATH`, but `/Applications/Codex.app` is installed and
   bundles it at `Contents/Resources/codex`. The VS Code extension `openai.chatgpt` bundles a
   *second, different* build at `bin/macos-aarch64/codex`.
2. `codex --version` on both.
3. `codex features list` to check whether hooks are gated behind a flag.
4. `strings` over the binary to enumerate the hook event names, config keys, and error messages
   the shipped build actually contains — rather than trusting the docs.
5. Read the official documentation at `developers.openai.com/codex/hooks`, which 308-redirects
   to `learn.chatgpt.com/docs/hooks`.
6. Inspected the real `~/.codex/config.toml` on this machine.

## Result

**Two versions coexist**, both reading the same `~/.codex`:

| Build | Version |
|---|---|
| `/Applications/Codex.app/Contents/Resources/codex` | 0.138.0-alpha.7 |
| `~/.vscode/extensions/openai.chatgpt-*/bin/macos-aarch64/codex` | 0.149.0-alpha.4.1 |

**Hooks are stable and on by default** — `codex features list` reports:

```
hooks                                stable             true
```

**Event names present in the binary** (snake_case internally, PascalCase in config):
`session_start`, `session_end`, `user_prompt_submit`, `pre_tool_use`, `permission_request`,
`post_tool_use`, `subagent_start`, `subagent_stop`, `Stop`, `pre_compact`, `post_compact`.
Both builds contain `hooks.json`, `trusted_hash`, and `PermissionRequest`, so hook support is
present in the VS Code-bundled build too.

**Configuration sources**, in the documented discovery order: `~/.codex/hooks.json`,
`~/.codex/config.toml` `[hooks]`, then the project-level equivalents, then plugin-bundled hooks.
The JSON shape matches Claude Code's nested form, and `async` and `timeout` are both supported.

**Payload**: one JSON object on stdin carrying `session_id`, `transcript_path`, `cwd`,
`hook_event_name`, `model`, `permission_mode`, and `turn_id` for turn-scoped events.

### Three findings that changed the design

**1. There is no `Notification` event.** Codex has no equivalent of Claude's `idle_prompt`, so
there is no official signal that the agent is waiting for a free-text answer. `PermissionRequest`
covers approval, but `waitingForInput` is genuinely unobservable.

**2. `notify` was already occupied.** The real `~/.codex/config.toml` on this machine contains:

```toml
notify = ["/Users/henrique/.codex/computer-use/.../SkyComputerUseClient", "turn-ended"]
```

That is Codex Computer Use. Every comparable tool surveyed (`unoryota/ai-notify`,
`cfngc4594/agent-notify`) installs itself by writing this key, which would have silently broken
a shipped feature on this user's machine. The binary also contains a `legacy_notify` symbol,
suggesting the mechanism is on its way out in favour of a newer `[notifications]` table.

**3. Hooks require explicit user trust.** The binary contains `trusted_hash`, `hooks.state`,
`hooks/list failed in TUI`, and `--dangerously-bypass-hook-trust`. A newly installed command
hook does not execute until the user reviews and trusts it.

### `async` is documented but not implemented

The documentation lists `async` as a supported field. Codex 0.138.0-alpha.7 does not implement
it, and does not merely ignore it:

```
⚠ skipping async hook in ~/.codex/hooks.json: async hooks are not supported yet
```

It discards the whole entry. An installation that looked correct on disk was invisible to the
agent, and `/hooks` reported no hooks installed for any event — which reads as "the file was
never written" rather than "every entry was rejected".

Claude Code's support for `async` was verified by running it. Codex's was taken from the docs.
That asymmetry is the whole mistake: the shipped build is the authority, and it is cheap to ask.

The consequence is a real downgrade, recorded rather than glossed. For Claude Code, "never blocks
the agent" is structural — an async hook *cannot* sit on the critical path. For Codex it is not:
the hook runs synchronously, and the guarantee rests on it being bounded instead. Roughly 10 ms
typical, a 50 ms cap on the socket connect, and `timeout: 5` as the backstop.

## The install was correct and still never ran

Everything above shipped, `~/.codex/hooks.json` held our seven entries, the user trusted them
through `/hooks` — six `trusted_hash` values sat in `config.toml` — and CodeStatus never received
a single Codex event. Running the CLI directly is what finally showed why:

```
hook: SessionStart
hook: SessionStart Failed
```

**Codex splits a hook's `command` on whitespace instead of treating it as one path.** Our binary
lives at `~/Library/Application Support/CodeStatus/bin/codestatus-hook`, so Codex tries to spawn
`/Users/<user>/Library/Application` and every invocation fails before the hook exists.

Isolated by substitution, holding everything else fixed:

| `command` | result |
|---|---|
| `/usr/bin/true` at a spaced path | Failed |
| `codestatus-hook` at `/tmp/cshook/` | **Completed** |
| `codestatus-hook` under `Application Support` | Failed |

The same run also shows the hook's own exit code is irrelevant: `/usr/bin/true` fails at a spaced
path, and our binary — which exits 0 on every path by construction — succeeds at a clean one.

Two consequences, both verified:

1. **`args` is never delivered.** `{"command": "/usr/bin/tee", "args": ["/tmp/out"]}` produced no
   file: Codex ignores the array entirely. The provider therefore cannot travel in `args`. It
   travels in the file name instead — a second copy staged as `codestatus-hook-codex`, read back
   off `argv[0]`. `args` is still written, so a build that starts honouring it agrees.
2. **`--dangerously-bypass-hook-trust` does not work in 0.138.0.** It prints its warning and runs
   nothing. It does work in 0.149.0-alpha.4.1, which is what made a scratch `CODEX_HOME` usable as
   a test harness.

Diagnosing this cost far more than it should have because Codex reports only `Failed` — no exit
code, no spawn error, no path. Upstream has the same complaint (openai/codex#27052).

### What trust actually covers

Trust survives replacing the binary: swapping `codestatus-hook` for `/usr/bin/true` at the same
path kept the hooks running. The hash is over the entry, not the file it points at. So changing
`hooks.json` — as the fix does — **requires the user to re-trust through `/hooks`**, while shipping
a new hook binary does not.

## Spike 4 resolved

Codex in VS Code **does** deliver hooks from `~/.codex/hooks.json`. `~/.codex/logs_2.sqlite`
records them from the app-server itself:

```
TRACE codex_app_server::outgoing_message  app-server event: hook/started
TRACE codex_app_server::outgoing_message  app-server event: hook/completed
```

This matters more than it sounds: `codex doctor` reports this machine's rollouts as
`vscode=33, cli=1`, so the editor is where Codex is actually used, and it was the one path the
capability matrix had marked unverified.

`SessionEnd` is real in 0.149.0-alpha.4.1 — it clamps our `timeout: 5` to 3s and says so — though
it is absent from 0.138.0's event enum, which silently ignores the entry.

## Limitations

- Both builds being pre-release alphas means event names could still move.
- The whitespace splitting is a Codex bug, not a documented contract. If it is fixed, a
  space-free path still works; that is why the fix moves the binary rather than quoting the string.

## Architectural decision

1. **Write only `~/.codex/hooks.json`; never touch `config.toml`.** This is the single most
   consequential decision from this spike. It means CodeStatus cannot damage `notify`,
   `mcp_servers`, `projects`, or plugin configuration, because it never parses or rewrites the
   user's TOML at all. It also removes any need for the `[features] hooks = true` mutation that
   agentbuddy performs — hooks are already on by default.
2. **`agent-turn-complete` via `notify` is an opt-in extra, offered only when `notify` is
   unset.** On this machine it is set, so the option is shown as unavailable *with the reason*.
3. **Never write `trusted_hash`.** Automating trust would defeat a deliberate security control.
   Onboarding instead instructs the user to run `/hooks` inside Codex, and then verifies.
4. **Report both CLI versions in Diagnostics**, because version skew between the app bundle and
   the VS Code extension is real and will confuse bug reports otherwise.

## V1 impact

- Codex row of the capability matrix: Discovery yes, Busy/free yes, Approval yes,
  **Input no**, Open yes, Send prompt no.
- Onboarding gains a Codex-specific trust step that cannot be automated away.
- `SessionEnd` is treated as best-effort; kqueue `NOTE_EXIT` is the guaranteed backstop for
  detecting that a session is gone.
