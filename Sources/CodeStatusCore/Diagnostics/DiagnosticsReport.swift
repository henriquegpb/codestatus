import Foundation

/// What CodeStatus can actually do in a given environment.
///
/// Computed at runtime from what was detected rather than hardcoded, so the
/// matrix on screen reflects this machine — the version of Codex installed here,
/// whether hooks are trusted here — instead of what the README hoped for.
public struct CapabilityRow: Sendable, Equatable, Identifiable {
    public enum Support: String, Sendable, Equatable {
        case yes
        case no
        case unverified
        case notApplicable

        public var symbol: String {
            switch self {
            case .yes: return "Yes"
            case .no: return "No"
            case .unverified: return "Needs verification"
            case .notApplicable: return "—"
            }
        }
    }

    public var id: String { environment }
    public var environment: String
    public var discovery: Support
    public var busyFree: Support
    public var approval: Support
    public var input: Support
    public var open: Support
    public var sendPrompt: Support
    /// Why a capability is missing, shown next to the row rather than hidden.
    public var note: String?

    public init(
        environment: String,
        discovery: Support,
        busyFree: Support,
        approval: Support,
        input: Support,
        open: Support,
        sendPrompt: Support,
        note: String? = nil
    ) {
        self.environment = environment
        self.discovery = discovery
        self.busyFree = busyFree
        self.approval = approval
        self.input = input
        self.open = open
        self.sendPrompt = sendPrompt
        self.note = note
    }
}

/// The state of one integration.
public struct AdapterStatus: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable, Equatable {
        case connected
        case needsVerification
        case notInstalled
        case notConfigured
        case error

        /// Written out rather than shown as a raw case name: this text ends up
        /// in an issue report a human has to read, where `needsVerification`
        /// reads as a leaked identifier.
        public var displayName: String {
            switch self {
            case .connected: return "Connected"
            case .needsVerification: return "Needs verification"
            case .notInstalled: return "Not installed"
            case .notConfigured: return "Not configured"
            case .error: return "Error"
            }
        }
    }

    public var id: String { name }
    public var name: String
    public var state: State
    public var detail: String?
    public var version: String?

    public init(name: String, state: State, detail: String? = nil, version: String? = nil) {
        self.name = name
        self.state = state
        self.detail = detail
        self.version = version
    }
}

/// Everything the diagnostics screen shows, and everything an exported report
/// contains.
public struct DiagnosticsReport: Sendable, Equatable {
    public var appVersion: String
    public var systemVersion: String
    public var architecture: String
    public var adapters: [AdapterStatus]
    public var capabilities: [CapabilityRow]
    public var socketPath: String?
    public var socketAccepted: Int
    public var socketDecoded: Int
    public var socketRejected: Int
    public var spoolFileCount: Int
    public var notificationAuthorization: String
    public var automationPermission: String
    public var sessionSummaries: [String]
    /// The most recent event, already reduced to metadata by the hook.
    public var lastEventSummary: String?
    public var errors: [String]

    public init(
        appVersion: String,
        systemVersion: String,
        architecture: String,
        adapters: [AdapterStatus] = [],
        capabilities: [CapabilityRow] = [],
        socketPath: String? = nil,
        socketAccepted: Int = 0,
        socketDecoded: Int = 0,
        socketRejected: Int = 0,
        spoolFileCount: Int = 0,
        notificationAuthorization: String = "unknown",
        automationPermission: String = "unknown",
        sessionSummaries: [String] = [],
        lastEventSummary: String? = nil,
        errors: [String] = []
    ) {
        self.appVersion = appVersion
        self.systemVersion = systemVersion
        self.architecture = architecture
        self.adapters = adapters
        self.capabilities = capabilities
        self.socketPath = socketPath
        self.socketAccepted = socketAccepted
        self.socketDecoded = socketDecoded
        self.socketRejected = socketRejected
        self.spoolFileCount = spoolFileCount
        self.notificationAuthorization = notificationAuthorization
        self.automationPermission = automationPermission
        self.sessionSummaries = sessionSummaries
        self.lastEventSummary = lastEventSummary
        self.errors = errors
    }
}

/// Removes anything that should not leave the machine in a bug report.
///
/// A diagnostics export is the one artefact users are *encouraged* to paste into
/// a public issue tracker, which makes it the highest-risk surface in the app
/// for accidental disclosure — higher than the logs, because sharing is the
/// point. It is scrubbed on the way out even though the pipeline should never
/// have collected anything sensitive in the first place, on the principle that
/// two independent defences are what make the guarantee credible.
public enum DiagnosticsSanitizer {

    /// Environment variable names whose *values* must never appear, matched
    /// case-insensitively as substrings so `MY_API_TOKEN` is caught too.
    static let sensitiveKeyFragments = [
        "token", "key", "secret", "password", "passwd", "credential",
        "auth", "session_token", "cookie", "bearer",
    ]

    /// Replaces the user's home directory with `~`.
    ///
    /// Real names appear in home paths far more often than people expect, and a
    /// stack trace full of `/Users/firstname.lastname/` identifies someone as
    /// surely as a signature.
    public static func redactHome(_ text: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return text }
        var result = text.replacingOccurrences(of: home, with: "~")
        // Catch other users' homes and the /private/var alias for the same path.
        result = result.replacingOccurrences(
            of: #"/Users/[^/\s"']+"#,
            with: "/Users/<user>",
            options: .regularExpression
        )
        return result
    }

    /// Masks anything that looks like a credential.
    public static func redactSecrets(_ text: String) -> String {
        var result = text

        // key=value and "key": "value" forms for any sensitive-looking name.
        for fragment in sensitiveKeyFragments {
            let patterns = [
                // `"?` after the name matters: a quoted key such as
                // `"authToken": "…"` puts a closing quote between the name and
                // the separator.
                "(?i)([A-Z0-9_]*\(fragment)[A-Z0-9_]*)\"?\\s*[=:]\\s*\"?[^\\s\",}]+\"?",
            ]
            for pattern in patterns {
                result = result.replacingOccurrences(
                    of: pattern,
                    with: "$1=<redacted>",
                    options: .regularExpression
                )
            }
        }

        // Long opaque strings that look like API keys regardless of their label.
        result = result.replacingOccurrences(
            of: #"\b(sk-|pk-|ghp_|gho_|github_pat_)[A-Za-z0-9_\-]{16,}"#,
            with: "<redacted>",
            options: .regularExpression
        )
        return result
    }

    public static func sanitize(_ text: String, home: String = NSHomeDirectory()) -> String {
        redactSecrets(redactHome(text, home: home))
    }
}

public extension DiagnosticsReport {
    /// Renders the report as Markdown, ready to paste into an issue.
    func exportText(home: String = NSHomeDirectory()) -> String {
        var lines: [String] = []
        lines.append("# CodeStatus diagnostics")
        lines.append("")
        lines.append("- CodeStatus: \(appVersion)")
        lines.append("- macOS: \(systemVersion) (\(architecture))")
        lines.append("- Notifications: \(notificationAuthorization)")
        lines.append("- Automation (Terminal): \(automationPermission)")
        lines.append("")

        lines.append("## Adapters")
        for adapter in adapters {
            let version = adapter.version.map { " \($0)" } ?? ""
            let detail = adapter.detail.map { " — \($0)" } ?? ""
            lines.append("- \(adapter.name)\(version): \(adapter.state.displayName)\(detail)")
        }
        lines.append("")

        lines.append("## Transport")
        lines.append("- Socket: \(socketPath ?? "not listening")")
        lines.append("- Events accepted/decoded/rejected: \(socketAccepted)/\(socketDecoded)/\(socketRejected)")
        lines.append("- Spool files pending: \(spoolFileCount)")
        if let lastEventSummary {
            lines.append("- Last event: \(lastEventSummary)")
        }
        lines.append("")

        lines.append("## Capabilities")
        lines.append("| Environment | Discovery | Busy/free | Approval | Input | Open | Send prompt |")
        lines.append("|---|---|---|---|---|---|---|")
        for row in capabilities {
            lines.append(
                "| \(row.environment) | \(row.discovery.symbol) | \(row.busyFree.symbol) "
                + "| \(row.approval.symbol) | \(row.input.symbol) | \(row.open.symbol) "
                + "| \(row.sendPrompt.symbol) |"
            )
        }
        for row in capabilities.compactMap(\.note) {
            lines.append("")
            lines.append("> \(row)")
        }
        lines.append("")

        lines.append("## Sessions (\(sessionSummaries.count))")
        for summary in sessionSummaries { lines.append("- \(summary)") }

        if !errors.isEmpty {
            lines.append("")
            lines.append("## Errors")
            for error in errors { lines.append("- \(error)") }
        }

        return DiagnosticsSanitizer.sanitize(lines.joined(separator: "\n"), home: home)
    }
}
