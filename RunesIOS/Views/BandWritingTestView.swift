import SwiftUI

/// What the band's own handwriting has read, kept while the app runs. The text is what the
/// person wrote, so it stays on this page and is never journalled.
@MainActor
final class BandWritingTest: ObservableObject {
    static let shared = BandWritingTest()

    @Published private(set) var on = false
    @Published private(set) var text = ""
    /// Rows of scores read so far. It moving says the band's model is running.
    @Published private(set) var rows = 0

    func heard(_ on: Bool, _ text: String, _ rows: Int) { self.on = on; self.text = text; self.rows = rows }
    func set(_ on: Bool) { SessionController.shared.setHandwriting(on) }
}

/// Handwriting on the band tests page: the band's own model reads letters drawn with the
/// hand, and the page shows what it read.
struct BandWritingPanel: View {
    @ObservedObject private var test = BandWritingTest.shared
    @ObservedObject private var controller = SessionController.shared

    var body: some View {
        PanelGroup("Handwriting", caption: "Puts the band in its handwriting state, where its own model reads letters you draw with your hand as if holding a pen. If the band keeps its gesture model, Runes then turns on the band's data collection with its handwriting model, two settings the band keeps. While it is on the band does not go to standby, and its usual gestures may stop. Stopping puts everything back as it was, and so does the next connection if the app closes first.") {
            ActionRow(test.on ? "Stop handwriting" : "Start handwriting") { test.set(!test.on) }
                .disabled(controller.snapshot.state != .streaming)
            if test.on || !test.text.isEmpty {
                Rule()
                Text(test.text.isEmpty ? "Nothing read yet." : test.text)
                    .font(.bodyText).foregroundStyle(test.text.isEmpty ? Color.muted : Color.ink).textSelection(.enabled)
                    .padding(.horizontal, Metric.inset).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                Rule()
                Text(test.rows == 0 ? "No scores from the band yet." : "\(test.rows) rows of scores read.")
                    .font(.code).foregroundStyle(Color.muted)
                    .padding(.horizontal, Metric.inset).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
