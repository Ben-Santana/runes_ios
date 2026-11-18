import SwiftUI

/// What the band probe has found, kept while the app runs.
@MainActor
final class BandProbeTest: ObservableObject {
    static let shared = BandProbeTest()

    @Published private(set) var lines: [String] = []
    @Published private(set) var running = false
    /// How far the probe is, replaced as it moves on.
    @Published private(set) var progress = ""

    /// Lines from the probe. While it runs the last one says how far it is.
    func heard(_ new: [String], _ running: Bool) {
        self.running = running
        progress = running ? new.last ?? "" : ""
        lines += running ? new.dropLast() : new
    }
    func start(_ title: String, _ trials: [BandProbe.Trial]) {
        lines.append(title); running = true
        SessionController.shared.startProbe(trials)
    }
    func stop() { SessionController.shared.stopProbe() }
}

/// The band probe on the band tests page: every stream and request the band's message
/// definitions name and Runes does not use, tried one at a time.
struct BandProbePanel: View {
    @ObservedObject private var test = BandProbeTest.shared
    @ObservedObject private var controller = SessionController.shared

    var body: some View {
        let ready = controller.snapshot.state == .streaming && !test.running
        PanelGroup("What else the band can send", caption: "The first row asks the band which kinds of request it knows, then turns on each stream Runes does not use, alone, for two seconds, and counts what arrives. It takes about two minutes. The second row listens to the streams that speak only when something happens: while it runs, take the band off and put it back, tilt your wrist and do a gesture. The switches last only while connected and are turned off again. No setting is written.") {
            ActionRow(test.running ? "Asking the band…" : "Try every stream and request") {
                test.start("Requests, then every stream alone:", BandProbe.census + BandProbe.sweep)
            }
            .disabled(!ready)
            Rule()
            ActionRow("Listen for events for 30 seconds") {
                test.start("Events, together for 30 seconds:", [.streams(BandProbe.events, listen: 30)])
            }
            .disabled(!ready)
            if test.running {
                Rule()
                ActionRow("Stop") { test.stop() }
            }
            if !test.lines.isEmpty {
                Rule()
                Text((test.lines + [test.progress]).filter { !$0.isEmpty }.joined(separator: "\n"))
                    .font(.code).foregroundStyle(Color.muted).textSelection(.enabled)
                    .padding(.horizontal, Metric.inset).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
