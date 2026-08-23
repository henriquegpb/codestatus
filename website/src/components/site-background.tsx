"use client";

import { useState } from "react";
import Grainient from "@/components/grainient";

/**
 * The site's one gradient, defined once and used by everything that shows it.
 *
 * Every shader parameter is left at the component's own default except `zoom`;
 * the three colours are the only other thing passed. Anything tuned away from
 * that is a deliberate, separate decision and should be commented as one.
 */
const FIELD = {
  color1: "#246800",
  color2: "#083400",
  color3: "#000000",
  // Below the component default of 0.9: the field was one green mass the size
  // of the screen.
  zoom: 0.45,
} as const;

/**
 * Fills its positioned parent with the gradient.
 *
 * Reduced motion gets a painted approximation rather than a frozen canvas:
 * holding `timeSpeed` at zero would still redraw an identical frame sixty times
 * a second, which is the cost without the effect. Its colours are derived from
 * the same constants, so darkening the green cannot leave the two out of step.
 */
export function GrainientField() {
  // Read once at mount rather than in an effect: the shell markup is identical
  // either way, so there is nothing for hydration to mismatch on.
  const [stillness] = useState(() =>
    typeof window !== "undefined" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches,
  );

  if (stillness) {
    return (
      <div
        className="absolute inset-0"
        style={{
          background: `radial-gradient(120% 90% at 8% 0%, ${FIELD.color1}44, ${FIELD.color2}26 45%, transparent 70%)`,
        }}
      />
    );
  }

  return <Grainient {...FIELD} />;
}

/**
 * The gradient behind the hero.
 *
 * Deliberately only one screen tall and positioned in the flow rather than
 * fixed, so it scrolls away with the hero. Everything below the fold is body
 * copy, and a moving field behind body copy is a readability problem dressed up
 * as a design decision -- it also lets the component's own
 * `IntersectionObserver` stop the render loop the moment you scroll past it.
 */
export function SiteBackground() {
  return (
    <div
      aria-hidden
      className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[100svh] overflow-hidden"
    >
      <GrainientField />
      {/* The only overlay: the last stretch fades to the page colour so the
          layer does not end on a hard edge where the sections begin. */}
      <div className="absolute inset-0 bg-gradient-to-b from-transparent from-70% to-background" />
    </div>
  );
}
