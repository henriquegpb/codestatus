# Spikes

The product spec requires a set of experiments to be run and recorded *before* committing to an
architecture, each with hypothesis, method, result, limitations, architectural decision, and V1
impact. This directory is that record.

Status is honest: a spike is `done` only when it was actually run on real software, `partial`
when the decisive part was verified but something remains, and `pending` when it has not run.
Nothing here is inferred from documentation alone unless the entry says so.

Environment for every completed spike: macOS 26.5 (25F71), Apple Silicon, Xcode 26.6 /
Swift 6.3.3, Claude Code 2.1.186, Codex CLI 0.138.0-alpha.7 (app bundle) and 0.149.0-alpha.4.1
(VS Code extension).

| # | Spike | Status | Record |
|---|---|---|---|
| 1 | Claude Code CLI emits every event we need | done | [01](01-claude-code-hooks.md) |
| 2 | Claude Code in VS Code uses the shared config | done | [01](01-claude-code-hooks.md) |
| 3 | Codex CLI lifecycle hooks and `agent-turn-complete` | done | [02](02-codex-hooks.md) |
| 4 | Codex in VS Code — which events actually arrive | pending | [02](02-codex-hooks.md) |
| 5 | PID → TTY → Terminal tab mapping | partial | [03](03-terminal-tab-mapping.md) |
| 6 | Stable notch HUD without private APIs | dropped — HUD removed, the menu bar carries it | [04](04-notch-hud.md) |
| 7 | `NSPanel` across Spaces and full screen | dropped with spike 6 | [04](04-notch-hud.md) |
| 8 | Unix socket transport with spool fallback | done | [05](05-event-transport.md) |
| 9 | Sleep/wake reconciliation | partial | [05](05-event-transport.md) |
| 10 | Sending a prompt to a PTY-managed session | pending | deferred to V1.1 |
| 11 | Behaviour when the user already has hooks | done | [06](06-agent-independence.md) |
| 12 | Behaviour when CodeStatus is not running | done | [06](06-agent-independence.md) |

## What the spikes changed

Three findings materially altered the plan, and are worth reading even if you skip the rest:

1. **`Notification.agent_needs_input` does not exist.** The spec's event mapping assumed it.
   Claude Code 2.1.186 emits only `permission_prompt`, `idle_prompt`, and `agent_completed`.
   The reducer therefore switches on the subtype and treats unknown subtypes as a silent no-op.
   See [01](01-claude-code-hooks.md).

2. **Codex has no `Notification` event at all**, so `waitingForInput` is not observable for
   Codex. The capability matrix says "No" rather than "partial". See [02](02-codex-hooks.md).

3. **`~/.codex/config.toml`'s `notify` key is already in use** on a real machine (by Codex
   Computer Use). Every comparable tool writes to it and would break that feature. We use
   `~/.codex/hooks.json` instead and never parse the user's TOML. See [02](02-codex-hooks.md).
