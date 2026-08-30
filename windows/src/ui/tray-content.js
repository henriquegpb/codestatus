'use strict';

// What the tray icon says, separated from how it is drawn.
//
// Split out so the editorial decisions here — which number wins, what the
// tooltip says when nothing is running — can be tested under plain Node.
// tray-icon.js requires Electron for the rasterising, which a unit test
// cannot.

// The macOS palette, deepened.
//
// The hues are the app's, so both platforms mean the same thing by a colour.
// The values are a notch darker because here the disc has to carry white text
// on top of it, which the menu bar's bare dot never does — the mac tints are
// tuned to sit beside a label, not behind one.
const COLORS = {
  needsYou: [0xF4, 0x52, 0x3F],
  busy: [0xE5, 0x89, 0x00],
  free: [0x24, 0xA9, 0x4C],
  idle: [0x8A, 0x8A, 0x90],
};

// Which number the icon shows is an editorial decision: what needs you beats
// everything, because it is the only thing that demands action. With nothing
// waiting, we show how many are working.
function chooseDisplay(counts) {
  if (counts.needsYou > 0) return { value: counts.needsYou, color: COLORS.needsYou, bucket: 'needsYou' };
  if (counts.busy > 0) return { value: counts.busy, color: COLORS.busy, bucket: 'busy' };
  if (counts.free > 0) return { value: counts.free, color: COLORS.free, bucket: 'free' };
  return { value: 0, color: COLORS.idle, bucket: 'idle' };
}

// Anything past nine becomes '+', so the drawn text is always one character.
// That is what lets the glyph be sized to the disc rather than squeezed to fit
// a variable-length string.
function glyphKeyFor(value) {
  if (value <= 0) return null;
  return value > 9 ? '+' : String(value);
}

// The tooltip carries the string the macOS menu bar shows outright. It is the
// only place on Windows where the full breakdown fits.
function buildTooltip(counts, unreportedCount, diagnosis) {
  // "Never connected" outranks everything: it is the one cause that never
  // resolves on its own, and it is what explains an otherwise empty icon.
  if (diagnosis && Object.keys(diagnosis.notConnected || {}).length > 0) {
    return 'CodeStatus — Claude Code is running but not connected';
  }

  const parts = [];
  if (counts.needsYou > 0) parts.push(`${counts.needsYou} needs you`);
  if (counts.busy > 0) parts.push(`${counts.busy} busy`);
  if (counts.free > 0) parts.push(`${counts.free} free`);
  if (counts.indeterminate > 0) parts.push(`${counts.indeterminate} unknown`);

  if (parts.length === 0) {
    return unreportedCount > 0
      ? `CodeStatus — ${unreportedCount} session(s) found but not reporting`
      : 'CodeStatus — no active agent sessions';
  }
  return `CodeStatus — ${parts.join(', ')}`;
}

module.exports = { COLORS, chooseDisplay, glyphKeyFor, buildTooltip };
