import Testing
import Foundation
@testable import CodeStatusCore

/// Installation exercised against configurations taken from a real machine,
/// rather than fixtures shaped to suit the implementation.
///
/// The claim this project makes about config editing — that everything outside
/// the inserted entry survives byte for byte — is only worth anything if it
/// holds for files people actually have. Comparable tools round-trip through
/// `JSONSerialization` and rewrite key order and whitespace; these tests are
/// what stop us drifting into the same behaviour.
@Suite("Installation against real-world configurations")
struct RealWorldConfigTests {

    /// The verbatim shape of a `~/.claude/settings.json` on a working machine:
    /// user settings, no `hooks` key, two-space indentation.
    static let realClaudeSettings = """
    {
      "permissions": {
        "allow": [
          "Bash",
          "mcp__pencil"
        ]
      },
      "theme": "dark",
      "effortLevel": "xhigh",
      "model": "opus[1m]"
    }
    """

    /// The same file after the user has added hooks of their own — the case
    /// where a careless installer destroys someone's work.
    static let claudeSettingsWithUserHooks = """
    {
      "permissions": { "allow": ["Bash"] },
      "hooks": {
        "Stop": [
          {
            "matcher": "*",
            "hooks": [
              { "type": "command", "command": "/usr/local/bin/my-codestatus-logger.sh" }
            ]
          }
        ],
        "PreToolUse": [
          { "hooks": [{ "type": "command", "command": "~/bin/audit.sh", "timeout": 30 }] }
        ]
      },
      "theme": "dark"
    }
    """

    private struct Environment {
        let home: URL
        let paths: RuntimePaths
        /// `~/.claude/settings.json` inside the fake home.
        let target: URL
        let cleanup: () -> Void
    }

    private func makeEnvironment() throws -> Environment {
        let home = URL(fileURLWithPath: "/tmp/cs-cfg-\(getuid())-\(UInt32.random(in: 0..<0xFFFFFF))")
        let manager = FileManager.default
        try manager.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try manager.createDirectory(
            at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let paths = RuntimePaths(home: home)
        try paths.createDirectories()
        return Environment(
            home: home,
            paths: paths,
            target: ClaudeHookInstaller.settingsURL(home: home),
            cleanup: { try? manager.removeItem(at: home) }
        )
    }

    private func installer(_ environment: Environment) -> ClaudeHookInstaller {
        ClaudeHookInstaller(paths: environment.paths, home: environment.home)
    }

    @Test("Installing into a real settings.json leaves every other byte identical")
    func bytePreservation() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        try Self.realClaudeSettings.write(to: environment.target, atomically: true, encoding: .utf8)

        _ = try installer(environment).install()
        let after = try String(contentsOf: environment.target, encoding: .utf8)

        // Every original line survives verbatim, including indentation and the
        // author's key order.
        for line in Self.realClaudeSettings.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed != "{" && trimmed != "}" else { continue }
            #expect(after.contains(line), "lost original line: \(line)")
        }

        // Key order is preserved, which a JSONSerialization round-trip with
        // .sortedKeys would silently destroy.
        let permissionsIndex = try #require(after.range(of: "\"permissions\"")).lowerBound
        let themeIndex = try #require(after.range(of: "\"theme\"")).lowerBound
        let modelIndex = try #require(after.range(of: "\"model\"")).lowerBound
        #expect(permissionsIndex < themeIndex)
        #expect(themeIndex < modelIndex)

        // And the result is still valid JSON carrying the original values.
        let parsed = try JSONSerialization.jsonObject(
            with: Data(after.utf8)) as? [String: Any]
        #expect(parsed?["theme"] as? String == "dark")
        #expect(parsed?["model"] as? String == "opus[1m]")
        #expect((parsed?["hooks"] as? [String: Any])?.isEmpty == false)
    }

    @Test("A user's own hooks survive install and uninstall untouched")
    func userHooksSurvive() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        try Self.claudeSettingsWithUserHooks.write(
            to: environment.target, atomically: true, encoding: .utf8)

        let subject = installer(environment)
        _ = try subject.install()

        let installed = try String(contentsOf: environment.target, encoding: .utf8)
        #expect(installed.contains("/usr/local/bin/my-codestatus-logger.sh"))
        #expect(installed.contains("~/bin/audit.sh"))

        _ = try subject.uninstall()
        let removed = try String(contentsOf: environment.target, encoding: .utf8)

        // Both user hooks are still there after we have taken ours back out.
        #expect(removed.contains("/usr/local/bin/my-codestatus-logger.sh"))
        #expect(removed.contains("~/bin/audit.sh"))
        #expect(removed.contains("\"timeout\": 30"))
        #expect(!removed.contains("codestatus-hook"))
    }

    /// The specific trap agentbuddy falls into: it identifies its own entries by
    /// testing whether the command string *contains* its name, so a user hook
    /// that merely mentions it is deleted on uninstall.
    @Test("A user hook whose command merely mentions codestatus is never removed")
    func substringMatchingWouldHaveBeenWrong() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        try Self.claudeSettingsWithUserHooks.write(
            to: environment.target, atomically: true, encoding: .utf8)

        let subject = installer(environment)
        _ = try subject.install()
        _ = try subject.uninstall()

        let text = try String(contentsOf: environment.target, encoding: .utf8)
        #expect(text.contains("my-codestatus-logger.sh"))
    }

    @Test("Installing twice leaves exactly one entry per event")
    func installIsIdempotent() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        try Self.realClaudeSettings.write(to: environment.target, atomically: true, encoding: .utf8)

        let subject = installer(environment)
        _ = try subject.install()
        let once = try String(contentsOf: environment.target, encoding: .utf8)
        _ = try subject.install()
        let twice = try String(contentsOf: environment.target, encoding: .utf8)

        #expect(once == twice)

        let occurrences = twice.components(separatedBy: "codestatus-hook").count - 1
        #expect(occurrences == ClaudeHookInstaller.events.count)
    }

    @Test("Every installed hook is async, so it can never block the agent")
    func hooksAreAlwaysAsync() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        try Self.realClaudeSettings.write(to: environment.target, atomically: true, encoding: .utf8)

        _ = try installer(environment).install()
        let text = try String(contentsOf: environment.target, encoding: .utf8)

        // Every entry of ours carries async: true. This is the structural
        // guarantee behind "CodeStatus never interferes" — enforced by the
        // agent, not by us being careful.
        let entries = text.components(separatedBy: "codestatus-hook").count - 1
        let asyncFlags = text.components(separatedBy: "\"async\"").count - 1
        #expect(entries > 0)
        #expect(asyncFlags == entries)
    }

    @Test("Codex installation never writes to config.toml")
    func codexLeavesTomlAlone() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }

        // A config.toml carrying the `notify` key that Codex Computer Use uses
        // on a real machine. Comparable tools install themselves by overwriting
        // exactly this, which silently breaks that feature.
        let configTOML = environment.home.appendingPathComponent(".codex/config.toml")
        let original = """
        model = "gpt-5.6-sol"
        notify = ["/Users/x/.codex/computer-use/SkyComputerUseClient", "turn-ended"]

        [features]
        js_repl = false
        """
        try original.write(to: configTOML, atomically: true, encoding: .utf8)

        let hooksJSON = CodexHookInstaller.hooksURL(home: environment.home)
        _ = try CodexHookInstaller(paths: environment.paths, home: environment.home).install()

        // hooks.json created; config.toml byte-identical.
        #expect(FileManager.default.fileExists(atPath: hooksJSON.path))
        let afterTOML = try String(contentsOf: configTOML, encoding: .utf8)
        #expect(afterTOML == original)
        #expect(afterTOML.contains("SkyComputerUseClient"))
    }

    /// Regression: installing used to `rename(2)` a temp file over the link,
    /// replacing it with a regular file. The dotfiles repo silently stopped
    /// controlling the settings, the next `stow` no longer reached Claude Code,
    /// and `git status` in the repo showed nothing at all.
    @Test("A settings.json symlinked from a dotfiles repo keeps its link")
    func symlinkedSettingsSurvive() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let manager = FileManager.default

        // The layout stow, chezmoi, and yadm all produce.
        let dotfiles = environment.home.appendingPathComponent("dotfiles/claude")
        try manager.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let realFile = dotfiles.appendingPathComponent("settings.json")
        try Self.realClaudeSettings.write(to: realFile, atomically: true, encoding: .utf8)

        try? manager.removeItem(at: environment.target)
        try manager.createSymbolicLink(at: environment.target, withDestinationURL: realFile)

        _ = try installer(environment).install()

        // The link is still a link.
        let attributes = try manager.attributesOfItem(atPath: environment.target.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)

        // And the edit landed in the repo, where the user can commit it.
        let inRepo = try String(contentsOf: realFile, encoding: .utf8)
        #expect(inRepo.contains("codestatus-hook"))
        #expect(inRepo.contains("\"model\": \"opus[1m]\""))
    }

    /// Regression: the mode was read with `attributesOfItem`, which does not
    /// follow symlinks, so the replacement inherited the *link's* 0755 instead
    /// of the target's 0600 — widening a file that routinely holds an `env`
    /// block with an API key in it.
    @Test("Installing never widens the permissions of a settings file")
    func permissionsAreNeverWidened() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let manager = FileManager.default

        let dotfiles = environment.home.appendingPathComponent("dotfiles/claude")
        try manager.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let realFile = dotfiles.appendingPathComponent("settings.json")
        let withSecret = """
        {
          "env": { "ANTHROPIC_API_KEY": "sk-ant-notarealkey" },
          "theme": "dark"
        }
        """
        try withSecret.write(to: realFile, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: realFile.path)

        try? manager.removeItem(at: environment.target)
        try manager.createSymbolicLink(at: environment.target, withDestinationURL: realFile)

        _ = try installer(environment).install()

        var info = stat()
        #expect(stat(realFile.path, &info) == 0)
        let mode = Int(info.st_mode & 0o777)
        #expect(mode == 0o600, "mode widened to \(String(mode, radix: 8))")
        // Specifically: not readable by anyone else on the machine.
        #expect(mode & 0o077 == 0)
    }

    /// Regression: `node(atPath:)` took the *first* match for a key. JSON allows
    /// duplicates and every real parser keeps the last, so our hooks were
    /// written into the object the agent throws away — while `isInstalled()`
    /// reported success.
    @Test("With a duplicated hooks key, we edit the one the agent will use")
    func duplicateKeysResolveLikeARealParser() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }

        let duplicated = """
        {
          "hooks": { "Stop": [] },
          "theme": "dark",
          "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "/bin/true" }] }] }
        }
        """
        try duplicated.write(to: environment.target, atomically: true, encoding: .utf8)

        _ = try installer(environment).install()
        let text = try String(contentsOf: environment.target, encoding: .utf8)

        // Asserted on the text rather than by round-tripping through
        // JSONSerialization, because Apple's parser is the odd one out here: it
        // keeps the *first* duplicate key, while JavaScript's JSON.parse (which
        // is what Claude Code's Node binary uses) and serde_json (Codex) both
        // keep the last. Validating with the Apple parser would assert the
        // opposite of what the agents actually do.
        let firstHooks = try #require(text.range(of: "\"hooks\""))
        let secondHooks = try #require(
            text.range(of: "\"hooks\"", range: firstHooks.upperBound..<text.endIndex)
        )
        let ourEntry = try #require(text.range(of: "codestatus-hook"))
        #expect(ourEntry.lowerBound > secondHooks.lowerBound,
                "our hook landed in the object the agent discards")

        // The user's own entry in that same object is untouched.
        #expect(text.contains("/bin/true"))
        let userEntry = try #require(text.range(of: "/bin/true"))
        #expect(userEntry.lowerBound > secondHooks.lowerBound)
    }

    /// Regression: uninstall removes a per-event key it created once that key is
    /// empty. `isEmptyContainer` resolved the duplicate the way the agent does —
    /// to the last `Stop` — while `removeKey` deleted the *first*, so the answer
    /// was about our empty array and the deletion was of the user's full one.
    /// Their hook was gone from the file entirely, and validation passed,
    /// because by then there really were zero CodeStatus entries left.
    @Test("Uninstall never deletes a user's hooks hiding behind a duplicated event key")
    func duplicatedEventKeyIsNotDeletedOnUninstall() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let subject = installer(environment)

        // A hooks object with no Stop, so the receipt records the Stop key as
        // ours — the precondition for uninstall removing it again.
        try #"{"hooks": {}}"#.write(to: environment.target, atomically: true, encoding: .utf8)
        _ = try subject.install()
        let receipt = try #require(
            subject.installer.receiptStore.receipt(for: subject.installer.targetPath))
        #expect(receipt.createdEventKeys.contains("Stop"))

        // The user then adds a Stop block of their own — by hand, or through a
        // config merge. JSON permits the duplicate key and every agent parser
        // reads the last occurrence, so nothing about the file looks broken.
        let installed = try String(contentsOf: environment.target, encoding: .utf8)
        let userBlock = #""Stop": [{"hooks": [{"type": "command", "command": "/usr/local/bin/team-audit.sh"}]}], "#
        let withDuplicate = installed.replacingOccurrences(
            of: #""hooks": {"#, with: #""hooks": {"# + userBlock)
        #expect(withDuplicate.contains("team-audit.sh"))
        try withDuplicate.write(to: environment.target, atomically: true, encoding: .utf8)

        _ = try subject.uninstall()
        let after = try String(contentsOf: environment.target, encoding: .utf8)

        #expect(after.contains("/usr/local/bin/team-audit.sh"), "we deleted the user's hook")
        #expect(!after.contains("codestatus-hook"))
        #expect((try? JSONSerialization.jsonObject(with: Data(after.utf8))) != nil)
    }

    /// Regression: `apply` learned to follow the symlink, but `restore` still
    /// wrote to the link's own path. So on the one path where nothing should
    /// change at all, a failed install left our half-installed text sitting in
    /// the dotfiles repo and `rename(2)`d the original over the link, replacing
    /// it with a regular file. The same restore runs without any test seam
    /// whenever the write itself fails — a read-only dotfiles checkout is enough.
    @Test("A failed install restores the real file and leaves the symlink a symlink")
    func failedInstallRestoresThroughTheSymlink() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let manager = FileManager.default

        let dotfiles = environment.home.appendingPathComponent("dotfiles/claude")
        try manager.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let realFile = dotfiles.appendingPathComponent("settings.json")
        try Self.realClaudeSettings.write(to: realFile, atomically: true, encoding: .utf8)

        try? manager.removeItem(at: environment.target)
        try manager.createSymbolicLink(at: environment.target, withDestinationURL: realFile)

        var subject = HookInstaller(
            paths: environment.paths,
            provider: .claudeCode,
            targetURL: environment.target,
            events: ClaudeHookInstaller.events
        )
        subject.validationProbe = { _ in
            throw HookInstaller.Failure.validationFailed(path: "probe", reason: "probe")
        }
        #expect(throws: (any Error).self) { _ = try subject.install() }

        // The link is still a link.
        let attributes = try manager.attributesOfItem(atPath: environment.target.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)

        // And the file it points at is byte-for-byte what it was, with none of
        // our half-installed text left in the repo for the user to commit.
        let inRepo = try String(contentsOf: realFile, encoding: .utf8)
        #expect(inRepo == Self.realClaudeSettings)
        #expect(!inRepo.contains("codestatus-hook"))
    }

    /// Regression: the leaf link's destination was joined onto the link's path
    /// and standardized, which collapses `..` lexically. The kernel resolves it
    /// from the directory the link really lives in, so the two disagree as soon
    /// as `~/.claude` is itself a link — an ordinary dotfiles layout. We then
    /// read the user's real settings and wrote them, plus our hooks, over
    /// whatever unrelated file happened to sit at the lexical path, while the
    /// settings the agent actually reads were never touched.
    @Test("A relative link under a symlinked .claude edits the file the agent reads")
    func relativeLinkUnderASymlinkedDirectory() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let manager = FileManager.default

        // ~/.claude -> dotfiles/claude, and the settings.json in that repo is
        // itself a relative link to a file shared with the user's other tools.
        try manager.createDirectory(
            at: environment.home.appendingPathComponent("dotfiles/claude"),
            withIntermediateDirectories: true)
        try manager.createDirectory(
            at: environment.home.appendingPathComponent("dotfiles/shared"),
            withIntermediateDirectories: true)
        let shared = environment.home.appendingPathComponent("dotfiles/shared/settings.json")
        try Self.realClaudeSettings.write(to: shared, atomically: true, encoding: .utf8)

        try manager.removeItem(at: environment.home.appendingPathComponent(".claude"))
        try manager.createSymbolicLink(
            atPath: environment.home.appendingPathComponent(".claude").path,
            withDestinationPath: "dotfiles/claude")
        try manager.createSymbolicLink(
            atPath: environment.home.appendingPathComponent("dotfiles/claude/settings.json").path,
            withDestinationPath: "../shared/settings.json")

        // An unrelated file sitting exactly where lexical `..` collapsing lands.
        try manager.createDirectory(
            at: environment.home.appendingPathComponent("shared"),
            withIntermediateDirectories: true)
        let bystander = environment.home.appendingPathComponent("shared/settings.json")
        let bystanderText = "{\n  \"something\": \"else entirely\"\n}"
        try bystanderText.write(to: bystander, atomically: true, encoding: .utf8)

        _ = try installer(environment).install()

        // The edit landed in the file the agent opens.
        let inRepo = try String(contentsOf: shared, encoding: .utf8)
        #expect(inRepo.contains("codestatus-hook"))
        #expect(inRepo.contains("\"model\": \"opus[1m]\""))

        // The unrelated file was never opened, let alone rewritten.
        #expect(try String(contentsOf: bystander, encoding: .utf8) == bystanderText)

        // And both links are still links.
        for path in [environment.target.path,
                     environment.home.appendingPathComponent(".claude").path] {
            var info = stat()
            #expect(lstat(path, &info) == 0)
            #expect((info.st_mode & S_IFMT) == S_IFLNK, "\(path) is no longer a symlink")
        }
    }

    @Test("A malformed settings file is refused, not rewritten")
    func malformedIsRefused() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let broken = "{ \"theme\": \"dark\", oops }"
        try broken.write(to: environment.target, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            _ = try installer(environment).install()
        }

        // The user's file is exactly as they left it, broken or not. Guessing at
        // a repair would risk destroying settings we cannot parse.
        let after = try String(contentsOf: environment.target, encoding: .utf8)
        #expect(after == broken)
    }
}

/// The three ways an install could have destroyed a settings file outright,
/// each found by probing rather than by reading the code.
///
/// They share a shape: something makes the installer believe the file is not
/// there, or is other than it is, and the recovery machinery then does exactly
/// the wrong thing with total confidence.
@Suite("Installation cannot destroy a file it misread")
struct DestructiveInstallTests {

    private func makeHome() throws -> (home: URL, paths: RuntimePaths, target: URL, cleanup: () -> Void) {
        let home = URL(fileURLWithPath: "/tmp/cs-dst-\(getuid())-\(UInt32.random(in: 0..<0xFFFFFF))")
        let manager = FileManager.default
        try manager.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let paths = RuntimePaths(home: home)
        try paths.createDirectories()
        let target = ClaudeHookInstaller.settingsURL(home: home)
        return (home, paths, target, {
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try? manager.removeItem(at: home)
        })
    }

    private static let precious = """
    {
      "env": { "ANTHROPIC_API_KEY": "sk-ant-the-users-key" },
      "permissions": { "allow": ["Bash"] },
      "theme": "dark"
    }
    """

    /// `FileManager.contents(atPath:)` answers nil for a file it cannot read
    /// exactly as it does for one that is not there. That nil decides three
    /// destructive things at once — no backup, `createdFile` on the receipt, and
    /// a restore that *deletes* — so reading a permission error as "absent" lost
    /// the user's settings with no way back.
    @Test("An unreadable settings file is refused, not treated as absent")
    func unreadableIsNotAbsent() throws {
        let environment = try makeHome()
        defer { environment.cleanup() }
        try Data(Self.precious.utf8).write(to: environment.target)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: environment.target.path)

        // Running as root would make this unreadable file readable and the test
        // meaningless, so skip rather than pass vacuously.
        try #require(FileManager.default.contents(atPath: environment.target.path) == nil)

        let installer = ClaudeHookInstaller(paths: environment.paths, home: environment.home)
        #expect(throws: (any Error).self) { _ = try installer.install() }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: environment.target.path)
        let after = try String(contentsOf: environment.target, encoding: .utf8)
        #expect(after == Self.precious, "the file we could not read was overwritten")
    }

    /// `apply` takes a plan, and `updatedText` is the whole file rather than a
    /// patch. Onboarding shows that plan as a diff and waits for a human, while
    /// the agent rewrites the same file whenever the user changes a setting — so
    /// the window is real, and writing through it would delete the intervening
    /// change *and* back up the stale text instead of the lost one.
    @Test("A plan is refused once the file has moved under it")
    func staleplanIsRefused() throws {
        let environment = try makeHome()
        defer { environment.cleanup() }
        try Data(Self.precious.utf8).write(to: environment.target)

        let installer = ClaudeHookInstaller(paths: environment.paths, home: environment.home)
        let plan = try installer.planInstall()

        // The user changes a setting while the confirmation sheet is open.
        let edited = Self.precious.replacingOccurrences(of: "\"dark\"", with: "\"light\"")
        try Data(edited.utf8).write(to: environment.target)

        #expect(throws: (any Error).self) { _ = try installer.installer.apply(plan) }

        let after = try String(contentsOf: environment.target, encoding: .utf8)
        #expect(after == edited, "an edit made after planning was silently discarded")
    }

    /// The failure path is supposed to change nothing. Sampling the mode from
    /// inside `restore` asks about a file that has just been deleted: `stat`
    /// fails, the 0600 fallback applies, and a 0644 file the user chose comes
    /// back narrowed by an operation that was meant to be a no-op.
    @Test("A failed install restores the file with its original permissions")
    func restoreKeepsPermissions() throws {
        let environment = try makeHome()
        defer { environment.cleanup() }
        try Data(Self.precious.utf8).write(to: environment.target)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: environment.target.path)

        var installer = HookInstaller(
            paths: environment.paths,
            provider: .claudeCode,
            targetURL: environment.target,
            events: ClaudeHookInstaller.events
        )
        struct Forced: Error {}
        installer.validationProbe = { _ in throw Forced() }

        #expect(throws: (any Error).self) { _ = try installer.install() }

        let after = try String(contentsOf: environment.target, encoding: .utf8)
        #expect(after == Self.precious, "restore did not put the original bytes back")

        var info = stat()
        #expect(stat(environment.target.path, &info) == 0)
        #expect(Int(info.st_mode & 0o777) == 0o644,
                "restore changed permissions on a path that was supposed to be untouched")
    }

    /// The same misreading, reached through `ELOOP` rather than `EACCES`. A
    /// mutually-referencing pair of links is unreadable, so the installer took
    /// the path for empty ground and `rename(2)`d a regular file over the first
    /// link — quietly destroying a link the user could still repair by fixing
    /// the other end.
    @Test("A looping symlink is refused rather than replaced with a regular file")
    func symlinkLoopIsRefused() throws {
        let environment = try makeHome()
        defer { environment.cleanup() }
        let manager = FileManager.default
        let other = environment.home.appendingPathComponent(".claude/other.json")
        try manager.createSymbolicLink(
            atPath: environment.target.path, withDestinationPath: "other.json")
        try manager.createSymbolicLink(
            atPath: other.path, withDestinationPath: "settings.json")

        let installer = ClaudeHookInstaller(paths: environment.paths, home: environment.home)
        #expect(throws: (any Error).self) { _ = try installer.install() }

        var info = stat()
        #expect(lstat(environment.target.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFLNK,
                "the link was replaced by a regular file")
    }

    /// The mode has to be sampled before anything on disk moves, not from inside
    /// `restore`. This is the shape where it matters: uninstall *removes* the
    /// file, so by the time `restore` asked, `stat` had nothing to answer about
    /// and the 0600 fallback applied — a failure that changed nothing otherwise
    /// still narrowed a file the user had deliberately made group-readable.
    @Test("A failed uninstall puts the file back with the permissions it had")
    func failedUninstallKeepsPermissions() throws {
        let environment = try makeHome()
        defer { environment.cleanup() }

        // A file we created, so uninstall is entitled to remove it — the only
        // path on which `restore` is asked to recreate a file from nothing.
        let claude = ClaudeHookInstaller(paths: environment.paths, home: environment.home)
        try claude.install()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: environment.target.path)
        let before = try String(contentsOf: environment.target, encoding: .utf8)

        var installer = HookInstaller(
            paths: environment.paths,
            provider: .claudeCode,
            targetURL: environment.target,
            events: ClaudeHookInstaller.events
        )
        struct Forced: Error {}
        installer.validationProbe = { _ in throw Forced() }
        #expect(throws: (any Error).self) { _ = try installer.uninstall() }

        #expect(FileManager.default.fileExists(atPath: environment.target.path),
                "a failed uninstall left the file deleted")
        #expect(try String(contentsOf: environment.target, encoding: .utf8) == before)
        var info = stat()
        #expect(stat(environment.target.path, &info) == 0)
        #expect(Int(info.st_mode & 0o777) == 0o644,
                "restore recreated the file with the 0600 fallback instead of its own mode")
    }
}

/// `isInstalled()` is the only question the rest of the app asks about the
/// config, and it has to mean what it says.
@Suite("isInstalled agrees with what the agent will actually run")
struct InstalledStateTests {

    private func makeHome() throws -> (paths: RuntimePaths, target: URL, cleanup: () -> Void) {
        let home = URL(fileURLWithPath: "/tmp/cs-ist-\(getuid())-\(UInt32.random(in: 0..<0xFFFFFF))")
        let manager = FileManager.default
        try manager.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let paths = RuntimePaths(home: home)
        try paths.createDirectories()
        return (paths, ClaudeHookInstaller.settingsURL(home: home), {
            try? manager.removeItem(at: home)
        })
    }

    /// Our binary lives at a fixed path across upgrades, so an entry written by
    /// an older build still resolves to it. Testing only "some entry here points
    /// at our binary" therefore reports such a file as healthy and the entry is
    /// never refreshed. `"async": false` is the case that matters: it puts our
    /// hook on the agent's critical path on every single tool call — the one
    /// thing this installer promises never to do — while the app shows a green
    /// tick and never offers to fix it.
    @Test("A blocking entry left by an older build does not read as installed")
    func staleBlockingEntryIsNotInstalled() throws {
        let environment = try makeHome()
        defer { environment.cleanup() }
        let paths = environment.paths

        // Exactly what an older build would have left: same command path, same
        // shape, but synchronous and with its own timeout.
        let stale = "{\"hooks\":{"
            + ClaudeHookInstaller.events.map { event in
                "\"\(event)\":[{\"hooks\":[{\"type\":\"command\",\"command\":"
                    + JSONSurgeon.quoted(paths.hookBinary.path)
                    + ",\"args\":[\"--provider\",\"claude-code\"]"
                    + ",\"timeout\":30,\"async\":false}]}]"
            }.joined(separator: ",")
            + "}}"
        try Data(stale.utf8).write(to: environment.target)

        let claude = ClaudeHookInstaller(
            paths: paths, home: environment.target.deletingLastPathComponent()
                .deletingLastPathComponent())
        #expect(try claude.isInstalled() == false,
                "a synchronous hook on the agent's critical path read as installed")

        // And the cure is the ordinary install, which replaces it in place.
        try claude.install()
        #expect(try claude.isInstalled())
        let after = try String(contentsOf: environment.target, encoding: .utf8)
        #expect(!after.contains("\"async\": false") && !after.contains("\"async\":false"))
    }

    /// Two copies of our entry fire the hook twice for every event. `validate`
    /// already refuses to accept that as the result of an install; asking the
    /// same question later must not get a different answer.
    @Test("Our entry present twice does not read as installed")
    func duplicateOfOursIsNotInstalled() throws {
        let environment = try makeHome()
        defer { environment.cleanup() }
        let home = environment.target.deletingLastPathComponent().deletingLastPathComponent()
        let claude = ClaudeHookInstaller(paths: environment.paths, home: home)
        try claude.install()
        #expect(try claude.isInstalled())

        var surgeon = try JSONSurgeon(try String(contentsOf: environment.target, encoding: .utf8))
        try surgeon.appendToArray(
            atPath: ["hooks", "Stop"], element: claude.installer.entryJSON())
        try Data(surgeon.text.utf8).write(to: environment.target)

        #expect(try claude.isInstalled() == false, "a doubled entry read as installed")

        try claude.install()
        #expect(try claude.isInstalled())
        let elements = try #require(
            JSONSurgeon(try String(contentsOf: environment.target, encoding: .utf8))
                .arrayElements(atPath: ["hooks", "Stop"]))
        #expect(elements.filter(claude.installer.isOurEntry).count == 1)
    }
}
