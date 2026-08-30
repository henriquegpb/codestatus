'use strict';

// A test runner in thirty lines, for the same reason the macOS side has no
// third-party dependencies: every dependency is something else that has to be
// trusted with a machine that watches the user's coding sessions.

const tests = [];

function test(name, fn) {
  tests.push([name, fn]);
}

function run(suite) {
  let failed = 0;
  console.log(`\n${suite}`);
  for (const [name, fn] of tests) {
    try {
      fn();
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

// Windows-only suites call this instead of failing on a Mac or on Linux CI.
function skipUnlessWindows(suite) {
  if (process.platform === 'win32') return false;
  console.log(`\n${suite}`);
  console.log(`  SKIP  needs Windows (running on ${process.platform})`);
  return true;
}

module.exports = { test, run, skipUnlessWindows };
