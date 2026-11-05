import Foundation

/// Recognises Codex's internal memory workspace using filesystem metadata only.
/// Custom CODEX_HOME locations are supported; a project named `memories` alone
/// is insufficient. No configuration, memory, or database contents are read.
public enum CodexMemoryWorkspace {
    public static func contains(_ cwd: String) -> Bool {
        matches(cwd, fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    static func matches(_ cwd: String, fileExists: (String) -> Bool) -> Bool {
        guard cwd.hasPrefix("/") else { return false }
        let workspace = URL(fileURLWithPath: cwd).standardizedFileURL
        guard workspace.lastPathComponent == "memories" else { return false }
        let home = workspace.deletingLastPathComponent()
        return fileExists(home.appendingPathComponent("config.toml").path)
            && fileExists(home.appendingPathComponent("memories_1.sqlite").path)
    }
}
