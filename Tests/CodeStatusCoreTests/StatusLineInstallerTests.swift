import Testing
import Foundation
@testable import CodeStatusCore

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("statusline-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func installer(in directory: URL) -> StatusLineInstaller {
    StatusLineInstaller(
        settingsURL: directory.appendingPathComponent("settings.json"),
        hookBinary: URL(fileURLWithPath: "/tmp/cs/bin/codestatus-hook")
    )
}

private func write(_ json: [String: Any], to directory: URL) {
    let data = try! JSONSerialization.data(withJSONObject: json)
    try! data.write(to: directory.appendingPathComponent("settings.json"))
}

private func read(_ directory: URL) -> [String: Any] {
    let data = try! Data(contentsOf: directory.appendingPathComponent("settings.json"))
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}

@Suite("Claiming the status line slot")
struct StatusLineInstallerTests {

    @Test("An empty slot is claimed")
    func installsIntoEmptySlot() throws {
        let directory = temporaryDirectory()
        write(["hooks": ["Stop": []]], to: directory)

        let outcome = try installer(in: directory).install()
        #expect(outcome == .installed)

        let root = read(directory)
        let entry = root["statusLine"] as! [String: Any]
        #expect((entry["command"] as! String).contains("--status-line"))
        // Everything else in the file survives.
        #expect(root["hooks"] != nil)
    }

    /// The difference from `hooks`, and the reason this type exists: the slot
    /// holds one command, so claiming it would otherwise silently delete the
    /// status line someone spent time building.
    @Test("An existing command is wrapped, not replaced")
    func wrapsExistingCommand() throws {
        let directory = temporaryDirectory()
        write(["statusLine": ["type": "command", "command": "~/bin/my-fancy-line.sh"]], to: directory)

        let outcome = try installer(in: directory).install()
        #expect(outcome == .wrapped(previous: "~/bin/my-fancy-line.sh"))

        let command = (read(directory)["statusLine"] as! [String: Any])["command"] as! String
        #expect(command.contains("--chain"))
        #expect(command.contains("my-fancy-line.sh"))
    }

    @Test("Installing twice does not wrap our own wrapper")
    func idempotent() throws {
        let directory = temporaryDirectory()
        write(["statusLine": ["type": "command", "command": "~/bin/mine.sh"]], to: directory)

        let subject = installer(in: directory)
        _ = try subject.install()
        let second = try subject.install()
        #expect(second == .alreadyInstalled)

        let command = (read(directory)["statusLine"] as! [String: Any])["command"] as! String
        // One --chain, not two.
        #expect(command.components(separatedBy: "--chain").count == 2)
    }

    /// The thing that must not be lost: uninstalling has to give back what was
    /// wrapped, or we have destroyed it on the way out instead of on the way in.
    @Test("Uninstalling restores the wrapped command")
    func uninstallRestores() throws {
        let directory = temporaryDirectory()
        write(["statusLine": ["type": "command", "command": "~/bin/mine.sh"]], to: directory)

        let subject = installer(in: directory)
        _ = try subject.install()
        #expect(try subject.uninstall())

        let command = (read(directory)["statusLine"] as! [String: Any])["command"] as! String
        #expect(command == "~/bin/mine.sh")
    }

    @Test("Uninstalling a slot we claimed from empty removes the key")
    func uninstallClearsWhenNothingWrapped() throws {
        let directory = temporaryDirectory()
        write([:], to: directory)

        let subject = installer(in: directory)
        _ = try subject.install()
        #expect(try subject.uninstall())
        #expect(read(directory)["statusLine"] == nil)
    }

    @Test("Someone else's status line is left completely alone")
    func doesNotTouchForeignEntries() throws {
        let directory = temporaryDirectory()
        write(["statusLine": ["type": "command", "command": "~/bin/theirs.sh"]], to: directory)
        #expect(try !installer(in: directory).uninstall())
        let command = (read(directory)["statusLine"] as! [String: Any])["command"] as! String
        #expect(command == "~/bin/theirs.sh")
    }

    /// A path with a space or a quote is exactly where a naive interpolation
    /// produces a command that silently never runs.
    @Test("Awkward paths survive quoting", arguments: [
        "/Users/a b/bin/line.sh",
        "/Users/o'brien/line.sh",
        "/Users/x/line.sh --flag \"q\"",
    ])
    func quotesAwkwardCommands(_ previous: String) throws {
        let directory = temporaryDirectory()
        write(["statusLine": ["type": "command", "command": previous]], to: directory)

        let subject = installer(in: directory)
        _ = try subject.install()
        let command = (read(directory)["statusLine"] as! [String: Any])["command"] as! String
        #expect(StatusLineInstaller.chainedCommand(in: command) == previous)

        _ = try subject.uninstall()
        let restored = (read(directory)["statusLine"] as! [String: Any])["command"] as! String
        #expect(restored == previous)
    }
}
