import Foundation

/// What we found on this Mac that says an agent is installed.
///
/// Several independent signals rather than one, because each of them is
/// individually wrong often enough to have stranded a real user. A hardcoded
/// list of binary directories misses `~/.local/bin`, which is where the official
/// Codex installer puts it. A `PATH` probe misses the desktop app, which ships
/// its binary inside the bundle and never goes on `PATH`. Neither sees an agent
/// installed under a version manager whose shim directory nobody thought to
/// list. And all three miss nothing at all when the user simply has the agent
/// running in front of them.
///
/// So none of these is a gate. Any one of them is enough, and their absence is
/// reported as "we did not find it" rather than as "you do not have it" — the
/// distinction the previous detection could not make, and the reason someone
/// with a working Codex was told there was nothing to connect.
public struct AgentEvidence: Sendable, Equatable {

    /// The agent's own configuration directory, e.g. `~/.codex`.
    ///
    /// The strongest signal we have, and the cheapest. An agent that has ever
    /// run has one; it does not move when the binary moves; and it survives the
    /// user switching install methods, which is exactly when every path-based
    /// check breaks at once.
    public var configDirectory: String?

    /// A runnable binary we located.
    public var executable: String?

    /// A path named for this agent that exists but cannot be executed.
    ///
    /// Almost always a dangling Homebrew symlink left behind by an install that
    /// moved elsewhere. Useless as a target and excellent as evidence: nobody
    /// has `/opt/homebrew/bin/codex` by accident.
    public var unusableExecutable: String?

    /// A VS Code-family extension directory, carrying its version in the name.
    public var editorExtension: String?

    /// The agent is running on this Mac right now.
    public var isRunning: Bool = false

    public init(
        configDirectory: String? = nil,
        executable: String? = nil,
        unusableExecutable: String? = nil,
        editorExtension: String? = nil,
        isRunning: Bool = false
    ) {
        self.configDirectory = configDirectory
        self.executable = executable
        self.unusableExecutable = unusableExecutable
        self.editorExtension = editorExtension
        self.isRunning = isRunning
    }

    /// Whether anything at all points at this agent being installed.
    public var isPresent: Bool {
        configDirectory != nil
            || executable != nil
            || unusableExecutable != nil
            || editorExtension != nil
            || isRunning
    }

    /// One line for the setup screen, naming the evidence rather than asserting
    /// a conclusion, so a wrong guess is visibly a guess.
    public var summary: String {
        if isRunning { return "Running right now" }
        if executable != nil, editorExtension != nil {
            return "Command line and editor extension — one setup covers both"
        }
        if editorExtension != nil { return "Editor extension" }
        if executable != nil { return "Command line" }
        if let configDirectory { return "Configured in \(abbreviate(configDirectory))" }
        if unusableExecutable != nil { return "Installed, but its command line link is broken" }
        return "Not found on this Mac"
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// The places outside the user's home directory that detection looks in.
///
/// Injectable for one reason that turned out to matter: with these baked in, a
/// test laying out a fake home still found the real `/opt/homebrew/bin/codex`
/// on the machine running it, so every "we do not find it here" assertion
/// passed for the wrong reason and could never have caught a regression.
public struct SystemLocations: Sendable, Equatable {
    public var binaryDirectories: [String]
    /// Absolute paths inside a desktop app bundle, which never go on `PATH`.
    public var bundledExecutables: [AgentProvider: [String]]

    public init(
        binaryDirectories: [String],
        bundledExecutables: [AgentProvider: [String]]
    ) {
        self.binaryDirectories = binaryDirectories
        self.bundledExecutables = bundledExecutables
    }

    public static let macOS = SystemLocations(
        binaryDirectories: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/opt/local/bin",
            "/run/current-system/sw/bin",
            "/nix/var/nix/profiles/default/bin",
        ],
        bundledExecutables: [
            .codex: ["/Applications/Codex.app/Contents/Resources/codex"],
        ]
    )

    /// Nothing outside the home directory. For tests.
    public static let homeOnly = SystemLocations(binaryDirectories: [], bundledExecutables: [:])
}

/// Finds the agents installed on this Mac, without ever making its answer a
/// precondition for offering to connect them.
public struct AgentDiscovery: Sendable {

    public let home: URL
    public let systemLocations: SystemLocations

    public init(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        systemLocations: SystemLocations = .macOS
    ) {
        self.home = home
        self.systemLocations = systemLocations
    }

    // MARK: - Per-provider facts

    private struct Spec {
        /// Directories under the home directory the agent creates for itself.
        var configDirectories: [String] = []
        /// Files under the home directory that mean the same thing.
        var configFiles: [String] = []
        var executableNames: [String] = []
        /// Matched against a directory *name* in an editor's extensions folder.
        var extensionPrefixes: [String] = []
    }

    private static func spec(for provider: AgentProvider) -> Spec {
        switch provider {
        case .claudeCode:
            return Spec(
                configDirectories: [".claude"],
                // Claude Code keeps its project registry here, next to — not
                // inside — the directory it also creates.
                configFiles: [".claude.json"],
                executableNames: ["claude"],
                extensionPrefixes: ["anthropic.claude-code"]
            )
        case .codex:
            return Spec(
                configDirectories: [".codex"],
                configFiles: [],
                executableNames: ["codex"],
                // The ChatGPT extension is what ships Codex inside VS Code; the
                // second prefix is there for a rename we do not control.
                extensionPrefixes: ["openai.chatgpt", "openai.codex"]
            )
        case .generic:
            return Spec()
        }
    }

    /// Providers CodeStatus knows how to connect, in the order they are shown.
    public static let supportedProviders: [AgentProvider] = [.claudeCode, .codex]

    // MARK: - Survey

    /// Everything we can learn about every supported agent.
    ///
    /// Async because two of the signals cost real time — spawning a login shell
    /// to read the user's `PATH`, and walking the process table — and a setup
    /// screen that blocks for a second while it decides whether you own an
    /// agent is its own kind of broken. The synchronous parts answer first; see
    /// ``evidence(for:extraDirectories:runningProviders:fileManager:)``.
    public func survey(
        fileManager: FileManager = .default
    ) async -> [AgentProvider: AgentEvidence] {
        async let shellDirectories = Self.loginShellPathDirectories()
        async let running = Self.runningProviders()

        let extra = await shellDirectories
        let live = await running

        var result: [AgentProvider: AgentEvidence] = [:]
        for provider in Self.supportedProviders {
            result[provider] = evidence(
                for: provider,
                extraDirectories: extra,
                runningProviders: live,
                fileManager: fileManager
            )
        }
        return result
    }

    /// The part of the survey that touches nothing but the filesystem.
    public func evidence(
        for provider: AgentProvider,
        extraDirectories: [String] = [],
        runningProviders: Set<AgentProvider> = [],
        fileManager: FileManager = .default
    ) -> AgentEvidence {
        let spec = Self.spec(for: provider)
        var evidence = AgentEvidence()

        evidence.configDirectory = spec.configDirectories
            .map { home.appendingPathComponent($0).path }
            .first { isDirectory($0, fileManager: fileManager) }
            ?? spec.configFiles
                .map { home.appendingPathComponent($0).path }
                .first { fileManager.fileExists(atPath: $0) }

        let (executable, unusable) = findExecutable(
            spec: spec,
            provider: provider,
            extraDirectories: extraDirectories,
            fileManager: fileManager
        )
        evidence.executable = executable
        evidence.unusableExecutable = executable == nil ? unusable : nil

        evidence.editorExtension = findEditorExtension(
            prefixes: spec.extensionPrefixes, fileManager: fileManager
        )
        evidence.isRunning = runningProviders.contains(provider)
        return evidence
    }

    // MARK: - Binaries

    /// Directories an agent's command line plausibly lives in.
    ///
    /// Long on purpose. Every entry past the first two is a real install layout
    /// somebody uses — the official Codex installer writes `~/.local/bin`, npm
    /// with a user prefix writes `~/.npm-global/bin`, and version managers put
    /// a shim in a directory named after themselves. Missing one costs a user
    /// their whole setup; listing one that does not exist costs a `stat`.
    private var searchDirectories: [String] {
        var directories = systemLocations.binaryDirectories
        let relative = [
            ".local/bin",
            "bin",
            ".bun/bin",
            ".deno/bin",
            ".cargo/bin",
            ".volta/bin",
            ".npm-global/bin",
            ".npm-packages/bin",
            ".yarn/bin",
            ".config/yarn/global/node_modules/.bin",
            ".asdf/shims",
            ".local/share/mise/shims",
            ".local/share/fnm/aliases/default/bin",
            "Library/pnpm",
            ".nix-profile/bin",
            ".codex/bin",
            ".claude/local",
        ]
        directories.append(contentsOf: relative.map { home.appendingPathComponent($0).path })
        directories.append(contentsOf: nodeVersionManagerDirectories())
        return directories
    }

    /// `~/.nvm/versions/node/*/bin`, which is a glob rather than a path.
    private func nodeVersionManagerDirectories(
        fileManager: FileManager = .default
    ) -> [String] {
        let root = home.appendingPathComponent(".nvm/versions/node")
        guard let versions = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        // Newest first, so a user with six Node versions installed gets the one
        // they most likely use without us reading every one of them.
        return versions.sorted().reversed().map {
            root.appendingPathComponent($0).appendingPathComponent("bin").path
        }
    }

    /// The first runnable binary, plus the first unrunnable one we passed on the
    /// way — which is the whole point of returning two values.
    private func findExecutable(
        spec: Spec,
        provider: AgentProvider,
        extraDirectories: [String],
        fileManager: FileManager
    ) -> (executable: String?, unusable: String?) {
        var unusable: String?

        for path in systemLocations.bundledExecutables[provider] ?? [] {
            if fileManager.isExecutableFile(atPath: path) { return (path, nil) }
            if unusable == nil, exists(path) { unusable = path }
        }

        // `extraDirectories` first: the user's own `PATH` is the definition of
        // which binary they actually run, and our list is only a guess at it.
        var seen = Set<String>()
        for directory in extraDirectories + searchDirectories {
            guard seen.insert(directory).inserted else { continue }
            for name in spec.executableNames {
                let path = (directory as NSString).appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: path) { return (path, nil) }
                // `exists`, not `fileExists`: a dangling symlink is exactly the
                // case this branch is here for, and `fileExists` follows links
                // and so reports the very thing we want to notice as absent.
                if unusable == nil, exists(path) { unusable = path }
            }
        }
        return (nil, unusable)
    }

    /// Whether anything is at this path, link or not.
    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private func isDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    // MARK: - Editors

    /// Every VS Code-family extensions directory we know of.
    ///
    /// The forks matter: Cursor and Windsurf install the same extension into
    /// their own folder, and a user whose only Claude Code is the Cursor
    /// extension has a `~/.claude` we would find anyway — but reporting *why*
    /// we think they have it is what makes the screen trustworthy.
    private var extensionDirectories: [String] {
        [
            ".vscode/extensions",
            ".vscode-insiders/extensions",
            ".vscode-server/extensions",
            ".cursor/extensions",
            ".windsurf/extensions",
        ].map { home.appendingPathComponent($0).path }
    }

    private func findEditorExtension(
        prefixes: [String],
        fileManager: FileManager
    ) -> String? {
        for directory in extensionDirectories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else {
                continue
            }
            // Directory names carry the version:
            // `anthropic.claude-code-2.1.240-darwin-arm64`. Sorted so the answer
            // is the newest rather than whichever the filesystem listed first.
            let match = entries
                .filter { entry in prefixes.contains { entry.hasPrefix($0) } }
                .sorted()
                .last
            if let match { return match }
        }
        return nil
    }

    // MARK: - The user's own PATH

    /// The directories on the `PATH` a login shell would give the user.
    ///
    /// Our own `PATH` is useless here: a bundled app is launched by `launchd`
    /// with a minimal environment that has never seen the user's dotfiles. So we
    /// ask their shell, which is the only authority on where `codex` resolves
    /// for them — and covers install layouts no list can anticipate, like nix
    /// profiles or a hand-rolled prefix.
    ///
    /// Login rather than interactive: `-l` sources the profile files where
    /// `PATH` is set, while `-i` can block forever on a prompt or a version
    /// manager that expects a terminal. The timeout is a backstop for the shells
    /// that manage it anyway.
    static func loginShellPathDirectories(timeout: TimeInterval = 2.0) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: readLoginShellPath(timeout: timeout))
            }
        }
    }

    private static func readLoginShellPath(timeout: TimeInterval) -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }

        // Read to EOF here rather than waiting on exit first: a shell that wrote
        // more than the pipe buffer holds would block in `write` while we
        // blocked in `waitUntilExit`, and neither would ever move.
        //
        // The timeout is a signal rather than `Process.terminate()`, so nothing
        // non-`Sendable` crosses into the work item. Killing the shell closes
        // the write end, which is what unblocks the read below — the timeout
        // needs no second thread of its own to observe.
        let pid = process.processIdentifier
        let watchdog = DispatchWorkItem { kill(pid, SIGTERM) }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + timeout, execute: watchdog
        )
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        // A shell we had to kill may still have written a partial `PATH`, and a
        // truncated directory name is a directory that does not exist — which
        // the caller's `stat` rejects anyway. Nothing here needs to be trusted.
        return String(decoding: output, as: UTF8.self)
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
    }

    // MARK: - Live processes

    /// Which agents are running right now.
    ///
    /// The one signal that cannot be fooled by an unusual install layout,
    /// because it reads what is actually executing. Off the main actor: it walks
    /// the process table.
    static func runningProviders() async -> Set<AgentProvider> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let providers = Set(ProcessInspector().discoverAgents().map(\.provider))
                continuation.resume(returning: providers)
            }
        }
    }
}
