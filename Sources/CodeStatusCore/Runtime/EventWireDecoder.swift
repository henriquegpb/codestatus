import Foundation

/// Decodes the NDJSON line produced by `codestatus-hook` into an ``AgentEvent``.
///
/// This is the trust boundary in the other direction: the hook has already
/// dropped every non-allowlisted key, so anything arriving here is metadata by
/// construction. The decoder still validates rather than assumes, because the
/// socket is reachable by anything running as this user.
public enum EventWireDecoder {

    public enum DecodeError: Error, Equatable {
        case notJSON
        case unsupportedVersion(Int)
        case missingField(String)
        case unknownEvent(String)
    }

    /// The current wire version. Bumped only on a breaking change; the daemon
    /// rejects versions it does not understand rather than guessing.
    public static let supportedVersion = 1

    public static func decode(line: Data) throws -> AgentEvent {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw DecodeError.notJSON
        }

        let version = object["v"] as? Int ?? 0
        guard version == supportedVersion else {
            throw DecodeError.unsupportedVersion(version)
        }

        guard let id = object["id"] as? String, !id.isEmpty else {
            throw DecodeError.missingField("id")
        }
        guard let rawEvent = object["hook_event_name"] as? String else {
            throw DecodeError.missingField("hook_event_name")
        }
        guard let kind = HookEventKind(rawValue: rawEvent) else {
            // A lifecycle event added after this build shipped. Surfacing it as
            // an error lets the caller count it in diagnostics; it never
            // reaches the reducer, so it cannot misclassify a session.
            throw DecodeError.unknownEvent(rawEvent)
        }

        let provider = AgentProvider(rawValue: object["provider"] as? String ?? "") ?? .generic

        let timestamp: Date
        if let seconds = object["ts"] as? Double {
            timestamp = Date(timeIntervalSince1970: seconds)
        } else {
            timestamp = Date()
        }

        // Claude Code calls the turn `prompt_id`; Codex calls it `turn_id`.
        let turnID = (object["turn_id"] as? String) ?? (object["prompt_id"] as? String)

        // SessionStart's reason appears as `source` in some versions and
        // `start_reason` in others; both are allowlisted and either is accepted.
        let startReason = (object["start_reason"] as? String) ?? (object["source"] as? String)

        let notificationType = (object["notification_type"] as? String)
            .flatMap(NotificationType.init(rawValue:))

        let pid = (object["ppid"] as? Int).map { pid_t($0) }

        return AgentEvent(
            id: EventID(id),
            provider: provider,
            kind: kind,
            source: .hook,
            timestamp: timestamp,
            providerSessionID: nonEmpty(object["session_id"]),
            providerTurnID: turnID,
            notificationType: notificationType,
            toolName: nonEmpty(object["tool_name"]),
            toolUseID: nonEmpty(object["tool_use_id"]),
            startReason: startReason,
            endReason: nonEmpty(object["end_reason"]),
            errorType: nonEmpty(object["error_type"]),
            permissionMode: nonEmpty(object["permission_mode"]),
            model: nonEmpty(object["model"]),
            cwd: nonEmpty(object["cwd"]),
            pid: pid,
            termProgram: nonEmpty(object["term_program"]),
            termSessionID: nonEmpty(object["term_session_id"])
        )
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// Splits a stream buffer into complete newline-delimited lines, returning
    /// the remainder so a partial line can be carried into the next read.
    public static func splitLines(_ buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<index]
            buffer = buffer[buffer.index(after: index)...]
            if !line.isEmpty { lines.append(Data(line)) }
        }
        buffer = Data(buffer)
        return lines
    }
}
