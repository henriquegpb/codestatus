import Testing
import Foundation
@testable import CodeStatusCore

// MARK: - Fixtures

private struct Sandbox {
    let home: URL
    let paths: RuntimePaths

    init() throws {
        home = URL(fileURLWithPath: "/tmp/cs-install-\(getuid())-\(UInt32.random(in: 0..<0xFFFFFF))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = RuntimePaths(home: home)
    }

    func destroy() {
        try? FileManager.default.removeItem(at: home)
    }

    /// Writes a Claude settings file with exactly these bytes.
    @discardableResult
    func writeClaudeSettings(_ text: String, mode: Int = 0o600) throws -> URL {
        let url = ClaudeHookInstaller.settingsURL(home: home)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    func readClaudeSettings() -> String? {
        let url = ClaudeHookInstaller.settingsURL(home: home)
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var backups: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: nil)) ?? []
    }
}

private struct ProbeFailure: Error {}

private func mode(of url: URL) -> Int? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let permissions = attributes[.posixPermissions] as? NSNumber else { return nil }
    return permissions.intValue
}

// MARK: - JSONSurgeon

@Suite("JSONSurgeon — format preservation")
struct JSONSurgeonTests {

    @Test("Every byte outside the edited region is identical after an append")
    func bytesOutsideTheEditSurvive() throws {
        let source = """
            {
                "$schema"   :   "https://example.invalid/settings.json",
                "env": { "CLAUDE_THING": "ø 日本語 ✓" },
                "deeply": {"nested": {"unrelated": {"object": [1, 2.5e10, true, null]}}},
                "statusLine": {"type": "command", "command": "~/bin/line.sh"}
            }
            """ + "\n \t\n"

        var surgeon = try JSONSurgeon(source)
        try surgeon.appendToArray(atPath: ["hooks", "Stop"], element: #"{"type":"command"}"#)
        let result = surgeon.text

        #expect(result.hasPrefix("{\n    \"$schema\"   :   \"https://example.invalid/settings.json\",\n"))
        #expect(result.contains(#""env": { "CLAUDE_THING": "ø 日本語 ✓" },"#))
        #expect(result.contains(#""deeply": {"nested": {"unrelated": {"object": [1, 2.5e10, true, null]}}},"#))
        #expect(result.contains(#""statusLine": {"type": "command", "command": "~/bin/line.sh"}"#))
        // Trailing whitespace after the document is the user's; we do not tidy it.
        #expect(result.hasSuffix("}\n \t\n"))
        // The addition adopted the file's four-space indentation.
        #expect(result.contains("""
                "hooks": {
                    "Stop": [
                        {
                            "type": "command"
                        }
                    ]
                }
            """))
    }

    @Test("A tab-indented file receives tab-indented additions")
    func tabsAreDetected() throws {
        let source = "{\n\t\"model\": \"opus\"\n}\n"
        var surgeon = try JSONSurgeon(source)
        try surgeon.appendToArray(atPath: ["hooks", "Stop"], element: #"{"a":1}"#)
        #expect(surgeon.style.indentUnit == "\t")
        #expect(surgeon.text.hasPrefix("{\n\t\"model\": \"opus\",\n"))
        #expect(surgeon.text.contains(
            "\n\t\"hooks\": {\n\t\t\"Stop\": [\n\t\t\t{\n\t\t\t\t\"a\": 1\n\t\t\t}\n\t\t]\n\t}\n}"
        ))
    }

    @Test("CRLF line endings are preserved and used for inserted lines")
    func crlfIsPreserved() throws {
        let source = "{\r\n  \"model\": \"opus\"\r\n}\r\n"
        var surgeon = try JSONSurgeon(source)
        try surgeon.appendToArray(atPath: ["hooks", "Stop"], element: #"{"a":1}"#)
        let result = surgeon.text
        #expect(!result.contains("\n\n"))
        #expect(result.contains("\"model\": \"opus\",\r\n  \"hooks\": {\r\n    \"Stop\": [\r\n"))
        #expect(result.hasSuffix("}\r\n"))
    }

    @Test("Braces, brackets, and escaped quotes inside strings do not confuse the parser")
    func stringsWithStructuralCharacters() throws {
        let source = #"{"a":"} ] { [ \" \\ é","b":["{","]"],"hooks":{"Stop":[{"k":"[x]"}]}}"#
        var surgeon = try JSONSurgeon(source)
        #expect(surgeon.arrayElements(atPath: ["hooks", "Stop"]) == [#"{"k":"[x]"}"#])
        try surgeon.appendToArray(atPath: ["hooks", "Stop"], element: #"{"n":2}"#)
        // A minified document stays minified.
        #expect(surgeon.text == #"{"a":"} ] { [ \" \\ é","b":["{","]"],"hooks":{"Stop":[{"k":"[x]"},{"n":2}]}}"#)
    }

    @Test("An escaped path is decoded for comparison but re-emitted verbatim")
    func escapedStringsRoundTrip() throws {
        let source = #"{"hooks":{"Stop":[{"command":"/Users/a\"b/bin\\x"}]}}"#
        var surgeon = try JSONSurgeon(source)
        let element = try #require(surgeon.arrayElements(atPath: ["hooks", "Stop"])?.first)
        let inner = try JSONSurgeon(element)
        #expect(inner.string(atPath: ["command"]) == #"/Users/a"b/bin\x"#)
        try surgeon.appendToArray(atPath: ["hooks", "Stop"], element: #"{"c":1}"#)
        #expect(surgeon.text.contains(#""/Users/a\"b/bin\\x""#))
    }

    @Test("Malformed JSON is rejected rather than repaired")
    func malformedInputThrows() {
        let broken = [
            #"{"a": 1,}"#,          // trailing comma
            #"{a: 1}"#,             // unquoted key
            #"{"a": "unclosed}"#,   // unterminated string
            #"{"a": 1} trailing"#,  // content after the document
            #"{"a": 01}"#,          // leading zero
            #"{"a" 1}"#,            // missing colon
            #"["not", "an", "object"]"#,
        ]
        for source in broken {
            #expect(throws: JSONSurgeon.Failure.self) { try JSONSurgeon(source) }
        }
    }

    @Test("An empty document is treated as the empty object it stands for")
    func emptyDocument() throws {
        for source in ["", "\n", "   \r\n  "] {
            var surgeon = try JSONSurgeon(source)
            #expect(surgeon.wasSynthesized)
            try surgeon.appendToArray(atPath: ["hooks", "Stop"], element: #"{"a":1}"#)
            #expect(surgeon.text == """
                {
                  "hooks": {
                    "Stop": [
                      {
                        "a": 1
                      }
                    ]
                  }
                }
                """)
        }
    }

    @Test("Removing the middle of an array leaves its neighbours' layout intact")
    func removalKeepsLayout() throws {
        let source = """
            {
              "hooks": {
                "Stop": [
                  {"id": 1},
                  {"id": 2},
                  {"id": 3}
                ]
              }
            }
            """
        var surgeon = try JSONSurgeon(source)
        let removed = try surgeon.removeFromArray(atPath: ["hooks", "Stop"]) { $0.contains("2") }
        #expect(removed == 1)
        #expect(surgeon.text == """
            {
              "hooks": {
                "Stop": [
                  {"id": 1},
                  {"id": 3}
                ]
              }
            }
            """)
    }

    @Test("Removing the only element of an array leaves an empty array, not a hole")
    func removingTheOnlyElement() throws {
        var surgeon = try JSONSurgeon("{\n  \"hooks\": {\n    \"Stop\": [\n      {\"id\": 1}\n    ]\n  }\n}")
        let removed = try surgeon.removeFromArray(atPath: ["hooks", "Stop"]) { _ in true }
        #expect(removed == 1)
        #expect(surgeon.isEmptyContainer(atPath: ["hooks", "Stop"]))
        #expect(surgeon.text == "{\n  \"hooks\": {\n    \"Stop\": []\n  }\n}")
    }

    @Test("Removing from a path that does not exist is not an error")
    func removingFromMissingPath() throws {
        var surgeon = try JSONSurgeon(#"{"a": 1}"#)
        let removed = try surgeon.removeFromArray(atPath: ["hooks", "Stop"]) { _ in true }
        #expect(removed == 0)
        #expect(surgeon.text == #"{"a": 1}"#)
    }

    @Test("A value of the wrong shape is refused instead of overwritten")
    func wrongShapedPathThrows() throws {
        var surgeon = try JSONSurgeon(#"{"hooks": "please do not eat me"}"#)
        #expect(throws: JSONSurgeon.Failure.notAnObject(path: "hooks")) {
            try surgeon.appendToArray(atPath: ["hooks", "Stop"], element: "{}")
        }
        #expect(surgeon.text == #"{"hooks": "please do not eat me"}"#)
    }

    /// Regression: every lookup resolves a duplicated key to the last
    /// occurrence, the way `JSON.parse` and `serde_json` do, but `removeKey`
    /// removed the first. The two must agree, or a caller that asks a question
    /// about one member and then deletes another is deleting something it never
    /// looked at.
    @Test("Removing a duplicated key removes the one a real parser resolves to")
    func removingADuplicatedKeyTakesTheLast() throws {
        var surgeon = try JSONSurgeon(#"{"hooks": {"Stop": [1]}, "hooks": {}}"#)
        // The emptiness that justifies the removal is the *last* member's.
        #expect(surgeon.isEmptyContainer(atPath: ["hooks"]))
        #expect(try surgeon.removeKey(atPath: ["hooks"]))
        #expect(surgeon.text == #"{"hooks": {"Stop": [1]}}"#)

        // And one level down, where our per-event keys live.
        var nested = try JSONSurgeon(#"{"hooks": {"Stop": [1], "Stop": []}}"#)
        #expect(nested.isEmptyContainer(atPath: ["hooks", "Stop"]))
        #expect(try nested.removeKey(atPath: ["hooks", "Stop"]))
        #expect(nested.text == #"{"hooks": {"Stop": [1]}}"#)
    }

    @Test("An existing user array is extended at the user's own indentation")
    func matchesExistingElementIndentation() throws {
        let source = """
            {
              "hooks": {
                "Stop": [
                      {"id": 1}
                ]
              }
            }
            """
        var surgeon = try JSONSurgeon(source)
        try surgeon.appendToArray(atPath: ["hooks", "Stop"], element: #"{"id":2}"#)
        // Ten spaces, because that is what the user used — not the file's unit.
        #expect(surgeon.text.contains(
            "          {\"id\": 1},\n          {\n            \"id\": 2\n          }\n"
        ))
    }
}

// MARK: - Hook installation

@Suite("Hook installation")
struct HookInstallerTests {

    @Test("Installing into a missing settings file creates it 0600 with one entry per event")
    func installIntoMissingFile() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }

        let claude = ClaudeHookInstaller(paths: sandbox.paths, home: sandbox.home)
        let plan = try claude.install()

        #expect(plan.createsFile)
        let text = try #require(sandbox.readClaudeSettings())
        #expect(mode(of: claude.settingsURL) == 0o600)
        #expect((try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil)

        let surgeon = try JSONSurgeon(text)
        for event in ClaudeHookInstaller.events {
            let elements = try #require(surgeon.arrayElements(atPath: ["hooks", event]))
            #expect(elements.count == 1)
            #expect(elements[0].contains("\"async\": true"))
            #expect(elements[0].contains("\"--provider\", \"claude-code\""))
            #expect(elements[0].contains(sandbox.paths.hookBinary.path))
            // `matcher` is omitted so both agents read the entry as match-all.
            #expect(!elements[0].contains("matcher"))
        }
        #expect(try claude.isInstalled())
    }

    @Test("Installing twice leaves exactly one entry per event")
    func installIsIdempotent() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }

        let claude = ClaudeHookInstaller(paths: sandbox.paths, home: sandbox.home)
        try claude.install()
        let once = try #require(sandbox.readClaudeSettings())
        let second = try claude.install()
        let twice = try #require(sandbox.readClaudeSettings())

        #expect(second.isNoOp)
        #expect(once == twice)

        let surgeon = try JSONSurgeon(twice)
        for event in ClaudeHookInstaller.events {
            #expect(surgeon.arrayElements(atPath: ["hooks", event])?.count == 1)
        }
    }

    @Test("A user's own hook in the same event survives install and uninstall byte-for-byte")
    func userHooksInTheSameEventSurvive() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }

        let original = """
            {
              "model": "opus",
              "hooks": {
                "Stop": [
                  {
                    "matcher": "*",
                    "hooks": [
                      {"type": "command", "command": "/usr/local/bin/my-bell.sh"}
                    ]
                  }
                ]
              },
              "permissions": {"allow": ["Bash(git status:*)"]}
            }

            """
        try sandbox.writeClaudeSettings(original)

        let claude = ClaudeHookInstaller(paths: sandbox.paths, home: sandbox.home)
        try claude.install()

        let installed = try #require(sandbox.readClaudeSettings())
        #expect(installed.contains(#"{"type": "command", "command": "/usr/local/bin/my-bell.sh"}"#))
        #expect(installed.contains(#""permissions": {"allow": ["Bash(git status:*)"]}"#))
        #expect(try JSONSurgeon(installed).arrayElements(atPath: ["hooks", "Stop"])?.count == 2)

        try claude.uninstall()
        #expect(sandbox.readClaudeSettings() == original)
    }

    @Test("Uninstall leaves a user hook whose command merely contains our name alone")
    func lookalikeCommandIsNotOurs() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }

        let original = """
            {
              "hooks": {
                "Stop": [
                  {"hooks": [{"type": "command", "command": "/usr/local/bin/codestatus-notify"}]},
                  {"hooks": [{"type": "command", "command": "echo codestatus-hook"}]}
                ]
              }
            }
            """
        try sandbox.writeClaudeSettings(original)

        let claude = ClaudeHookInstaller(paths: sandbox.paths, home: sandbox.home)
        try claude.install()
        try claude.uninstall()

        #expect(sandbox.readClaudeSettings() == original)
    }

    @Test("Uninstall removes only our entries and the structure we created")
    func uninstallRemovesOnlyOurWork() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }

        let original = "{\n  \"model\": \"opus\"\n}\n"
        try sandbox.writeClaudeSettings(original)

        let claude = ClaudeHookInstaller(paths: sandbox.paths, home: sandbox.home)
        try claude.install()
        #expect(try #require(sandbox.readClaudeSettings()).contains("\"hooks\""))

        let plan = try claude.uninstall()
        #expect(plan.removedEntries == ClaudeHookInstaller.events.count)
        // We created `hooks`, so we take it away again — and nothing else.
        #expect(sandbox.readClaudeSettings() == original)
        #expect(try claude.isInstalled() == false)
    }

    @Test("A settings file we created is removed again by uninstall")
    func uninstallRemovesAFileWeCreated() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }

        let claude = ClaudeHookInstaller(paths: sandbox.paths, home: sandbox.home)
        try claude.install()
        let plan = try claude.uninstall()

        #expect(plan.removesFile)
        #expect(sandbox.readClaudeSettings() == nil)
    }

    @Test("An empty settings file becomes a valid settings file")
    func emptyFileInstalls() throws {
        for source in ["", "{}"] {
            let sandbox = try Sandbox()
            defer { sandbox.destroy() }
            try sandbox.writeClaudeSettings(source)

            let claude = ClaudeHookInstaller(paths: sandbox.paths, home: sandbox.home)
            try claude.install()

            let text = try #require(sandbox.readClaudeSettings())
            #expect((try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil)
            #expect(try claude.isInstalled())

            try claude.uninstall()
            // The file existed before us, so it stays — as the empty object it was.
            #expect(sandbox.readClaudeSettings() == "{}")
        }
    }

    @Test("The user's file permissions are left as the user set them")
    func existingPermissionsAreNotChanged() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let url = try sandbox.writeClaudeSettings("{}", mode: 0o644)

        try ClaudeHookInstaller(paths: sandbox.paths, home: sandbox.home).install()
        #expect(mode(of: url) == 0o644)
    }

    @Test("Malformed JSON throws and leaves the file on disk untouched")
    func malformedFileIsNeverRewritten() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }

        let broken = "{\n  \"hooks\": {\n    \"Stop\": [\n"
        try sandbox.writeClaudeSettings(broken)

        let claude = ClaudeHookInstaller(paths: sandbox.paths, home: sandbox.home)
        #expect(throws: JSONSurgeon.Failure.self) { try claude.install() }
        #expect(sandbox.readClaudeSettings() == broken)
        #expect(sandbox.backups.isEmpty)
    }

    @Test("A failed validation restores the backup and reports the failure")
    func validationFailureRestoresTheBackup() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }

        let original = "{\n  \"model\": \"opus\"\n}\n"
        try sandbox.writeClaudeSettings(original)

        var installer = HookInstaller(
            paths: sandbox.paths,
            provider: .claudeCode,
            targetURL: ClaudeHookInstaller.settingsURL(home: sandbox.home),
            events: ClaudeHookInstaller.events
        )
        installer.validationProbe = { _ in throw ProbeFailure() }

        #expect(throws: ProbeFailure.self) { try installer.install() }
        #expect(sandbox.readClaudeSettings() == original)

        let backups = sandbox.backups
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect(mode(of: backup) == 0o600)
    }

    @Test("A backup is written before the file is changed")
    func backupPrecedesTheWrite() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }

        let original = "{\n  \"model\": \"opus\"\n}\n"
        try sandbox.writeClaudeSettings(original)

        let claude = ClaudeHookInstaller(paths: sandbox.paths, home: sandbox.home)
        try claude.install()

        let backup = try #require(sandbox.backups.first)
        #expect(backup.lastPathComponent.hasPrefix("claudeCode-settings.json."))
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
    }

    @Test("A dry run reports the exact resulting text without touching disk")
    func dryRunTouchesNothing() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }

        let original = "{\n  \"model\": \"opus\"\n}\n"
        try sandbox.writeClaudeSettings(original)

        let claude = ClaudeHookInstaller(paths: sandbox.paths, home: sandbox.home)
        let plan = try claude.planInstall()

        #expect(plan.originalText == original)
        #expect(plan.previewText.contains("\"hooks\""))
        #expect(sandbox.readClaudeSettings() == original)
        #expect(sandbox.backups.isEmpty)

        try claude.install()
        #expect(sandbox.readClaudeSettings() == plan.updatedText)
    }

    @Test("Ownership is decided by resolved path, not by substring")
    func ownershipIsPathBased() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }

        let installer = HookInstaller(
            paths: sandbox.paths,
            provider: .claudeCode,
            targetURL: ClaudeHookInstaller.settingsURL(home: sandbox.home),
            events: ["Stop"]
        )
        let ours = sandbox.paths.hookBinary.path

        #expect(installer.isOurEntry(installer.entryJSON()))
        #expect(installer.isOurEntry(#"{"hooks":[{"type":"command","command":"\#(ours)"}]}"#))
        // The same file reached through the /tmp symlink.
        #expect(installer.isOurEntry(#"{"hooks":[{"type":"command","command":"/private\#(ours)"}]}"#))
        #expect(!installer.isOurEntry(#"{"hooks":[{"type":"command","command":"\#(ours)-notify"}]}"#))
        #expect(!installer.isOurEntry(#"{"hooks":[{"type":"command","command":"echo codestatus-hook"}]}"#))
        #expect(!installer.isOurEntry(#"{"hooks":[{"type":"command","command":"codestatus-hook"}]}"#))
        #expect(!installer.isOurEntry(#"{"matcher":"*"}"#))
        #expect(!installer.isOurEntry("not json at all"))
    }

    @Test("Installing under Codex writes hooks.json 0600 and never mentions config.toml")
    func codexInstallsIntoHooksJSON() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }

        // A config.toml whose `notify` key is already claimed by another feature.
        let configTOML = sandbox.home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: configTOML.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let toml = "notify = [\"codex-computer-use\"]\n"
        try Data(toml.utf8).write(to: configTOML)

        let codex = CodexHookInstaller(paths: sandbox.paths, home: sandbox.home)
        try codex.install()

        #expect(mode(of: codex.hooksURL) == 0o600)
        let text = try #require(
            FileManager.default.contents(atPath: codex.hooksURL.path)
                .flatMap { String(data: $0, encoding: .utf8) }
        )
        let surgeon = try JSONSurgeon(text)
        for event in CodexHookInstaller.events {
            let elements = try #require(surgeon.arrayElements(atPath: ["hooks", event]))
            #expect(elements.count == 1)
            #expect(elements[0].contains("\"--provider\", \"codex\""))
            // Deliberately absent. Codex 0.138.0 prints "skipping async hook:
            // async hooks are not supported yet" and discards the whole entry,
            // so writing the flag makes the entire installation invisible —
            // /hooks reports no hooks installed at all. Its documentation says
            // otherwise; the shipped build is the authority.
            #expect(!elements[0].contains("async"))
        }
        #expect(!surgeon.contains(path: ["hooks", "Notification"]))

        // The TOML is untouched, byte for byte.
        #expect(try String(contentsOf: configTOML, encoding: .utf8) == toml)

        // Trust is the user's to grant; we only report that it is outstanding.
        #expect(try codex.trustRequirement() == .awaitingUserTrust(
            instructions: CodexHookInstaller.trustInstructions
        ))
        try codex.uninstall()
        #expect(try codex.trustRequirement() == .notInstalled)
    }

    @Test("An entry left by an older install at a different path is replaced, not duplicated")
    func staleEntriesAreUpgraded() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }

        let claude = ClaudeHookInstaller(paths: sandbox.paths, home: sandbox.home)
        try claude.install()
        let first = try #require(sandbox.readClaudeSettings())

        // Same binary, spelled with a redundant path component.
        let awkward = sandbox.paths.bin
            .appendingPathComponent("./codestatus-hook")
        let relocated = ClaudeHookInstaller(
            paths: sandbox.paths,
            home: sandbox.home,
            hookBinary: awkward
        )
        try relocated.install()

        let second = try #require(sandbox.readClaudeSettings())
        #expect(second == first)
        let surgeon = try JSONSurgeon(second)
        for event in ClaudeHookInstaller.events {
            #expect(surgeon.arrayElements(atPath: ["hooks", event])?.count == 1)
        }
    }
}
