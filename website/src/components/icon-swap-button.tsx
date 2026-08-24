import { ArrowRight } from "lucide-react";
import type { ReactNode } from "react";

/**
 * A link whose leading icon collapses as an arrow expands in its place.
 *
 * The swap is driven by width and margin rather than by mounting and unmounting
 * either icon, which is what lets the label stay put: the two boxes hand the
 * same 16px back and forth, and the negative margin cancels the flex gap on
 * whichever side is currently empty. Nothing reflows, so the text does not
 * shift by a pixel.
 *
 * `overflow-hidden` on the anchor is load-bearing. Both icons translate as they
 * shrink, and without it they are visible sliding past the border radius.
 */
type Variant = "primary" | "secondary";
type Size = "sm" | "md";

const VARIANT: Record<Variant, string> = {
  // The glow is the one the accent button always had, kept so this still reads
  // as the primary action rather than merely a coloured one.
  primary:
    "bg-accent text-black transition-shadow hover:shadow-[0_0_28px_-6px_var(--accent)]",
  // Solid black, not transparent: over the hero's gradient a translucent
  // button borrowed the green behind it and stopped reading as a control.
  secondary:
    "border border-line bg-background text-foreground transition-colors hover:border-muted",
};

const SIZE: Record<Size, string> = {
  sm: "h-[35px] px-3 text-[13px]",
  md: "px-5 py-2.5 text-sm",
};

/** Shared timing. The long duration is what makes the swap read as one motion. */
const SWAP =
  "transition-[width,margin,opacity,transform] duration-[520ms] ease-[cubic-bezier(.16,1,.3,1)]";

export function IconSwapButton({
  href,
  label,
  icon,
  variant = "secondary",
  size = "md",
  className = "",
}: {
  href: string;
  label: string;
  icon: ReactNode;
  variant?: Variant;
  size?: Size;
  className?: string;
}) {
  return (
    <a
      href={href}
      className={`group inline-flex items-center justify-center gap-2 overflow-hidden rounded-lg font-medium focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[3px] focus-visible:outline-accent ${SIZE[size]} ${VARIANT[variant]} ${className}`}
    >
      <span
        aria-hidden
        className={`grid h-4 w-4 shrink-0 place-items-center overflow-hidden ${SWAP} group-hover:-mr-2 group-hover:w-0 group-hover:-translate-x-[18px] group-hover:opacity-0 group-focus-visible:-mr-2 group-focus-visible:w-0 group-focus-visible:-translate-x-[18px] group-focus-visible:opacity-0`}
      >
        {icon}
      </span>
      <span className="whitespace-nowrap">{label}</span>
      <span
        aria-hidden
        className={`-ml-2 grid h-4 w-0 translate-x-[18px] place-items-center overflow-hidden opacity-0 ${SWAP} group-hover:ml-0 group-hover:w-4 group-hover:translate-x-0 group-hover:opacity-100 group-focus-visible:ml-0 group-focus-visible:w-4 group-focus-visible:translate-x-0 group-focus-visible:opacity-100`}
      >
        <ArrowRight size={16} strokeWidth={2.2} />
      </span>
    </a>
  );
}
