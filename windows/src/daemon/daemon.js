'use strict';

// Porte de EventSocketServer + EventSpool + ProcessWatcher + StatePersistence.
//
// O transporte e a maior diferenca em relacao ao original: la e um socket de
// dominio Unix, aqui e um named pipe do Windows. O formato na linha e o mesmo
// NDJSON, e a semantica tambem - uma conexao por evento, o hook escreve e sai.

const net = require('net');
const fs = require('fs');
const path = require('path');
const { EventEmitter } = require('events');

const { paths, pipeName, createDirectories } = require('../core/paths');
const { SessionRegistry } = require('../core/registry');
const { decodeLine, processExitedEvent } = require('./decoder');
const { LogicalClock } = require('../core/clock');
const { AgentState } = require('../core/state');

const HEARTBEAT_INTERVAL_MS = 30 * 1000;
const PROCESS_CHECK_INTERVAL_MS = 5 * 1000;
const SWEEP_INTERVAL_MS = 4 * 1000;
const PERSIST_DEBOUNCE_MS = 1500;
const MAX_LINE_BYTES = 64 * 1024;

// Um pid que nao existe mais e o unico fato que a observacao de processo pode
// afirmar sobre estado. process.kill(pid, 0) nao envia sinal: so testa.
function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    // EPERM significa que o processo existe mas nao e nosso - ainda esta vivo.
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
    this.timers.push(setInterval(() => this.drainSpool(), 2000));
    this.timers.push(setInterval(() => this.checkProcesses(), PROCESS_CHECK_INTERVAL_MS));
    this.timers.push(setInterval(() => this.sweep(), SWEEP_INTERVAL_MS));

    // Eventos que chegaram enquanto o app estava fechado.
    this.drainSpool();
  }

  stop() {
    for (const t of this.timers) clearInterval(t);
    this.timers = [];
    if (this.persistTimer) clearTimeout(this.persistTimer);
    this.persist();
    if (this.server) {
      try { this.server.close(); } catch { /* ignora */ }
      this.server = null;
    }
  }

  // MARK: - Transporte

  listen() {
    const server = net.createServer((socket) => {
      let buffer = '';
      socket.setEncoding('utf8');
      socket.on('data', (chunk) => {
        buffer += chunk;
        // Uma linha absurdamente longa e lixo ou ataque; corta a conexao.
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
      socket.on('error', () => { /* o hook pode sumir a qualquer momento */ });
    });

    server.on('error', (err) => {
      this.emit('error', err);
    });

    server.listen(this.pipe, () => {
      // O ponteiro em disco existe para o hook descobrir o pipe sem te-lo
      // compilado dentro - assim o nome pode mudar sem reescrever a config
      // de nenhum agente.
      try {
        fs.writeFileSync(paths.pipePointer, this.pipe, 'utf8');
      } catch { /* sem ponteiro o hook cai no spool */ }
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

  // Reproduz eventos que o hook gravou quando nao conseguiu nos alcancar.
  drainSpool() {
    let names;
    try {
      names = fs.readdirSync(paths.spool).filter((n) => n.endsWith('.ndjson'));
    } catch {
      return;
    }
    if (names.length === 0) return;

    // Ordem de chegada importa: os nomes comecam com o timestamp em ms.
    names.sort();
    for (const name of names) {
      const full = path.join(paths.spool, name);
      try {
        const text = fs.readFileSync(full, 'utf8');
        for (const line of text.split('\n')) {
          if (line.trim()) this.ingest(line);
        }
      } catch {
        /* arquivo corrompido: some com ele mesmo assim */
      }
      try { fs.unlinkSync(full); } catch { /* ignora */ }
    }
  }

  // MARK: - Liveness

  // O heartbeat e o que autoriza o hook a enfileirar em disco. Se o app for
  // apagado, ele para de ser tocado e o hook para de enfileirar.
  touchHeartbeat() {
    try {
      fs.writeFileSync(paths.heartbeat, String(Date.now()), 'utf8');
    } catch { /* ignora */ }
  }

  // Uma sessao cujo processo sumiu sem SessionEnd precisa sair dos contadores.
  checkProcesses() {
    for (const session of this.registry.all) {
      if (session.state === AgentState.ended || !session.pid) continue;
      if (!isAlive(session.pid)) {
        this.applyEvent(processExitedEvent(session.pid));
      }
    }
  }

  sweep() {
    const removed = this.registry.sweep();
    if (removed.length > 0) {
      this.emit('effects', removed.map((id) => ({ type: 'sessionRemoved', sessionID: id })), this.snapshot());
      this.schedulePersist();
    }
  }

  // MARK: - Persistencia

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
    } catch { /* ignora */ }
  }

  // Ao voltar, o que estava rodando so pode ser reafirmado se o processo ainda
  // existe. O resto e descartado em vez de exibido como verdade antiga.
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
      // O app reiniciou: perdemos eventos, entao o estado deixa de ser
      // confiavel ate um hook novo chegar. Nao inventamos que continua busy.
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
      unreported: this.registry.unreported.length,
    };
  }
}

module.exports = { Daemon, isAlive };
