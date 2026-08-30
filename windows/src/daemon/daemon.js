'use strict';

// Port of EventSocketServer + EventSpool + ProcessWatcher + StatePersistence.
//
// The transport is the biggest difference from the original: there it is a Unix
// domain socket, here a Windows named pipe. The wire format is the same NDJSON
// and the semantics are the same too — one connection per event, the hook
// writes and exits.

const net = require('net');
const fs = require('fs');
const path = require('path');
const { EventEmitter } = require('events');

const { paths, createDirectories } = require('../platform/paths');
const { pipeName } = require('../platform/transport');
const { SessionRegistry } = require('../core/registry');
const { decodeLine, processExitedEvent } = require('./decoder');
const { LogicalClock } = require('../core/clock');
const { AgentState } = require('../core/state');

const HEARTBEAT_INTERVAL_MS = 30 * 1000;
const SPOOL_DRAIN_INTERVAL_MS = 2 * 1000;
const LIVENESS_INTERVAL_MS = 5 * 1000;
const SWEEP_INTERVAL_MS = 4 * 1000;
const PERSIST_DEBOUNCE_MS = 1500;
const MAX_LINE_BYTES = 64 * 1024;

// A pid that no longer exists is the one fact process observation can assert
// about state. process.kill(pid, 0) sends no signal: it only tests.
function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    // EPERM means the process exists but is not ours — still alive.
    return err.code === 'EPERM';
  }
}

class Daemon extends EventEmitter {
  constructor() {
    super();
    this.registry = new SessionRegistry();
    this.server = null;
    this.timers = [];
    this.persistTimer = null;
    this.pipe = pipeName();
  }

  start() {
    createDirectories();
    this.restore();
    this.listen();
    this.touchHeartbeat();

    this.timers.push(setInterval(() => this.touchHeartbeat(), HEARTBEAT_INTERVAL_MS));
    this.timers.push(setInterval(() => this.drainSpool(), SPOOL_DRAIN_INTERVAL_MS));
    this.timers.push(setInterval(() => this.checkLiveness(), LIVENESS_INTERVAL_MS));
    this.timers.push(setInterval(() => this.sweep(), SWEEP_INTERVAL_MS));

    // Events that arrived while the app was closed.
    this.drainSpool();
  }

  stop() {
    for (const t of this.timers) clearInterval(t);
    this.timers = [];
    if (this.persistTimer) clearTimeout(this.persistTimer);
    this.persist();
    if (this.server) {
      try { this.server.close(); } catch { /* ignore */ }
      this.server = null;
    }
  }

  // MARK: - Transport

  listen() {
    const server = net.createServer((socket) => {
      let buffer = '';
      socket.setEncoding('utf8');
      socket.on('data', (chunk) => {
        buffer += chunk;
        // An absurdly long line is junk or an attack; drop the connection.
        if (buffer.length > MAX_LINE_BYTES) {
          buffer = '';
          socket.destroy();
          return;
        }
        let index = buffer.indexOf('\n');
        while (index !== -1) {
          const line = buffer.slice(0, index);
          buffer = buffer.slice(index + 1);
          if (line.trim()) this.ingest(line);
          index = buffer.indexOf('\n');
        }
      });

      socket.on('error', () => { /* the hook may vanish at any moment */ });
    });

    server.on('error', (err) => {
      this.emit('error', err);
    });

    server.listen(this.pipe, () => {
      // The on-disk pointer exists so the hook can find the pipe without having
      // it compiled in — the name can change without rewriting any agent config.
      try {
        fs.writeFileSync(paths.pipePointer, this.pipe, 'utf8');
      } catch { /* without the pointer the hook falls back to the spool */ }
      this.emit('listening', this.pipe);
    });

    this.server = server;
  }

  ingest(line) {
    const event = decodeLine(line);
    if (!event) return;
    this.applyEvent(event);
  }

  applyEvent(event) {
    const effects = this.registry.apply(event);
    if (effects.length > 0) {
      this.emit('effects', effects, this.snapshot());
      this.schedulePersist();
    }
  }

  // MARK: - Spool

  // Replays events the hook wrote when it could not reach us.
  drainSpool() {
    let names;
    try {
      names = fs.readdirSync(paths.spool).filter((n) => n.endsWith('.ndjson'));
    } catch {
      return;
    }
    if (names.length === 0) return;

    // Arrival order matters: the names start with the timestamp in ms.
    names.sort();
    for (const name of names) {
      const full = path.join(paths.spool, name);
      try {
        const text = fs.readFileSync(full, 'utf8');
        for (const line of text.split('\n')) {
          if (line.trim()) this.ingest(line);
        }
      } catch {
        /* corrupt file: delete it anyway */
      }
      try { fs.unlinkSync(full); } catch { /* ignore */ }
    }
  }

  // MARK: - Liveness

  // The heartbeat is what authorises the hook to queue to disk. If the app is
  // deleted it stops being touched, and the hook stops queueing.
  touchHeartbeat() {
    try {
      fs.writeFileSync(paths.heartbeat, String(Date.now()), 'utf8');
    } catch { /* ignore */ }
  }

  // A session whose process disappeared without a SessionEnd has to leave the
  // counts.
  checkLiveness() {
    for (const session of this.registry.all) {
      if (session.state === AgentState.ended || !session.pid) continue;
      if (!isAlive(session.pid)) {
        this.applyEvent(processExitedEvent(session.pid));
      }
    }
  }

  // MARK: - Persistence

  schedulePersist() {
    if (this.persistTimer) return;
    this.persistTimer = setTimeout(() => {
      this.persistTimer = null;
      this.persist();
    }, PERSIST_DEBOUNCE_MS);
  }

  persist() {
    try {
      const tmp = `${paths.sessionsSnapshot}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(this.registry.toJSON()), 'utf8');
      fs.renameSync(tmp, paths.sessionsSnapshot);
    } catch { /* ignore */ }
  }

  // On the way back, what was running can only be reasserted if the process
  // still exists. The rest is discarded rather than displayed as stale truth.
  restore() {
    let saved;
    try {
      saved = JSON.parse(fs.readFileSync(paths.sessionsSnapshot, 'utf8'));
    } catch {
      return;
    }
    if (!saved || !Array.isArray(saved.sessions)) return;

    for (const s of saved.sessions) {
      if (s.state === AgentState.ended) continue;
      if (!s.pid || !isAlive(s.pid)) continue;
      s.clock = new LogicalClock(s.clock);
      // The app restarted: we lost events, so the state stops being trustworthy
      // until a fresh hook arrives. We do not invent that it is still busy.
      s.previousState = s.state;
      s.state = AgentState.reconnecting;
      this.registry.sessions.set(s.id, s);
      if (s.pid) this.registry.pidIndex.set(s.pid, s.id);
    }
  }

  snapshot() {
    return {
      counts: this.registry.counts(),
      sessions: this.registry.visible,
      unreportedCount: this.registry.unreported.length,
    };
  }
}

module.exports = { Daemon, isAlive };
