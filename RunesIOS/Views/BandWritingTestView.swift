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

/// Which gesture model the band runs, as far as the band says, kept while the app runs.
@MainActor
final class BandModelTest: ObservableObject {
    static let shared = BandModelTest()

    @Published private(set) var trial = false
    @Published private(set) var lines: [String] = []
    /// Gesture messages since the last change, by whether the band marked them as from its trial model.
    @Published private(set) var usual = 0
    @Published private(set) var marked = 0

    func heard(_ line: String?, _ trial: Bool, _ usual: Int, _ marked: Int) {
        if let line { lines.append(line) }
        self.trial = trial; self.usual = usual; self.marked = marked
    }
    func set(_ on: Bool) { SessionController.shared.setTrialModel(on) }
}

/// The band's two gesture models on the band tests page: a switch for the setting that
/// looks like what selects the trial one, and a count of gestures by the model they came from.
struct BandModelPanel: View {
    @ObservedObject private var test = BandModelTest.shared
    @ObservedObject private var controller = SessionController.shared
    @State private var asking = false

    var body: some View {
        PanelGroup("Gesture model", caption: "Build 72 lists a second, newer gesture model beside the one it uses. Nothing public says what selects it. The best guess is the band's load flash model setting, which the band keeps. This turns it on, asks the band what it then runs, and counts the gestures the band marks as from the trial model. Going back puts the setting as it was, and so does the next connection.") {
            ActionRow(test.trial ? "Go back to the usual model" : "Try the trial model") {
                if test.trial { test.set(false) } else { asking = true }
            }
            .disabled(controller.snapshot.state != .streaming)
            Rule()
            Text((["\(test.usual) gesture messages from the usual model, \(test.marked) marked as from the trial model."] + test.lines.suffix(8)).joined(separator: "\n"))
                .font(.code).foregroundStyle(Color.muted).textSelection(.enabled)
                .padding(.horizontal, Metric.inset).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Turn on a setting the band keeps?", isPresented: $asking, titleVisibility: .visible) {
            Button("Turn on load flash model") { test.set(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is a guess at what selects the trial model, and nobody has written down what the setting does. If gestures stop or feel wrong, tap Go back to the usual model. Runes also puts it back the next time it connects.")
        }
    }
}
