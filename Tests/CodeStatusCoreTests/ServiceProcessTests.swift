import Testing
import Foundation
@testable import CodeStatusCore

/// A coding agent's binary is not always a coding *session*.
///
/// Found by looking at the HUD on a real machine: a permanent `Codex · Unknown`
/// row with no project name, which turned out to be
/// `codex -c features.code_mode_host=true app-server --analytics-default-enabled`
/// — the background service the ChatGPT VS Code extension starts with VS Code,
/// whether or not anyone opens Codex. A daemon is not something the user is
/// waiting on, so counting it as a session is the same category of error as
/// calling any `node` process an agent.
@Suite("Service processes are not sessions")
struct ServiceProcessTests {

    private static let vsCodeCodex =
        "/Users/x/.vscode/extensions/openai.chatgpt-26.818.41705-darwin-arm64/bin/macos-aarch64/codex"
    private static let codexApp = "/Applications/Codex.app/Contents/Resources/codex"

    @Test("Codex's service subcommands are recognised", arguments: [
        ["codex", "app-server"],
        ["codex", "-c", "features.code_mode_host=true", "app-server", "--analytics-default-enabled"],
        ["codex", "mcp-server"],
        ["codex", "exec-server"],
        ["codex", "remote-control"],
    ])
    func serviceSubcommandsDetected(arguments: [String]) {
        #expect(AgentIdentification.namesAServiceSubcommand(arguments))
    }

    @Test("An ordinary Codex invocation is not a service", arguments: [
        ["codex"],
        ["codex", "write me a test"],
        ["codex", "-c", "model=gpt-5.6", "refactor this"],
        ["codex", "exec", "do the thing"],
        ["codex", "resume", "--last"],
    ])
    func sessionsAreNotServices(arguments: [String]) {
        #expect(!AgentIdentification.namesAServiceSubcommand(arguments))
    }

    /// argv[0] is the binary's own path and is never a subcommand. A user whose
    /// codex binary sat in a directory called `app-server` would otherwise have
    /// every session silently dropped.
    @Test("argv[0] is never treated as a subcommand")
    func argvZeroIgnored() {
        #expect(!AgentIdentification.namesAServiceSubcommand(["/opt/app-server/codex"]))
        #expect(!AgentIdentification.namesAServiceSubcommand(["app-server"]))
    }

    @Test("The VS Code extension's codex is never a session")
    func vsCodeCodexIsAService() {
        // The extension has no per-session process: everything runs through the
        // one app-server. Excluded on the path alone, so no argv is read at all.
        #expect(AgentIdentification.identify(executablePath: Self.vsCodeCodex) == nil)
    }

    @Test("The Codex desktop CLI is still a session")
    func codexAppIsASession() {
        let identity = AgentIdentification.identify(executablePath: Self.codexApp)
        #expect(identity?.provider == .codex)
    }

    @Test("Claude Code in VS Code is still a session")
    func claudeInVSCodeIsASession() {
        // Deliberately asymmetric with Codex: the Claude extension spawns a real
        // per-session CLI process, so this one genuinely is a session.
        let path = "/Users/x/.vscode/extensions/anthropic.claude-code-2.1.240-darwin-arm64"
            + "/resources/native-binary/claude"
        let identity = AgentIdentification.identify(executablePath: path)
        #expect(identity?.provider == .claudeCode)
        #expect(identity?.hostApplication == .vsCode)
    }

    @Test("Argument inspection stays limited to paths that need it")
    func argumentInspectionIsNarrow() {
        // Reading argv means touching a buffer that also holds the environment,
        // so the set of paths we do it for is part of the privacy surface.
        #expect(AgentIdentification.needsArgumentInspection(executablePath: "/usr/bin/node"))
        #expect(AgentIdentification.needsArgumentInspection(executablePath: Self.codexApp))
        #expect(!AgentIdentification.needsArgumentInspection(executablePath: "/opt/homebrew/bin/claude"))
        #expect(!AgentIdentification.needsArgumentInspection(executablePath: "/bin/zsh"))
        #expect(!AgentIdentification.needsArgumentInspection(executablePath: nil))
    }

    @Test("No service process on this machine is offered as a session")
    func liveServicesAreExcluded() {
        // Runs against whatever is actually running right now, so it keeps
        // holding as these tools change shape.
        let inspector = ProcessInspector()
        for agent in inspector.discoverAgents() {
            guard let path = agent.snapshot.executablePath else { continue }
            #expect(
                !path.contains("openai.chatgpt-"),
                "the ChatGPT extension's app-server was reported as a session"
            )
            if AgentIdentification.isCodexExecutable(path) {
                #expect(
                    !inspector.runsAServiceSubcommand(pid: agent.pid),
                    "a Codex service subcommand was reported as a session"
                )
            }
        }
    }
}

@Suite("Session naming")
struct SessionNamingTests {

    private func session(cwd: String?, repo: String? = nil) -> AgentSession {
        var s = AgentSession(
            id: SessionID("codex:x"), provider: .codex,
            now: Date(timeIntervalSince1970: 0), sourceAdapter: "test"
        )
        s.cwd = cwd
        s.repositoryName = repo
        return s
    }

    @Test("A session at the filesystem root is not labelled '/'")
    func rootIsNotAName() {
        // What the phantom app-server row actually looked like in the HUD.
        #expect(session(cwd: "/").displayName == "Codex")
        #expect(session(cwd: "").displayName == "Codex")
        #expect(session(cwd: nil).displayName == "Codex")
    }

    @Test("A real project still shows its own name")
    func realNamesSurvive() {
        #expect(session(cwd: "/Users/x/Desktop/codestatus").displayName == "codestatus")
        #expect(session(cwd: "/tmp/whatever", repo: "my-repo").displayName == "my-repo")
    }
}
