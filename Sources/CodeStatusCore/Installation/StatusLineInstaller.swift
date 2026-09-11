import Foundation

/// Claims Claude Code's `statusLine` slot, without costing anyone the status
/// line they already had.
///
/// This exists because plan quota — how much of the five-hour and weekly windows
/// is spent — reaches no hook. Claude Code pushes it to the status line command
/// on every render and never writes it anywhere, so this is the only channel.
///
/// The slot is a **single command**, unlike `hooks`, which is a list. That is
/// what makes this different from everything else this app installs: two tools
/// can share the hooks array, and cannot share this. So an existing command is
/// wrapped rather than replaced — ours runs, captures the reading, then executes
/// theirs with the same payload and lets their output be the status line.
public struct StatusLineInstaller {

    public enum Outcome: Equatable, Sendable {
        /// The slot was empty; we now own it.
        case installed
        /// Someone else's command was there and is now wrapped.
        case wrapped(previous: String)
        /// Ours was already there, unchanged.
        case alreadyInstalled
        /// Ours was there but pointed somewhere stale, and was refreshed.
        case refreshed
    }

    public let settingsURL: URL
    public let hookBinary: URL

    public init(settingsURL: URL, hookBinary: URL) {
        self.settingsURL = settingsURL
        self.hookBinary = hookBinary
    }

    /// Recognises our own entry however it was written.
    ///
    /// Matched on the flag rather than the path, so a moved or renamed binary is
    /// still recognised as ours and refreshed instead of being wrapped by a
    /// second copy of itself.
    public static func isOurs(_ command: String) -> Bool {
        command.contains("--status-line") && command.contains("codestatus-hook")
    }

    /// The command we install, wrapping `previous` when there is one.
    ///
    /// When `previous` is already ours, the command it wraps is carried over
    /// rather than dropped. Without that, a second install — a repair, an
    /// upgrade, a re-run of Setup — would quietly discard the user's own status
    /// line, which is the exact harm this whole type exists to prevent, arriving
    /// by a different door.
    public func command(wrapping previous: String?) -> String {
        let quoted = Self.shellQuote(hookBinary.path)
        guard let previous, !previous.isEmpty else { return "\(quoted) --status-line" }

        let inner = Self.isOurs(previous) ? Self.chainedCommand(in: previous) : previous
        guard let inner, !inner.isEmpty else { return "\(quoted) --status-line" }
        return "\(quoted) --status-line --chain \(Self.shellQuote(inner))"
    }

    /// Single-quotes for `/bin/sh`, which is what runs both this command and the
    /// chained one.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Reading and writing

    public func currentCommand(fileManager: FileManager = .default) throws -> String? {
        guard let data = fileManager.contents(atPath: settingsURL.path),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["statusLine"] as? [String: Any]
        else { return nil }
        return entry["command"] as? String
    }

    @discardableResult
    public func install(fileManager: FileManager = .default) throws -> Outcome {
        let existing = try currentCommand(fileManager: fileManager)
        let desired = command(wrapping: existing)

        if let existing, existing == desired { return .alreadyInstalled }

        var root: [String: Any] = [:]
        if let data = fileManager.contents(atPath: settingsURL.path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        root["statusLine"] = ["type": "command", "command": desired]

        try write(root, fileManager: fileManager)

        if let existing {
            return Self.isOurs(existing) ? .refreshed : .wrapped(previous: existing)
        }
        return .installed
    }

    /// Removes our entry, restoring whatever we wrapped.
    ///
    /// Deleting the key outright would take the user's own status line with it —
    /// the thing this installer went out of its way not to break on the way in.
    @discardableResult
    public func uninstall(fileManager: FileManager = .default) throws -> Bool {
        guard let data = fileManager.contents(atPath: settingsURL.path),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["statusLine"] as? [String: Any],
              let command = entry["command"] as? String,
              Self.isOurs(command)
        else { return false }

        if let restored = Self.chainedCommand(in: command) {
            root["statusLine"] = ["type": "command", "command": restored]
        } else {
            root.removeValue(forKey: "statusLine")
        }
        try write(root, fileManager: fileManager)
        return true
    }

    /// Pulls the wrapped command back out of one of our entries.
    static func chainedCommand(in command: String) -> String? {
        guard let range = command.range(of: "--chain ") else { return nil }
        let tail = command[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard tail.hasPrefix("'"), tail.count >= 2 else {
            return tail.isEmpty ? nil : tail
        }
        // Unquote, reversing the escaping in `shellQuote`.
        let inner = tail.dropFirst().dropLast()
        return inner.replacingOccurrences(of: "'\\''", with: "'")
    }

    private func write(_ root: [String: Any], fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
        // Written beside and moved into place, so a crash mid-write cannot leave
        // the user with a settings file their agent refuses to parse.
        let temporary = settingsURL.appendingPathExtension("codestatus-tmp")
        try data.write(to: temporary)
        _ = try fileManager.replaceItemAt(settingsURL, withItemAt: temporary)
    }
}
