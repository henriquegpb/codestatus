'use strict';

// Starting with the session, on Windows.
//
// Electron implements this natively here — it writes the Run registry key — so
// the seam exists only so main.js can call one pair of functions on both
// platforms instead of branching. The real work is in linux/autostart.js, which
// has to write the XDG .desktop file the platform has no API for.

function electronApp() {
  try {
    // eslint-disable-next-line global-require
    return require('electron').app || null;
  } catch {
    return null;
  }
}

function isEnabled() {
  const app = electronApp();
  if (!app) return false;
  try {
    return Boolean(app.getLoginItemSettings().openAtLogin);
  } catch {
    return false;
  }
}

function setEnabled(enabled) {
  const app = electronApp();
  if (app) app.setLoginItemSettings({ openAtLogin: Boolean(enabled) });
  return { enabled: Boolean(enabled), path: null };
}

module.exports = { isEnabled, setEnabled };
