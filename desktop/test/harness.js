'use strict';

// A test runner in forty lines, for the same reason the macOS side has no
// third-party dependencies: every dependency is something else that has to be
// trusted with a machine that watches the user's coding sessions.

const tests = [];

function test(name, fn) {
  tests.push([name, fn]);
}

// Awaits whatever a case returns, so a case may be async without the runner
// having to know which are. A promise that was merely returned and never waited
// on fails as an unhandled rejection at exit — reported nowhere near the case
// that caused it, and after the summary has already said everything passed.
async function run(suite) {
  let failed = 0;
  console.log(`\n${suite}`);
  for (const [name, fn] of tests) {
    try {
      await fn();
      console.log(`  ok    ${name}`);
    } catch (err) {
      failed += 1;
      console.log(`  FAIL  ${name}`);
      console.log(`        ${err.message}`);
    }
  }
  console.log(`\n${tests.length - failed}/${tests.length} passed`);
  process.exit(failed === 0 ? 0 : 1);
}

// Suites that need one specific kernel underneath them call this instead of
// failing everywhere else. It is deliberately rare: almost everything in
// src/platform/ is a pure function or a filesystem call, and those are tested
// on whichever machine is running the suite. See the note in platform.test.js.
function skipUnlessPlatform(suite, platform) {
  if (process.platform === platform) return false;
  console.log(`\n${suite}`);
  console.log(`  SKIP  needs ${platform} (running on ${process.platform})`);
  return true;
}

function skipUnlessWindows(suite) {
  return skipUnlessPlatform(suite, 'win32');
}

module.exports = {
  test, run, skipUnlessPlatform, skipUnlessWindows,
};
