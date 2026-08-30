'use strict';

// The one name the app and the hook have to agree on.
//
// On macOS this is a Unix domain socket path. On Windows it is a named pipe,
// which lives in its own kernel namespace rather than on disk. Keeping it in
// its own module is what makes a third platform a new file here rather than a
// change spread through the daemon.

// The pipe name includes the user so two accounts on the same machine cannot
// collide in the global pipe namespace.
function pipeName() {
  const user = (process.env.USERNAME || 'user').replace(/[^A-Za-z0-9_-]/g, '');
  // Written by explicit concatenation: the name has to come out as
  // \\.\pipe\codestatus-<user>, and every backslash here is a real one.
  return '\\\\.\\pipe\\codestatus-' + user;
}

module.exports = { pipeName };
