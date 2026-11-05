import Foundation
import Testing
@testable import CodeStatusCore

@Suite("Codex terminal clients are not separate sessions")
struct CodexClientConnectionsTests {
    @Test("Two terminal clients of one daemon are both excluded")
    func sharedBackend() {
        let clients = CodexClientConnections.clientPIDs(services: [100], sockets: [
            100: [.init(socket: 10, peer: 20), .init(socket: 11, peer: 21)],
            200: [.init(socket: 20, peer: 10)],
            201: [.init(socket: 21, peer: 11)],
        ])
        #expect(clients == [200, 201])
    }

    @Test("An unrelated connection or a listener is not evidence of a Codex client")
    func unrelatedSockets() {
        let clients = CodexClientConnections.clientPIDs(services: [100], sockets: [
            100: [.init(socket: 10, peer: 0)],
            200: [.init(socket: 20, peer: 99)],
            201: [.init(socket: 21, peer: 0)],
        ])
        #expect(clients.isEmpty)
    }

    @Test("Unavailable socket metadata never invents a client")
    func unavailableMetadata() {
        #expect(CodexClientConnections.clientPIDs(services: [100], sockets: [:]).isEmpty)
        #expect(CodexClientConnections.clientPIDs(services: [100], sockets: [
            100: [.init(socket: 0, peer: 0)], 200: [.init(socket: 0, peer: 0)],
        ]).isEmpty)
        #expect(CodexClientConnections.clientPIDs(services: [], sockets: [
            200: [.init(socket: 20, peer: 10)],
        ]).isEmpty)
    }

    @Test("Backends connected to each other are never classified as terminal clients")
    func backendConnections() {
        let clients = CodexClientConnections.clientPIDs(services: [100, 101], sockets: [
            100: [.init(socket: 10, peer: 11)],
            101: [.init(socket: 11, peer: 10)],
        ])
        #expect(clients.isEmpty)
    }

    @Test("A client adopted before connecting is removed without a false session-ended alert")
    func removeEarlyDiscovery() {
        var registry = SessionRegistry()
        _ = registry.adopt(provider: .codex, pid: 200, startTime: 123, now: Date())
        let id = SessionID.process(.codex, pid: 200, startTime: 123)
        let changes = registry.removeUnreportedCodexClients([client(pid: 200, start: 123)])
        #expect(changes == [.sessionRemoved(id)])
        #expect(registry.unreported.isEmpty)
        #expect(registry[id] == nil)
    }

    @Test("Hook-reported identities survive client discovery", arguments: [false, true])
    func preserveReportedIdentity(withProviderID: Bool) throws {
        var registry = SessionRegistry()
        _ = registry.adopt(provider: .codex, pid: 200, startTime: 123, now: Date())
        _ = registry.ingest(AgentEvent(
            id: EventID("start"), provider: .codex, kind: .sessionStart,
            source: .hook, timestamp: Date(),
            providerSessionID: withProviderID ? "actual" : nil, pid: 200
        ))
        let reportedID = withProviderID ? SessionID.provider(.codex, "actual")
            : SessionID.process(.codex, pid: 200, startTime: 123)
        var reported = try #require(registry[reportedID])
        reported.processStartTime = 123
        registry.update(reported)
        let before = registry.visible.map(\.id)
        let changes = registry.removeUnreportedCodexClients([client(pid: 200, start: 123)])
        let expected: [RegistryEvent] = withProviderID
            ? [.sessionRemoved(SessionID.process(.codex, pid: 200, startTime: 123))] : []
        #expect(changes == expected)
        #expect(registry.visible.map(\.id) == before)
        #expect(registry.visible.first?.hasHookEvidence == true)
    }

    @Test("PID reuse and other providers cannot remove an unrelated session")
    func unrelatedIdentities() {
        var registry = SessionRegistry()
        _ = registry.adopt(provider: .codex, pid: 200, startTime: 123, now: Date())
        _ = registry.adopt(provider: .claudeCode, pid: 201, startTime: 456, now: Date())
        let changes = registry.removeUnreportedCodexClients([
            client(pid: 200, start: 999), client(pid: 201, start: 456),
        ])
        #expect(changes.isEmpty)
        #expect(registry.unreported.count == 2)
    }

    private func client(pid: pid_t, start: UInt64) -> ProcessSnapshot {
        ProcessSnapshot(pid: pid, parentPID: 1, startTime: start, name: "codex")
    }
}
