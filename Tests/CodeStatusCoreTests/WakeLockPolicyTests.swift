import Testing
import Foundation
@testable import CodeStatusCore

// MARK: - Fixtures

private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

private func session(
    _ state: AgentState,
    previous: AgentState? = nil,
    hookEvidence: Bool = true,
    id: String = "s1"
) -> AgentSession {
    var session = AgentSession(
        id: SessionID(id),
        provider: .claudeCode,
        state: state,
        now: t0,
        sourceAdapter: "test"
    )
    session.previousState = previous
    session.hasHookEvidence = hookEvidence
    return session
}

private func conditions(
    enabled: Bool = true,
    engagement: WakeLockPolicy.Engagement = .whileAgentsWork,
    battery: Int? = 80,
    onAC: Bool = false,
    lowPower: Bool = false,
    floor: Int = WakeLockPolicy.defaultBatteryFloor
) -> WakeLockPolicy.Conditions {
    WakeLockPolicy.Conditions(
        isEnabled: enabled,
        engagement: engagement,
        batteryPercentage: battery,
        isOnExternalPower: onAC,
        isLowPowerModeEnabled: lowPower,
        batteryFloor: floor
    )
}

// MARK: - What counts as working

@Suite("Which sessions justify holding the Mac awake")
struct WorkingSessionsTests {

    @Test("A busy session holds")
    func busyHolds() {
        let decision = WakeLockPolicy.decide(
            sessions: [session(.busy)], conditions: conditions()
        )
        #expect(decision == .hold(.agentsWorking(1)))
    }

    /// The distinction the whole feature turns on. An agent blocked on the user
    /// is making no progress, so the battery buys nothing — and only a real
    /// lifecycle state can tell this apart from working.
    @Test("A session waiting on the user does not hold", arguments: [
        AgentState.waitingForApproval, .waitingForInput,
    ])
    func waitingDoesNotHold(_ state: AgentState) {
        let decision = WakeLockPolicy.decide(
            sessions: [session(state)], conditions: conditions()
        )
        #expect(decision == .release(.noAgentsWorking))
    }

    @Test("Idle, finished and failed sessions do not hold", arguments: [
        AgentState.free, .failed, .ended, .discovering,
    ])
    func inactiveDoesNotHold(_ state: AgentState) {
        let decision = WakeLockPolicy.decide(
            sessions: [session(state)], conditions: conditions()
        )
        #expect(decision == .release(.noAgentsWorking))
    }

    /// A process we merely found says nothing about what it is doing. Holding on
    /// it would let one stale process keep a Mac awake with no visible cause.
    @Test("A session with no hook evidence never holds")
    func unreportedDoesNotHold() {
        let decision = WakeLockPolicy.decide(
            sessions: [session(.busy, hookEvidence: false)], conditions: conditions()
        )
        #expect(decision == .release(.noAgentsWorking))
    }

    /// After a wake everything is reconnecting for a few seconds. Dropping the
    /// lock in that window would idle the Mac back to sleep underneath an agent
    /// that never stopped.
    @Test("Reconnecting holds only if it was busy before")
    func reconnectingUsesPreviousState() {
        #expect(
            WakeLockPolicy.decide(
                sessions: [session(.reconnecting, previous: .busy)], conditions: conditions()
            ) == .hold(.agentsWorking(1))
        )
        #expect(
            WakeLockPolicy.decide(
                sessions: [session(.reconnecting, previous: .free)], conditions: conditions()
            ) == .release(.noAgentsWorking)
        )
        #expect(
            WakeLockPolicy.decide(
                sessions: [session(.reconnecting, previous: nil)], conditions: conditions()
            ) == .release(.noAgentsWorking)
        )
    }

    @Test("Working sessions are counted, not just detected")
    func countsWorking() {
        let sessions = [
            session(.busy, id: "a"),
            session(.busy, id: "b"),
            session(.free, id: "c"),
            session(.waitingForApproval, id: "d"),
        ]
        #expect(
            WakeLockPolicy.decide(sessions: sessions, conditions: conditions())
                == .hold(.agentsWorking(2))
        )
    }
}

// MARK: - Vetoes

@Suite("Conditions that override the session state")
struct WakeLockVetoTests {

    @Test("Off means off, whatever the agents are doing")
    func disabledWins() {
        let decision = WakeLockPolicy.decide(
            sessions: [session(.busy)],
            conditions: conditions(enabled: false, engagement: .always)
        )
        #expect(decision == .release(.disabled))
    }

    @Test("Always holds with no sessions at all")
    func alwaysHoldsWithoutAgents() {
        #expect(
            WakeLockPolicy.decide(sessions: [], conditions: conditions(engagement: .always))
                == .hold(.always)
        )
    }

    @Test("At or below the floor, the Mac is allowed to sleep mid-turn")
    func batteryFloorReleases() {
        #expect(
            WakeLockPolicy.decide(
                sessions: [session(.busy)], conditions: conditions(battery: 20, floor: 20)
            ) == .release(.batteryLow(percentage: 20, floor: 20))
        )
        #expect(
            WakeLockPolicy.decide(
                sessions: [session(.busy)], conditions: conditions(battery: 21, floor: 20)
            ) == .hold(.agentsWorking(1))
        )
    }

    /// A mode that could out-vote the floor would make the floor decorative.
    @Test("The floor beats Always")
    func floorBeatsAlways() {
        let decision = WakeLockPolicy.decide(
            sessions: [],
            conditions: conditions(engagement: .always, battery: 5, floor: 20)
        )
        #expect(decision == .release(.batteryLow(percentage: 5, floor: 20)))
    }

    /// Both vetoes exist to stop someone being stranded on a dead machine, and a
    /// plugged-in Mac cannot be stranded.
    @Test("Neither veto applies on external power")
    func externalPowerIgnoresVetoes() {
        let decision = WakeLockPolicy.decide(
            sessions: [session(.busy)],
            conditions: conditions(battery: 3, onAC: true, lowPower: true, floor: 20)
        )
        #expect(decision == .hold(.agentsWorking(1)))
    }

    /// Unknown must not be read as empty: a desktop reports no battery at all,
    /// and treating that as 0% would disable the feature outright.
    @Test("An unknown battery does not trigger the floor")
    func unknownBatteryDoesNotVeto() {
        let decision = WakeLockPolicy.decide(
            sessions: [session(.busy)], conditions: conditions(battery: nil)
        )
        #expect(decision == .hold(.agentsWorking(1)))
    }

    /// The system-wide setting should win over ours, or one of the two is a lie.
    @Test("Low Power Mode on battery releases")
    func lowPowerModeReleases() {
        let decision = WakeLockPolicy.decide(
            sessions: [session(.busy)], conditions: conditions(lowPower: true)
        )
        #expect(decision == .release(.lowPowerMode))
    }

    /// Reported ahead of Low Power Mode: it names a number the user can act on.
    @Test("The battery floor is reported ahead of Low Power Mode")
    func floorReportedBeforeLowPowerMode() {
        let decision = WakeLockPolicy.decide(
            sessions: [session(.busy)],
            conditions: conditions(battery: 10, lowPower: true, floor: 20)
        )
        #expect(decision == .release(.batteryLow(percentage: 10, floor: 20)))
    }
}
