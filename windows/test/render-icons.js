'use strict';

// Writes the tray icon to test/icons/ for every state, so the artwork can be
// checked with an eye rather than an assertion. Whether a digit is legible at
// this size is a judgement, and the only way to make it is to look.
//
//   npm run icons

const { app } = require('electron');
const fs = require('fs');
const path = require('path');

const { buildIcon } = require('../src/ui/tray-icon');

const OUT = path.join(__dirname, 'icons');

const CASES = [
  ['idle', { free: 0, busy: 0, needsYou: 0, indeterminate: 0 }],
  ['free-1', { free: 1, busy: 0, needsYou: 0, indeterminate: 0 }],
  ['free-3', { free: 3, busy: 0, needsYou: 0, indeterminate: 0 }],
  ['busy-2', { free: 1, busy: 2, needsYou: 0, indeterminate: 0 }],
  ['busy-8', { free: 0, busy: 8, needsYou: 0, indeterminate: 0 }],
  ['needs-1', { free: 2, busy: 1, needsYou: 1, indeterminate: 0 }],
  ['needs-5', { free: 0, busy: 0, needsYou: 5, indeterminate: 0 }],
  ['overflow', { free: 0, busy: 0, needsYou: 12, indeterminate: 0 }],
];

app.whenReady().then(() => {
  fs.mkdirSync(OUT, { recursive: true });
  for (const [name, counts] of CASES) {
    fs.writeFileSync(path.join(OUT, `${name}.png`), buildIcon(counts).toPNG());
  }
  console.log(`Wrote ${CASES.length} images to ${OUT}`);
  app.quit();
});
