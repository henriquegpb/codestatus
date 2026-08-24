import Foundation

/// What one install left behind in a user-owned config file.
///
/// Uninstall has to answer a question the file itself cannot: did the `hooks`
/// key exist before we arrived? A user who wrote `"hooks": {}` by hand and a
/// file where we created it look identical once our entries are removed. So we
/// remember, rather than guess, and only ever delete structure we created.
public struct InstallReceipt: Codable, Sendable, Equatable {
    public var targetPath: String
    /// We created the file itself, so removing it entirely on uninstall is safe.
    public var createdFile: Bool
    /// We created the top-level `hooks` object.
    public var createdHooksKey: Bool
    /// The per-event keys under `hooks` that did not exist before us.
    public var createdEventKeys: [String]
    /// The binary path we wrote, kept for diagnostics after an app relocation.
    public var hookBinaryPath: String
    public var installedAt: Date

    public init(
        targetPath: String,
        createdFile: Bool = false,
        createdHooksKey: Bool = false,
        createdEventKeys: [String] = [],
        hookBinaryPath: String = "",
        installedAt: Date = Date()
    ) {
        self.targetPath = targetPath
        self.createdFile = createdFile
        self.createdHooksKey = createdHooksKey
        self.createdEventKeys = createdEventKeys
        self.hookBinaryPath = hookBinaryPath
        self.installedAt = installedAt
    }
}

/// Persists ``InstallReceipt`` values under our own state directory.
///
/// Ours, so it is written 0600 like everything else we own. Losing it is not
/// fatal: uninstall then simply leaves any empty container it cannot prove it
/// created, which is untidy but never destructive.
public struct InstallReceiptStore: Sendable {
    public let paths: RuntimePaths

    public init(paths: RuntimePaths) {
        self.paths = paths
    }

    public var url: URL { paths.state.appendingPathComponent("installation.json") }

    public func load(fileManager: FileManager = .default) -> [String: InstallReceipt] {
        guard let data = fileManager.contents(atPath: url.path) else { return [:] }
        return (try? JSONDecoder().decode([String: InstallReceipt].self, from: data)) ?? [:]
    }

    public func receipt(for targetPath: String, fileManager: FileManager = .default) -> InstallReceipt? {
        load(fileManager: fileManager)[targetPath]
    }

    public func save(_ receipt: InstallReceipt, fileManager: FileManager = .default) throws {
        var all = load(fileManager: fileManager)
        all[receipt.targetPath] = receipt
        try write(all, fileManager: fileManager)
    }

    public func forget(targetPath: String, fileManager: FileManager = .default) throws {
        var all = load(fileManager: fileManager)
        guard all.removeValue(forKey: targetPath) != nil else { return }
        try write(all, fileManager: fileManager)
    }

    private func write(_ all: [String: InstallReceipt], fileManager: FileManager) throws {
        try paths.createDirectories(fileManager: fileManager)
        let encoder = JSONEncoder()
        // Our own file, so canonical formatting is a feature here — unlike the
        // user's config, where it would be vandalism.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(all)
        try FileSurgery.atomicallyWrite(data, to: url, mode: 0o600, fileManager: fileManager)
    }
}

/// Installs and removes our hook entries in an agent's user-owned config file.
///
/// Three guarantees shape everything below:
///
///  1. We never block the agent. Every entry is written with `async: true`,
///     which both Claude Code and Codex honour, so our hook can never sit on
///     the agent's critical path even if the daemon is wedged.
///  2. We only ever touch our own entries. Ownership is decided by resolving
///     the entry's `command` to a real path and comparing it to the binary we
///     control — never by substring, which would let us delete a user hook
///     whose command merely mentions our name.
///  3. We never lose the user's file. Backup, atomic replace, re-validate,
///     restore on failure.
public struct HookInstaller: Sendable {

    public enum Failure: Error, Equatable {
        case targetIsNotUTF8(path: String)
        /// Something is at the target path, but we could not read it — so we
        /// cannot know what replacing it would destroy.
        case targetIsUnreadable(path: String)
        case writeFailed(path: String)
        case backupFailed(path: String)
        case validationFailed(path: String, reason: String)
        /// The file moved under a plan computed against an older version of it.
        case targetChangedSincePlan(path: String)
    }

    /// Seconds we allow ourselves before the agent gives up on us. The hook is
    /// `async`, so this is a backstop against a wedged process, not a latency
    /// budget the agent ever waits out.
    public static let timeoutSeconds = 5

    public let paths: RuntimePaths
    public let provider: AgentProvider
    public let targetURL: URL
    public let events: [String]
    public let hookBinary: URL
    /// Paths earlier builds installed this provider's hook at.
    ///
    /// Ownership has to include them or a move is not a move: `planInstall`
    /// removes only entries it recognises as ours, so an entry left at the old
    /// path would survive alongside the new one and the hook would fire twice
    /// per event — or, when the old path is the broken one, keep failing next to
    /// a working entry and keep reporting the session as unhealthy.
    public let legacyHookBinaries: [URL]

    /// Test seam: forces post-write validation to fail so the restore path can
    /// be exercised. Never set outside tests.
    var validationProbe: (@Sendable (String?) throws -> Void)?

    public init(
        paths: RuntimePaths,
        provider: AgentProvider,
        targetURL: URL,
        events: [String],
        hookBinary: URL? = nil,
        legacyHookBinaries: [URL] = []
    ) {
        self.paths = paths
        self.provider = provider
        self.targetURL = targetURL
        self.events = events
        self.hookBinary = (hookBinary ?? paths.hookBinary).standardizedFileURL
        self.legacyHookBinaries = legacyHookBinaries.map(\.standardizedFileURL)
    }

    public var targetPath: String { targetURL.path }
    public var receiptStore: InstallReceiptStore { InstallReceiptStore(paths: paths) }

    /// The value we pass to `codestatus-hook --provider`. The payload alone
    /// cannot identify the agent, so the config carries it.
    public var providerArgument: String {
        switch provider {
        case .claudeCode: return "claude-code"
        case .codex: return "codex"
        case .generic: return "generic"
        }
    }

    /// One element of an event's array. `matcher` is deliberately omitted, which
    /// both agents read as "every invocation".
    /// Whether this agent honours `async: true`.
    ///
    /// Claude Code does, verified by running it. Codex does not: 0.138.0 prints
    /// `skipping async hook: async hooks are not supported yet` and discards the
    /// entry outright, so writing the flag there does not merely fail to help —
    /// it makes the whole installation invisible, with `/hooks` reporting no
    /// hooks installed at all.
    ///
    /// Its documentation lists `async` as supported. The shipped build is the
    /// authority.
    public var supportsAsyncHooks: Bool {
        switch provider {
        case .claudeCode: return true
        case .codex, .generic: return false
        }
    }

    public func entryJSON() -> String {
        let command = JSONSurgeon.quoted(hookBinary.path)
        // Without `async`, the hook runs on the agent's critical path, so the
        // "never blocks" guarantee for Codex rests on the hook being bounded
        // instead of on the agent enforcing it: ~10 ms typical, a 50 ms cap on
        // the socket, and this timeout as the backstop.
        let asyncField = supportsAsyncHooks ? ",\"async\":true" : ""
        return "{\"hooks\":[{\"type\":\"command\",\"command\":\(command),"
            + "\"args\":[\"--provider\",\"\(providerArgument)\"],"
            + "\"timeout\":\(Self.timeoutSeconds)\(asyncField)}]}"
    }

    // MARK: - Ownership

    /// Whether an event-array element was written by us.
    ///
    /// The test is that one of its commands resolves to the exact binary we
    /// control. A user hook at `/usr/local/bin/codestatus-notify`, or a shell
    /// line that prints the word "codestatus", is not ours and survives
    /// uninstall untouched.
    public func isOurEntry(_ elementText: String) -> Bool {
        guard let element = try? JSONSurgeon(elementText),
              let hooks = element.arrayElements(atPath: ["hooks"]) else { return false }
        for hookText in hooks {
            guard let hook = try? JSONSurgeon(hookText),
                  let command = hook.string(atPath: ["command"]) else { continue }
            for binary in [hookBinary] + legacyHookBinaries
            where Self.identifiesSameFile(command, binary) {
                return true
            }
        }
        return false
    }

    static func identifiesSameFile(_ command: String, _ binary: URL) -> Bool {
        let candidates = normalisedPaths(command)
        guard !candidates.isEmpty else { return false }
        return !candidates.isDisjoint(with: normalisedPaths(binary.path))
    }

    /// Both the standardized and the symlink-resolved spelling of a path.
    ///
    /// Two spellings because `/tmp/x` and `/private/tmp/x` name the same file on
    /// macOS, as do a home directory reached through `/System/Volumes/Data`.
    /// Anything that is not an absolute or tilde path is not a path we could
    /// have written, so it belongs to the user and we leave it alone.
    private static func normalisedPaths(_ raw: String) -> Set<String> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return [] }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
        return [url.path, realPath(of: url)]
    }

    /// Symlink resolution applied to the deepest ancestor that exists, with the
    /// remaining components appended.
    ///
    /// `URL.resolvingSymlinksInPath()` alone gives up when the leaf is missing,
    /// which is the normal case here: we compare against a hook binary that may
    /// not have been staged yet.
    private static func realPath(of url: URL, fileManager: FileManager = .default) -> String {
        var missing: [String] = []
        var current = url.standardizedFileURL
        while true {
            if fileManager.fileExists(atPath: current.path) {
                var resolved = current.resolvingSymlinksInPath()
                for component in missing.reversed() {
                    resolved.appendPathComponent(component)
                }
                return resolved.path
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return url.standardizedFileURL.path }
            missing.append(current.lastPathComponent)
            current = parent
        }
    }

    // MARK: - Planning

    /// The exact before and after text of a change, computed without touching
    /// disk, so onboarding can show a diff and let the user decline.
    public struct Plan: Sendable, Equatable {
        public enum Operation: String, Sendable, Codable {
            case install
            case uninstall
        }

        public let operation: Operation
        public let targetPath: String
        /// nil when the file does not exist yet.
        public let originalText: String?
        /// nil when applying the plan removes the file.
        public let updatedText: String?
        public let receipt: InstallReceipt?
        /// How many of our entries the plan removes.
        public let removedEntries: Int

        public var isNoOp: Bool { originalText == updatedText }
        public var createsFile: Bool { originalText == nil && updatedText != nil }
        public var removesFile: Bool { originalText != nil && updatedText == nil }
        /// The text a preview should render.
        public var previewText: String { updatedText ?? "" }
    }

    public func planInstall(fileManager: FileManager = .default) throws -> Plan {
        let original = try readTarget(fileManager: fileManager)
        var surgeon = try JSONSurgeon(original ?? "")

        var receipt = receiptStore.receipt(for: targetPath, fileManager: fileManager)
            ?? InstallReceipt(targetPath: targetPath)
        // Merged, not replaced: a second install must not forget that the first
        // one created the `hooks` key, or uninstall would leave it behind.
        receipt.createdFile = receipt.createdFile || original == nil
        receipt.createdHooksKey = receipt.createdHooksKey || !surgeon.contains(path: ["hooks"])
        receipt.hookBinaryPath = hookBinary.path
        receipt.installedAt = Date()

        var createdEventKeys = Set(receipt.createdEventKeys)
        let entry = entryJSON()
        var removed = 0

        for event in events {
            if !surgeon.contains(path: ["hooks", event]) { createdEventKeys.insert(event) }
            // Remove first, then append exactly one. That is what makes install
            // idempotent and what upgrades an entry left by an older app build
            // living at a different path under our bin directory.
            removed += try surgeon.removeFromArray(atPath: ["hooks", event], where: isOurEntry)
            try surgeon.appendToArray(atPath: ["hooks", event], element: entry)
        }
        receipt.createdEventKeys = createdEventKeys.sorted()

        return Plan(
            operation: .install,
            targetPath: targetPath,
            originalText: original,
            updatedText: surgeon.text,
            receipt: receipt,
            removedEntries: removed
        )
    }

    public func planUninstall(fileManager: FileManager = .default) throws -> Plan {
        guard let original = try readTarget(fileManager: fileManager) else {
            return Plan(
                operation: .uninstall,
                targetPath: targetPath,
                originalText: nil,
                updatedText: nil,
                receipt: nil,
                removedEntries: 0
            )
        }

        var surgeon = try JSONSurgeon(original)
        var removed = 0
        for event in events {
            // A `hooks` value of the wrong shape cannot contain anything of
            // ours, so there is nothing to remove and nothing to complain about.
            removed += (try? surgeon.removeFromArray(atPath: ["hooks", event], where: isOurEntry)) ?? 0
        }

        let receipt = receiptStore.receipt(for: targetPath, fileManager: fileManager)
        if let receipt {
            for event in receipt.createdEventKeys
            where surgeon.isEmptyContainer(atPath: ["hooks", event]) {
                _ = try? surgeon.removeKey(atPath: ["hooks", event])
            }
            if receipt.createdHooksKey, surgeon.isEmptyContainer(atPath: ["hooks"]) {
                _ = try? surgeon.removeKey(atPath: ["hooks"])
            }
        }

        // Only when the file was ours from the start and nothing else ever went
        // into it do we take it away again.
        let updated: String?
        if let receipt, receipt.createdFile, surgeon.isEmptyContainer(atPath: []) {
            updated = nil
        } else {
            updated = surgeon.text
        }

        return Plan(
            operation: .uninstall,
            targetPath: targetPath,
            originalText: original,
            updatedText: updated,
            receipt: receipt,
            removedEntries: removed
        )
    }

    // MARK: - Applying

    @discardableResult
    public func install(fileManager: FileManager = .default) throws -> Plan {
        let plan = try planInstall(fileManager: fileManager)
        try apply(plan, fileManager: fileManager)
        if let receipt = plan.receipt {
            try receiptStore.save(receipt, fileManager: fileManager)
        }
        return plan
    }

    @discardableResult
    public func uninstall(fileManager: FileManager = .default) throws -> Plan {
        let plan = try planUninstall(fileManager: fileManager)
        try apply(plan, fileManager: fileManager)
        try receiptStore.forget(targetPath: targetPath, fileManager: fileManager)
        return plan
    }

    /// Whether every event we manage currently carries exactly our entry.
    ///
    /// Exactly, and exactly *ours as we would write it now* — not merely one
    /// entry somewhere in the array whose command happens to resolve to our
    /// binary. Our binary sits at a fixed path across upgrades, so an entry
    /// written by an older build still points at it: a loose test reports such a
    /// file as installed and the entry is never refreshed. An entry carrying
    /// `"async": false` is the case that matters, because it puts our hook on
    /// the agent's critical path on every tool call — the one thing this
    /// installer promises never to do — while reporting itself healthy.
    ///
    /// Duplicates count too: two of our entries fire the hook twice per event,
    /// and ``validate(_:fileManager:)`` already refuses to accept that as the
    /// result of an install. This is the same question, asked later.
    public func isInstalled(fileManager: FileManager = .default) throws -> Bool {
        guard let text = try readTarget(fileManager: fileManager) else { return false }
        guard let expected = Self.canonicalEntry(entryJSON()) else { return false }
        let surgeon = try JSONSurgeon(text)
        return events.allSatisfy { event in
            let ours = (surgeon.arrayElements(atPath: ["hooks", event]) ?? []).filter(isOurEntry)
            guard ours.count == 1 else { return false }
            return Self.canonicalEntry(ours[0]) == expected
        }
    }

    /// Whether the file carries entries of ours that are not what we would write
    /// today — an install from an older build that has to be refreshed.
    ///
    /// The distinction that matters is against a file with *no* entries of ours,
    /// which is a user who never connected this agent. Reinstalling there would
    /// be adding hooks to someone's agent without being asked, so this is
    /// deliberately not "is it missing?" but "is ours stale?".
    public func needsMigration(fileManager: FileManager = .default) throws -> Bool {
        guard try !isInstalled(fileManager: fileManager) else { return false }
        guard let text = try readTarget(fileManager: fileManager) else { return false }
        let surgeon = try JSONSurgeon(text)
        return events.contains { event in
            (surgeon.arrayElements(atPath: ["hooks", event]) ?? []).contains(where: isOurEntry)
        }
    }

    /// One entry reduced to a form two spellings of the same entry compare equal
    /// on: whitespace and key order gone, every value left exactly as written.
    ///
    /// Needed because the entry in the file is rendered in the user's own
    /// layout, so it is never byte-equal to ``entryJSON()``. `JSONSerialization`
    /// is safe here in a way it is not for editing: this compares two small
    /// objects we authored and never writes anything back.
    private static func canonicalEntry(_ text: String) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Backup, atomic replace, re-validate, and restore the backup if the result
    /// is not exactly what the plan promised.
    ///
    /// Returns where the backup went, so onboarding can tell the user.
    @discardableResult
    public func apply(_ plan: Plan, fileManager: FileManager = .default) throws -> URL? {
        guard !plan.isNoOp else { return nil }

        // A plan is a statement about a file as it was when the plan was made,
        // and `updatedText` is the *whole* file, not a patch. Writing it over a
        // file that has moved since would not merge the two — it would silently
        // delete whatever changed in between, and the backup we are about to
        // take would preserve the stale text rather than the lost one. The
        // window is real: `apply` is public precisely so onboarding can show a
        // diff and wait for the user, and `~/.claude/settings.json` is written
        // by the agent itself whenever the user changes a setting.
        guard try readTarget(fileManager: fileManager) == plan.originalText else {
            throw Failure.targetChangedSincePlan(path: targetPath)
        }

        try paths.createDirectories(fileManager: fileManager)
        let directory = targetURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let originalData = plan.originalText.map { Data($0.utf8) }
        var backup: URL?
        if let originalData {
            backup = try writeBackup(originalData, fileManager: fileManager)
        }

        // A file that already exists keeps its own permissions: it is the user's
        // file, and quietly narrowing access to a config the CLI and the VS Code
        // extension share is not ours to decide. A file we create is ours to
        // create, and is created 0600.
        //
        // Sampled once, here, before anything on disk moves. Asking again from
        // inside `restore` would be asking about a file we had just deleted —
        // `stat` fails, the fallback applies, and a 0644 file the user chose
        // came back 0600 from a failure that was supposed to change nothing.
        let mode = existingMode(fileManager: fileManager) ?? 0o600

        do {
            if let updated = plan.updatedText {
                try FileSurgery.atomicallyWrite(
                    Data(updated.utf8),
                    to: resolvedTarget(fileManager: fileManager),
                    mode: mode,
                    fileManager: fileManager
                )
            } else {
                // Only reached when the receipt says we created the file, and we
                // never create symlinks — but resolve anyway so a link the user
                // added afterwards is left in place rather than deleted.
                try fileManager.removeItem(at: resolvedTarget(fileManager: fileManager))
            }
            try validate(plan, fileManager: fileManager)
        } catch {
            restore(originalData, mode: mode, fileManager: fileManager)
            throw error
        }
        return backup
    }

    // MARK: - Disk

    /// The target's text, or nil when there is genuinely nothing there.
    ///
    /// The nil is load-bearing in three separate destructive decisions: it means
    /// no backup is taken, it sets `createdFile` on the receipt so a later
    /// uninstall deletes the file, and it makes ``restore(_:fileManager:)``
    /// remove whatever is at the path instead of writing bytes back. So "absent"
    /// has to mean absent.
    ///
    /// `FileManager.contents(atPath:)` cannot carry that distinction: it answers
    /// nil for a file that is not there, for one we lack permission to read, for
    /// a directory, for a symlink loop, and for an I/O error alike. Reading each
    /// of those as "absent" meant overwriting a config we had never seen, with
    /// no backup, and then deleting it when validation could not read it back —
    /// total, unrecoverable loss of the user's settings. `stat(2)` plus `errno`
    /// is what actually distinguishes them: only `ENOENT`/`ENOTDIR` mean nothing
    /// is there, and a dangling symlink is one of those, so an unfollowed link
    /// still reads as the empty path it points at.
    private func readTarget(fileManager: FileManager) throws -> String? {
        if let data = fileManager.contents(atPath: targetURL.path) {
            guard let text = String(data: data, encoding: .utf8) else {
                // Lossy decoding would silently rewrite bytes we cannot represent,
                // which is exactly the corruption this whole type exists to prevent.
                throw Failure.targetIsNotUTF8(path: targetPath)
            }
            return text
        }

        var info = stat()
        if stat(targetURL.path, &info) == 0 {
            throw Failure.targetIsUnreadable(path: targetPath)
        }
        switch errno {
        case ENOENT, ENOTDIR: return nil
        default: throw Failure.targetIsUnreadable(path: targetPath)
        }
    }

    /// The file a write must actually land on.
    ///
    /// `~/.claude/settings.json` is very often a symlink into a dotfiles repo —
    /// stow, chezmoi, and yadm all work this way. Renaming a temp file over the
    /// link would replace the link with a regular file: the user's repo would
    /// silently stop controlling their settings, their next `stow` would not
    /// reach Claude Code, and the change would not even show up as a diff. We
    /// follow the leaf link and edit the file it points at, leaving the link
    /// itself intact.
    ///
    /// A path that is not a link comes back spelled exactly as it was given, so
    /// the common case never turns `/tmp` into `/private/tmp`. Once a link is
    /// followed we are naming a different file anyway, and the directory it
    /// lands in is spelled the way the kernel spells it. Either way this is only
    /// ever a write destination: the receipt store keys off ``targetPath``,
    /// which never moves.
    private func resolvedTarget(fileManager: FileManager) -> URL {
        var current = targetURL
        // Bounded: a symlink loop must not hang the installer.
        for _ in 0..<8 {
            guard let destination = try? fileManager.destinationOfSymbolicLink(
                atPath: current.path
            ) else { return current }
            current = Self.joining(destination, onto: current.deletingLastPathComponent())
        }
        return current
    }

    /// A symlink's destination joined onto the directory the link actually lives
    /// in, resolved the way the kernel resolves it.
    ///
    /// A relative destination is interpreted by the kernel from the link's *real*
    /// directory, so `..` in it steps out of that directory. Collapsing `..`
    /// lexically against the path we happened to spell instead names a different
    /// file the moment any parent component is itself a symlink — and
    /// `~/.claude -> ~/dotfiles/claude` with a `../shared/settings.json` inside
    /// is an ordinary dotfiles layout, not a contrived one. We would then read
    /// the user's real settings, write them plus our hooks over whatever
    /// unrelated file sits at the lexical path, and leave the real one untouched.
    ///
    /// `realpath(3)` on the directory is the kernel's own algorithm, so there is
    /// no second implementation of symlink resolution to keep in step. Only the
    /// directory goes through it: the leaf is what we are deliberately following
    /// one hop at a time. When the directory does not exist there is nothing to
    /// resolve and nothing to write, and the lexical answer is as good as any.
    private static func joining(_ destination: String, onto directory: URL) -> URL {
        let raw = destination.hasPrefix("/")
            ? destination
            : (directory.path as NSString).appendingPathComponent(destination)
        let leaf = (raw as NSString).lastPathComponent
        guard let resolved = realpath((raw as NSString).deletingLastPathComponent, nil) else {
            return URL(fileURLWithPath: raw).standardizedFileURL
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent(leaf)
    }

    /// The mode of the file we are about to rewrite.
    ///
    /// `stat`, not `attributesOfItem`: the latter does not follow symlinks, so
    /// on a symlinked settings file it reports the link's own `0755` rather than
    /// the target's. Applying that to the replacement would widen a file that
    /// routinely holds an `env` block with an API key in it — a permission
    /// downgrade CodeStatus caused rather than one the user chose.
    private func existingMode(fileManager: FileManager) -> Int? {
        let resolved = resolvedTarget(fileManager: fileManager)
        var info = stat()
        guard stat(resolved.path, &info) == 0 else { return nil }
        return Int(info.st_mode & 0o777)
    }

    private func writeBackup(_ data: Data, fileManager: FileManager) throws -> URL {
        let stamp = Self.backupTimestamp.string(from: Date())
        // Provider-qualified because both agents' files land in one directory
        // and `hooks.json` is not a unique name.
        let name = "\(provider.rawValue)-\(targetURL.lastPathComponent).\(stamp).bak"
        let destination = paths.backups.appendingPathComponent(name)
        do {
            try FileSurgery.atomicallyWrite(data, to: destination, mode: 0o600, fileManager: fileManager)
        } catch {
            throw Failure.backupFailed(path: destination.path)
        }
        return destination
    }

    /// Best effort by construction: we are already unwinding from a failure, and
    /// throwing a second error here would hide the first.
    ///
    /// It writes to the same resolved file ``apply(_:fileManager:)`` wrote to. A
    /// restore aimed at `targetURL` would not be a restore at all on a symlinked
    /// config: it would leave our half-installed text in the dotfiles repo and
    /// `rename(2)` the original over the link, replacing it with a regular
    /// file — destroying the link on the one path where we changed nothing.
    private func restore(_ originalData: Data?, mode: Int, fileManager: FileManager) {
        let destination = resolvedTarget(fileManager: fileManager)
        if let originalData {
            try? FileSurgery.atomicallyWrite(
                originalData,
                to: destination,
                mode: mode,
                fileManager: fileManager
            )
        } else {
            try? fileManager.removeItem(at: destination)
        }
    }

    private func validate(_ plan: Plan, fileManager: FileManager) throws {
        try validationProbe?(plan.updatedText)

        guard let expected = plan.updatedText else {
            guard !fileManager.fileExists(atPath: targetURL.path) else {
                throw Failure.validationFailed(path: targetPath, reason: "file was not removed")
            }
            return
        }

        guard let actual = try readTarget(fileManager: fileManager) else {
            throw Failure.validationFailed(path: targetPath, reason: "file is missing after write")
        }
        guard actual == expected else {
            throw Failure.validationFailed(path: targetPath, reason: "written bytes differ from the plan")
        }
        // A second, independent parser: if our surgeon and Foundation disagree
        // about what we just wrote, the agent is the one that would find out.
        guard (try? JSONSerialization.jsonObject(with: Data(actual.utf8))) != nil else {
            throw Failure.validationFailed(path: targetPath, reason: "result is not valid JSON")
        }

        let surgeon = try JSONSurgeon(actual)
        for event in events {
            let ours = (surgeon.arrayElements(atPath: ["hooks", event]) ?? []).filter(isOurEntry).count
            switch plan.operation {
            case .install where ours != 1:
                throw Failure.validationFailed(
                    path: targetPath,
                    reason: "\(event) carries \(ours) CodeStatus entries, expected exactly 1"
                )
            case .uninstall where ours != 0:
                throw Failure.validationFailed(
                    path: targetPath,
                    reason: "\(event) still carries \(ours) CodeStatus entries"
                )
            default:
                continue
            }
        }
    }

    /// Sortable and human-readable, so a directory listing of backups reads as
    /// a history.
    private static let backupTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}

/// The write half of the install path, kept separate so its failure modes are
/// obvious in isolation.
enum FileSurgery {
    /// Writes via a temp file in the *same* directory plus `rename(2)`.
    ///
    /// Same directory because rename is only atomic within a filesystem, and a
    /// half-written `settings.json` would break the agent on its next launch.
    /// The mode is set on the temp file before the rename, so the destination is
    /// never observable with the wrong permissions.
    static func atomicallyWrite(
        _ data: Data,
        to destination: URL,
        mode: Int,
        fileManager: FileManager = .default
    ) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: mode]
        ) else {
            throw HookInstaller.Failure.writeFailed(path: destination.path)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw HookInstaller.Failure.writeFailed(path: destination.path)
        }
    }
}
