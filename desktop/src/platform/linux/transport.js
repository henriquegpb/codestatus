'use strict';

// The one name the app and the hook have to agree on, on Linux.
//
// This is the same mechanism the macOS app uses — an AF_UNIX socket, one
// connection per event, NDJSON on the wire — and Node's `net` takes the path
// through exactly the call the Windows build passes a pipe name to. Which is
// why the Windows transport suite has always been able to run off Windows: it
// was already exercising this.
//
// What a filesystem socket needs and a named pipe does not is the two functions
// below. A pipe name vanishes with the process that held it; a socket file
// outlives its daemon and has permissions of its own.

const fs = require('fs');

const { paths } = require('./paths');

function endpoint() {
  // The same seam the Windows side has, and the reason both are named for what
  // they are rather than for how they are implemented.
  if (process.env.CODESTATUS_PIPE) return process.env.CODESTATUS_PIPE;
  return paths.socket;
}

// Clears a socket left behind by a daemon that did not exit cleanly.
//
// `bind` fails with EADDRINUSE when the path exists at all, whether or not
// anything is listening, so a hard kill or a crash would otherwise stop the app
// from ever starting again — with an error that reads as though a second copy
// were running.
//
// It is safe to remove without probing first, because the caller has already
// established it is the only instance: the app holds Electron's single-instance
// lock, and the tests bind a path of their own. What is checked is that the
// thing at the path really is a socket, so a mistyped override can never delete
// somebody's file.
function prepare(target = endpoint()) {
  let stat;
  try {
    stat = fs.statSync(target);
  } catch {
    return false;
  }
  if (!stat.isSocket()) return false;
  try {
    fs.unlinkSync(target);
    return true;
  } catch {
    // Someone else's, or a read-only directory. Let bind produce the real
    // error rather than inventing one here.
    return false;
  }
}

// Same-user only.
//
// The containing directory is already 0700, so this is the second of two locks
// rather than the only one — but $XDG_RUNTIME_DIR is not ours to guarantee, and
// a socket that accepts a connection accepts whatever that connection sends.
function finalize(target = endpoint()) {
  try {
    fs.chmodSync(target, 0o600);
  } catch { /* the directory mode still bounds access */ }
}

module.exports = { endpoint, prepare, finalize };
