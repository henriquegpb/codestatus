import { ChevronDown } from "lucide-react";
import { StructuredData } from "@/components/structured-data";

/**
 * Questions phrased the way they get asked, not the way the product is built.
 *
 * Somebody with this problem does not search for "agent presence layer" — they
 * ask an assistant "how do I know when Claude Code is done". These are those
 * sentences, and the answers are the shortest true replies to them.
 *
 * One array drives both the visible list and the FAQPage schema. Structured
 * data that answers something the page does not say is a guideline violation
 * and, worse, a claim a machine will repeat with confidence.
 */
export const FAQ = [
  {
    q: "How do I get notified when Claude Code finishes?",
    a: "Install CodeStatus and it registers a hook with Claude Code during onboarding. When a turn ends you get a macOS notification naming the repository, and the menu bar count moves from busy to free. Nothing to configure per project.",
  },
  {
    q: "Can I track several coding agents at once?",
    a: "That is the reason it exists. Every Claude Code and Codex session on the Mac appears in one list with its own state, so you can start four and keep working instead of tabbing between terminals to check on them.",
  },
  {
    q: "Does it work with Codex, including inside VS Code?",
    a: "Yes, both the Codex CLI and Codex in VS Code, which runs as an app-server and delivers the same hooks. Codex requires you to approve hooks once with the /hooks command before it will run them — a security control CodeStatus deliberately does not automate.",
  },
  {
    q: "How does it know an agent is busy rather than just quiet?",
    a: "It reads the agents' own lifecycle hooks, so state is reported rather than inferred. CPU is never an input: an agent waiting on a network response burns none, and one running a six-minute build burns plenty. When nothing has been reported, the session reads as unknown instead of being announced as finished.",
  },
  {
    q: "Does it send my prompts or code anywhere?",
    a: "No. There is no network code in the product at all — no account, no server, no telemetry. The hook copies an allowlist of metadata such as session id, event name and working directory, and walks past everything else without ever reading those bytes.",
  },
  {
    q: "Does it support Cursor, Windsurf, or Gemini CLI?",
    a: "Not today. It supports Claude Code and Codex, because it depends on official lifecycle hooks and those are the agents that expose them in the form it needs.",
  },
  {
    q: "How much does it cost?",
    a: "Nothing. It is free and MIT licensed, and the source is on GitHub.",
  },
] as const;

const SCHEMA = {
  "@context": "https://schema.org",
  "@type": "FAQPage",
  mainEntity: FAQ.map(({ q, a }) => ({
    "@type": "Question",
    name: q,
    acceptedAnswer: { "@type": "Answer", text: a },
  })),
};

/**
 * Native `<details>` rather than state and a height transition.
 *
 * Three things come free with it and none of them are free otherwise: it works
 * before hydration, the summary is a real keyboard control, and find-in-page
 * opens the section it matched. It also keeps every answer in the DOM while
 * collapsed, which is what lets the FAQPage schema stay honest — an accordion
 * that mounts its content on click would leave the structured data describing
 * text no crawler ever sees.
 */
export function Faq() {
  return (
    <>
      <StructuredData schema={SCHEMA} />
      <ul className="border-t border-line">
        {FAQ.map(({ q, a }) => (
          <li key={q} className="border-b border-line">
            <details className="group">
              <summary
                // The default disclosure triangle is removed in both spellings:
                // `list-none` covers Firefox, the pseudo-element covers WebKit.
                className="flex cursor-pointer list-none items-center justify-between gap-6 py-4 text-sm font-medium transition-colors hover:text-accent [&::-webkit-details-marker]:hidden"
              >
                {q}
                <ChevronDown
                  className="size-4 shrink-0 text-muted transition-transform duration-300 ease-[cubic-bezier(.16,1,.3,1)] group-open:rotate-180"
                  strokeWidth={1.75}
                  aria-hidden
                />
              </summary>
              <p className="max-w-2xl pb-5 text-sm leading-relaxed text-muted text-pretty">
                {a}
              </p>
            </details>
          </li>
        ))}
      </ul>
    </>
  );
}
