'use strict';

// Port of EventSocketServer + EventSpool + ProcessWatcher + StatePersistence.
//
// The transport is the biggest difference from the original: there it is a Unix
// domain socket, here a Windows named pipe. The wire format is the same NDJSON
// and the semantics are the same too — one connection per event, the hook
// writes and exits.
//
// The other difference is how a dead process is noticed. macOS gets kqueue,
// which tells the app the moment a pid exits. Windows has no equivalent that is
// cheap from Node, so liveness is polled. Nothing about state depends on the
// polling interval: a session is only ever removed because its process is gone,
// never because it went quiet.

const net = require('net');
const fs = require('fs');
const path = require('path');
const { EventEmitter } = require('events');

const { paths, createDirectories } = require('../platform/paths');
const { pipeName } = require('../platform/transport');
const { scan } = require('../platform/process-scan');
const { hostFromProcessTree } = require('../platform/host');
const { gitRoot } = require('../platform/workspace');
const { SessionTitleReader } = require('../platform/titles');
const { SessionRegistry } = require('../core/registry');
const { decodeLine, processExitedEvent } = require('./decoder');
const { LogicalClock } = require('../core/clock');
const { AgentState, isActive } = require('../core/state');
const { HostApplication } = require('../core/events');
const { diagnose } = require('../core/diagnosis');
const installer = require('../install/claude');

const HEARTBEAT_INTERVAL_MS = 30 * 1000;
const SPOOL_DRAIN_INTERVAL_MS = 2 * 1000;
const LIVENESS_INTERVAL_MS = 5 * 1000;
const SWEEP_INTERVAL_MS = 4 * 1000;
// How often to ask the agents what they have named their own sessions, and to
// resolve the repository a session sits in. Matches the macOS sweep. Both are
// filesystem work, which is why neither happens on the event path: a hook
// arrives on every tool call of every session.
const LABEL_INTERVAL_MS = 10 * 1000;
// Slow on purpose: the scan shells out to PowerShell and costs a few hundred
// milliseconds. Nothing time-critical depends on it — hooks arrive over the
// pipe regardless — so it only has to be fast enough to explain a silent agent
// before the user gives up on the app.
const PROCESS_SCAN_INTERVAL_MS = 20 * 1000;
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
    this.scanning = false;
    this.scanEnabled = true;
    this.lastScanFailed = false;
    this.titles = new SessionTitleReader();
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
    this.timers.push(setInterval(() => this.refreshLabels(), LABEL_INTERVAL_MS));
    this.timers.push(setInterval(() => this.scanForAgents(), PROCESS_SCAN_INTERVAL_MS));

    // Events that arrived while the app was closed.
    this.drainSpool();
    this.scanForAgents();
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
      // Buffered as bytes, not as a decoded string: the size guard below is a
      // byte budget, and a multi-byte character split across two chunks would
      // otherwise be mangled before it reached JSON.parse.
      let buffer = Buffer.alloc(0);

      socket.on('data', (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        // An absurdly long line is junk or an attack; drop the connection.
        if (buffer.length > MAX_LINE_BYTES) {
          buffer = Buffer.alloc(0);
          socket.destroy();
          return;
        }
        let index = buffer.indexOf(0x0a);
        while (index !== -1) {
          const line = buffer.subarray(0, index).toString('utf8');
          buffer = buffer.subarray(index + 1);
          if (line.trim()) this.ingest(line);
          index = buffer.indexOf(0x0a);
        }
      });

      // A hook that exits without a trailing newline still delivered a whole
      // event; the close is the terminator.
      socket.on('end', () => {
        const line = buffer.toString('utf8').trim();
        buffer = Buffer.alloc(0);
        if (line) this.ingest(line);
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
    const now = Date.now();
    // Addressed per session, not per pid. One pid can carry two sessions — the
    // one the scan discovered and the one its hooks reported — and ending only
    // whichever the pid index points at would leave the other behind for good.
    for (const session of this.registry.all) {
      if (session.state === AgentState.ended || !session.pid) continue;
      if (!isAlive(session.pid)) {
        this.applyEvent(processExitedEvent(session.pid, now, session.id));
      }
    }
  }

  // Drops ended sessions once their grace period is up.
  //
  // The registry keeps them briefly so the popover can show the row going away
  // rather than having it vanish mid-glance; this is what actually collects
  // them afterwards.
  sweep() {
    const removed = this.registry.sweep();
    if (removed.length === 0) return;
    this.emit(
      'effects',
      removed.map((sessionID) => ({ type: 'sessionRemoved', sessionID })),
      this.snapshot(),
    );
    this.schedulePersist();
  }

  // Picks up what each row should be called: the repository a session is in,
  // and the name the agent gave the session itself.
  //
  // On a sweep rather than on an event, for two reasons. It touches the
  // filesystem. And there would be nothing to read: Claude Code writes its
  // first custom-title a turn or so into a session, so a lookup at
  // SessionStart is guaranteed to come back empty. A row therefore leads with
  // its repository for the first sweep or two and then takes the title, which
  // is the honest order — we did not know it yet.
  refreshLabels() {
    let changed = false;
    const live = new Set();

    for (const session of this.registry.all) {
      // Resolved once and kept: a session does not change repository, and the
      // walk is the expensive half of this pass.
      if (session.cwd && !session.repositoryName) {
        const root = gitRoot(session.cwd);
        if (root) {
          session.gitRoot = root;
          session.repositoryName = path.basename(root);
          changed = true;
        }
      }

      if (!session.providerSessionID) continue;
      live.add(session.providerSessionID);
      const title = this.titles.title(session.provider, session.providerSessionID);
      // A title that has gone missing — a rotated transcript, a deleted index
      // — is not evidence that the session was renamed to nothing.
      if (!title || title === session.sessionTitle) continue;
      session.sessionTitle = title;
      changed = true;
    }

    this.titles.prune(live);
    if (changed) this.emit('effects', [{ type: 'labelsRefreshed' }], this.snapshot());
  }

  // MARK: - Process discovery

  // Finds agents that are running and have never reported, and fills in the
  // terminal each session is hosted by.
  //
  // Guarded against overlap: the scan is slower than nothing, and two of them
  // racing would double the cost for no new information.
  async scanForAgents() {
    if (this.scanning || !this.scanEnabled) return;
    this.scanning = true;
    try {
      const { agents, tree, failed } = await scan();
      this.lastScanFailed = failed;
      if (failed) return;

      let changed = false;
      for (const agent of agents) {
        if (this.registry.observeProcess(agent)) changed = true;
      }

      // Host enrichment. The hook can only prove VS Code and Windows Terminal
      // from the environment; the process tree covers everything else, and the
      // scan already has the tree in hand.
      for (const session of this.registry.all) {
        if (!session.pid || !isActive(session.state)) continue;
        if (session.hostApplication !== HostApplication.unknown) continue;
        const host = hostFromProcessTree(session.pid, tree);
        if (host !== HostApplication.unknown) {
          session.hostApplication = host;
          session.controlTarget.hostApplication = host;
          changed = true;
        }
      }

      if (changed) {
        this.emit('effects', [{ type: 'processesScanned' }], this.snapshot());
        this.schedulePersist();
      }
    } finally {
      this.scanning = false;
    }
  }

  // Re-runs everything that discovers state, for the Refresh button.
  //
  // The macOS Refresh re-scans processes; this does the same, plus a spool
  // drain, because on Windows the spool is the path a hook takes whenever the
  // app was not listening — including the seconds right after launch.
  async refresh() {
    this.drainSpool();
    this.checkLiveness();
    await this.scanForAgents();
    this.emit('effects', [{ type: 'refreshed' }], this.snapshot());
  }

  forget(sessionID) {
    if (!this.registry.forget(sessionID)) return false;
    this.emit('effects', [{ type: 'sessionRemoved', sessionID }], this.snapshot());
    this.schedulePersist();
    return true;
  }

  setScanEnabled(enabled) {
    this.scanEnabled = Boolean(enabled);
    if (this.scanEnabled) this.scanForAgents();
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
    const unreported = this.registry.unreported;
    return {
      counts: this.registry.counts(),
      sessions: this.registry.visible,
      unreportedCount: unreported.length,
      diagnosis: diagnose({
        sessions: unreported,
        hooksInstalledAt: installer.hooksInstalledAt(),
        connectedProviders: installer.connectedProviders(),
      }),
      scanFailed: this.lastScanFailed,
    };
  }
}

module.exports = { Daemon, isAlive };
