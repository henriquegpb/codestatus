'use strict';

// Port of Sources/CodeStatusCore/Runtime/SessionRegistry.swift
//
// The single source of truth about which sessions exist and what they are
// doing. Tray, HUD, notifications and diagnostics all read from here; none of
// them keeps its own idea of state.

const {
  AgentState, isActive, bucketOf, StateBucket, displayPriority,
} = require('./state');
const { HookEventKind, EventSource } = require('./events');
const { EventDeduplicator } = require('./dedup');
const { reduce, Outcome } = require('./reducer');
const {
  makeSession,
  sessionIDFromProvider,
  sessionIDFromProcess,
} = require('./session');

const DropReason = Object.freeze({
  duplicate: 'duplicate',
  outOfOrder: 'outOfOrder',
  unmapped: 'unmapped',
  sessionAlreadyEnded: 'sessionAlreadyEnded',
  unroutable: 'unroutable',
});

// How long an ended session lingers before removal, so the HUD can show the
// transition instead of the row vanishing mid-glance.
const ENDED_GRACE_MS = 8000;

class SessionRegistry {
  constructor(dedupCapacity = 4096) {
    this.sessions = new Map();
    this.dedup = new EventDeduplicator(dedupCapacity);
    // Routes events that identify the session only by process, such as exits
    // reported by the process watcher.
    this.pidIndex = new Map();
    // Sessions the user explicitly stopped watching. Kept so a later event for
    // the same session does not resurrect the row they just dismissed.
    this.dismissed = new Set();
  }

  get all() {
    return Array.from(this.sessions.values());
  }

  get(id) {
    return this.sessions.get(id);
  }

  // Sessions the HUD lists, ordered by how much they want the user: what needs
  // attention first, then what is working, then the rest.
  //
  // Only sessions an agent has actually reported on. A session found by
  // scanning processes proves something is running; it says nothing about what
  // that something is doing, and listing it as "unknown" forever dilutes the
  // one question the HUD exists to answer.
  get visible() {
    return this.all
      .filter((s) => isActive(s.state) && s.hasHookEvidence)
      .sort((a, b) => {
        const pa = displayPriority(a.state);
        const pb = displayPriority(b.state);
        if (pa !== pb) return pb - pa;
        return b.stateChangedAt - a.stateChangedAt;
      });
  }

  // Live sessions no agent has reported on yet. Exposed as a count rather than
  // hidden: silently omitting a running agent would be its own form of
  // dishonesty. Usually it means hooks were installed after the session began.
  //
  // A process-discovered session is suppressed as soon as a hook arrives from
  // the same pid — at that point the two rows are the same session seen twice,
  // once by identity and once by process.
  get unreported() {
    const reportingPIDs = new Set(
      this.all.filter((s) => s.hasHookEvidence && s.pid).map((s) => s.pid),
    );
    return this.all.filter((s) => {
      if (!isActive(s.state) || s.hasHookEvidence) return false;
      if (!s.pid) return true;
      return !reportingPIDs.has(s.pid);
    });
  }

  counts() {
    const out = {
      free: 0, busy: 0, needsYou: 0, indeterminate: 0,
    };
    for (const s of this.visible) {
      const b = bucketOf(s.state);
      if (b !== StateBucket.gone) out[b] += 1;
    }
    return out;
  }

  // Apply one event. Returns the list of effects for the app to react to.
  apply(event) {
    const effects = [];

    if (!this.dedup.admit(event.id)) {
      effects.push({ type: 'eventDropped', eventID: event.id, reason: DropReason.duplicate });
      return effects;
    }

    const id = this.routeToSessionID(event);
    if (!id) {
      effects.push({ type: 'eventDropped', eventID: event.id, reason: DropReason.unroutable });
      return effects;
    }

    // The user dismissed this session. Terminal events still get through, so
    // the bookkeeping stays correct, but nothing puts the row back.
    if (this.dismissed.has(id) && !this.sessions.has(id)) {
      effects.push({ type: 'eventDropped', eventID: event.id, reason: DropReason.sessionAlreadyEnded });
      return effects;
    }

    let session = this.sessions.get(id);
    let added = false;
    if (!session) {
      // A terminal event for a session we never saw does not create one —
      // creating a session just to mark it ended would flash ghost rows.
      if (event.kind === HookEventKind.sessionEnd || event.kind === HookEventKind.processExited) {
        effects.push({ type: 'eventDropped', eventID: event.id, reason: DropReason.unroutable });
        return effects;
      }
      session = makeSession({
        id,
        provider: event.provider,
        now: event.timestamp,
        sourceAdapter: event.source,
      });
      this.sessions.set(id, session);
      added = true;
    }

    const result = reduce(session, event);

    if (session.pid) this.pidIndex.set(session.pid, id);

    if (added) effects.push({ type: 'sessionAdded', sessionID: id });

    switch (result.outcome) {
      case Outcome.stateChanged:
        effects.push({ type: 'sessionChanged', transition: result.transition });
        if (result.transition.to === AgentState.ended) {
          session.endedAt = event.timestamp;
        }
        break;
      case Outcome.refreshed:
        effects.push({ type: 'sessionRefreshed', sessionID: id });
        break;
      case Outcome.ignoredOutOfOrder:
        effects.push({ type: 'eventDropped', eventID: event.id, reason: DropReason.outOfOrder });
        break;
      case Outcome.ignoredUnmapped:
        effects.push({ type: 'eventDropped', eventID: event.id, reason: DropReason.unmapped });
        break;
      case Outcome.ignoredEnded:
        effects.push({
          type: 'eventDropped',
          eventID: event.id,
          reason: DropReason.sessionAlreadyEnded,
        });
        break;
      default:
        break;
    }

    return effects;
  }

  // Records that an agent process exists, without claiming anything about what
  // it is doing. The counterpart to macOS's ProcessWatcher: it is what lets the
  // app say "something is running and not reporting" instead of showing an
  // empty popover and leaving the user to guess.
  //
  // Idempotent, because the scan re-reports the same pids every time it runs.
  observeProcess({
    pid, provider, startTime, cwd, now = Date.now(),
  }) {
    if (!pid) return null;

    const existing = this.pidIndex.get(pid);
    if (existing && this.sessions.has(existing)) return null;

    const id = sessionIDFromProcess(provider, pid, startTime);
    if (this.sessions.has(id) || this.dismissed.has(id)) return null;

    const session = makeSession({
      id,
      provider,
      now,
      sourceAdapter: EventSource.process,
      // Discovering, never `unknown`: we have not failed to determine the
      // state, we have not been told one yet.
      state: AgentState.discovering,
    });
    session.pid = pid;
    session.processStartTime = startTime || null;
    if (cwd) session.cwd = cwd;

    this.sessions.set(id, session);
    this.pidIndex.set(pid, id);
    return id;
  }

  // Preferred identity is the agent's own session id; the pid only comes into
  // play when there is none, as with watcher-detected exits.
  routeToSessionID(event) {
    // An event addressed at one session by name, which is how the liveness
    // check ends exactly the session whose process died rather than whichever
    // one the pid index happens to point at.
    if (event.targetSessionID) {
      return this.sessions.has(event.targetSessionID) ? event.targetSessionID : null;
    }
    if (event.providerSessionID) {
      return sessionIDFromProvider(event.provider, event.providerSessionID);
    }
    if (event.pid) {
      const known = this.pidIndex.get(event.pid);
      if (known) return known;
      if (event.source === EventSource.process) {
        // A process exit that maps to no known session has nothing to end.
        return null;
      }
      return sessionIDFromProcess(event.provider, event.pid, event.processStartTime || 0);
    }
    return null;
  }

  // Stop watching one session, at the user's request.
  //
  // Remembered rather than merely deleted: the agent is still running and will
  // keep sending events, and a row that reappears three seconds after you
  // dismissed it reads as the app ignoring you. The memory has to outlive the
  // session for the same reason, so it is kept for as long as the app runs —
  // a handful of strings, bounded by how many times a person clicks.
  forget(id) {
    const session = this.sessions.get(id);
    if (!session) return false;
    this.sessions.delete(id);
    if (session.pid) this.pidIndex.delete(session.pid);
    this.dismissed.add(id);
    return true;
  }

  // Removes ended sessions after the grace period.
  sweep(now = Date.now()) {
    const removed = [];
    for (const [id, s] of this.sessions) {
      if (s.state === AgentState.ended && s.endedAt && now - s.endedAt > ENDED_GRACE_MS) {
        this.sessions.delete(id);
        if (s.pid) this.pidIndex.delete(s.pid);
        removed.push(id);
      }
    }
    return removed;
  }

  // Serialisable snapshot, to persist across app restarts.
  toJSON() {
    return {
      version: 1,
      savedAt: Date.now(),
      sessions: this.all.map((s) => ({ ...s, clock: s.clock.toJSON() })),
    };
  }
}

module.exports = { SessionRegistry, DropReason, ENDED_GRACE_MS };
