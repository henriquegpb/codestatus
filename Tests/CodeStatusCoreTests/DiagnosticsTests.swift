import Testing
import Foundation
@testable import CodeStatusCore

/// The diagnostics export is the artefact users are actively encouraged to
/// paste into a public issue tracker, which makes it the highest-risk surface in
/// the app for accidental disclosure. These tests are the second of the two
/// independent defences: the pipeline should never have collected anything
/// sensitive, and the export scrubs it again on the way out.
@Suite("Diagnostics export sanitisation")
struct DiagnosticsSanitizerTests {

    @Test("The user's home directory is replaced with a tilde")
    func homeIsRedacted() {
        let text = "cwd: /Users/henrique/Desktop/codestatus"
        let sanitized = DiagnosticsSanitizer.redactHome(text, home: "/Users/henrique")
        #expect(sanitized == "cwd: ~/Desktop/codestatus")
        #expect(!sanitized.contains("henrique"))
    }

    @Test("Someone else's home path is redacted too")
    func otherUsersRedacted() {
        // A path belonging to a different account can appear via a shared
        // volume or a copied config; a real name is a real name either way.
        let sanitized = DiagnosticsSanitizer.sanitize(
            "found /Users/jane.doe/.claude/settings.json",
            home: "/Users/henrique"
        )
        #expect(!sanitized.contains("jane.doe"))
        #expect(sanitized.contains("/Users/<user>"))
    }

    @Test("Credential-shaped environment values are masked", arguments: [
        "ANTHROPIC_API_KEY=sk-ant-abcdef1234567890abcdef",
        "GITHUB_TOKEN: ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "MY_APP_SECRET=hunter2hunter2hunter2",
        "\"authToken\": \"abcdefghijklmnop\"",
    ])
    func secretsAreMasked(input: String) {
        let sanitized = DiagnosticsSanitizer.redactSecrets(input)
        #expect(sanitized.contains("<redacted>"))
        for leak in ["sk-ant-abcdef1234567890abcdef", "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                     "hunter2hunter2hunter2", "abcdefghijklmnop"] {
            #expect(!sanitized.contains(leak))
        }
    }

    @Test("An API key is masked even without a telltale variable name")
    func bareKeysAreMasked() {
        let sanitized = DiagnosticsSanitizer.redactSecrets(
            "the value was sk-proj-AAAAAAAAAAAAAAAAAAAAAAAA and it failed"
        )
        #expect(!sanitized.contains("sk-proj-AAAAAAAAAAAAAAAAAAAAAAAA"))
        #expect(sanitized.contains("<redacted>"))
    }

    @Test("Ordinary diagnostic text is left readable")
    func benignTextSurvives() {
        let text = "Socket: ~/Library/Application Support/CodeStatus/run/e.sock, 42 accepted"
        #expect(DiagnosticsSanitizer.sanitize(text, home: "/Users/nobody") == text)
    }
}

@Suite("Diagnostics report")
struct DiagnosticsReportTests {

    private func makeReport() -> DiagnosticsReport {
        DiagnosticsReport(
            appVersion: "0.1.0",
            systemVersion: "26.5",
            architecture: "arm64",
            adapters: [
                AdapterStatus(name: "Claude Code CLI", state: .connected, version: "2.1.186"),
                AdapterStatus(
                    name: "Codex CLI", state: .needsVerification,
                    detail: "Run /hooks in Codex and trust the CodeStatus entries",
                    version: "0.138.0-alpha.7"
                ),
            ],
            capabilities: [
                CapabilityRow(
                    environment: "Codex CLI", discovery: .yes, busyFree: .yes,
                    approval: .yes, input: .no, open: .yes, sendPrompt: .no,
                    note: "Codex emits no Notification event, so 'waiting for a reply' is not observable."
                ),
            ],
            socketPath: "/Users/henrique/Library/Application Support/CodeStatus/run/e.sock",
            socketAccepted: 12, socketDecoded: 11, socketRejected: 1,
            sessionSummaries: ["codestatus — Claude Code — free"]
        )
    }

    @Test("The export carries the facts a maintainer needs")
    func exportIsUseful() {
        let text = makeReport().exportText(home: "/Users/henrique")
        for expected in ["CodeStatus: 0.1.0", "macOS: 26.5", "Claude Code CLI 2.1.186: Connected",
                         "12/11/1", "codestatus — Claude Code — free"] {
            #expect(text.contains(expected), "missing \(expected)")
        }
    }

    @Test("The export never contains the user's name")
    func exportIsSanitized() {
        let text = makeReport().exportText(home: "/Users/henrique")
        #expect(!text.contains("henrique"))
        #expect(text.contains("~/Library/Application Support/CodeStatus"))
    }

    @Test("Limitations are exported, not quietly dropped")
    func limitationsAreVisible() {
        // The spec is explicit that the matrix must not hide gaps. An export
        // that shows only what works would mislead whoever reads the issue.
        let text = makeReport().exportText(home: "/Users/henrique")
        #expect(text.contains("No"))
        #expect(text.contains("no Notification event"))
        #expect(text.contains("Needs verification"))
    }
}
