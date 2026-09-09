'use strict';

// Where our own files are, which is a different question on each of the two
// ways this app can be running.
//
// Packaged, the hook script is kept out of the asar archive by `extraResources`
// so it is a plain readable file on disk — an asar is an Electron construct,
// and the hook has to be runnable by something that is only pretending to be
// Electron. From a source checkout it is simply the file in the tree.
//
// Shared by both platform seams because neither of these answers has an
// operating system in it. What does differ — which binary runs the script, and
// how the agent is told to invoke it — stays in win32/runtime.js and
// linux/runtime.js.

const path = require('path');

// Whether we are running from an installed bundle or from a source checkout.
//
// Read lazily and defensively: this module is loaded by the installer tests,
// which run under plain Node with no Electron at all.
function electronApp() {
  try {
    // eslint-disable-next-line global-require
    return require('electron').app || null;
  } catch {
    return null;
  }
}

function isPackaged() {
  const app = electronApp();
  return Boolean(app && app.isPackaged);
}

// The root of the checkout: the directory holding package.json, hook/ and
// node_modules/. Three levels up from src/platform/<os>/.
function checkoutRoot() {
  return path.join(__dirname, '..', '..');
}

// Where hook.js lives.
function resolveHookScript() {
  if (process.env.CODESTATUS_HOOK_SCRIPT) return process.env.CODESTATUS_HOOK_SCRIPT;
  if (isPackaged()) return path.join(process.resourcesPath, 'hook', 'hook.js');
  return path.join(checkoutRoot(), 'hook', 'hook.js');
}

// The Electron that npm installed, by platform-specific executable name. Used
// from a source checkout, where the point is to stop depending on a `node`
// being on PATH.
function bundledElectron(executableName) {
  return path.join(checkoutRoot(), 'node_modules', 'electron', 'dist', executableName);
}

module.exports = {
  electronApp, isPackaged, checkoutRoot, resolveHookScript, bundledElectron,
};
