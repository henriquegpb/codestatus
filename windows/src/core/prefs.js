'use strict';

// User preferences, stored beside the rest of the app state.
//
// Deliberately tiny: these are choices about when to interrupt, not
// configuration of core behaviour. What decides state is still only the hook.

const fs = require('fs');
const { paths } = require('../platform/paths');

const DEFAULTS = Object.freeze({
  // Notify when a session starts needing you: approval, a reply, or a failure.
  // This is the app's reason to exist; turning it off leaves only the icon.
  notifyWhenNeeded: true,

  // Notify when a turn finishes.
  //
  // Off by default because the macOS app does not do this at all — it
  // interrupts only when there is something to do, and "your agent finished"
  // is not something to do. Kept as an option because the distinction it
  // depends on is already implemented correctly and costs nothing to offer:
  // see isTurnCompletion, which looks at where a transition came *from*, so
  // opening a session never announces that something finished.
  notifyOnCompletion: false,

  // Play the system sound with the notification.
  soundEnabled: true,

  // Scan for running agents that are not reporting. The scan shells out to
  // PowerShell, so it is the one periodic cost in the app worth being able to
  // switch off on a slow machine.
  scanForUnreported: true,
});

let cache = null;

function load() {
  if (cache) return cache;
  let saved = {};
  try {
    saved = JSON.parse(fs.readFileSync(paths.prefs, 'utf8'));
  } catch { /* first run, or a corrupt file: fall back to defaults */ }
  // Unknown keys are ignored and missing keys fall back, so a file from a newer
  // or older version never breaks the app.
  cache = { ...DEFAULTS };
  for (const key of Object.keys(DEFAULTS)) {
    if (typeof saved[key] === typeof DEFAULTS[key]) cache[key] = saved[key];
  }
  return cache;
}

function get(key) {
  return load()[key];
}

function all() {
  return { ...load() };
}

function set(key, value) {
  if (!(key in DEFAULTS)) return;
  load()[key] = value;
  try {
    fs.mkdirSync(paths.state, { recursive: true });
    fs.writeFileSync(paths.prefs, JSON.stringify(cache, null, 2), 'utf8');
  } catch { /* not being able to save must not take the app down */ }
}

module.exports = {
  get, set, all, DEFAULTS,
};
