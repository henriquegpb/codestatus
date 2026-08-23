"use client";

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import Image from "next/image";
import mark from "../../public/mark.svg";

/**
 * A scripted minute in the life of the HUD: sessions start and end, states
 * change, and a system notification fires the moment one finishes.
 *
 * Drawn in markup rather than shipped as a screen recording so it stays sharp,
 * follows the palette, and costs a few kilobytes. The frames are derived from a
 * fixed rotation rather than randomised, because the product's whole claim is
 * that state changes are events -- a random shuffle would be showing the
 * opposite.
 */

type State = "free" | "busy" | "needs";

type Row = {
  id: string;
  label: string;
  detail: string;
  state: State;
  note: string;
  /** Set on the frame where the session ends; the next frame drops it. */
  leaving?: boolean;
};

type Frame = {
  rows: Row[];
  /** Fires the "done" notification. Only a finished session gets one. */
  toast?: string;
  ms: number;
};

const CLAUDE_TERMINAL = "Claude Code · Terminal";
const CLAUDE_VSCODE = "Claude Code · VS Code";
const CODEX_TERMINAL = "Codex · Terminal";

/*
 * The cast in arrival order, not display order. A row takes SEATS cycles to
 * walk from the top of the list to the bottom and out, so as long as the cast
 * is longer than that, the session arriving is never one already on screen --
 * and after a full rotation the list is identical to where it started.
 */
const CAST = [
  { label: "notch-hud", detail: CODEX_TERMINAL, notes: ["measuring the notch", "tuning layout"] },
  { label: "dotfiles", detail: CLAUDE_TERMINAL, notes: ["installing", "linking configs"] },
  { label: "landing", detail: CODEX_TERMINAL, notes: ["editing files", "rewriting copy"] },
  { label: "nora-api", detail: CLAUDE_VSCODE, notes: ["reading files", "writing migration"] },
  { label: "codestatus", detail: CLAUDE_TERMINAL, notes: ["running tests", "fixing the reducer"] },
] as const;

function seat(index: number, note: 0 | 1): Row {
  const { label, detail, notes } = CAST[index % CAST.length];
  return { id: label, label, detail, state: "busy", note: notes[note] };
}

/** Rows on screen at once. The hero has to fit one screen, so: three. */
const SEATS = 3;

/*
 * Each cycle: the middle row is asked for approval and continues, the oldest
 * row at the bottom finishes and leaves to the right, and a new session arrives
 * at the top. Three rows at all times -- the leaving row keeps its slot until
 * the arriving one takes it -- so the panel never changes height.
 *
 * The opening list is the last SEATS arrivals, newest first, and every row
 * walks the same seat sequence. After a full rotation the list is identical to
 * the opening frame, so the loop wraps without a visible reset.
 */
function buildFrames(): Frame[] {
  const frames: Frame[] = [];
  const last = SEATS - 1;
  let rows: Row[] = Array.from({ length: SEATS }, (_, i) =>
    seat(CAST.length - 1 - i, i < SEATS - 1 ? 0 : 1),
  );
  let arriving = 0;

  const at = (index: number, patch: Partial<Row>) =>
    rows.map((row, i) => (i === index ? { ...row, ...patch } : row));

  for (let cycle = 0; cycle < CAST.length; cycle++) {
    rows = at(1, { state: "needs", note: "approval requested" });
    frames.push({ rows, ms: 2600 });

    const { notes } = CAST.find((c) => c.label === rows[1].label)!;
    rows = at(1, { state: "busy", note: notes[1] });
    frames.push({ rows, ms: 2200 });

    rows = at(last, { state: "free", note: "done" });
    frames.push({ rows, ms: 2900, toast: rows[last].label });

    rows = at(last, { leaving: true });
    frames.push({ rows, ms: 520 });

    rows = [seat(arriving++, 0), ...rows.slice(0, last)];
    frames.push({ rows, ms: 2400 });
  }

  return frames;
}

const FRAMES = buildFrames();

const DOT: Record<State, string> = {
  free: "bg-free text-free",
  busy: "bg-busy text-busy dot-busy",
  needs: "bg-needs text-needs",
};

export function HudPreview({ className = "" }: { className?: string }) {
  const [index, setIndex] = useState(0);
  const [running, setRunning] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);

  // A timeline nobody is looking at is just a wakeup every two seconds, and
  // someone who asked for less motion gets the first frame and nothing else.
  useEffect(() => {
    const node = containerRef.current;
    if (!node) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    const observer = new IntersectionObserver(
      ([entry]) => setRunning(entry.isIntersecting),
      { threshold: 0.2 },
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    if (!running) return;
    const timer = setTimeout(
      () => setIndex((i) => (i + 1) % FRAMES.length),
      FRAMES[index].ms,
    );
    return () => clearTimeout(timer);
  }, [running, index]);

  const frame = FRAMES[index];
  const live = frame.rows.filter((row) => !row.leaving);
  const count = (state: State) => live.filter((row) => row.state === state).length;

  return (
    <div
      ref={containerRef}
      className={`relative overflow-hidden rounded-2xl border border-line bg-panel ${className}`}
    >
      <div className="flex flex-wrap items-center gap-x-8 gap-y-3 border-b border-line px-6 py-4 font-mono text-sm">
        <Count state="free" n={count("free")} label="free" />
        <Count state="busy" n={count("busy")} label="busy" />
        <Count state="needs" n={count("needs")} label="needs you" />
      </div>

      <SessionList rows={frame.rows} />

      {frame.toast && <Notification key={index} label={frame.toast} />}
    </div>
  );
}

/**
 * Rows are positioned by the browser and animated by FLIP: measure where each
 * row was, let the DOM update, then transform it back and release. Without it,
 * a row leaving the bottom would teleport the rows above it into place.
 */
function SessionList({ rows }: { rows: Row[] }) {
  const elements = useRef(new Map<string, HTMLLIElement>());
  const positions = useRef(new Map<string, number>());

  useLayoutEffect(() => {
    const previous = positions.current;
    const current = new Map<string, number>();
    elements.current.forEach((el, id) => current.set(id, el.offsetTop));

    const settled = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (!settled) {
      elements.current.forEach((el, id) => {
        const from = previous.get(id);
        const to = current.get(id);
        // A row with no previous position is arriving; it has its own entrance.
        if (from === undefined || to === undefined || from === to) return;
        el.style.transition = "none";
        el.style.transform = `translateY(${from - to}px)`;
        requestAnimationFrame(() => {
          el.style.transition = "transform 520ms cubic-bezier(0.16, 1, 0.3, 1)";
          el.style.transform = "";
        });
      });
    }

    positions.current = current;
  }, [rows]);

  return (
    <ul className="divide-y divide-line">
      {rows.map((row, i) => (
        <li
          key={row.id}
          ref={(el) => {
            if (el) elements.current.set(row.id, el);
            else elements.current.delete(row.id);
          }}
          className={`flex items-center gap-3 px-6 py-4 text-sm ${
            row.leaving ? "row-out" : "row-in"
          }`}
        >
          <Dot state={row.state} offset={i * 320} />
          <span className="font-medium">{row.label}</span>
          <span className="truncate text-muted">{row.detail}</span>
          <span className="ml-auto shrink-0 font-mono text-xs text-muted">
            {row.note}
          </span>
        </li>
      ))}
    </ul>
  );
}

/**
 * The banner macOS actually shows when a session finishes, in the corner it
 * actually shows it in -- so it is portalled to the top right of the window
 * rather than parked inside the card.
 */
function Notification({ label }: { label: string }) {
  // Only ever reached after hydration -- the opening frame carries no
  // notification -- so there is no server render to mismatch.
  if (typeof document === "undefined") return null;

  return createPortal(
    <div
      role="status"
      className="toast pointer-events-none fixed top-4 right-4 z-50 flex w-[21rem] max-w-[calc(100vw-2rem)] items-center gap-3 rounded-[1.1rem] border border-white/10 bg-[#1c1c1e]/75 p-3 shadow-[0_20px_50px_-12px_rgba(0,0,0,0.9)] backdrop-blur-2xl"
    >
      <Image
        src={mark}
        alt=""
        width={40}
        height={40}
        className="shrink-0 rounded-[10px]"
      />
      <div className="min-w-0 flex-1">
        <p className="text-[13px] leading-tight font-semibold text-white">
          CodeStatus
        </p>
        <p className="mt-0.5 truncate text-[13px] leading-tight text-white/75">
          <span className="font-medium text-white/90">{label}</span> is done
        </p>
      </div>
      <span className="shrink-0 self-start text-[11px] text-white/40">now</span>
    </div>,
    document.body,
  );
}

function Dot({ state, offset = 0 }: { state: State; offset?: number }) {
  return (
    <span
      // Four dots breathing in lockstep read as one blinking element, so each
      // row is offset a little.
      style={offset ? { animationDelay: `${offset}ms` } : undefined}
      className={`dot-glow size-2 shrink-0 rounded-full transition-colors duration-500 ${DOT[state]}`}
      aria-hidden
    />
  );
}

function Count({ state, n, label }: { state: State; n: number; label: string }) {
  return (
    <span className="flex items-center gap-2.5">
      <Dot state={state} />
      <span className="tabular-nums">{n}</span> {label}
    </span>
  );
}
