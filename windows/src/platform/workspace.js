'use strict';

// Port of SessionDaemon.gitRoot (Sources/CodeStatusApp/SessionDaemon.swift).
//
// A filesystem walk rather than shelling out to git: this runs for every
// discovered session, and spawning a process per session would be both slower
// and one more thing that can hang.

const fs = require('fs');
const path = require('path');

// Deep enough for any real checkout, bounded so a symlink loop or a path we
// cannot climb out of cannot spin here.
const MAX_DEPTH = 32;

function gitRoot(start) {
  if (!start) return null;
  let current;
  try {
    current = path.resolve(start);
  } catch {
    return null;
  }
  for (let i = 0; i < MAX_DEPTH; i += 1) {
    // A file, not a directory, in a worktree or a submodule — `existsSync` is
    // what both cases have in common.
    if (fs.existsSync(path.join(current, '.git'))) return current;
    const parent = path.dirname(current);
    if (parent === current) return null;
    current = parent;
  }
  return null;
}

module.exports = { gitRoot };
