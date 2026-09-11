import SwiftUI

/// What a figure or a control actually means, one click away.
///
/// The explanations this replaces were printed under the thing they qualified,
/// which meant a screen read as an argument rather than a report, and the
/// numbers competed with the prose explaining them. The explanations still
/// matter — an estimate mistaken for an invoice, or a sleep setting mistaken for
/// one that keeps the screen on, are the mistakes with a cost attached — so they
/// are kept in full and moved behind a target, rather than shortened into
/// something that no longer says the true thing.
///
/// Shared between the popover and the usage window so that one glyph means one
/// thing everywhere, and a reader who learns it once has learned it.
struct InfoTip: View {
    let text: String
    @State private var isPresented = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("What this means")
        // Also on hover, so the keyboard-free path to it is not a click that
        // opens something the reader then has to dismiss.
        .help(text)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}
