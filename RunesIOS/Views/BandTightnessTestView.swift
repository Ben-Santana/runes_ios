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

/// Asks the band for its own tightness check once, and shows everything the band sends back
/// in the next half minute. It writes no setting the band keeps.
struct BandTightnessPanel: View {
    let ready: Bool
    @ObservedObject private var test = BandTightnessTest.shared
    @ObservedObject private var tests = BandTests.shared
    @State private var action: UInt64?
    @State private var value: Int64?

    var body: some View {
        if let trigger = test.trigger {
            let actions = BandTightness.actions(trigger.capability), values = BandTightness.values(trigger.capability)
            let sendable = !actions.isEmpty && values?.isEmpty != true
            PanelGroup("Band tightness", caption: sendable
                       ? "Wear the band as usual and keep your arm still. This asks the band for its own tightness check once and listens for \(Int(BandTightness.listen)) seconds. No setting is written."
                       : "The band describes this check in a way this test cannot send. Copy the results so it can be worked out.") {
                lines("#\(trigger.setting.id) \(trigger.setting.name): \(trigger.capability.summary)")
                if actions.count > 1 {
                    Rule()
                    ChipRow(selection: Binding(get: { action ?? actions[0] }, set: { action = $0 }), options: actions) { "Action \($0)" }
                        .padding(.vertical, 12)
                }
                if let values, !values.isEmpty {
                    Rule()
                    ChipRow(selection: Binding(get: { chosen(from: values, trigger.capability) }, set: { value = $0 }), options: values) { "Value \($0)" }
                        .padding(.vertical, 12)
                }
                Rule()
                ActionRow(test.listening ? "Listening to the band…" : "Run the tightness check") {
                    test.start()
                    SessionController.shared.checkBandTightness(trigger.setting, action: action.flatMap { actions.contains($0) ? $0 : nil } ?? actions[0],
                                                                value: values.map { chosen(from: $0, trigger.capability) })
                }
                .disabled(!ready || !sendable || test.listening || tests.busy)
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

    /// The value picked, or the one in the band's description, or the first.
    private func chosen(from values: [Int64], _ capability: BandCapability) -> Int64 {
        if let value, values.contains(value) { return value }
        if let current = capability.current, values.contains(current) { return current }
        return values[0]
    }

    private func lines(_ text: String) -> some View {
        Text(text).font(.code).foregroundStyle(Color.muted).textSelection(.enabled)
            .padding(.horizontal, Metric.inset).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
