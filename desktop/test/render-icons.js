'use strict';

// Writes the tray icon to test/icons/ at every size and every state, so the
// artwork can be checked with an eye rather than an assertion.
//
// The tray icon is the one part of this app that cannot be unit-tested into
// correctness: whether a digit is legible at 16 pixels is a judgement, and the
// only way to make it is to look.
//
//   npm run icons

const { app, nativeImage } = require('electron');
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
    const icon = buildIcon(counts);
    for (const rep of [1, 2]) {
      // Round-tripped through the bitmap for the representation we want,
      // because toPNG picks one and the small one is the one that has to work.
      const size = rep === 1 ? 16 : 32;
      const bitmap = icon.toBitmap({ scaleFactor: rep });
      const png = nativeImage.createFromBitmap(bitmap, {
        width: size, height: size, scaleFactor: 1,
      }).toPNG();
      fs.writeFileSync(path.join(OUT, `${name}@${size}.png`), png);
    }
  }

  console.log(`Wrote ${CASES.length * 2} images to ${OUT}`);
  console.log('Look at the @16 files first — that is the size the tray uses at 100%.');
  app.quit();
});
