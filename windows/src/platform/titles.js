'use strict';

// Port of SessionTitleReader (Sources/CodeStatusCore/Runtime/SessionTitleReader.swift).
//
// Reads the name an agent gave a session, from that agent's own transcript
// store. The one place in CodeStatus that reads an agent's private files
// rather than what a hook handed us, so the boundaries are worth stating.
//
// The hook is not involved and does not change: transcript_path stays off its
// allowlist, and nothing here crosses the pipe. What this reads is
// undocumented and unversioned, so every failure — a moved directory, a
// renamed key, a format that stops being NDJSON — has to return null and leave
// the session with the name it already had.
//
// Only the title is ever retained. Transcript bytes are read into a buffer to
// be searched and then dropped; nothing else from them is copied out.

const fs = require('fs');
const path = require('path');

const { paths } = require('./paths');
const { AgentProvider } = require('../core/events');

// How much of the end of a transcript to search.
//
// Claude Code appends a fresh custom-title record throughout a session, so the
// newest one is near the end. Measured against the three largest transcripts
// on a real machine — 9.3 MB, 8.1 MB and 7.2 MB — where the last record sat
// 4 KB, 0 KB and 15 KB from the end. 64 KB is four times the worst of those,
// and it bounds the read for a file that has no bound of its own.
const TAIL_BYTES = 64 * 1024;

// Cheap filter applied before any JSON parsing, so a multi-megabyte transcript
// costs one substring search per line instead of a parse.
const MARKER = '"custom-title"';

function statOf(file) {
  try {
    const stat = fs.statSync(file);
    return { size: stat.size, modified: stat.mtimeMs };
  } catch {
    return null;
  }
}

function sameStamp(a, b) {
  if (!a || !b) return a === b;
  return a.size === b.size && a.modified === b.modified;
}

// Scans the last TAIL_BYTES of a transcript backwards for the newest
// custom-title record.
function lastCustomTitle(file, size) {
  let fd;
  try {
    fd = fs.openSync(file, 'r');
  } catch {
    return null;
  }
  try {
    const start = size > TAIL_BYTES ? size - TAIL_BYTES : 0;
    const length = size - start;
    if (length <= 0) return null;

    const buffer = Buffer.allocUnsafe(length);
    const read = fs.readSync(fd, buffer, 0, length, start);
    const lines = buffer.toString('utf8', 0, read).split('\n');

    // Seeking to a byte offset lands mid-record unless we started at zero, and
    // half a JSON object is not something to hand to a parser. It also takes
    // any UTF-8 character the offset split down the middle with it.
    if (start > 0) lines.shift();

    for (let i = lines.length - 1; i >= 0; i -= 1) {
      if (!lines[i].includes(MARKER)) continue;
      let record;
      try {
        record = JSON.parse(lines[i]);
      } catch {
        continue;
      }
      if (!record || record.type !== 'custom-title') continue;
      const title = typeof record.customTitle === 'string' ? record.customTitle.trim() : '';
      return title || null;
    }
    return null;
  } catch {
    return null;
  } finally {
    try { fs.closeSync(fd); } catch { /* already gone */ }
  }
}

class SessionTitleReader {
  constructor(options = {}) {
    this.claudeProjects = options.claudeProjects || paths.claudeProjects;
    this.codexSessionIndex = options.codexSessionIndex || paths.codexSessionIndex;

    // sessionID -> { file, size, title }. The resolved path is cached because
    // finding it means listing the projects directory, and a transcript never
    // moves. The size is the invalidation stamp: the file is append-only, so
    // an unchanged size means an unchanged answer and no read at all.
    this.claudeCache = new Map();

    this.codexIndex = new Map();
    this.codexStamp = null;
  }

  // The agent's own name for a session, or null when it has not named one.
  title(provider, sessionID) {
    if (!sessionID) return null;
    if (provider === AgentProvider.claudeCode) return this.claudeTitle(sessionID);
    if (provider === AgentProvider.codex) return this.codexTitle(sessionID);
    return null;
  }

  // Drops everything cached for sessions that no longer exist. Without it the
  // cache is a leak with a slow fuse: one entry per session the machine has
  // ever run, held for as long as the app is up.
  prune(live) {
    for (const key of Array.from(this.claudeCache.keys())) {
      if (!live.has(key)) this.claudeCache.delete(key);
    }
  }

  claudeTitle(sessionID) {
    const cached = this.claudeCache.get(sessionID);
    if (cached) {
      const stat = statOf(cached.file);
      if (stat) {
        if (stat.size === cached.size) return cached.title;
        // A transcript that outgrows the tail window carries its title out of
        // reach. Keeping the last one we saw is right: the session was named,
        // and nothing has told us it was renamed.
        const title = lastCustomTitle(cached.file, stat.size) || cached.title;
        this.claudeCache.set(sessionID, { file: cached.file, size: stat.size, title });
        return title;
      }
      // The file we resolved is gone; the entry is worthless.
      this.claudeCache.delete(sessionID);
    }

    // Deliberately no negative cache. A miss costs one directory listing and a
    // handful of stat calls every ten seconds, and the alternative was worse:
    // a transcript that did not exist at first lookup would stay invisible for
    // the life of the process.
    const file = this.locate(sessionID);
    if (!file) return null;
    const stat = statOf(file);
    if (!stat) return null;

    const title = lastCustomTitle(file, stat.size);
    this.claudeCache.set(sessionID, { file, size: stat.size, title });
    return title;
  }

  // Finds <projects>/<slug>/<session id>.jsonl by listing rather than by
  // rebuilding the slug.
  //
  // Claude Code derives that directory name from the working directory with a
  // substitution it has never documented, and on Windows a drive letter and
  // backslashes give it more to do than on macOS. A session started in a path
  // we transform even slightly differently would silently never be found;
  // listing is a handful of stat calls once per session and cannot drift.
  locate(sessionID) {
    const file = `${sessionID}.jsonl`;
    let entries;
    try {
      entries = fs.readdirSync(this.claudeProjects);
    } catch {
      return null;
    }
    for (const entry of entries) {
      const candidate = path.join(this.claudeProjects, entry, file);
      if (fs.existsSync(candidate)) return candidate;
    }
    return null;
  }

  // Codex keeps names in one small index rather than in the session file. Its
  // rollout transcript carries no name at all, so this index is the only
  // source and it is a lagging one: a session it has not reached yet, and any
  // `codex exec` run, has no name here and falls back to the directory.
  codexTitle(sessionID) {
    const stamp = statOf(this.codexSessionIndex);
    if (!sameStamp(stamp, this.codexStamp)) {
      this.codexStamp = stamp;
      this.codexIndex = this.loadCodexIndex();
    }
    return this.codexIndex.get(sessionID) || null;
  }

  loadCodexIndex() {
    const index = new Map();
    let text;
    try {
      text = fs.readFileSync(this.codexSessionIndex, 'utf8');
    } catch {
      return index;
    }
    for (const line of text.split('\n')) {
      if (!line) continue;
      let record;
      try {
        record = JSON.parse(line);
      } catch {
        continue;
      }
      if (!record || typeof record.id !== 'string') continue;
      const name = typeof record.thread_name === 'string' ? record.thread_name.trim() : '';
      // The file is append-only and a rename appends again, so the last entry
      // for an id is the current name.
      if (name) index.set(record.id, name);
      else index.delete(record.id);
    }
    return index;
  }
}

module.exports = { SessionTitleReader, TAIL_BYTES };
