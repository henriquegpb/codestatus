'use strict';

// The tray icon, drawn at runtime.
//
// This is the most visible adaptation from the original. The macOS menu bar
// accepts text, so the app writes "● 2 busy  ● 1 needs you" and is done. The
// Windows tray accepts no text at all: one icon and a tooltip. So the
// information has to be drawn — a disc coloured by the most urgent situation
// present, with the count inside it.
//
// The bitmap is assembled by hand because nativeImage.createFromBitmap is the
// only route from the main process that does not need a window to rasterise in.
// Everything is supersampled and box-filtered down, which is what keeps a 16px
// glyph from looking like the broken 8-bit sprite that nearest-neighbour
// scaling produces next to the system's own icons.

const { nativeImage } = require('electron');
const {
  COLORS, chooseDisplay, glyphKeyFor, buildTooltip,
} = require('./tray-content');

// Rendered at every scale factor Windows asks for, rather than one bitmap
// stretched. 100%, 125%, 150% and 200% are the display scalings the tray
// actually requests, and a wrong-sized tray icon is resampled by the shell with
// no filtering at all.
const REPRESENTATIONS = [
  { scaleFactor: 1, size: 16 },
  { scaleFactor: 1.25, size: 20 },
  { scaleFactor: 1.5, size: 24 },
  { scaleFactor: 2, size: 32 },
];

// Subsamples per axis. Four is where the edge stops visibly stepping.
const SUPERSAMPLE = 4;

// A 5x7 font. Small enough to fit inside a 16px disc with a margin, and shaped
// enough at that size to tell 6 from 8 — which a 3x5 grid cannot do.
const GLYPHS = {
  0: ['01110', '10001', '10011', '10101', '11001', '10001', '01110'],
  1: ['00100', '01100', '00100', '00100', '00100', '00100', '01110'],
  2: ['01110', '10001', '00001', '00010', '00100', '01000', '11111'],
  3: ['11111', '00010', '00100', '00010', '00001', '10001', '01110'],
  4: ['00010', '00110', '01010', '10010', '11111', '00010', '00010'],
  5: ['11111', '10000', '11110', '00001', '00001', '10001', '01110'],
  6: ['00110', '01000', '10000', '11110', '10001', '10001', '01110'],
  7: ['11111', '00001', '00010', '00100', '01000', '01000', '01000'],
  8: ['01110', '10001', '10001', '01110', '10001', '10001', '01110'],
  9: ['01110', '10001', '10001', '01111', '00001', '00010', '01100'],
  '+': ['00000', '00100', '00100', '11111', '00100', '00100', '00000'],
};

const GLYPH_COLUMNS = 5;
const GLYPH_ROWS = 7;

// How far, in font cells, the ink spreads past the cells that are set.
//
// A 5x7 grid scaled into a 16px disc puts each stroke at barely one pixel, and
// one antialiased pixel of white on orange is a smudge rather than a digit —
// 8 and 5 in particular stopped being tellable apart. Dilating the glyph is the
// small-size equivalent of reaching for a bold weight, and it rounds the
// corners slightly on the way, which is no loss at this size.
const GLYPH_BOLD = 0.22;

// Squared distance from a point to the unit cell whose corner is (cx, cy).
// Zero inside the cell, so a point in an ink cell is always ink.
function distanceToCell(gx, gy, cx, cy) {
  const dx = Math.max(cx - gx, 0, gx - (cx + 1));
  const dy = Math.max(cy - gy, 0, gy - (cy + 1));
  return Math.hypot(dx, dy);
}

// Whether a sample lands on ink, given the glyph's continuous coordinates.
function isInk(glyph, gx, gy) {
  const col = Math.floor(gx);
  const row = Math.floor(gy);
  for (let r = row - 1; r <= row + 1; r += 1) {
    if (r < 0 || r >= GLYPH_ROWS) continue;
    for (let c = col - 1; c <= col + 1; c += 1) {
      if (c < 0 || c >= GLYPH_COLUMNS) continue;
      if (glyph[r][c] !== '1') continue;
      if (distanceToCell(gx, gy, c, r) <= GLYPH_BOLD) return true;
    }
  }
  return false;
}

function renderBitmap(size, counts) {
  const { value, color } = chooseDisplay(counts);
  const key = glyphKeyFor(value);
  const glyph = key ? GLYPHS[key] : null;

  // The geometric centre of the bitmap, not the centre pixel's index: sample
  // coordinates below are continuous, so an N-pixel icon is centred at N/2.
  const centre = size / 2;
  // A sliver in from the edge: a disc drawn flush to the bounds looks clipped
  // beside the system icons, which all carry a little air.
  const radius = size / 2 - size * 0.03;

  // Glyph geometry, in icon-space pixels. Sized off the disc so it scales with
  // the icon instead of being tuned per size.
  let scale = 0;
  let glyphX = 0;
  let glyphY = 0;
  if (glyph) {
    scale = Math.min((radius * 2 * 0.62) / GLYPH_ROWS, (radius * 2 * 0.72) / GLYPH_COLUMNS);
    glyphX = centre - (GLYPH_COLUMNS * scale) / 2;
    glyphY = centre - (GLYPH_ROWS * scale) / 2;
  }

  const buffer = Buffer.alloc(size * size * 4, 0);
  const step = 1 / SUPERSAMPLE;
  const samples = SUPERSAMPLE * SUPERSAMPLE;

  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      let discHits = 0;
      let glyphHits = 0;

      for (let sy = 0; sy < SUPERSAMPLE; sy += 1) {
        for (let sx = 0; sx < SUPERSAMPLE; sx += 1) {
          const px = x + (sx + 0.5) * step;
          const py = y + (sy + 0.5) * step;
          if (Math.hypot(px - centre, py - centre) > radius) continue;
          discHits += 1;

          if (!glyph) continue;
          if (isInk(glyph, (px - glyphX) / scale, (py - glyphY) / scale)) glyphHits += 1;
        }
      }

      if (discHits === 0) continue;

      const discAlpha = discHits / samples;
      // The glyph's coverage is measured against the samples that landed on the
      // disc, so a digit touching the rim fades with the rim instead of
      // spilling past it.
      const inkAlpha = glyphHits / discHits;

      const r = Math.round(color[0] * (1 - inkAlpha) + 255 * inkAlpha);
      const g = Math.round(color[1] * (1 - inkAlpha) + 255 * inkAlpha);
      const b = Math.round(color[2] * (1 - inkAlpha) + 255 * inkAlpha);
      const a = Math.round(discAlpha * 255);

      const i = (y * size + x) * 4;
      // BGRA, premultiplied — which is what createFromBitmap expects, and what
      // keeps a soft edge from picking up a dark halo.
      buffer[i] = Math.round((b * a) / 255);
      buffer[i + 1] = Math.round((g * a) / 255);
      buffer[i + 2] = Math.round((r * a) / 255);
      buffer[i + 3] = a;
    }
  }

  return buffer;
}

function buildIcon(counts) {
  const image = nativeImage.createEmpty();
  for (const { scaleFactor, size } of REPRESENTATIONS) {
    image.addRepresentation({
      scaleFactor,
      width: size,
      height: size,
      buffer: renderBitmap(size, counts),
    });
  }
  return image;
}

module.exports = { buildIcon, buildTooltip, COLORS };
