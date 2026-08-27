# Spike 1 & 2 — Claude Code hooks, CLI and VS Code

Both **done**.

## Hypothesis

Claude Code emits enough lifecycle events to drive the full state machine, and the VS Code
extension honours the same `~/.claude/settings.json` hooks as the CLI — so one installation
covers both surfaces without touching extension internals.

## Method

1. Read the official hooks reference at `code.claude.com/docs/en/hooks`.
2. `strings` over the shipped `claude` binary (2.1.186) to confirm which events and notification
   subtypes exist in the build actually installed, rather than trusting the docs.
3. Read `code.claude.com/docs/en/vs-code` for the configuration section.
4. Inspected the *running* VS Code extension's process arguments with `ps`.

## Result

**Events present in the 2.1.186 binary**, all of which we register:

```
SessionStart  SessionEnd  UserPromptSubmit  PreToolUse  PostToolUse
PermissionRequest  PermissionDenied  Notification  Stop  StopFailure  SubagentStop
```

**Notification subtypes present in the binary** — and this is the important one:

```
permission_prompt   idle_prompt   agent_completed
```

The product spec's event mapping assumed a fourth subtype, `agent_needs_input`. **It does not
exist.** Mapping it would have produced a `waitingForInput` state that never fires.

> **Superseded — re-verified against 2.1.247 (2026-08-27).** See
> [07](07-blocking-questions.md). The subtype list is now fourteen values and *does* include
> `agent_needs_input` — but it is emitted by the fleet-view watcher about *other* agents, so
> mapping it, or `agent_completed`, misattributes another session's state to this one. Both are
> now deliberately unmodelled.

**`async: true` is supported** on command hooks, which makes a hook structurally incapable of
blocking, approving, denying, or altering the agent's flow.

**Exit-code semantics**: `0` proceeds; `2` blocks on events that support blocking. Our hook
always exits `0`, so it can never block anything even by accident.

### VS Code (spike 2)

The documentation states plainly that `~/.claude/settings.json` is *"shared between the
extension and CLI. Use it for allowed commands, environment variables, hooks, and MCP servers."*

That is corroborated by the live process. The running extension spawns its own bundled CLI:

```
~/.vscode/extensions/anthropic.claude-code-2.1.240-darwin-arm64/resources/native-binary/claude
  --output-format stream-json --input-format stream-json
  --setting-sources=user,project,local
  --permission-prompt-tool stdio --permission-mode acceptEdits ...
```

`--setting-sources=user,...` is the decisive detail: the `user` source *is*
`~/.claude/settings.json`. The sidebar, editor tabs, and integrated terminal are all the same
CLI underneath, so hooks installed once cover every Claude Code surface in VS Code.

Note the extension bundles its own CLI copy (2.1.240) which can differ from the standalone CLI
on `PATH` (2.1.186). Both read the same user settings.

## Limitations

- The subtype list is what 2.1.186 contains. A future release may add subtypes, so unknown
  values must never be treated as an error or a guess.
- `Stop` fires when the *turn* ends, not the session. Treating it as session termination — as
  some prior art does — would remove a session that is still open and usable.
- Hook processes are spawned per event, so a chatty session with heavy tool use spawns many
  short-lived processes. This is why hook startup cost is a real design constraint
  (see [05](05-event-transport.md)).

## Architectural decision

1. **Register all ten events with `async: true`.** Async delivery is the structural guarantee
   behind the spec's "CodeStatus never interferes" principle — not a promise we have to keep by
   being careful, but a property the agent enforces for us.
2. **Switch on `notification_type`, and no-op on unknown values.** In `StateReducer`,
   `targetState(for:)` returns `nil` for an unrecognised subtype, and the registry records it as
   `eventDropped(.unmapped)`. New subtypes are ignored rather than misclassified.
3. **`Stop → free`, never `ended`.** The session stays in the counters, ready for another prompt.
   `SessionEnd` and process exit are the only things that end a session.
4. **One installation covers CLI and VS Code.** No extension-specific integration, no private
   commands, no reading extension internals.

## V1 impact

- Claude Code CLI row: Discovery yes, Busy/free yes, Approval yes, Input yes (`idle_prompt`),
  Open yes, Send prompt no (deferred).
- Claude Code VS Code row: identical, except Open resolves a workspace rather than a tab.
- The mapping table in `StateReducer.targetState(for:)` reflects the binary, not the spec's
  original assumption, and the discrepancy is documented in the plan.
