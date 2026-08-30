'use strict';

// Draws the tray icon at runtime.
//
// This is the most visible adaptation from the original. The macOS menu bar
// accepts text, so the app writes "3 busy — 1 needs you" and is done. The
// Windows tray accepts no text at all: one icon and a tooltip. So the
// information has to be drawn — a disc coloured by the worst situation present,
// with the count on top of it.
//
// The bitmap is assembled by hand in BGRA because nativeImage.createFromBitmap
// is the only route from the main process that does not need a window to
// rasterise in.

const { nativeImage } = require('electron');

const SIZE = 32;

// The colour answers the same question the whole app answers: do I need to go
// back there?
const COLORS = {
  needsYou: [0xF5, 0x9E, 0x0B], // amber — someone is waiting for you
  busy: [0x38, 0x7A, 0xE8], // blue — working
  free: [0x2E, 0xA0, 0x43], // green — free
  idle: [0x8A, 0x8A, 0x8A], // grey — no sessions
};

// A 3x5 font. Small enough to fit in 32px with room to spare, and legible once
// scaled 3x.
const GLYPHS = {
  0: ['111', '101', '101', '101', '111'],
  1: ['010', '110', '010', '010', '111'],
  2: ['111', '001', '111', '100', '111'],
  3: ['111', '001', '111', '001', '111'],
  4: ['101', '101', '111', '001', '001'],
  5: ['111', '100', '111', '001', '111'],
  6: ['111', '100', '111', '101', '111'],
  7: ['111', '001', '010', '010', '010'],
  8: ['111', '101', '111', '101', '111'],
  9: ['111', '101', '111', '001', '111'],
  '+': ['000', '010', '111', '010', '000'],
};

function blankBuffer() {
  return Buffer.alloc(SIZE * SIZE * 4, 0);
}

function setPixel(buf, x, y, [r, g, b], alpha = 255) {
  if (x < 0 || y < 0 || x >= SIZE || y >= SIZE) return;
  const i = (y * SIZE + x) * 4;
  const a = alpha / 255;
  buf[i] = Math.round(b * a);
  buf[i + 1] = Math.round(g * a);
  buf[i + 2] = Math.round(r * a);
  buf[i + 3] = alpha;
}

function drawDisc(buf, color) {
  const c = (SIZE - 1) / 2;
  const radius = SIZE / 2 - 1;
  for (let y = 0; y < SIZE; y += 1) {
    for (let x = 0; x < SIZE; x += 1) {
      const d = Math.hypot(x - c, y - c);
      if (d <= radius - 1) {
        setPixel(buf, x, y, color, 255);
      } else if (d <= radius) {
        // A one-pixel softened edge keeps the icon from looking broken beside
        // the system's own tray icons.
        setPixel(buf, x, y, color, Math.round(255 * (radius - d)));
      }
    }
  }
}

function drawGlyphs(buf, text, color) {
  const scale = 3;
  const glyphW = 3 * scale;
  const gap = scale;
  const totalW = text.length * glyphW + (text.length - 1) * gap;
  const startX = Math.round((SIZE - totalW) / 2);
  const startY = Math.round((SIZE - 5 * scale) / 2);

  text.split('').forEach((ch, index) => {
    const rows = GLYPHS[ch];
    if (!rows) return;
    const ox = startX + index * (glyphW + gap);
    for (let ry = 0; ry < rows.length; ry += 1) {
      for (let rx = 0; rx < rows[ry].length; rx += 1) {
        if (rows[ry][rx] !== '1') continue;
        for (let sy = 0; sy < scale; sy += 1) {
          for (let sx = 0; sx < scale; sx += 1) {
            setPixel(buf, ox + rx * scale + sx, startY + ry * scale + sy, color, 255);
          }
        }
      }
    }
  });
}

// Which number the icon shows is an editorial decision: what needs you beats
// everything, because it is the only thing that demands action. With nothing
// waiting, we show how many are working.
function chooseDisplay(counts) {
  if (counts.needsYou > 0) return { value: counts.needsYou, color: COLORS.needsYou };
  if (counts.busy > 0) return { value: counts.busy, color: COLORS.busy };
  if (counts.free > 0) return { value: counts.free, color: COLORS.free };
  return { value: 0, color: COLORS.idle };
}

function buildIcon(counts) {
  const { value, color } = chooseDisplay(counts);
  const buf = blankBuffer();
  drawDisc(buf, color);
  if (value > 0) {
    drawGlyphs(buf, value > 9 ? '+' : String(value), [255, 255, 255]);
  }
  return nativeImage.createFromBitmap(buf, {
    width: SIZE,
    height: SIZE,
    scaleFactor: 2,
  });
}

// The tooltip carries the text the macOS menu bar would show outright.
function buildTooltip(counts, unreportedCount) {
  const parts = [];
  if (counts.needsYou > 0) parts.push(`${counts.needsYou} needs you`);
  if (counts.busy > 0) parts.push(`${counts.busy} busy`);
  if (counts.free > 0) parts.push(`${counts.free} free`);
  if (parts.length === 0) parts.push('no active sessions');
  if (unreportedCount > 0) parts.push(`${unreportedCount} without hooks`);
  return `CodeStatus — ${parts.join(', ')}`;
}

module.exports = { buildIcon, buildTooltip, COLORS };
