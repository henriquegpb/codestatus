'use strict';

const { isTerminalEvent, rankOf } = require('./events');

// Porte de LogicalClock (Sources/CodeStatusCore/Domain/AgentSession.swift).
//
// Hooks rodam concorrentes e assincronos, entao a ordem de entrega nao e
// garantida. Turn ids sao strings opacas sem ordem inerente, entao damos a cada
// turno novo um numero de sequencia monotonico e ordenamos por (turno, rank).
class LogicalClock {
  constructor(init) {
    this.turnSequence = init ? init.turnSequence : 0;
    this.lastAppliedRank = init ? init.lastAppliedRank : -1;
    this.currentTurnID = init ? init.currentTurnID : null;
  }

  // Retorna a posicao do evento, atribuindo sequencia nova se o turno e inedito.
  position(event) {
    const turnID = event.providerTurnID;
    if (turnID === null || turnID === undefined) {
      return { turn: this.turnSequence, rank: rankOf(event) };
    }
    if (turnID === this.currentTurnID) {
      return { turn: this.turnSequence, rank: rankOf(event) };
    }
    // Um turno que nunca vimos: e mais novo que tudo ate agora.
    return { turn: this.turnSequence + 1, rank: rankOf(event) };
  }

  accepts(event) {
    if (isTerminalEvent(event)) return true;
    const pos = this.position(event);
    if (pos.turn > this.turnSequence) return true;
    if (pos.turn < this.turnSequence) return false;
    return pos.rank >= this.lastAppliedRank;
  }

  advance(event) {
    const pos = this.position(event);
    if (pos.turn > this.turnSequence) {
      this.turnSequence = pos.turn;
      this.currentTurnID = event.providerTurnID ?? null;
      this.lastAppliedRank = pos.rank;
    } else if (pos.turn === this.turnSequence) {
      this.lastAppliedRank = Math.max(this.lastAppliedRank, pos.rank);
      if (this.currentTurnID === null || this.currentTurnID === undefined) {
        this.currentTurnID = event.providerTurnID ?? null;
      }
    }
  }

  toJSON() {
    return {
      turnSequence: this.turnSequence,
      lastAppliedRank: this.lastAppliedRank,
      currentTurnID: this.currentTurnID,
    };
  }
}

module.exports = { LogicalClock };
