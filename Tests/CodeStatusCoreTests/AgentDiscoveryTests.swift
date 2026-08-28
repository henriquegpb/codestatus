import Testing
import Foundation
@testable import CodeStatusCore

/// A throwaway home directory we can lay agents out in.
private struct FakeHome {
    let url: URL
    let discovery: AgentDiscovery

    init() throws {
        url = URL(fileURLWithPath: "/tmp/cs-discovery-\(getuid())-\(UInt32.random(in: 0..<0xFFFFFF))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // `.homeOnly`, or every assertion below would be answered by whatever
        // the machine running the tests happens to have in /opt/homebrew.
        discovery = AgentDiscovery(home: url, systemLocations: .homeOnly)
    }

    func destroy() { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func makeDirectory(_ relative: String) throws -> URL {
        let directory = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// An executable file, since that is what detection actually tests for.
    @discardableResult
    func makeExecutable(_ relative: String) throws -> URL {
        let path = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: path.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        return path
    }

    @discardableResult
    func makeDanglingSymlink(_ relative: String) throws -> URL {
        let path = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: path.path, withDestinationPath: "/nowhere/at/all/codex"
        )
        return path
    }
}

// MARK: - The case that stranded a real user

@Test("Codex installed to ~/.local/bin is found")
func findsCodexOutsideHomebrew() throws {
    let home = try FakeHome()
    defer { home.destroy() }

    try home.makeExecutable(".local/bin/codex")

    let evidence = home.discovery.evidence(for: .codex)
    #expect(evidence.executable?.hasSuffix(".local/bin/codex") == true)
    #expect(evidence.isPresent)
}

@Test("A dangling Homebrew symlink counts as evidence, not as an executable")
func danglingSymlinkIsEvidence() throws {
    let home = try FakeHome()
    defer { home.destroy() }

    // Stands in for `/opt/homebrew/bin/codex` pointing at an install that moved.
    let link = try home.makeDanglingSymlink(".local/bin/codex")

    let evidence = home.discovery.evidence(for: .codex)
    #expect(evidence.executable == nil, "a broken link is not something we can run")
    #expect(evidence.unusableExecutable == link.path)
    #expect(evidence.isPresent, "nobody has a file named codex by accident")
}

@Test("The config directory alone is enough, with no binary anywhere")
func configDirectoryIsEnough() throws {
    let home = try FakeHome()
    defer { home.destroy() }

    try home.makeDirectory(".codex")

    let evidence = home.discovery.evidence(for: .codex)
    #expect(evidence.configDirectory?.hasSuffix(".codex") == true)
    #expect(evidence.executable == nil)
    #expect(evidence.isPresent)
}

@Test("A user's own PATH beats our guesses")
func honoursExtraDirectories() throws {
    let home = try FakeHome()
    defer { home.destroy() }

    let exotic = try home.makeDirectory("nix/profile/bin")
    try home.makeExecutable("nix/profile/bin/codex")

    let none = home.discovery.evidence(for: .codex)
    #expect(none.executable == nil, "nothing should find an unlisted directory unaided")

    let found = home.discovery.evidence(for: .codex, extraDirectories: [exotic.path])
    #expect(found.executable == exotic.appendingPathComponent("codex").path)
}

@Test("A running agent is evidence even with nothing on disk")
func runningProcessIsEvidence() throws {
    let home = try FakeHome()
    defer { home.destroy() }

    let evidence = home.discovery.evidence(for: .codex, runningProviders: [.codex])
    #expect(evidence.isPresent)
    #expect(evidence.summary == "Running right now")
}

@Test("An empty machine reports absence without asserting it")
func absenceIsReportedHonestly() throws {
    let home = try FakeHome()
    defer { home.destroy() }

    let evidence = home.discovery.evidence(for: .codex)
    #expect(!evidence.isPresent)
    #expect(evidence.summary == "Not found on this Mac")
}

@Test("Editor extensions are found in VS Code forks, newest first")
func findsEditorExtensionsInForks() throws {
    let home = try FakeHome()
    defer { home.destroy() }

    try home.makeDirectory(".cursor/extensions/anthropic.claude-code-2.1.100-darwin-arm64")
    try home.makeDirectory(".cursor/extensions/anthropic.claude-code-2.1.240-darwin-arm64")

    let evidence = home.discovery.evidence(for: .claudeCode)
    #expect(evidence.editorExtension == "anthropic.claude-code-2.1.240-darwin-arm64")
    #expect(evidence.isPresent)
}

@Test("Claude Code is recognised by ~/.claude.json alone")
func claudeConfigFileIsEnough() throws {
    let home = try FakeHome()
    defer { home.destroy() }

    FileManager.default.createFile(
        atPath: home.url.appendingPathComponent(".claude.json").path,
        contents: Data("{}".utf8)
    )

    #expect(home.discovery.evidence(for: .claudeCode).isPresent)
}

@Test("One agent's evidence is never another's")
func providersDoNotBleed() throws {
    let home = try FakeHome()
    defer { home.destroy() }

    try home.makeDirectory(".codex")
    try home.makeExecutable(".local/bin/codex")

    #expect(home.discovery.evidence(for: .codex).isPresent)
    #expect(!home.discovery.evidence(for: .claudeCode).isPresent)
}
