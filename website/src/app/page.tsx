import Image from "next/image";
import Link from "next/link";
import {
  Binary,
  Clock,
  Cpu,
  CircleHelp,
  Download,
  EyeOff,
  FileCode,
  ListFilter,
  MousePointerClick,
  ShieldCheck,
  Webhook,
} from "lucide-react";
import wordmark from "../../public/wordmark.svg";
import mark from "../../public/mark.svg";
import githubMark from "../../public/GitHub.svg";
import { SITE } from "@/lib/site";
import { HudPreview } from "@/components/hud-preview";
import { GrainientField } from "@/components/site-background";
import { Section, Claims } from "@/components/section";
import { CapabilityMatrix } from "@/components/capability-matrix";
import { IconSwapButton } from "@/components/icon-swap-button";

/** Exactly what the hook binary is allowed to copy. */
const METADATA = [
  "session id",
  "provider",
  "event",
  "timestamp",
  "pid",
  "tty",
  "working directory",
  "git root",
  "workspace",
  "host app",
];

export default function Home() {
  return (
    <>
      {/* Solid black rather than transparent: the gradient running under the
          wordmark made the logo compete with the field behind it. */}
      <header className="h-[var(--header-h)] w-full border-b border-line bg-background">
        <nav className="mx-auto flex h-full max-w-5xl items-center justify-between px-6">
          <Link href="/" aria-label="CodeStatus — home">
            <Image src={wordmark} alt="CodeStatus" height={26} priority />
          </Link>
          <IconSwapButton
            href={SITE.repo}
            label="Star on GitHub"
            size="sm"
            icon={<Image src={githubMark} alt="" width={15} height={15} aria-hidden />}
          />
        </nav>
      </header>

      <main className="flex-1">
        {/*
          The hero is sized to one screen: everything above the fold, centred in
          whatever height the window has, so a laptop sees the panel animate
          without scrolling.
        */}
        <section className="mx-auto flex min-h-[calc(100svh-var(--header-h))] max-w-5xl flex-col justify-center px-6 py-10">
          {/* mt-10 is the space the eyebrow line used to occupy (its 1rem line
              box plus the heading's 1.5rem margin), kept so the hero sits where
              it did. */}
          <h1 className="mt-10 text-5xl font-extralight tracking-tight text-balance sm:text-6xl lg:text-7xl">
            Stop watching AI work.
          </h1>
          <p className="mt-6 max-w-2xl text-xl leading-relaxed font-light text-muted text-pretty">
            Run several coding agents. Keep working. Come back only when one is
            done, or needs you.
          </p>

          <div className="mt-9 flex flex-wrap items-center gap-4">
            <IconSwapButton
              href={SITE.download}
              label="Download for macOS"
              variant="primary"
              icon={<Download className="size-4" strokeWidth={2} />}
            />
            <IconSwapButton
              href={SITE.repo}
              label="View source"
              icon={<Image src={githubMark} alt="" width={16} height={16} aria-hidden />}
            />
            <span className="font-mono text-xs text-muted">
              {SITE.requirements}
            </span>
          </div>

          <HudPreview className="mt-12" />
          <p className="mt-3.5 flex items-center gap-2 text-sm text-muted">
            <MousePointerClick className="size-4 shrink-0 text-accent" strokeWidth={1.5} aria-hidden />
            Every Claude Code and Codex session on your Mac. Click one to land
            back in its terminal tab or workspace.
          </p>
        </section>

        <Section
          id="not"
          eyebrow="What it is not"
          title="Not a prettier Activity Monitor."
          lead="CPU tells you nothing about whether an agent is thinking, running a tool, or waiting on you. Lifecycle hooks tell you exactly."
        >
          <Claims
            items={[
              {
                icon: Webhook,
                title: "Hooks are the source of truth",
                body: "State comes from the agents' own official lifecycle events.",
              },
              {
                icon: Cpu,
                title: "Processes are only for facts",
                body: "Discovery, enrichment, and real death. Never state.",
              },
              {
                icon: CircleHelp,
                title: "Unknown stays unknown",
                body: "A quiet session is never announced as finished.",
              },
            ]}
          />
        </Section>

        <Section
          id="privacy"
          eyebrow="Privacy"
          title="Structural, not a promise."
          lead="No account, no server, no telemetry — there is no network code in the product at all."
        >
          <Claims
            items={[
              {
                icon: ListFilter,
                title: "The allowlist lives in the hook",
                body: "It walks past everything not on it, without ever copying those bytes.",
              },
              {
                icon: EyeOff,
                title: "Your prompts cannot leak",
                body: "Not to the socket, the logs, or the crash reporter. A test asserts it.",
              },
              {
                icon: Binary,
                title: "225 KB, no Foundation",
                body: "The hook has no general-purpose parser to leak through.",
              },
            ]}
          />
          <div className="mt-8">
            <p className="font-mono text-xs uppercase tracking-[0.14em] text-muted">
              All we read
            </p>
            <ul className="mt-3 flex flex-wrap gap-2">
              {METADATA.map((field) => (
                <li
                  key={field}
                  className="rounded-md border border-line bg-panel px-2.5 py-1 font-mono text-xs text-muted"
                >
                  {field}
                </li>
              ))}
            </ul>
          </div>
        </Section>

        <Section
          id="how"
          eyebrow="How it works"
          title="Hooks, not guesswork."
        >
          <pre className="overflow-x-auto rounded-xl border border-line bg-panel p-5 font-mono text-[13px] leading-relaxed text-foreground">
{`Claude Code / Codex
        │  official lifecycle hook (async, never blocking)
        ▼
codestatus-hook          ← metadata allowlist applied here
        │  one NDJSON line over a Unix domain socket
        ▼
CodeStatus daemon
        │
        ├── StateReducer      pure, idempotent, out-of-order tolerant
        ├── SessionRegistry   the single source of truth
        └── ProcessWatcher    kqueue NOTE_EXIT — discovery and death
                │
                ▼
        HUD · sound · notification`}
          </pre>
          <div className="mt-8">
            <Claims
              items={[
                {
                  icon: ShieldCheck,
                  title: "Async hooks cannot interfere",
                  body: "Never blocking, approving, or altering the agent's flow — enforced by the agent, not by us.",
                },
                {
                  icon: FileCode,
                  title: "Config edits are byte-preserving",
                  body: (
                    <>
                      Your <code>settings.json</code> is spliced, never
                      re-serialised.
                    </>
                  ),
                },
                {
                  icon: Clock,
                  title: "Nothing is inferred from time",
                  body: "A ten-minute tool call is still busy. Only our confidence decays.",
                },
              ]}
            />
          </div>
        </Section>

        <Section
          id="capabilities"
          eyebrow="Capabilities"
          title="Limitations are stated, not hidden."
        >
          <CapabilityMatrix />
          <dl className="mt-6 grid gap-x-8 gap-y-3 text-sm sm:grid-cols-3">
            <div>
              <dt className="text-needs">Codex input</dt>
              <dd className="mt-1 text-muted">
                No <code className="font-mono">Notification</code> event exists
                to observe it.
              </dd>
            </div>
            <div>
              <dt className="text-free">Codex in VS Code</dt>
              <dd className="mt-1 text-muted">
                Runs as <code className="font-mono">app-server</code>, and
                delivers the same hooks the CLI does.
              </dd>
            </div>
            <div>
              <dt className="text-needs">Send prompt</dt>
              <dd className="mt-1 text-muted">
                Only for sessions we launch ourselves, through a PTY.
              </dd>
            </div>
          </dl>
        </Section>

        <section className="mx-auto max-w-5xl px-6 py-20">
          <div className="relative overflow-hidden rounded-2xl border border-line bg-background text-center">
            {/* The same field as the hero, cropped to the card. It sits before
                the content in the DOM and the content is positioned, so the
                content paints over it without either needing a z-index. */}
            <div aria-hidden className="pointer-events-none absolute inset-0">
              <GrainientField />
            </div>
            <div className="relative px-8 py-12">
            <Image
              src={mark}
              alt=""
              height={56}
              className="mx-auto rounded-xl"
              aria-hidden
            />
            <h2 className="mt-8 text-3xl font-light tracking-tight">
              Get it running in a minute.
            </h2>
            <p className="mx-auto mt-3 max-w-sm text-muted text-pretty">
              Free and MIT licensed. Onboarding installs the hooks and leaves the
              rest of your config untouched.
            </p>
            <div className="mt-8 flex flex-wrap justify-center gap-4">
              <IconSwapButton
                href={SITE.download}
                label="Download for macOS"
                variant="primary"
                icon={<Download className="size-4" strokeWidth={2} />}
              />
              <IconSwapButton
                href={`${SITE.repo}#building`}
                label="Build from source"
                icon={<Image src={githubMark} alt="" width={16} height={16} aria-hidden />}
              />
            </div>
            </div>
          </div>
        </section>
      </main>

      <footer className="border-t border-line">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-4 px-6 py-8 text-sm text-muted">
          <span>MIT licensed · no account, no server, no telemetry</span>
          <div className="flex gap-6">
            <a className="transition-colors hover:text-foreground" href={SITE.repo}>
              GitHub
            </a>
            <a
              className="transition-colors hover:text-foreground"
              href={`${SITE.repo}/tree/main/docs/spikes`}
            >
              Design notes
            </a>
          </div>
        </div>
      </footer>
    </>
  );
}
