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
/// band gives by itself when it hears a gesture. Reading the named settings and playing the
/// band's own patterns change nothing. The one write here is the band's `haptics` setting,
/// which the band keeps until it is written again.
struct BandTestsScreen: View {
    @ObservedObject private var tests = BandTests.shared
    @ObservedObject private var controller = SessionController.shared
    @State private var copied = false
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
                        UIPasteboard.general.string = ([tests.patternAnswer, tests.settings] + tests.lines).compactMap { $0 }.joined(separator: "\n")
                        copied = true
                    }
                }
            }
            .padding(.horizontal, Metric.gutter).padding(.vertical, 20)
        }
        .page()
        .navigationTitle("Band tests")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: ready) { _, _ in tests.interrupted() }
        .onChange(of: haptics?.value) { _, value in
            if firstHaptics < 0, let value { firstHaptics = Int(value) }
        }
    }

    /// The band's `haptics` setting: choose a value, do a gesture to feel whether the band still
    /// buzzes by itself, then send a pulse to check that ours still plays.
    @ViewBuilder private var ownBuzz: some View {
        if let setting = haptics, let value = setting.value, setting.writable {
            let range = setting.range.map { $0.lowerBound...min($0.upperBound, $0.lowerBound + 7) } ?? 0...3
            PanelGroup("The band's own buzz", caption: "This is kept on the band until it is changed again. It was \(firstHaptics < 0 ? Int(value) : firstHaptics) when first read: choose that to put it back. After each change, do a gesture and feel whether the band buzzes by itself, then send a pulse.") {
                ValueRow("haptics") { Text("\(value)").monospacedDigit() }
                Rule()
                ChipRow(selection: Binding(get: { value }, set: { chosen in
                    guard chosen != value else { return }
                    tests.startWriting(); controller.writeNamedSetting(setting, value: chosen)
                }), options: Array(range)) { String($0) }
                .padding(.vertical, 12)
                .disabled(!ready || tests.busy)
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

    private func lines(_ text: String) -> some View {
        Text(text).font(.code).foregroundStyle(Color.muted).textSelection(.enabled)
            .padding(.horizontal, Metric.inset).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
