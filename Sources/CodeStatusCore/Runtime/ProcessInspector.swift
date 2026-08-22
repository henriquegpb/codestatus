import Foundation

/// One live process, as the kernel describes it.
///
/// Identity is always the pair `(pid, startTime)`. Pids are recycled within
/// minutes on a busy machine, and a session keyed on a bare pid would let an
/// unrelated new process inherit — or terminate — a dead agent's state.
public struct ProcessSnapshot: Sendable, Equatable, Identifiable {
    public var id: pid_t { pid }
    public let pid: pid_t
    public let parentPID: pid_t
    /// Microseconds since the epoch, read from `kp_proc.p_starttime`.
    ///
    /// Stable for the life of the process: the kernel records it once at exec
    /// and never updates it, which is what makes it usable as an identity
    /// component rather than a timestamp.
    public let startTime: UInt64
    /// `p_comm`, which the kernel truncates to 16 bytes. Good enough to filter
    /// on cheaply, never good enough to identify an agent — that needs the path.
    public let name: String
    /// Controlling terminal, e.g. `/dev/ttys003`, or nil when the process has
    /// none. Agents launched by the VS Code extension host have no controlling
    /// tty at all, so tty-based window targeting only ever works for terminals.
    public let tty: String?
    /// Resolved via `proc_pidpath`, which reports the real vnode path — so a
    /// `claude` symlink on `PATH` still resolves to the binary it points at.
    /// Nil for processes owned by another user.
    public let executablePath: String?

    public init(
        pid: pid_t,
        parentPID: pid_t,
        startTime: UInt64,
        name: String,
        tty: String? = nil,
        executablePath: String? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.startTime = startTime
        self.name = name
        self.tty = tty
        self.executablePath = executablePath
    }
}

/// A process recognised as a coding agent, with everything the app layer needs
/// to adopt it as a session.
public struct AgentProcess: Sendable, Equatable {
    public let provider: AgentProvider
    public let snapshot: ProcessSnapshot
    /// Best host attribution reachable without AppKit. `.unknown` is honest and
    /// common; the app layer can refine it from ``ancestorPIDs``.
    public let hostApplication: HostApplication
    public let evidence: AgentIdentity.Evidence
    public let workingDirectory: String?
    /// The ppid chain, immediate parent first, up to but excluding `launchd`.
    ///
    /// Exposed rather than resolved here because turning a pid into a bundle
    /// identifier needs `NSRunningApplication`, and CodeStatusCore stays free of
    /// AppKit so it can be tested and reasoned about without a UI session.
    public let ancestorPIDs: [pid_t]

    public var pid: pid_t { snapshot.pid }
    public var startTime: UInt64 { snapshot.startTime }
}

/// What a process was recognised by. Diagnostics show this so a missed or
/// mistaken match can be explained instead of guessed at.
public struct AgentIdentity: Sendable, Equatable {
    public enum Evidence: String, Sendable, Equatable {
        /// The executable path is one of the known agent binaries.
        case executablePath
        /// The binary lives inside a known VS Code extension bundle, which also
        /// tells us the host application for free.
        case editorExtensionBundle
        /// An interpreter running a known agent entry point, identified from
        /// `argv[1]` only.
        case interpreterScript
    }

    public let provider: AgentProvider
    public let hostApplication: HostApplication
    public let evidence: Evidence
}

/// Recognises agent processes from their executable path and, only where that
/// is genuinely inconclusive, `argv[1]`.
///
/// Pure and free of IO so the match table is testable as data. The rule this
/// enforces is the spec's: identification is by *what binary is running*, never
/// by "a node process exists", never by CPU, never by liveness.
public enum AgentIdentification {

    /// Interpreters that can host an agent's entry point. Nothing here is an
    /// agent on its own — a bare `node` must identify as nothing at all.
    private static let interpreters: Set<String> = ["node", "bun", "deno"]

    /// The Claude Code CLI as npm installs it. Matched as a path suffix so a
    /// directory that merely contains the word "claude" cannot match.
    private static let claudeCLISuffix = "/@anthropic-ai/claude-code/bin/claude.exe"
    /// VS Code extension directory prefixes. The extension id is a whole path
    /// *component*: `anthropic.claude-code-2.1.240-darwin-arm64` (verified on
    /// this machine), and the version suffix means it can only ever be a prefix.
    private static let claudeExtensionPrefix = "anthropic.claude-code-"
    private static let codexExtensionPrefix = "openai.chatgpt-"
    private static let codexAppPath = "/Applications/Codex.app/Contents/Resources/codex"

    /// Codex subcommands that run a long-lived *service* rather than a session.
    ///
    /// These processes have no conversation, no turn, and no user waiting on
    /// them. Counting one as a session puts a permanent phantom row in the HUD —
    /// which is exactly what `codex … app-server` did, since the ChatGPT VS Code
    /// extension starts one at launch whether or not anyone opens Codex.
    static let serviceSubcommands: Set<String> = [
        "app-server", "mcp-server", "exec-server", "remote-control",
    ]

    /// Whether reading `argv` could add anything the path did not already say.
    ///
    /// Gating on this matters for privacy, not speed: `KERN_PROCARGS2` returns
    /// the process environment as well as its arguments, so we ask for it only
    /// where it can change the answer — interpreters, which the path alone
    /// cannot classify, and `codex`, where a service subcommand is the
    /// difference between a session and a daemon.
    public static func needsArgumentInspection(executablePath: String?) -> Bool {
        guard let path = executablePath, !path.isEmpty else { return false }
        let name = basename(of: path)
        return interpreters.contains(name) || name == "codex"
    }

    /// Whether these arguments name a Codex service subcommand.
    ///
    /// A membership test, deliberately not an extraction: it answers yes or no
    /// and the caller never receives an argument. That distinction is the whole
    /// point — the buffer these tokens came from also holds the environment and,
    /// for `codex "<prompt>"`, the user's prompt.
    ///
    /// A prompt that happens to be exactly `app-server` would be misread as a
    /// service. That failure is one-directional and safe: we decline to track a
    /// session rather than inventing one, and a session that reports hooks still
    /// appears through the hook path regardless of what we decided here.
    public static func namesAServiceSubcommand(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { serviceSubcommands.contains($0) }
    }

    public static func isCodexExecutable(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return basename(of: path) == "codex"
    }

    /// Identifies an agent, or returns nil.
    ///
    /// `arguments` is expected to hold at most `argv[0]` and `argv[1]`; nothing
    /// past `argv[1]` is read, because that is where a `claude -p "<prompt>"`
    /// invocation starts carrying user content.
    public static func identify(executablePath: String?, arguments: [String] = []) -> AgentIdentity? {
        guard let path = executablePath, !path.isEmpty else { return nil }
        let name = basename(of: path)
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        if path == codexAppPath {
            return AgentIdentity(provider: .codex, hostApplication: .unknown, evidence: .executablePath)
        }
        if name == "claude", components.contains(where: { $0.hasPrefix(claudeExtensionPrefix) }) {
            return AgentIdentity(
                provider: .claudeCode, hostApplication: .vsCode, evidence: .editorExtensionBundle
            )
        }
        if name == "codex", components.contains(where: { $0.hasPrefix(codexExtensionPrefix) }) {
            // Not a session. The ChatGPT extension runs everything through a
            // single long-lived `app-server` it starts with VS Code, so this
            // process exists whether or not anyone has opened Codex, and there
            // is no per-session process behind it. Reporting it produced a
            // permanent phantom row in the HUD.
            //
            // Real Codex-in-VS-Code sessions, if that build delivers hooks at
            // all, arrive through the hook path carrying a genuine session id —
            // which is the source of truth anyway.
            return nil
        }
        if path.hasSuffix(claudeCLISuffix) || name == "claude" || name == "claude.exe" {
            return AgentIdentity(
                provider: .claudeCode, hostApplication: .unknown, evidence: .executablePath
            )
        }
        if name == "codex" {
            return AgentIdentity(provider: .codex, hostApplication: .unknown, evidence: .executablePath)
        }

        // An interpreter is only ever an agent because of what it was told to
        // run, so it is the one case where the path alone cannot decide.
        guard interpreters.contains(name), arguments.count > 1 else { return nil }
        let script = arguments[1]
        let scriptComponents = script.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if scriptComponents.contains("@anthropic-ai"), scriptComponents.contains("claude-code") {
            return AgentIdentity(
                provider: .claudeCode, hostApplication: .unknown, evidence: .interpreterScript
            )
        }
        if scriptComponents.contains("@openai"), scriptComponents.contains(where: { $0.hasPrefix("codex") }) {
            return AgentIdentity(provider: .codex, hostApplication: .unknown, evidence: .interpreterScript)
        }
        return nil
    }

    /// Maps an ancestor's executable path to the application hosting it.
    ///
    /// Takes the *outermost* `.app` component: VS Code runs extensions inside
    /// `Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/…`,
    /// so scanning from the right would name the helper instead of the app the
    /// user can actually be sent back to.
    public static func hostApplication(forExecutablePath path: String) -> HostApplication {
        for component in path.split(separator: "/", omittingEmptySubsequences: true) where component.hasSuffix(".app") {
            switch component {
            case "Terminal.app": return .terminal
            case "iTerm.app", "iTerm2.app": return .iTerm
            case "Ghostty.app": return .ghostty
            case "Warp.app": return .warp
            case "Visual Studio Code.app", "Code.app", "Visual Studio Code - Insiders.app": return .vsCode
            default: return .unknown
            }
        }
        return .unknown
    }

    private static func basename(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

/// Cumulative processor time for one process.
///
/// DIAGNOSTICS ONLY. This must never influence session state, directly or
/// indirectly: an agent waiting on a network response burns no CPU, and an
/// agent running a six-minute build burns plenty, so CPU says nothing about
/// whether the user is needed. Hooks decide state; this exists so the
/// diagnostics screen can show what a process is doing physically.
public struct ProcessCPUSample: Sendable, Equatable {
    public let userNanoseconds: UInt64
    public let systemNanoseconds: UInt64
    public var totalNanoseconds: UInt64 { userNanoseconds &+ systemNanoseconds }
}

/// Reads the process table with native kernel APIs — no `ps`, no shelling out.
///
/// Stateless by design: every method is a fresh observation, so there is no
/// cache to invalidate and the type is trivially `Sendable`.
///
/// Cost, measured on this machine (526 processes): 0.6 ms for the `sysctl`
/// enumeration, plus 3.4 ms to resolve every executable path. That is why the
/// safety sweep can afford to be exhaustive at a low frequency, and why nothing
/// here belongs in a hot path.
public struct ProcessInspector: Sendable {

    public init() {}

    // MARK: - Enumeration

    /// Every process visible to this user, including other users' processes
    /// (whose paths and working directories will come back nil).
    public func snapshotAll() -> [ProcessSnapshot] {
        kernelProcesses().map { snapshot(from: $0) }
    }

    /// One process, or nil if it has already exited.
    ///
    /// A targeted `KERN_PROC_PID` lookup rather than a filtered full sweep: this
    /// runs on every watch registration, where the whole point is to be cheap.
    public func snapshot(pid: pid_t) -> ProcessSnapshot? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        // A live pid always reports itself; a zeroed record means it is gone.
        guard info.kp_proc.p_pid == pid else { return nil }
        return snapshot(from: info)
    }

    /// Whether this exact process — not merely this pid — is still alive.
    public func isAlive(pid: pid_t, startTime: UInt64) -> Bool {
        guard let current = snapshot(pid: pid) else { return false }
        return current.startTime == startTime
    }

    // MARK: - Enrichment

    /// The process's current working directory, which is how a session learns
    /// which repository it belongs to.
    ///
    /// Requires the app to be unsandboxed, and only ever works for processes of
    /// the same uid. Failure is normal, not exceptional: it returns nil.
    public func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size)
        }
        guard result > 0 else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
    }

    /// The ppid chain from `pid` upwards, immediate parent first, stopping
    /// before `launchd`.
    ///
    /// `table` avoids re-reading the process table once per hop during a sweep.
    /// The hop limit is a cycle guard: a corrupt or racing table must not spin.
    public func ancestry(of pid: pid_t, in table: [pid_t: ProcessSnapshot]? = nil, limit: Int = 16) -> [pid_t] {
        var chain: [pid_t] = []
        var current = pid
        for _ in 0..<limit {
            let parent: pid_t
            if let table {
                guard let entry = table[current] else { break }
                parent = entry.parentPID
            } else {
                guard let entry = snapshot(pid: current) else { break }
                parent = entry.parentPID
            }
            guard parent > 1 else { break }
            chain.append(parent)
            current = parent
        }
        return chain
    }

    /// `argv[0]` and `argv[1]`, and never more.
    ///
    /// `KERN_PROCARGS2` hands back one region holding argc, the exec path, the
    /// full argv *and the process environment*. Two consequences drive this
    /// implementation:
    ///
    /// 1. We stop at `argv[1]`. Everything after it can be user content — a
    ///    `claude -p "<prompt>"` puts the prompt in `argv[2]` — and the
    ///    environment beyond it routinely holds API keys.
    /// 2. The buffer must be sized to `KERN_ARGMAX`. Given a short buffer the
    ///    kernel copies out the *tail* of the region rather than the head
    ///    (verified: a 4 KB request returns environment bytes and an empty exec
    ///    path), so under-sizing would mean reading exactly the secrets we
    ///    refuse to touch.
    /// - Parameter limit: how many tokens to parse. Kept as small as the
    ///   caller can tolerate: every token past the subcommand is one more chance
    ///   to materialise something the user typed.
    public func identificationArguments(of pid: pid_t, limit: Int = 2) -> [String] {
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var argmaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMIB, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return [] }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = Int(argmax)
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return [] }

        var index = MemoryLayout<Int32>.size
        // The exec path sits between argc and argv[0], padded with NULs.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        let wanted = min(argc, max(0, limit))
        while index < size, arguments.count < wanted {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        // The buffer holds the environment too; drop it before it can be copied.
        buffer.removeAll(keepingCapacity: false)
        return arguments
    }

    /// Cumulative user and system time. See ``ProcessCPUSample`` — diagnostics
    /// only, never an input to state.
    public func cpuSample(of pid: pid_t) -> ProcessCPUSample? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return ProcessCPUSample(
            userNanoseconds: info.ri_user_time, systemNanoseconds: info.ri_system_time
        )
    }

    // MARK: - Discovery

    /// Identifies one already-captured process.
    ///
    /// Arguments are read only where the path cannot decide: an interpreter,
    /// which could be hosting anything, and `codex`, which could be running a
    /// service subcommand rather than a session.
    public func identify(_ snapshot: ProcessSnapshot) -> AgentIdentity? {
        let path = snapshot.executablePath
        // Resolved here rather than inside AgentIdentification so the argument
        // tokens never leave this scope — the caller gets an identity or nil,
        // never a string that came out of the process's argv buffer.
        if AgentIdentification.isCodexExecutable(path), runsAServiceSubcommand(pid: snapshot.pid) {
            return nil
        }
        let arguments = AgentIdentification.needsArgumentInspection(executablePath: path)
            ? identificationArguments(of: snapshot.pid, limit: 2)
            : []
        return AgentIdentification.identify(executablePath: path, arguments: arguments)
    }

    /// Whether this process is one of Codex's long-lived services rather than a
    /// session. Returns a verdict, never the arguments it inspected.
    public func runsAServiceSubcommand(pid: pid_t) -> Bool {
        // Twelve tokens comfortably covers `codex -c a=b -c c=d <subcommand>`
        // while staying far short of a full command line.
        AgentIdentification.namesAServiceSubcommand(identificationArguments(of: pid, limit: 12))
    }

    /// Every agent process running right now.
    ///
    /// Discovery only. Adopting a session from this reports it as
    /// ``AgentState/unknown``: we have learned that an agent exists, and
    /// deliberately nothing about what it is doing.
    public func discoverAgents() -> [AgentProcess] {
        let all = snapshotAll()
        var table: [pid_t: ProcessSnapshot] = [:]
        table.reserveCapacity(all.count)
        for entry in all { table[entry.pid] = entry }

        var found: [AgentProcess] = []
        for entry in all {
            guard let identity = identify(entry) else { continue }
            let ancestors = ancestry(of: entry.pid, in: table)
            var host = identity.hostApplication
            if host == .unknown {
                for ancestor in ancestors {
                    guard let path = table[ancestor]?.executablePath else { continue }
                    let candidate = AgentIdentification.hostApplication(forExecutablePath: path)
                    if candidate != .unknown {
                        host = candidate
                        break
                    }
                }
            }
            found.append(
                AgentProcess(
                    provider: identity.provider,
                    snapshot: entry,
                    hostApplication: host,
                    evidence: identity.evidence,
                    workingDirectory: workingDirectory(of: entry.pid),
                    ancestorPIDs: ancestors
                )
            )
        }
        return found
    }

    // MARK: - Kernel plumbing

    private func kernelProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride

        // Two attempts: the table can grow between sizing and reading, and the
        // headroom absorbs the common case without a second syscall pair.
        for _ in 0..<2 {
            var needed = 0
            guard sysctl(&mib, 4, nil, &needed, nil, 0) == 0, needed > 0 else { return [] }
            let capacity = needed / stride + 64
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var size = capacity * stride
            let result = buffer.withUnsafeMutableBytes { raw in
                sysctl(&mib, 4, raw.baseAddress, &size, nil, 0)
            }
            if result == 0 {
                return Array(buffer[0..<(size / stride)])
            }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    private func snapshot(from info: kinfo_proc) -> ProcessSnapshot {
        var record = info
        let started = record.kp_proc.p_un.__p_starttime
        let startTime = UInt64(bitPattern: Int64(started.tv_sec)) &* 1_000_000
            &+ UInt64(bitPattern: Int64(started.tv_usec))

        let name = withUnsafeBytes(of: &record.kp_proc.p_comm) { raw -> String in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }

        return ProcessSnapshot(
            pid: record.kp_proc.p_pid,
            parentPID: record.kp_eproc.e_ppid,
            startTime: startTime,
            name: name,
            tty: Self.ttyPath(for: record.kp_eproc.e_tdev),
            executablePath: Self.executablePath(for: record.kp_proc.p_pid)
        )
    }

    /// `devname_r`, not `devname`: the non-reentrant form returns a pointer into
    /// a shared static buffer, and this can be called from any queue.
    private static func ttyPath(for device: dev_t) -> String? {
        guard device != -1 else { return nil }
        var buffer = [CChar](repeating: 0, count: 128)
        guard devname_r(device, S_IFCHR, &buffer, Int32(buffer.count)) != nil else { return nil }
        let name = decode(buffer)
        return name.isEmpty ? nil : "/dev/" + name
    }

    private static func executablePath(for pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN; the macro itself is not
        // exposed to Swift, so the constant is spelled out.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = decode(buffer)
        return path.isEmpty ? nil : path
    }

    /// Kernel buffers are fixed-size and NUL-padded, and `String(cString:)` on an
    /// array is deprecated, so truncate at the terminator explicitly.
    private static func decode(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
