import SwiftUI

/// What the band tightness test has found so far, kept while the app runs.
@MainActor
final class BandTightnessTest: ObservableObject {
    static let shared = BandTightnessTest()

    /// The settings the test asks about and how the band describes each, once the named settings have been read.
    @Published private(set) var subjects: [BandTightness.Subject: (setting: NamedSettings.Setting, capability: BandCapability)] = [:]
    @Published private(set) var lines: [String] = []
    @Published private(set) var listening = false

    func described(_ setting: NamedSettings.Setting, _ capability: BandCapability) {
        if let subject = BandTightness.Subject(rawValue: setting.name) { subjects[subject] = (setting, capability) }
    }
    func start() { lines = []; listening = true }
    /// A line from the test. An empty line ends it.
    func heard(_ line: String) {
        if line.isEmpty { listening = false } else { lines.append(line) }
    }
}

/// Tries each way of getting the band's tightness in turn on one tap, and shows everything the
/// band sends back. It writes no setting the band keeps.
struct BandTightnessPanel: View {
    let ready: Bool
    @ObservedObject private var test = BandTightnessTest.shared
    @ObservedObject private var tests = BandTests.shared

    var body: some View {
        let known = BandTightness.Subject.allCases.compactMap { test.subjects[$0] }
        if known.isEmpty {
            PanelGroup("Band tightness", caption: "Read the named settings first. The band's tightness check appears here once the band has described it.") {
                lines("Not read yet.")
            }
        } else {
            let runs = BandTightness.plan(test.subjects.mapValues(\.capability)) != nil
            PanelGroup("Band tightness", caption: runs
                       ? "Wear the band as usual and keep your arm still. One tap tries each way of getting the band's tightness in turn, for up to a minute, and stops at the first that returns a number. The streams are put back after. No setting is written."
                       : "The band does not list running this check. Copy the results so it can be worked out.") {
                lines(known.map { "#\($0.setting.id) \($0.setting.name): \($0.capability.summary)" }.joined(separator: "\n"))
                Rule()
                ActionRow(test.listening ? "Listening to the band…" : "Run the tightness check") {
                    test.start()
                    SessionController.shared.checkBandTightness(known.map(\.setting))
                }
                .disabled(!ready || !runs || test.listening || tests.busy)
                if !test.lines.isEmpty {
                    Rule()
                    lines(test.lines.joined(separator: "\n"))
                }
            }
        }
    }

    private func lines(_ text: String) -> some View {
        Text(text).font(.code).foregroundStyle(Color.muted).textSelection(.enabled)
            .padding(.horizontal, Metric.inset).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
extension BandTightnessTest {
    /// Stands in for a band that has described both checks and whose wrist state changes after a run.
    func preview() async {
        func described(_ name: String, _ id: UInt64, actions: [UInt8], high: UInt64) -> Data {
            PB.field(2, 1) + PB.field(NamedSettings.field, PB.field(2, PB.field(3, Data(name.utf8)) + PB.field(4, id)
                + PB.field(6, Data(actions)) + PB.field(7, PB.field(3, high)) + PB.field(18, 2)))
        }
        for reply in [described(BandTightness.Subject.tightness.rawValue, 4, actions: [2, 3, 4], high: 100),
                      described(BandTightness.Subject.state.rawValue, 5, actions: [0, 2, 3, 4], high: 3)] {
            guard let setting = NamedSettings.setting(from: reply), let capability = BandCapability(describing: reply) else { return }
            self.described(setting, capability)
        }
        func answer(_ id: UInt64, _ action: UInt64) -> String {
            BandTightness.reply(PB.field(2, 1) + PB.field(NamedSettings.field, PB.field(3, PB.field(1, id) + PB.field(2, action))))
        }
        let steps: [(Double, String)] = [
            (3, "Started: tightness is setting 4, actions 2 3 4; wrist state is setting 5, actions 0 2 3 4."),
            (0.3, "+0.1s Wrist state reads 3."),
            (0.3, "+0.1s Asked tightness action 2: run alone."),
            (0.3, "+0.2s " + answer(4, 2)),
            (2, "+4.3s Wrist state reads 3."),
            (0.3, "+4.3s Asked wrist state action 2: run alone."),
            (0.3, "+4.4s " + answer(5, 2)),
            (2, "+8.5s Wrist state reads 2."),
            (0.3, "+8.5s Asked tightness action 3."),
            (0.3, "+8.6s " + answer(4, 3)),
            (1.5, "+20.1s Asked tightness action 4."),
            (0.3, "+20.2s " + answer(4, 4)),
            (0.1, "+20.2s Done: wrist state went from 3 to 2, wrist state run alone. Wrist state read 3 at first and 2 at the end. 0 other messages.")
        ]
        for (index, step) in steps.enumerated() {
            try? await Task.sleep(for: .seconds(step.0))
            if index == 0 { start() }
            heard(step.1)
        }
        heard("")
    }
}
#endif
