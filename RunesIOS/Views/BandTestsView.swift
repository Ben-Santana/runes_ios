import SwiftUI

/// What the band tests have found so far, kept while the app runs.
@MainActor
final class BandTests: ObservableObject {
    static let shared = BandTests()

    /// The band's settings as it last reported them, and its answer to the last of its own patterns.
    @Published var settings: String?
    @Published var patternAnswer: String?
    /// The named settings read so far: a line each for the page, and each one by its name.
    @Published private(set) var lines: [String] = []
    @Published private(set) var named: [String: NamedSettings.Setting] = [:]
    /// Whether a read or a write is still waiting on the band.
    @Published private(set) var busy = false
    /// What the other tests heard back, a line each.
    @Published var trials: [String] = []

    func startReading() { lines = []; named = [:]; busy = true }
    func startWriting() { busy = true }
    /// The link dropped: whatever was waiting will not be answered.
    func interrupted() { busy = false }
    /// A setting as it is read or written back, or a note. An empty line ends a read.
    func named(_ setting: NamedSettings.Setting?, _ line: String) {
        if let setting {
            // A write answers with one line, and that ends it.
            if named[setting.name] != nil { busy = false }
            named[setting.name] = setting
        }
        if line.isEmpty { busy = false } else { lines.append(line) }
    }
}

/// Tests that find out what the band does and can be told. The first question is the buzz the
/// band gives by itself when it hears a gesture, and how to take that over from the phone.
/// Acknowledging gestures, stored patterns, stop, reading the named settings and the band's
/// own patterns leave nothing behind. The one write here is the band's `haptics` setting,
/// which the band keeps, and which has needed a restart of the band to take effect.
struct BandTestsScreen: View {
    @ObservedObject private var tests = BandTests.shared
    @ObservedObject private var controller = SessionController.shared
    @State private var copied = false
    @State private var acknowledging = false
    /// A haptics value was written and the band has not been restarted since.
    @State private var awaitingRestart = false
    /// The value `haptics` had the first time it was read on this phone, to put back. Negative until then.
    @AppStorage("bandTests.haptics.first") private var firstHaptics = -1

    private var ready: Bool { controller.snapshot.state == .streaming }
    private var haptics: NamedSettings.Setting? { tests.named["haptics"] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !ready {
                    Text("Connect the band to run these.").font(.bodyText).foregroundStyle(Color.muted)
                }
                PanelGroup("Named settings", caption: "Asks the band for every setting it can name and reads each one. Takes a few seconds.") {
                    ActionRow(tests.busy ? "Waiting for the band…" : "Read named settings") {
                        tests.startReading(); controller.readNamedSettings()
                    }
                    .disabled(!ready || tests.busy)
                }
                PanelGroup("Acknowledge gestures", caption: "The Meta app tells the band it received each gesture, and Runes never has. Turn this on, do a few gestures and feel whether the band's own buzz changes. Nothing is kept on the band.") {
                    Toggle(isOn: $acknowledging) { Text("Acknowledge each gesture").font(.bodyText) }
                        .padding(.horizontal, Metric.inset).padding(.vertical, 10)
                }
                .disabled(!ready)
                PanelGroup("Your own vibration", caption: "The first has the band store a pattern and play it by itself, so its timing does not depend on the phone. The second starts a two second buzz and stops it early.") {
                    ActionRow("Play a pattern stored on the band") { controller.playStored(Self.sample, named: "runes-test") }
                    Rule()
                    ActionRow("Long buzz, then stop it") {
                        controller.vibrate([BandPulse(duration: 2000, amplitude: 200)])
                        Task {
                            try? await Task.sleep(for: .seconds(0.5))
                            controller.stopVibration()
                        }
                    }
                    if !tests.trials.isEmpty {
                        Rule()
                        lines(tests.trials.suffix(6).joined(separator: "\n"))
                    }
                }
                .disabled(!ready)
                ownBuzz
                PanelGroup("The band's own patterns", caption: tests.patternAnswer ?? "The band keeps these itself. Play each and compare it with the buzz you feel when it hears a gesture.") {
                    ActionRow("Play pattern 1") { controller.performBandPattern(1) }
                    Rule()
                    ActionRow("Play pattern 2") { controller.performBandPattern(2) }
                }
                .disabled(!ready)
                if !tests.lines.isEmpty {
                    PanelGroup("What the band reported", caption: nil) { lines(tests.lines.joined(separator: "\n")) }
                }
                PanelGroup("Settings read on connecting", caption: "The band sends these when it connects.") {
                    lines(tests.settings ?? "Not read yet.")
                }
                PanelGroup(nil, caption: "Copies everything above as text.") {
                    ActionRow(copied ? "Copied" : "Copy results", icon: copied ? .check : .clipboardCopy) {
                        UIPasteboard.general.string = ([tests.patternAnswer, tests.settings] + tests.trials + tests.lines).compactMap { $0 }.joined(separator: "\n")
                        copied = true
                    }
                }
            }
            .padding(.horizontal, Metric.gutter).padding(.vertical, 20)
        }
        .page()
        .navigationTitle("Band tests")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: ready) { _, now in
            tests.interrupted()
            // The band came back, so a written value has been through a restart: read it afresh.
            guard now, awaitingRestart else { return }
            awaitingRestart = false
            tests.startReading(); controller.readNamedSettings()
        }
        .onChange(of: acknowledging) { _, on in controller.acknowledgeGestures(on) }
        .onDisappear { acknowledging = false }
        .onChange(of: haptics?.value) { _, value in
            if firstHaptics < 0, let value { firstHaptics = Int(value) }
        }
    }

    /// The band's `haptics` setting: choose a value, do a gesture to feel whether the band still
    /// buzzes by itself, then send a pulse to check that ours still plays.
    @ViewBuilder private var ownBuzz: some View {
        if let setting = haptics, let value = setting.value, setting.writable {
            let range = setting.range.map { $0.lowerBound...min($0.upperBound, $0.lowerBound + 7) } ?? 0...3
            PanelGroup("The band's own buzz", caption: awaitingRestart
                       ? "Restart the band now: hold its button 8 seconds until the light goes dark, then 2 seconds to turn it on. When it reconnects, do a gesture and send a pulse."
                       : "Kept on the band. A change has only taken effect after the band is restarted, so change one value, restart, then test. It was \(firstHaptics < 0 ? Int(value) : firstHaptics) when first read: choose that and restart to put it back.") {
                ValueRow("haptics") { Text("\(value)").monospacedDigit() }
                Rule()
                ChipRow(selection: Binding(get: { value }, set: { chosen in
                    guard chosen != value else { return }
                    tests.startWriting(); controller.writeNamedSetting(setting, value: chosen)
                    awaitingRestart = true
                }), options: Array(range)) { String($0) }
                .padding(.vertical, 12)
                .disabled(!ready || tests.busy || awaitingRestart)
                Rule()
                ActionRow("Send a pulse from the phone") { controller.vibrate([BandPulse(duration: 150, amplitude: 230)]) }
                    .disabled(!ready)
            }
        } else {
            PanelGroup("The band's own buzz", caption: "Read the named settings first. The band's haptics setting appears here once it has been read.") {
                lines("Not read yet.")
            }
        }
    }

    /// A pattern to store on the band: two heartbeats with a rest between them.
    private static let sample = [BandPulse(duration: 60, amplitude: 190, gap: 90), BandPulse(duration: 110, amplitude: 245, gap: 260),
                                 BandPulse(duration: 60, amplitude: 190, gap: 90), BandPulse(duration: 110, amplitude: 245)]

    private func lines(_ text: String) -> some View {
        Text(text).font(.code).foregroundStyle(Color.muted).textSelection(.enabled)
            .padding(.horizontal, Metric.inset).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
