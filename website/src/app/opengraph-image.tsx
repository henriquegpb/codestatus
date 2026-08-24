import { ImageResponse } from "next/og";

export const alt = "CodeStatus — Stop watching AI work";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

/**
 * The site's gradient, restated in the CSS subset Satori can actually paint.
 *
 * `GrainientField` is a WebGL shader with animated noise; none of that survives
 * here, so the field is rebuilt as stacked radial gradients from the same three
 * constants the site declares — #246800, #083400, #000000. Keep them in step
 * with `site-background.tsx`: this is an approximation of that field, not a
 * second palette.
 *
 * Order matters, and it is the CSS one: the first entry paints nearest the
 * viewer, the last sits furthest back. The greens are laid down weighted to the
 * left, where the hero puts its mass, and two linear washes sit behind them to
 * pull the right edge and the floor back to black — they darken the greens
 * exactly where those have faded to part-transparent, so the type always lands
 * on near-black rather than on mid-green.
 */
const FIELD = [
  // A small counterweight in the far corner, so the right half is not dead
  // black. Anchored past the corner rather than inside it: centred on the plate
  // it reads as a floating ball, bled off the edge it reads as light. It leads
  // the list because the two washes below would otherwise sit over it at their
  // strongest and swallow it whole.
  "radial-gradient(34% 55% at 99% 100%, rgba(46, 130, 0, 0.62), rgba(46, 130, 0, 0) 74%)",
  // The main body of green: left of centre, and tall enough to run the whole
  // left edge the way the hero field does rather than sitting in one corner.
  "radial-gradient(72% 115% at 13% 50%, rgba(36, 104, 0, 0.95), rgba(36, 104, 0, 0) 74%)",
  // A brighter core inside it, so the mass has a light source rather than
  // reading as one flat wash.
  "radial-gradient(40% 60% at 26% 30%, rgba(64, 150, 4, 0.5), rgba(64, 150, 4, 0) 72%)",
  // The darker green the shader carries in its corners.
  "radial-gradient(85% 80% at 0% 6%, rgba(8, 52, 0, 0.9), rgba(8, 52, 0, 0) 70%)",
  // Right edge and floor return to the page colour, which is also what keeps
  // the headline and the muted sub-line legible. The floor starts low so it
  // darkens the type's backdrop without flattening the left edge above it.
  "linear-gradient(to right, rgba(0, 0, 0, 0) 36%, rgba(0, 0, 0, 0.85) 90%)",
  "linear-gradient(to bottom, rgba(0, 0, 0, 0) 52%, rgba(0, 0, 0, 0.72) 100%)",
].join(", ");

/**
 * The share card, built from the same three elements as the logo: the green
 * field, thin white type, one glowing green dot. Drawn here rather than
 * exported as a flat PNG so the copy stays editable alongside the page.
 */
export default function OpengraphImage() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          backgroundColor: "#000000",
          backgroundImage: FIELD,
          padding: 80,
          fontFamily: "sans-serif",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 20 }}>
          <span style={{ fontSize: 40, fontWeight: 300, color: "#f2f3f5" }}>
            Code Status
          </span>
          <span
            style={{
              width: 26,
              height: 26,
              borderRadius: 999,
              background: "#4ee000",
              boxShadow: "0 0 40px 6px rgba(78, 224, 0, 0.55)",
            }}
          />
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 28 }}>
          <span
            style={{
              fontSize: 82,
              fontWeight: 300,
              color: "#ffffff",
              letterSpacing: -2,
            }}
          >
            Stop watching AI work.
          </span>
          <span style={{ fontSize: 32, color: "#a9adb8", maxWidth: 900 }}>
            A native macOS presence layer for coding agents. Busy, free, or needs
            you — in your menu bar.
          </span>
        </div>
      </div>
    ),
    size,
  );
}
