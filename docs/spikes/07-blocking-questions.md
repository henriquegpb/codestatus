# Spike 13 — what Claude Code emits when it asks the user a question

**Done.**

## Hypothesis

When Claude Code blocks on `AskUserQuestion` or `ExitPlanMode`, no hook fires — the agent is
mid-turn, so `Stop` has not run, and `Notification.idle_prompt` is about an abandoned prompt
rather than a blocked one. If that were true, "the agent is waiting for an answer" would be
unobservable and CodeStatus would sit on `busy` for as long as the person takes to answer.

Reported symptom: the menu bar never shows a session as needing the user when Claude asks a
multiple-choice question.

## Method

1. `strings` and a byte-level scan over the shipped 2.1.247 binary
   (`~/.vscode/extensions/anthropic.claude-code-2.1.247-darwin-arm64/resources/native-binary/claude`),
   to enumerate every `notificationType:` call site and read the tool definitions directly,
   rather than trusting the docs or the 2.1.186 findings in [01](01-claude-code-hooks.md).
2. A logging hook registered on all eleven events via `--settings`, driven against a real
   session in the same mode the VS Code extension runs
   (`--input-format stream-json --permission-prompt-tool stdio`), prompted to call
   `AskUserQuestion` and then left unanswered so the blocked state could be observed.
3. The same run repeated with `--setting-sources user`, so the *installed* CodeStatus hooks
   fired, correlated against `CodeStatusApp`'s notification delivery in the unified log.
4. The run repeated once more with a `Bash` call ordered *before* the question, which is what
   turned up the real defect.

## Result

**The hypothesis was wrong: the events are all there.** Blocking on `AskUserQuestion` emits

```
+0.000s  PreToolUse         {tool_name: AskUserQuestion, tool_use_id: toolu_…}
+0.003s  PermissionRequest  {tool_name: AskUserQuestion}          ← no tool_use_id
+6.03s   Notification       {notification_type: permission_prompt}
```

The mechanism is in the tool definition: `AskUserQuestion` declares
`requiresUserInteraction() { return true }`, and the permission resolver has an explicit branch
— `if (tool.requiresUserInteraction?.()) return {behavior: "ask", decisionReason: {reason:
"requiresUserInteraction"}}` — that runs *before* the permission-mode checks. A question is
therefore routed down the ordinary ask path no matter the mode. `ExitPlanMode` declares the same
flag. Both surface as dialog kinds `permission_ask_user_question` and
`permission_exit_plan_mode_v2`.

End-to-end through the installed hooks, CodeStatus posted its notification 20ms after the
`PermissionRequest` hook fired. The pipeline was never the problem.

**The real defect was ours, in `LogicalClock`.** Events were ordered by `(turnSequence, rank)`,
but `rank` describes the shape of a *single tool use* — `PreToolUse` (2) before
`PermissionRequest` (3) before `PostToolUse` (4). A turn contains many tool uses, so the first
`PostToolUse` raised the floor to 4 and every later tool use was rejected as out-of-order. Two
`busy` states in a row made that invisible; a question made it obvious, because the session held
`busy` for as long as someone was being asked something.

Reproduced exactly: with `AskUserQuestion` as the first tool call of a turn, the state flips
correctly. Put a single `echo` before it and both the `PreToolUse` and the `PermissionRequest`
are dropped.

**Cancelling a question emits nothing at all.** Three shapes tested, with all 31 events
registered: a permission deny carrying `interrupt`, an `interrupt` control request while the
question was on screen, and an `interrupt` while a tool was genuinely mid-run (a stdio MCP
server told to sleep). Every one produced total silence for the following 30–90 seconds. Only a
deny *without* `interrupt` produces anything — `Stop`, about two seconds later.

This matches the documented behaviour that `Stop` "does not run if the stoppage occurred due to
a user interrupt", and nothing takes its place. `PostToolUseFailure` carries an `is_interrupt`
field, which looked like the answer and is not: it is never emitted for a user interrupt.

The consequence is that an interrupted session holds whatever state it was in until the next
`UserPromptSubmit`. This is not new and not specific to questions — Esc during an approved
`Bash` has always left a session on `busy` forever. It is newly *visible*, because the stuck
state is now a red "needs a reply" rather than an unremarkable "busy". Left unfixed rather than
papered over with a timeout: guessing that a session became free would, at any threshold short
enough to help, also erase questions that are still genuinely on screen.

**The event list has tripled.** 2.1.186 had the 11 events in [01](01-claude-code-hooks.md);
2.1.247 has 31. What each one is worth to us, all verified by firing them:

| Event | Fires | Decision |
|---|---|---|
| `PostToolUseFailure` | when a tool errors — **instead of** `PostToolUse`, never alongside it | register → `busy` |
| `PostToolBatch` | once a parallel batch has settled | register → `busy` |
| `Elicitation` | an MCP server asks the user; the tool call blocks | register → `waitingForInput` |
| `ElicitationResult` | that answer arrives | register → `busy` |
| `MessageDisplay` | per assistant message, with `delta`/`index` | skip — pure cost, no state |
| `InstructionsLoaded` | at startup, per memory file | skip |
| `SubagentStart`, `TaskCreated`, `TaskCompleted` | subagents and background tasks | skip for now — they describe work that is not the session |
| `Setup`, `ConfigChange`, `CwdChanged`, `FileChanged`, `DirectoryAdded`, `WorktreeCreate/Remove`, `UserPromptExpansion`, `PreCompact`, `PostCompact`, `TeammateIdle` | various | skip — none changes what we can say about state |

`PostToolUseFailure` is the one that was silently costing us: because it *replaces*
`PostToolUse`, a tool that was approved and then errored left the session sitting on
`waitingForApproval` for the rest of the turn.

The full elicitation cycle, measured end to end against a stdio MCP server written for the
purpose:

```
PreToolUse{mcp__probe__ask}  PermissionRequest{mcp__probe__ask}
Elicitation{mcp_server_name, mode: form}      ← blocks
ElicitationResult{action, content}            ← releases
Notification{elicitation_response}  PostToolUse{mcp__probe__ask}  PostToolBatch
```

Neither `Elicitation` nor `ElicitationResult` carries `tool_name` or `tool_use_id`, so both ride
in the step its tool's permission check opened.

Three further findings from the same pass:

- **`PermissionRequest` carries no `tool_use_id`**, only `tool_name`. Anything keyed on tool use
  id has to tolerate its absence.
- **`args` on Claude Code command hooks is honoured** — confirmed by logging `$@`. Only Codex
  ignores it. The installer's use of `--provider claude-code` is sound.
- **`Notification.idle_prompt` can never fire mid-turn.** The idle notifier bails on
  `if (isLoading) return` before it arms its timer, so `idle_prompt` only ever means "you walked
  away from an empty prompt". At rank 3 it was also being rejected by every session that had
  finished a turn (`stop` is rank 8) — that is, by every session capable of producing it.

**The subtype list in [01](01-claude-code-hooks.md) is superseded.** 2.1.247 carries fourteen:

```
permission_prompt  idle_prompt  auth_success  elicitation_dialog  agent_needs_input
agent_completed  elicitation_url_dialog  worker_permission_prompt  push_notification
computer_use_enter  computer_use_exit  quota_auto_resume_fired/_stale/_disabled
```

`agent_needs_input` now exists — and is a trap. It and `agent_completed` are emitted by the
fleet-view band watcher and describe some *other* agent, a background task or a teammate. The
shipped reducer mapped `agent_completed → free`, which marked a session free because a different
one had finished.

## Limitations

- Verified on 2.1.247. The `requiresUserInteraction` branch is structural rather than a name
  list, so it should survive new tools, but the tool *names* we match on are a hardcoded set.
- **A user interrupt remains unobservable.** A session cancelled with Esc holds its last state
  until the next prompt. Worth raising upstream: `Stop` skipping user interrupts leaves every
  hook consumer unable to tell a blocked session from an abandoned one.
- A `PostToolBatch` arrived once before any `PreToolUse` in the same turn, so it cannot be
  assumed to follow tools it summarises. Harmless here — it maps to `busy` either way.
- An MCP server raising a *second* elicitation inside one tool call has the later questions
  outranked by the first result, because elicitations carry no identifier of their own. The
  session reads `busy` rather than blocked until `PostToolUse` closes the step.
- An MCP server can mark its own tools with `anthropic/requiresUserInteraction`; those names are
  unknowable to us, so such tools land on `waitingForApproval` rather than `waitingForInput`.
  Blocked is still reported as blocked, only mislabelled.
- The ~6s delay before `permission_prompt` is a `setTimeout` constant in the binary, measured
  twice at 6.03s. It is not a documented contract.

## Architectural decision

1. **Order events by `(turnSequence, stepSequence, rank)`.** A step is one tool use. Rank keeps
   its straggler duty inside a step; steps stop tool uses from starving each other. Steps are
   keyed on `tool_use_id` where it exists and `tool_name` where it does not, which also keeps a
   `PreToolUse` that loses the race to its own `PermissionRequest` from dragging the session
   back to `busy`.
2. **Discriminate on `tool_name`.** `PreToolUse` and `PermissionRequest` for the tools in
   `toolsThatAskTheUser` map to `waitingForInput`; everything else keeps `waitingForApproval`.
   The distinction is user-visible: the approval copy says "review the command", and for a
   question there is no command to review.
3. **Rank `permission_prompt` below `permissionRequest`.** It is the same fact six seconds late
   and without the `tool_name`, so it stays a backstop for a lost hook and can no longer arrive
   late to relabel a question as an approval. `idle_prompt` moves above `stop`, where it can
   actually apply.
4. **Do not model `agent_completed` or `agent_needs_input`.** They are about other sessions.
   Unknown subtypes already decode to `nil` and no-op, so leaving them out of the enum is the
   whole fix.
5. **Register four of the twenty new events, and no more.** Every registered event is a process
   spawned on the user's machine on the agent's critical path budget, so the bar is "changes
   what we can say about state". `MessageDisplay` is the clearest refusal: it fires per
   assistant message and tells us nothing a tool event does not.
6. **Add nothing to the hook's allowlist.** The four new events are acted on by name alone, so
   `message`, `requested_schema`, `content`, `error`, and `tool_calls` stay structurally
   incapable of reaching the socket rather than merely unread. `mcp_server_name` would have made
   a nicer diagnostics line and is not worth widening the surface for.
7. **Migrate existing installs on launch.** A longer event list makes an existing install read
   as *not installed*, which would put an already-connected agent back in front of the user and
   silently drop the new states. `ClaudeHookInstaller` gained `needsMigration()` and the app
   tops the entries up, announcing it — because Claude Code reads hooks at session start, so
   nothing already open picks them up.

## V1 impact

- Claude Code rows: Input needed changes from "yes (`idle_prompt`)" — which in practice never
  fired for a blocked session — to "yes, on the tool call itself, within milliseconds".
- Every tool use after the first in a turn is now observed at all. This was not limited to
  questions; approvals for a second `Bash` call in one turn were being dropped the same way.
- `LogicalClock` gained three stored fields. Snapshots written before this decode leniently and
  restart at step 0.
- A tool that is approved and then errors no longer strands the session on `waitingForApproval`.
- MCP elicitations are now reported, which adds a second route to "Input needed" that no
  previous build could see. Confirmed end to end: CodeStatus logged two transitions 6ms apart —
  approval, then input needed — at the moment a live server raised one.
- Existing installs are migrated on next launch: 10 registered events become 14, with the rest
  of the user's `settings.json` spliced around untouched (verified on a real file carrying
  permissions, theme, model, and effort settings).
