import type { ReactNode } from "react";
import type { LucideIcon } from "lucide-react";

/**
 * A section is a label, one short claim, and structured content. The long-form
 * argument lives in the repository README -- this page states the conclusion.
 */
export function Section({
  id,
  eyebrow,
  title,
  lead,
  children,
}: {
  id: string;
  eyebrow: string;
  title: string;
  lead?: string;
  children?: ReactNode;
}) {
  return (
    <section id={id} className="border-t border-line">
      <div className="mx-auto grid max-w-5xl gap-x-8 gap-y-6 px-6 py-14 md:grid-cols-[11rem_1fr]">
        <p className="font-mono text-xs uppercase tracking-[0.14em] text-muted">
          {eyebrow}
        </p>
        <div>
          <h2 className="text-2xl font-normal tracking-tight text-balance">
            {title}
          </h2>
          {lead && (
            <p className="mt-3 max-w-xl leading-relaxed text-muted text-pretty">
              {lead}
            </p>
          )}
          {children && <div className="mt-8">{children}</div>}
        </div>
      </div>
    </section>
  );
}

/**
 * Three short claims, side by side. Each is one line of support, no more.
 * The icon is decorative -- it gives the eye somewhere to land while scanning,
 * so it carries the brand green rather than any state meaning.
 */
export function Claims({
  items,
}: {
  items: readonly { icon: LucideIcon; title: string; body: ReactNode }[];
}) {
  return (
    <ul className="grid gap-x-8 gap-y-8 sm:grid-cols-3">
      {items.map(({ icon: Icon, title, body }) => (
        <li key={title}>
          <Icon
            className="size-5 text-accent"
            strokeWidth={1.5}
            aria-hidden
          />
          <h3 className="mt-3 text-sm font-medium">{title}</h3>
          <p className="mt-1.5 text-sm leading-relaxed text-muted [&_code]:font-mono [&_code]:text-[0.9em] [&_code]:text-foreground">
            {body}
          </p>
        </li>
      ))}
    </ul>
  );
}
