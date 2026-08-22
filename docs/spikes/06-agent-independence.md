# Spike 11 & 12 — pre-existing hooks, and CodeStatus not running

Both **done**.

The spec's third non-negotiable is that CodeStatus never interferes with the agent. These two
spikes are how that claim is made falsifiable: what happens to a user who already configured
their own hooks, and what happens to an agent when CodeStatus is closed, crashed, or deleted.

## Spike 12 — CodeStatus is not running

### Hypothesis

With no daemon listening, the hook exits cleanly and quickly, the agent proceeds normally, and
nothing accumulates on disk.

### Method

Ran the real hook binary with no socket, no pointer file, and no heartbeat, then with a
heartbeat but no listener, and inspected exit status and the filesystem afterwards.

### Result

| Situation | Hook exit | Side effect |
|---|---|---|
| No daemon, no heartbeat (app deleted) | 0 | none — spool stays empty |
| Heartbeat fresh, socket unreachable (app crashed/restarting) | 0 | exactly one atomic `.ndjson` in the spool |
| Daemon listening | 0 | event delivered |
| Malformed payload | 0 | partial event delivered, agent unaffected |

The stale-install case is the one that matters and is easy to get wrong. Uninstalling the app
without running the uninstaller leaves hook entries in `~/.claude/settings.json`, so the hook
keeps being invoked on every tool call, forever. Without a gate it would spool indefinitely and
fill the disk of someone who no longer even has the app. The heartbeat gate — spool only if the
daemon was seen within 24 hours — makes that case a genuine no-op, and it is asserted by a test
named for exactly that guarantee.

Combined with `async: true` registration, the hook is off the agent's critical path entirely.
The worst case a running agent can experience is a 50 ms bounded connect attempt in a background
process it is not waiting on.

### Architectural decision

Exit 0 on every path, without exception. Every wait is bounded. The spool is gated on daemon
liveness and capped in both file count and bytes.

## Spike 11 — the user already has hooks

### Hypothesis

CodeStatus can add its entries to an existing configuration without disturbing the user's own
hooks, key order, or formatting — and can later remove exactly its own entries and nothing else.

### Method

Surveyed how comparable tools do it, then designed against what they get wrong. Verified
against fixture configurations with unusual formatting, pre-existing user hooks in the same
event, and hostile edge cases.

### Result

Every comparable Swift tool surveyed round-trips the whole settings file through
`JSONSerialization`. `bacongravy/your-turn` writes back with:

```swift
JSONSerialization.data(withJSONObject: settings,
                       options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
```

`.sortedKeys` reorders every key in the user's file. `techgocodingnow/agentbuddy` does the same
kind of dictionary round-trip. Both produce a semantically equivalent file and a textually
different one — which the spec explicitly forbids ("não sobrescrever formatação ou chaves
desnecessariamente").

Ownership detection is the second trap. agentbuddy identifies its own entries with:

```swift
command.lowercased().contains("hook") && command.lowercased().contains("agentbuddy")
```

A user hook whose command merely mentions the name would be deleted on uninstall.

The real `~/.claude/settings.json` on this machine contains user settings (`permissions`,
`theme`, `effortLevel`, `model`) and no `hooks` key, so both the create-from-absent and
preserve-existing paths are exercised by real data.

### Architectural decision

1. **Format-preserving text splice, not re-serialisation.** `JSONSurgeon` tokenises the file
   recording source byte ranges, then splices our entry in as text. Every byte outside the
   inserted region is identical afterwards — and that is asserted by tests, not just claimed.
2. **Ownership by resolved path**, not substring. An entry is ours only if its `command`
   resolves to `RuntimePaths.hookBinary`. A user hook that merely contains the word
   "codestatus" is explicitly tested to survive uninstall.
3. **Backup, atomic write, validate, restore on failure.** Timestamped backup before any write;
   temp file plus `rename` in the same directory; re-parse afterwards; restore the backup and
   throw if validation fails.
4. **Preview before applying.** Onboarding shows the exact resulting text so the user can see
   the change before it happens — an idea taken from `cfngc4594/agent-notify`, whose repository
   has no licence file, so the concept was adopted and none of its code was.
5. **For Codex, sidestep the problem entirely** by writing `~/.codex/hooks.json` and never
   parsing the user's `config.toml`. See [02](02-codex-hooks.md).

## V1 impact

- Acceptance criteria 11 ("existing hooks are not erased"), 12 ("CodeStatus closed does not
  break any agent"), and 13 ("no prompt, response, or code content in logs") are each backed by
  a named test rather than by inspection.
- The uninstaller is a first-class feature, not an afterthought, because the stale-install case
  is the one that harms a user who has already walked away.
