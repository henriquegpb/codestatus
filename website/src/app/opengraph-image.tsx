import { ImageResponse } from "next/og";

export const alt = "CodeStatus — Stop watching AI work";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

/**
 * The share card, built from the same three elements as the logo: black plate,
 * thin white type, one glowing green dot. Drawn here rather than exported as a
 * flat PNG so the copy stays editable alongside the page.
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
          background: "#000000",
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
          <span style={{ fontSize: 32, color: "#8b8f9c", maxWidth: 900 }}>
            A native macOS presence layer for coding agents. Busy, free, or needs
            you — around the notch.
          </span>
        </div>
      </div>
    ),
    size,
  );
}
