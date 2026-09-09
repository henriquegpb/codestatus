'use strict';

// Which platform seam the rest of the app talks to.
//
// Everything under src/platform/ that names an operating system lives in
// win32/ or linux/, behind a file of the same name here that does nothing but
// forward. So `require('../platform/paths')` reads identically in the daemon
// whichever machine it is running on, and adding a third platform is adding a
// directory rather than editing the callers.
//
// The override is a test seam, and it is the reason the split is worth having
// rather than just tidy. The Windows port learned once that a suite which only
// ever runs on its own operating system does not catch a method that does not
// exist — so both seams are exercised from one machine here, and only the
// parts that genuinely need the kernel underneath them are skipped.
//
// Anything that is not Windows resolves to the Unix seam. On macOS that is
// wrong for production and irrelevant to it: the macOS product is the Swift app
// at the repository root, and the only thing this build does there is run its
// own tests.
function platformDirectory() {
  const override = process.env.CODESTATUS_PLATFORM;
  if (override === 'win32' || override === 'linux') return override;
  return process.platform === 'win32' ? 'win32' : 'linux';
}

module.exports = { platformDirectory };
