import Foundation

/// Why live agent sessions are running without reporting anything.
///
/// The registry can see that a process exists and that no hook event has ever
/// arrived from it (``SessionRegistry/unreported``). That fact alone has two
/// very different causes, and telling the user the wrong one is worse than
/// saying nothing:
///
///  * The session was already running when its hooks were installed. Both
///    agents read their hook configuration once, at session start, so it will
///    never report and a new session fixes it. Nothing is broken.
///  * Codex has hooks installed but has not been told to trust them. Codex
///    refuses to execute anything in `hooks.json` until the user approves it
///    through `/hooks`, and it fails *silently* — Codex works normally and
///    CodeStatus simply shows nothing, which reads as CodeStatus being broken.
///
/// The two are distinguishable, because we record when we wrote each config
/// file and the kernel records when each process started. A Codex process that
/// started *after* we installed its hooks and has still never said a word is
/// not a timing accident: it is an untrusted hooks file.
public struct UnreportedDiagnosis: Sendable, Equatable {

    /// Codex sessions that started after `hooks.json` was written and have
    /// still never reported. The user has to run `/hooks` in Codex.
    public var codexAwaitingTrust: Int = 0

    /// Sessions of an agent CodeStatus has never connected at all.
    ///
    /// The most explainable silence there is, and the one that used to be filed
    /// under ``unexplained`` — which is why a user running Codex with no hooks
    /// installed saw an app that simply did nothing and told them nothing. The
    /// fix is a trip through Setup, not a trust prompt, and confusing the two
    /// sends people to a `/hooks` screen that correctly reports zero entries.
    public var notConnected: [AgentProvider: Int] = [:]

    /// Sessions that were already running when their hooks were installed.
    /// A new session fixes these on its own.
    public var predatesHooks: Int = 0

    /// Live and silent, with no install recorded to date it against, or too
    /// recently started to judge. Counted but never explained, because any
    /// explanation would be invented.
    public var unexplained: Int = 0

    public init(
        codexAwaitingTrust: Int = 0,
        notConnected: [AgentProvider: Int] = [:],
        predatesHooks: Int = 0,
        unexplained: Int = 0
    ) {
        self.codexAwaitingTrust = codexAwaitingTrust
        self.notConnected = notConnected
        self.predatesHooks = predatesHooks
        self.unexplained = unexplained
    }

    public var notConnectedTotal: Int { notConnected.values.reduce(0, +) }

    public var total: Int {
        codexAwaitingTrust + notConnectedTotal + predatesHooks + unexplained
    }

    public var isEmpty: Bool { total == 0 }

    /// How long a session gets to report before its silence counts as evidence.
    ///
    /// `SessionStart` fires immediately, so this is generous. It exists because
    /// a warning that flashes up every time someone opens a new Codex tab is a
    /// warning people learn to ignore, and being briefly silent about a real
    /// problem costs far less than that.
    public static let settlingPeriod: TimeInterval = 20

    /// Classifies every unreported session.
    ///
    /// - Parameters:
    ///   - sessions: live sessions with no hook evidence, from
    ///     ``SessionRegistry/unreported``.
    ///   - hooksInstalledAt: when each provider's config file was written, from
    ///     the install receipts. A provider missing here has no recorded
    ///     install, so its sessions cannot be dated against one.
    ///   - now: for the settling period.
    ///   - connectedProviders: providers whose hook entries are in their config
    ///     file right now. Defaults to whatever has a receipt, which is what
    ///     every caller meant before this parameter existed.
    public static func diagnose(
        sessions: [AgentSession],
        hooksInstalledAt: [AgentProvider: Date],
        connectedProviders: Set<AgentProvider>? = nil,
        now: Date = Date()
    ) -> UnreportedDiagnosis {
        var diagnosis = UnreportedDiagnosis()
        let connected = connectedProviders ?? Set(hooksInstalledAt.keys)

        for session in sessions {
            // First, because it is the only cause that never resolves on its
            // own: no hooks in the file means no session of this agent will
            // ever report, however long anyone waits. There is nothing to
            // settle and no start time worth consulting.
            guard connected.contains(session.provider) else {
                diagnosis.notConnected[session.provider, default: 0] += 1
                continue
            }

            guard let startedAt = session.processStartedAt else {
                diagnosis.unexplained += 1
                continue
            }
            guard let installedAt = hooksInstalledAt[session.provider] else {
                // No receipt: either hooks were never installed through us, or
                // the receipt was lost. Both leave the silence unexplained.
                diagnosis.unexplained += 1
                continue
            }

            if startedAt < installedAt {
                diagnosis.predatesHooks += 1
                continue
            }

            // Started after the install and still silent. For Codex that is the
            // trust step; for anything else we have no such explanation, and
            // guessing would be worse than admitting it.
            guard now.timeIntervalSince(startedAt) >= settlingPeriod else {
                diagnosis.unexplained += 1
                continue
            }

            if session.provider == .codex {
                diagnosis.codexAwaitingTrust += 1
            } else {
                diagnosis.unexplained += 1
            }
        }

        return diagnosis
    }
}

public extension AgentSession {
    /// When the session's process started, as a date.
    ///
    /// ``ProcessInspector`` stores it as microseconds since the epoch, which is
    /// the right shape for identity comparisons but not for arithmetic against
    /// an install timestamp.
    var processStartedAt: Date? {
        guard let processStartTime, processStartTime > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(processStartTime) / 1_000_000)
    }
}
