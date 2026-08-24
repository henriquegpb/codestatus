import Testing
import Foundation
@testable import CodeStatusCore

/// End-to-end coverage of the delivery path: the real `codestatus-hook` binary,
/// a real Unix socket, the real decoder, and the real registry.
///
/// These are the tests that would catch a mismatch between the two binaries'
/// idea of the wire format, which unit tests on either side cannot.
@Suite("Transport — hook to registry", .serialized)
struct TransportIntegrationTests {

    /// Locates the built hook binary next to the test bundle.
    static var hookBinary: URL? {
        // .build/<arch>/debug/CodeStatusPackageTests.xctest → siblings include
        // the hook executable.
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent(),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // CodeStatusCoreTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // package root
                .appendingPathComponent(".build/debug"),
        ]
        for directory in candidates {
            let candidate = directory.appendingPathComponent("codestatus-hook")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// A short home so the socket fits inside `sun_path`, exercising the primary
    /// path rather than the `/tmp` fallback.
    private func makeTestHome() throws -> URL {
        let home = URL(fileURLWithPath: "/tmp/cs-\(getuid())-\(UInt32.random(in: 0..<0xFFFF))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func runHook(
        binary: URL,
        home: URL,
        payload: String,
        provider: String = "claude-code",
        environment extra: [String: String] = [:]
    ) throws {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--provider", provider]
        var environment = ["HOME": home.path]
        environment.merge(extra) { _, new in new }
        process.environment = environment

        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()

        // The agent must never see a failure from us.
        #expect(process.terminationStatus == 0)
    }

    @Test("A hook invocation becomes a session in the registry")
    func endToEnd() throws {
        guard let binary = Self.hookBinary else {
            Issue.record("codestatus-hook not built; run `swift build` first")
            return
        }
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = RuntimePaths(home: home)
        let received = Received()
        let server = EventSocketServer(paths: paths, onEvent: { received.append($0) })
        try server.start()
        defer { server.stop() }

        try runHook(
            binary: binary,
            home: home,
            payload: """
            {"session_id":"s-1","hook_event_name":"UserPromptSubmit","cwd":"/tmp/proj",\
            "prompt_id":"t-1","prompt":"CONTENT_PROMPT"}
            """,
            environment: ["TERM_PROGRAM": "Apple_Terminal"]
        )
        try runHook(
            binary: binary,
            home: home,
            payload: """
            {"session_id":"s-1","hook_event_name":"Stop","cwd":"/tmp/proj",\
            "prompt_id":"t-1","last_assistant_message":"CONTENT_REPLY"}
            """,
            environment: ["TERM_PROGRAM": "Apple_Terminal"]
        )

        let events = try received.wait(forAtLeast: 2)
        var registry = SessionRegistry()
        for event in events { _ = registry.ingest(event) }

        let sessions = registry.visible
        #expect(sessions.count == 1)
        #expect(sessions.first?.state == .free)
        #expect(sessions.first?.hostApplication == .terminal)
        #expect(sessions.first?.cwd == "/tmp/proj")
        #expect(registry.counts()[.free] == 1)
    }

    @Test("With no daemon listening the hook still succeeds and stays silent")
    func noDaemonIsHarmless() throws {
        guard let binary = Self.hookBinary else { return }
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // No server, and no heartbeat: the hook must exit 0 and write nothing,
        // which is the state a user who deleted the app is left in.
        try runHook(binary: binary, home: home, payload: #"{"session_id":"x","hook_event_name":"Stop"}"#)

        let spool = RuntimePaths(home: home).spool
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: spool.path)) ?? []
        #expect(contents.isEmpty, "a stale install must not accumulate spool files")
    }

    @Test("With the daemon recently alive but unreachable, events are spooled")
    func spoolsWhenDaemonRecentlyAlive() throws {
        guard let binary = Self.hookBinary else { return }
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = RuntimePaths(home: home)
        try paths.createDirectories()
        // A heartbeat but no listening socket: the daemon crashed or is restarting.
        FileManager.default.createFile(atPath: paths.heartbeat.path, contents: Data())
        try Data(paths.preferredSocket.path.utf8).write(to: paths.socketPointer)

        try runHook(binary: binary, home: home, payload: #"{"session_id":"x","hook_event_name":"Stop"}"#)

        let contents = try FileManager.default.contentsOfDirectory(atPath: paths.spool.path)
        #expect(contents.count == 1)
        // Nothing half-written is ever visible under its final name.
        #expect(contents.allSatisfy { $0.hasSuffix(".ndjson") })

        let spooled = try Data(contentsOf: paths.spool.appendingPathComponent(contents[0]))
        let event = try EventWireDecoder.decode(line: spooled)
        #expect(event.kind == .stop)
    }

    /// Codex never passes the entry's `args`, so the only channel left is the
    /// file name. This runs the real binary the way Codex runs it — argv[0] and
    /// nothing else — and asserts the event still says `codex`.
    ///
    /// Getting this wrong is silent: the event arrives, the session appears, and
    /// it is simply attributed to the wrong agent.
    @Test("Copied as codestatus-hook-codex and given no arguments, the hook still reports codex")
    func providerTravelsInTheFileName() throws {
        guard let binary = Self.hookBinary else { return }
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let renamed = home.appendingPathComponent("codestatus-hook-codex")
        try FileManager.default.copyItem(at: binary, to: renamed)

        let received = Received()
        let server = EventSocketServer(paths: RuntimePaths(home: home), onEvent: { received.append($0) })
        try server.start()
        defer { server.stop() }

        let process = Process()
        process.executableURL = renamed
        process.arguments = []               // exactly what Codex spawns
        process.environment = ["HOME": home.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(
            Data(#"{"session_id":"c-1","hook_event_name":"UserPromptSubmit","cwd":"/tmp/p"}"#.utf8)
        )
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let events = try received.wait(forAtLeast: 1)
        #expect(events.first?.provider == .codex)
    }

    @Test("Concurrent hook invocations all arrive with distinct ids")
    func concurrentInvocations() throws {
        guard let binary = Self.hookBinary else { return }
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let received = Received()
        let server = EventSocketServer(paths: RuntimePaths(home: home), onEvent: { received.append($0) })
        try server.start()
        defer { server.stop() }

        let count = 12
        DispatchQueue.concurrentPerform(iterations: count) { index in
            try? runHook(
                binary: binary,
                home: home,
                payload: """
                {"session_id":"s-\(index % 3)","hook_event_name":"PreToolUse","tool_name":"Bash"}
                """
            )
        }

        let events = try received.wait(forAtLeast: count)
        #expect(Set(events.map(\.id)).count == count, "event ids must never collide")

        // Three distinct sessions, regardless of arrival order.
        var registry = SessionRegistry()
        for event in events { _ = registry.ingest(event) }
        #expect(registry.all.count == 3)
    }

    @Test("Malformed input on the socket is rejected without killing the server")
    func malformedInputIsSurvivable() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let received = Received()
        let paths = RuntimePaths(home: home)
        let server = EventSocketServer(paths: paths, onEvent: { received.append($0) })
        try server.start()
        defer { server.stop() }

        let socketPath = try String(contentsOf: paths.socketPointer, encoding: .utf8)
        writeRaw("garbage, not json\n", to: socketPath)
        writeRaw(#"{"v":1,"id":"ok","provider":"codex","hook_event_name":"Stop","session_id":"s"}"# + "\n",
                 to: socketPath)

        let events = try received.wait(forAtLeast: 1)
        #expect(events.contains { $0.id == EventID("ok") })
        #expect(server.currentStats().rejected >= 1)
    }

    private func writeRaw(_ text: String, to path: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, byte) in bytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
                dst[bytes.count] = 0
            }
        }
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return }
        _ = Array(text.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

/// Thread-safe collector with a bounded wait, so tests never hang on a
/// regression in delivery.
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    func wait(forAtLeast count: Int, timeout: TimeInterval = 5) throws -> [AgentEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let snapshot = events
            lock.unlock()
            if snapshot.count >= count { return snapshot }
            usleep(20_000)
        }
        lock.lock()
        let snapshot = events
        lock.unlock()
        throw TimeoutError(expected: count, got: snapshot.count)
    }

    struct TimeoutError: Error, CustomStringConvertible {
        let expected: Int
        let got: Int
        var description: String { "timed out waiting for \(expected) events, received \(got)" }
    }
}
