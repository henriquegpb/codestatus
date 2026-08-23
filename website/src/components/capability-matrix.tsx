import { Check, CircleHelp, X, type LucideIcon } from "lucide-react";

const COLUMNS = [
  "Discovery",
  "Busy/free",
  "Approval",
  "Input",
  "Open",
  "Send prompt",
] as const;

type Cell = "yes" | "no" | "unverified";

const ROWS: { env: string; cells: Cell[]; notes?: Partial<Record<number, string>> }[] = [
  {
    env: "Claude Code CLI",
    cells: ["yes", "yes", "yes", "yes", "yes", "no"],
    notes: { 4: "tab" },
  },
  {
    env: "Claude Code in VS Code",
    cells: ["yes", "yes", "yes", "yes", "yes", "no"],
    notes: { 4: "workspace" },
  },
  {
    env: "Codex CLI",
    cells: ["yes", "yes", "yes", "no", "yes", "no"],
    notes: { 4: "tab" },
  },
  {
    env: "Codex in VS Code",
    cells: ["yes", "unverified", "unverified", "no", "yes", "no"],
    notes: { 4: "workspace" },
  },
];

/**
 * Icons carry the state colours from the HUD, not the brand green: a red cross
 * has to read as a limitation at a glance, which is the point of the table.
 */
const CELL: Record<Cell, { icon: LucideIcon; className: string }> = {
  yes: { icon: Check, className: "text-free" },
  no: { icon: X, className: "text-needs" },
  unverified: { icon: CircleHelp, className: "text-busy" },
};

export function CapabilityMatrix() {
  return (
    <div className="overflow-x-auto rounded-xl border border-line">
      <table className="w-full min-w-[42rem] border-collapse text-left text-sm">
        <thead>
          <tr className="border-b border-line bg-panel">
            <th scope="col" className="px-4 py-3 font-medium text-foreground">
              Environment
            </th>
            {COLUMNS.map((c) => (
              <th
                key={c}
                scope="col"
                className="px-4 py-3 font-mono text-xs font-normal text-muted"
              >
                {c}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {ROWS.map((row) => (
            <tr key={row.env} className="border-b border-line last:border-0">
              <th scope="row" className="px-4 py-3 font-medium text-foreground">
                {row.env}
              </th>
              {row.cells.map((cell, i) => {
                const { icon: Icon, className } = CELL[cell];
                return (
                  <td key={i} className="px-4 py-3">
                    <span className="flex items-center gap-1.5">
                      <Icon
                        className={`size-4 shrink-0 ${className}`}
                        strokeWidth={2}
                        aria-hidden
                      />
                      <span className="sr-only">{cell}</span>
                      {row.notes?.[i] && (
                        <span className="text-xs text-muted">
                          {row.notes[i]}
                        </span>
                      )}
                    </span>
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
