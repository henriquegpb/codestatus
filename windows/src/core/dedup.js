'use strict';

// Port of Sources/CodeStatusCore/Domain/EventDeduplicator.swift
//
// A FIFO window, not a true LRU: events arrive as a stream, so the oldest id is
// always the least likely to recur and eviction stays O(1). This is what
// guarantees "one sound and one notification per transition".
class EventDeduplicator {
  constructor(capacity = 4096) {
    if (!(capacity > 0)) throw new Error('capacity must be positive');
    this.capacity = capacity;
    this.seen = new Set();
    this.order = [];
    this.head = 0;
  }

  // Records an id and says whether it was new. false => drop it silently.
  admit(id) {
    if (this.seen.has(id)) return false;
    this.seen.add(id);
    this.order.push(id);
    if (this.order.length - this.head > this.capacity) {
      const evicted = this.order[this.head];
      this.head += 1;
      this.seen.delete(evicted);
      // Compact occasionally so the array does not grow without bound.
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
