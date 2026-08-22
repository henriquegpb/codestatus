import AppKit
import CodeStatusCore
import SwiftUI

/// The diagnostics window.
///
/// Written for a contributor triaging someone else's bug report as much as for
/// the user: it shows what was detected, what is unverified, and what cannot
/// work here — and the export button produces text that is safe to paste into a
/// public issue.
struct DiagnosticsView: View {
    let report: DiagnosticsReport
    var onRefresh: () -> Void
    var onSendTestEvent: () -> Void

    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                environmentSection
                adaptersSection
                transportSection
                capabilitiesSection
                sessionsSection
                if !report.errors.isEmpty { errorsSection }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Send Test Event", action: onSendTestEvent)
                    .help("Exercises the socket, the sound, and the notification without involving an agent.")
                Button("Refresh", action: onRefresh)
                Button(copied ? "Copied" : "Copy Report") {
                    let text = report.exportText()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .help("Copies a sanitised report: no prompts, responses, tokens, or usernames.")
            }
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    // MARK: - Sections

    private var environmentSection: some View {
        Section("Environment") {
            row("CodeStatus", report.appVersion)
            row("macOS", "\(report.systemVersion) · \(report.architecture)")
            row("Notifications", report.notificationAuthorization)
            row("Automation", report.automationPermission)
        }
    }

    private var adaptersSection: some View {
        Section("Adapters") {
            ForEach(report.adapters) { adapter in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Circle().fill(tint(for: adapter.state)).frame(width: 7, height: 7)
                        Text(adapter.name).font(.system(size: 12, weight: .medium))
                        if let version = adapter.version {
                            Text(version)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(adapter.state.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let detail = adapter.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 15)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var transportSection: some View {
        Section("Transport") {
            row("Socket", report.socketPath ?? "not listening")
            row("Events", "\(report.socketAccepted) accepted · \(report.socketDecoded) decoded · \(report.socketRejected) rejected")
            row("Spool", "\(report.spoolFileCount) pending")
            if let last = report.lastEventSummary { row("Last event", last) }
        }
    }

    private var capabilitiesSection: some View {
        Section("What works here") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(report.capabilities) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.environment).font(.system(size: 12, weight: .medium))
                        HStack(spacing: 12) {
                            capability("Discovery", row.discovery)
                            capability("Busy/free", row.busyFree)
                            capability("Approval", row.approval)
                            capability("Input", row.input)
                            capability("Open", row.open)
                            capability("Prompt", row.sendPrompt)
                        }
                        // Gaps are explained inline rather than left as a bare
                        // "No" the reader has to guess at.
                        if let note = row.note {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var sessionsSection: some View {
        Section("Sessions (\(report.sessionSummaries.count))") {
            if report.sessionSummaries.isEmpty {
                Text("No agent sessions detected.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.sessionSummaries, id: \.self) { summary in
                    Text(summary).font(.system(size: 12, design: .monospaced))
                }
            }
        }
    }

    private var errorsSection: some View {
        Section("Errors") {
            ForEach(report.errors, id: \.self) { error in
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Pieces

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func capability(_ label: String, _ support: CapabilityRow.Support) -> some View {
        VStack(spacing: 1) {
            Image(systemName: icon(for: support))
                .font(.system(size: 10))
                .foregroundStyle(tint(for: support))
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(support.symbol)")
    }

    private func icon(for support: CapabilityRow.Support) -> String {
        switch support {
        case .yes: return "checkmark.circle.fill"
        case .no: return "xmark.circle.fill"
        case .unverified: return "questionmark.circle.fill"
        case .notApplicable: return "minus.circle"
        }
    }

    private func tint(for support: CapabilityRow.Support) -> Color {
        switch support {
        case .yes: return .green
        case .no: return .red
        case .unverified: return .orange
        case .notApplicable: return .secondary
        }
    }

    private func tint(for state: AdapterStatus.State) -> Color {
        switch state {
        case .connected: return .green
        case .needsVerification: return .orange
        case .notInstalled, .notConfigured: return .secondary
        case .error: return .red
        }
    }
}

/// A titled block. Local rather than SwiftUI's `Section`, which outside a `Form`
/// or `List` renders without a header on macOS.
private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 4) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
