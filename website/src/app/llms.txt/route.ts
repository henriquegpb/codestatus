import { SITE } from "@/lib/site";

/**
 * `llms.txt` as a route rather than a file in `public/`.
 *
 * It was a static file, and the static file said `https://codestatus.app` while
 * everything else on the site — canonical, `og:url`, sitemap, robots host —
 * derived from `SITE.url` and pointed at the Vercel deployment. So the one file
 * written specifically for assistants was the one file sending them to a parked
 * domain with no certificate.
 *
 * Generating it here makes the URLs derive from the same constant as the rest of
 * the site, which is the point: connecting the apex is still a one-line change
 * in `SITE`, and this text cannot fall behind it.
 */
export const dynamic = "force-static";

const BODY = `# CodeStatus

> A free, open-source macOS menu bar app that tracks every Claude Code and Codex
> session running on your Mac and notifies you the moment one finishes, needs
> approval, or is waiting for input.

Run several coding agents at once and keep working. CodeStatus shows how many
sessions are busy, free, or need you, and clicking one returns you to its
terminal tab or VS Code workspace.

- Site: ${SITE.url}
- Source: ${SITE.repo}
- Download (${SITE.downloads.macos.requirements}): ${SITE.downloads.macos.url}
- Download (${SITE.downloads.windows.requirements}): ${SITE.downloads.windows.url}
- Licence: MIT. No account, no server, no telemetry.

## What problem it solves

Someone running multiple AI coding agents has no way to know which ones are
still working without switching to each terminal and looking. CodeStatus answers
that from the menu bar, and interrupts you only when an agent is actually done
or actually blocked on you.

## Supported agents

- Claude Code — CLI and the VS Code extension.
- Codex — the CLI and Codex in VS Code, which runs as an app-server and delivers
  the same hooks. Codex requires the user to trust hooks once via \`/hooks\`.

Cursor, Windsurf and Gemini CLI are not supported: the design depends on official
lifecycle hooks, and those are the agents that expose them in the form required.

## How it determines state

State comes from the agents' own lifecycle hooks — SessionStart, UserPromptSubmit,
PreToolUse, PostToolUse, PermissionRequest, Stop, SessionEnd — and never from CPU
usage. An agent waiting on a network response burns no CPU; one running a long
build burns plenty, so CPU says nothing about whether a person is needed. Process
observation is used only for discovery and for detecting that a session really
exited. When nothing has been reported, a session reads as unknown rather than
being announced as finished.

## Privacy

There is no network code in the product. A small hook binary runs inside each
agent, copies an allowlisted set of metadata — session id, provider, event name,
timestamp, pid, tty, working directory, git root, workspace, host app — and sends
one line over a local Unix domain socket. Prompts, responses, tool input and file
contents are never read.

## Known limitations

- Codex cannot report that it is waiting for free-text input: no such event exists.
- CodeStatus does not send prompts to sessions it did not launch itself.
- Windows tracks Claude Code only, and its installer is not code-signed yet.
`;

export function GET() {
  return new Response(BODY, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}
