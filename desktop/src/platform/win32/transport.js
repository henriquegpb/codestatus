'use strict';

// The one name the app and the hook have to agree on, on Windows.
//
// A named pipe lives in its own kernel namespace rather than on disk, so the
// whole socket-path/permissions/staleness mechanism that linux/transport.js
// carries has no equivalent here — `prepare` and `finalize` exist only so the
// daemon can call the same three functions on both platforms.

// The pipe name includes the user so two accounts on the same machine cannot
// collide in the global pipe namespace.
function endpoint() {
  // The seam that lets the daemon be exercised off Windows. Node's net server
  // takes a Unix socket path through the same call, so the whole transport —
  // and every timer the daemon schedules around it — can run in the ordinary
  // development loop instead of only on a Windows runner.
  if (process.env.CODESTATUS_PIPE) return process.env.CODESTATUS_PIPE;

  const user = (process.env.USERNAME || 'user').replace(/[^A-Za-z0-9_-]/g, '');
  // Written by explicit concatenation: the name has to come out as
  // \\.\pipe\codestatus-<user>, and every backslash here is a real one.
  return '\\\\.\\pipe\\codestatus-' + user;
}

// Nothing to clear: the kernel drops a pipe name when its last handle closes,
// so a crashed daemon cannot leave one behind for the next launch to trip on.
function prepare() {}

// Nothing to tighten: a named pipe created by a process is reachable by that
// user's processes and no one else's, which is the property linux/transport.js
// has to ask for explicitly.
function finalize() {}

module.exports = { endpoint, prepare, finalize };
