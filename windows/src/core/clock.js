'use strict';

const { isTerminalEvent, rankOf } = require('./events');

// Port of LogicalClock (Sources/CodeStatusCore/Domain/AgentSession.swift).
//
// Hooks run concurrently and asynchronously, so delivery order is not
// guaranteed. Turn ids are opaque strings with no inherent order, so we give
// every new turn a monotonic sequence number and order by (turn, rank).
class LogicalClock {
  constructor(init) {
    this.turnSequence = init ? init.turnSequence : 0;
    this.lastAppliedRank = init ? init.lastAppliedRank : -1;
    this.currentTurnID = init ? init.currentTurnID : null;
  }

  // The event's position, assigning a fresh sequence if the turn is new.
  position(event) {
    const turnID = event.providerTurnID;
    if (turnID === null || turnID === undefined) {
      return { turn: this.turnSequence, rank: rankOf(event) };
    }
    if (turnID === this.currentTurnID) {
      return { turn: this.turnSequence, rank: rankOf(event) };
    }
    // A turn we have never seen: it is newer than everything so far.
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
