'use strict';

// Port of Sources/CodeStatusCore/Diagnostics/UnreportedDiagnosis.swift
//
// Why live agent sessions are running without reporting anything.
//
// The registry can see that a process exists and that no hook event has ever
// arrived from it. That fact alone has two very different causes, and telling
// the user the wrong one is worse than saying nothing:
//
//  * The session was already running when its hooks were installed. Claude Code
//    reads its hook configuration once, at session start, so it will never
//    report and a new session fixes it. Nothing is broken.
//  * CodeStatus was never connected to that agent at all. No session of it will
//    ever report, however long anyone waits, and the fix is a trip through
//    "Connect Claude Code" rather than patience.
//
// The two are distinguishable, because we record when we wrote the config file
// and Windows records when each process started.
//
// The macOS build has a third cause — Codex refusing to run hooks it has not
// been trusted with. Codex is not installed by this build, so that case has no
// Windows equivalent yet and is deliberately absent rather than stubbed. Its
// settling period goes with it: on macOS that delay exists only to keep the
// loud Codex callout from flashing up on every new tab, and for every other
// provider both sides of the check land on `unexplained` anyway.

function emptyDiagnosis() {
  return {
    // Sessions of an agent CodeStatus has never connected at all.
    notConnected: {},
    // Sessions that were already running when their hooks were installed.
    // A new session fixes these on its own.
    predatesHooks: 0,
    // Live and silent, with no install recorded to date them against, or too
    // recently started to judge. Counted but never explained, because any
    // explanation would be invented.
    unexplained: 0,
  };
}

function notConnectedTotal(diagnosis) {
  return Object.values(diagnosis.notConnected).reduce((a, b) => a + b, 0);
}

function total(diagnosis) {
  return notConnectedTotal(diagnosis) + diagnosis.predatesHooks + diagnosis.unexplained;
}

// Classifies every unreported session.
//
// - sessions: live sessions with no hook evidence, from registry.unreported
// - hooksInstalledAt: { provider: epochMs } from the install receipts
// - connectedProviders: providers whose hook entries are in the config file
//   right now; defaults to whatever has a receipt
function diagnose({
  sessions, hooksInstalledAt = {}, connectedProviders = null, now = Date.now(),
}) {
  const diagnosis = emptyDiagnosis();
  const connected = connectedProviders || new Set(Object.keys(hooksInstalledAt));

  for (const session of sessions) {
    // First, because it is the only cause that never resolves on its own: no
    // hooks in the file means no session of this agent will ever report. There
    // is nothing to settle and no start time worth consulting.
    if (!connected.has(session.provider)) {
      diagnosis.notConnected[session.provider] = (diagnosis.notConnected[session.provider] || 0) + 1;
      continue;
    }

    const startedAt = session.processStartTime;
    const installedAt = hooksInstalledAt[session.provider];
    if (!startedAt || !installedAt) {
      // No start time, or no receipt: either hooks were never installed through
      // us, or the receipt was lost. Both leave the silence unexplained.
      diagnosis.unexplained += 1;
      continue;
    }

    if (startedAt < installedAt) {
      diagnosis.predatesHooks += 1;
      continue;
    }

    // Started after the install and still silent. We have no explanation for
    // that on Windows, and guessing would be worse than admitting it.
    diagnosis.unexplained += 1;
  }

  return diagnosis;
}

module.exports = {
  emptyDiagnosis,
  notConnectedTotal,
  total,
  diagnose,
};
