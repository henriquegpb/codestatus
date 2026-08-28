import Foundation
import Testing

@testable import CodeStatusCore

private let installedAt = Date(timeIntervalSince1970: 1_700_000_000)

/// A live session that has never reported, started `offset` seconds relative to
/// the install.
private func silentSession(
    _ provider: AgentProvider,
    startedRelativeToInstall offset: TimeInterval,
    pid: pid_t = 4242
) -> AgentSession {
    var session = AgentSession(
        id: SessionID("silent-\(provider.rawValue)-\(pid)-\(offset)"),
        provider: provider,
        now: installedAt,
        sourceAdapter: "process"
    )
    session.pid = pid
    session.processStartTime = UInt64(
        (installedAt.timeIntervalSince1970 + offset) * 1_000_000
    )
    session.hasHookEvidence = false
    return session
}

@Suite("Why sessions are not reporting")
struct UnreportedDiagnosisTests {

    /// The case that made a real user think the app was broken: Codex running
    /// fine, hooks installed, and total silence because nobody ran `/hooks`.
    @Test func codexSilentAfterItsHooksWereInstalledIsATrustProblem() {
        let session = silentSession(.codex, startedRelativeToInstall: 60)
        let diagnosis = UnreportedDiagnosis.diagnose(
            sessions: [session],
            hooksInstalledAt: [.codex: installedAt],
            now: installedAt.addingTimeInterval(300)
        )

        #expect(diagnosis.codexAwaitingTrust == 1)
        #expect(diagnosis.predatesHooks == 0)
        #expect(diagnosis.unexplained == 0)
    }

    /// The innocent explanation, which must never be reported as a trust
    /// failure: the session was already open when hooks arrived.
    @Test func aSessionOlderThanItsHooksSimplyPredatesThem() {
        let session = silentSession(.codex, startedRelativeToInstall: -3600)
        let diagnosis = UnreportedDiagnosis.diagnose(
            sessions: [session],
            hooksInstalledAt: [.codex: installedAt],
            now: installedAt.addingTimeInterval(300)
        )

        #expect(diagnosis.predatesHooks == 1)
        #expect(diagnosis.codexAwaitingTrust == 0)
    }

    /// A brand new session has not had time to say anything, and accusing it
    /// would make the warning flicker on every launch.
    @Test func aSessionInsideTheSettlingPeriodIsNotYetEvidence() {
        let session = silentSession(.codex, startedRelativeToInstall: 5)
        let now = installedAt.addingTimeInterval(5 + UnreportedDiagnosis.settlingPeriod - 1)
        let diagnosis = UnreportedDiagnosis.diagnose(
            sessions: [session],
            hooksInstalledAt: [.codex: installedAt],
            now: now
        )

        #expect(diagnosis.codexAwaitingTrust == 0)
        #expect(diagnosis.unexplained == 1)
    }

    /// Once it has been silent long enough, the same session is evidence.
    @Test func theSameSessionCountsOnceTheSettlingPeriodHasPassed() {
        let session = silentSession(.codex, startedRelativeToInstall: 5)
        let now = installedAt.addingTimeInterval(5 + UnreportedDiagnosis.settlingPeriod)
        let diagnosis = UnreportedDiagnosis.diagnose(
            sessions: [session],
            hooksInstalledAt: [.codex: installedAt],
            now: now
        )

        #expect(diagnosis.codexAwaitingTrust == 1)
    }

    /// Claude Code has no trust step, so its silence is never diagnosed as one.
    @Test func claudeSilenceIsNeverReportedAsATrustProblem() {
        let session = silentSession(.claudeCode, startedRelativeToInstall: 60)
        let diagnosis = UnreportedDiagnosis.diagnose(
            sessions: [session],
            hooksInstalledAt: [.claudeCode: installedAt],
            now: installedAt.addingTimeInterval(300)
        )

        #expect(diagnosis.codexAwaitingTrust == 0)
        #expect(diagnosis.unexplained == 1)
    }

    /// An agent with no hooks in its config file is the one silence that
    /// explains itself completely — and it is the state a user lands in when
    /// setup failed to detect their agent at all.
    ///
    /// Telling them to run `/hooks` here would send them to a screen that
    /// correctly reports zero entries, which is exactly the loop this
    /// distinction exists to break.
    @Test func anAgentThatWasNeverConnectedIsNamedAsSuch() {
        let session = silentSession(.codex, startedRelativeToInstall: 60)
        let diagnosis = UnreportedDiagnosis.diagnose(
            sessions: [session],
            hooksInstalledAt: [:],
            connectedProviders: [],
            now: installedAt.addingTimeInterval(300)
        )

        #expect(diagnosis.notConnected == [.codex: 1])
        #expect(diagnosis.codexAwaitingTrust == 0)
        #expect(diagnosis.unexplained == 0)
        #expect(diagnosis.total == 1)
    }

    /// Hooks in the file but no receipt to date them against — a receipt we
    /// lost, or a file the user installed some other way. The session is
    /// genuinely unexplained, and inventing a timeline is how a wrong
    /// instruction reaches the user.
    @Test func withHooksInstalledButNoReceiptNothingIsConcluded() {
        let session = silentSession(.codex, startedRelativeToInstall: 60)
        let diagnosis = UnreportedDiagnosis.diagnose(
            sessions: [session],
            hooksInstalledAt: [:],
            connectedProviders: [.codex],
            now: installedAt.addingTimeInterval(300)
        )

        #expect(diagnosis.unexplained == 1)
        #expect(diagnosis.notConnected.isEmpty)
        #expect(diagnosis.codexAwaitingTrust == 0)
    }

    /// A receipt proves we once wrote the file, not that the entries survived.
    /// Someone who restored `~/.claude/settings.json` from a dotfiles repo has
    /// the first and not the second.
    @Test func aReceiptDoesNotOutrankTheFileItself() {
        let session = silentSession(.claudeCode, startedRelativeToInstall: 60)
        let diagnosis = UnreportedDiagnosis.diagnose(
            sessions: [session],
            hooksInstalledAt: [.claudeCode: installedAt],
            connectedProviders: [],
            now: installedAt.addingTimeInterval(300)
        )

        #expect(diagnosis.notConnected == [.claudeCode: 1])
        #expect(diagnosis.predatesHooks == 0)
    }

    /// A session we never resolved to a process cannot be dated either.
    @Test func withNoProcessStartTimeNothingIsConcluded() {
        var session = silentSession(.codex, startedRelativeToInstall: 60)
        session.processStartTime = nil
        let diagnosis = UnreportedDiagnosis.diagnose(
            sessions: [session],
            hooksInstalledAt: [.codex: installedAt],
            now: installedAt.addingTimeInterval(300)
        )

        #expect(diagnosis.unexplained == 1)
    }

    @Test func mixedCausesAreCountedSeparately() {
        let sessions = [
            silentSession(.codex, startedRelativeToInstall: 60, pid: 1),
            silentSession(.codex, startedRelativeToInstall: 120, pid: 2),
            silentSession(.codex, startedRelativeToInstall: -600, pid: 3),
            silentSession(.claudeCode, startedRelativeToInstall: 60, pid: 4),
        ]
        let diagnosis = UnreportedDiagnosis.diagnose(
            sessions: sessions,
            hooksInstalledAt: [.codex: installedAt, .claudeCode: installedAt],
            now: installedAt.addingTimeInterval(600)
        )

        #expect(diagnosis.codexAwaitingTrust == 2)
        #expect(diagnosis.predatesHooks == 1)
        #expect(diagnosis.unexplained == 1)
        #expect(diagnosis.total == 4)
    }

    @Test func noSessionsMeansNothingToReport() {
        let diagnosis = UnreportedDiagnosis.diagnose(
            sessions: [], hooksInstalledAt: [.codex: installedAt]
        )
        #expect(diagnosis.isEmpty)
    }

    /// Microseconds in, a comparable date out.
    @Test func processStartTimeConvertsToADate() {
        var session = silentSession(.codex, startedRelativeToInstall: 0)
        session.processStartTime = UInt64(1_700_000_123 * 1_000_000)
        #expect(session.processStartedAt == Date(timeIntervalSince1970: 1_700_000_123))

        session.processStartTime = 0
        #expect(session.processStartedAt == nil)
    }
}
