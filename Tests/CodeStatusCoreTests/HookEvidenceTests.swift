import Testing
import Foundation
@testable import CodeStatusCore

/// A throwaway home directory to write the evidence file into.
private struct FakeHome {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: "/tmp/cs-evidence-\(getuid())-\(UInt32.random(in: 0..<0xFFFFFF))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func destroy() { try? FileManager.default.removeItem(at: url) }
}

@Test("The first event from a provider is always persisted")
func firstEventIsPersisted() throws {
    let home = try FakeHome()
    defer { home.destroy() }
    let store = HookEvidenceStore(paths: RuntimePaths(home: home.url))

    let now = Date()
    var ledger = HookEvidenceLedger()
    let outcome = ledger.record(.codex, at: now)
    #expect(outcome.isFirstEver)
    #expect(outcome.shouldPersist)
    #expect(ledger.table[.codex]?.firstSeen == now)

    try store.save(ledger.table)
    let reloaded = try #require(store.load()[.codex])
    // ISO 8601 truncates below the second, which nothing here is sensitive to.
    #expect(abs(reloaded.firstSeen.timeIntervalSince(now)) < 1)
}

@Test("Subsequent events do not write a file per tool call")
func laterEventsSkipTheWrite() throws {
    let start = Date()
    var ledger = HookEvidenceLedger()
    ledger.record(.claudeCode, at: start)

    let soon = ledger.record(.claudeCode, at: start.addingTimeInterval(5))
    #expect(!soon.isFirstEver)
    #expect(!soon.shouldPersist, "five seconds later is not worth a write")
    #expect(ledger.table[.claudeCode]?.lastSeen == start.addingTimeInterval(5))
    #expect(ledger.table[.claudeCode]?.firstSeen == start, "first sighting never moves")

    let later = ledger.record(
        .claudeCode, at: start.addingTimeInterval(HookEvidenceLedger.writeInterval + 1)
    )
    #expect(later.shouldPersist)
}

/// The bug this exists to prevent: measuring staleness from the last *event*
/// rather than the last *write* means a busy agent — one event every few
/// seconds, forever — never crosses the threshold and never persists at all.
@Test("A steady stream of events still gets written down periodically")
func steadyStreamStillPersists() throws {
    let start = Date()
    var ledger = HookEvidenceLedger()
    ledger.record(.claudeCode, at: start)

    var writes = 0
    // Twenty minutes of a tool call every five seconds.
    for tick in 1...240 {
        let outcome = ledger.record(.claudeCode, at: start.addingTimeInterval(Double(tick) * 5))
        if outcome.shouldPersist { writes += 1 }
    }

    #expect(writes == 4, "one write per five-minute interval, not zero and not 240")
}

@Test("A ledger loaded from disk does not immediately rewrite it")
func loadedLedgerIsAlreadyPersisted() throws {
    let start = Date()
    var ledger = HookEvidenceLedger([
        .codex: HookEvidence(firstSeen: start, lastSeen: start)
    ])
    let outcome = ledger.record(.codex, at: start.addingTimeInterval(10))
    #expect(!outcome.isFirstEver, "we already had evidence when we started")
    #expect(!outcome.shouldPersist)
}

@Test("A missing or corrupt evidence file is not an error")
func evidenceStoreToleratesGarbage() throws {
    let home = try FakeHome()
    defer { home.destroy() }
    let paths = RuntimePaths(home: home.url)
    let store = HookEvidenceStore(paths: paths)

    #expect(store.load().isEmpty)

    try paths.createDirectories()
    FileManager.default.createFile(atPath: store.url.path, contents: Data("not json".utf8))
    #expect(store.load().isEmpty, "losing this file must degrade to waiting, not to crashing")
}

@Test("An unknown provider in the file is dropped rather than decoded")
func evidenceStoreIgnoresUnknownProviders() throws {
    let home = try FakeHome()
    defer { home.destroy() }
    let paths = RuntimePaths(home: home.url)
    let store = HookEvidenceStore(paths: paths)

    try paths.createDirectories()
    let stamp = ISO8601DateFormatter().string(from: Date())
    let entry = #"{"firstSeen":"\#(stamp)","lastSeen":"\#(stamp)"}"#
    let json = #"{"gemini":\#(entry),"codex":\#(entry)}"#
    FileManager.default.createFile(atPath: store.url.path, contents: Data(json.utf8))

    let loaded = store.load()
    #expect(loaded.count == 1)
    #expect(loaded[.codex] != nil)
}
