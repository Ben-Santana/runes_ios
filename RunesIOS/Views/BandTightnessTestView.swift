import SwiftUI

/// What the band tightness test has found so far, kept while the app runs.
@MainActor
final class BandTightnessTest: ObservableObject {
    static let shared = BandTightnessTest()

    /// The setting that starts the check and how the band describes it, once the named settings have been read.
    @Published private(set) var trigger: (setting: NamedSettings.Setting, capability: BandCapability)?
    @Published private(set) var lines: [String] = []
    @Published private(set) var listening = false

    func described(_ setting: NamedSettings.Setting, _ capability: BandCapability) {
        if setting.name == BandTightness.trigger { trigger = (setting, capability) }
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
        if let trigger = test.trigger {
            let runs = BandTightness.plan(trigger.capability) != nil
            PanelGroup("Band tightness", caption: runs
                       ? "Wear the band as usual and keep your arm still. One tap tries each way of getting the band's tightness in turn, for up to a minute, and stops at the first that returns a number. The streams are put back after. No setting is written."
                       : "The band does not list running this check. Copy the results so it can be worked out.") {
                lines("#\(trigger.setting.id) \(trigger.setting.name): \(trigger.capability.summary)")
                Rule()
                ActionRow(test.listening ? "Listening to the band…" : "Run the tightness check") {
                    test.start()
                    SessionController.shared.checkBandTightness(trigger.setting, worn: tests.named[BandTightness.worn]?.id)
                }
                .disabled(!ready || !runs || test.listening || tests.busy)
                if !test.lines.isEmpty {
                    Rule()
                    lines(test.lines.joined(separator: "\n"))
                }
            }
        } else {
            PanelGroup("Band tightness", caption: "Read the named settings first. The band's tightness check appears here once the band has described it.") {
                lines("Not read yet.")
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
    /// Stands in for a band that has described the check and returns a number once updates are started.
    func preview() async {
        let described = PB.field(2, 1) + PB.field(NamedSettings.field, PB.field(2, PB.field(3, Data(BandTightness.trigger.utf8)) + PB.field(4, 3)
            + PB.field(6, Data([2, 3, 4])) + PB.field(7, PB.field(3, 100)) + PB.field(18, 1)))
        guard let setting = NamedSettings.setting(from: described), let capability = BandCapability(describing: described) else { return }
        self.described(setting, capability)
        func answer(_ action: UInt64) -> String {
            BandTightness.reply(PB.field(2, 1) + PB.field(NamedSettings.field, PB.field(3, PB.field(1, 3) + PB.field(2, action))))
        }
        let update = PB.field(15, PB.field(1, PB.field(1, 3) + PB.field(2, 2) + PB.field(4, PB.field(1, 37))))
        let steps: [(Double, String)] = [
            (3, "Started: setting 3, actions 2 3 4."),
            (0.3, "+0.1s On wrist: yes."),
            (0.3, "+0.1s Asked action 2: run alone."),
            (0.3, "+0.2s " + answer(2)),
            (2, "+5.2s Asked action 3."),
            (0.3, "+5.3s " + answer(3)),
            (1.5, "+8.3s Asked action 2: after action 3."),
            (0.3, "+8.4s " + answer(2)),
            (1.5, "+9.9s " + BandTightness.describe(kind: BandTightness.update, channel: 1, payload: update)),
            (0.1, "+9.9s Number: 37."),
            (0.3, "+9.9s Asked action 4."),
            (0.3, "+10.0s " + answer(4)),
            (0.1, "+10.0s Done: tightness 37 arrived, after action 3. 1 other messages.")
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
