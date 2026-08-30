'use strict';

// Porte de Sources/CodeStatusCore/Domain/EventDeduplicator.swift
//
// Janela FIFO, nao LRU de verdade: eventos chegam como stream, entao o id mais
// antigo e sempre o menos provavel de recorrer e a eviccao fica O(1).
// E isso que garante "um som e uma notificacao por transicao".
class EventDeduplicator {
  constructor(capacity = 4096) {
    if (!(capacity > 0)) throw new Error('capacity deve ser positivo');
    this.capacity = capacity;
    this.seen = new Set();
    this.order = [];
    this.head = 0;
  }

  // Registra um id e diz se ele era inedito. false => descartar em silencio.
  admit(id) {
    if (this.seen.has(id)) return false;
    this.seen.add(id);
    this.order.push(id);
    if (this.order.length - this.head > this.capacity) {
      const evicted = this.order[this.head];
      this.head += 1;
      this.seen.delete(evicted);
      // compacta de vez em quando para o array nao crescer sem limite
      if (this.head > this.capacity) {
        this.order = this.order.slice(this.head);
        this.head = 0;
      }
    }
    return true;
  }

  contains(id) {
    return this.seen.has(id);
  }

  get count() {
    return this.order.length - this.head;
  }
}

module.exports = { EventDeduplicator };
