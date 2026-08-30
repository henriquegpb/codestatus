'use strict';

// User preferences, stored beside the rest of the app state.
//
// Deliberately tiny: these are choices about when to interrupt, not
// configuration of core behaviour. What decides state is still only the hook.

const fs = require('fs');
const { paths } = require('../platform/paths');

const DEFAULTS = Object.freeze({
  // Notify when a turn finishes. The macOS app does not do this — it interrupts
  // only when there is something to do. On by default here because it was asked
  // for, but it stays a choice rather than an imposition.
  notifyOnCompletion: true,
  // Notify when a session starts needing you: approval, a reply, or a failure.
  // This is the app's reason to exist; turning it off leaves only the icon.
  notifyWhenNeeded: true,
  // Play the system sound with the notification.
  soundEnabled: true,
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
