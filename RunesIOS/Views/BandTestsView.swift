import SwiftUI

/// What the band tests have found so far, kept while the app runs.
@MainActor
final class BandTests: ObservableObject {
    static let shared = BandTests()

    /// The band's settings as it last reported them, and its answer to the last of its own patterns.
    @Published var settings: String?
    @Published var patternAnswer: String?
    /// The named settings read so far, a line each, and whether the read is still going.
    @Published private(set) var named: [String] = []
    @Published private(set) var reading = false

    func startReading() { named = []; reading = true }
    /// A line of the read as it arrives; nil ends it.
    func named(_ line: String?) {
        guard let line else { reading = false; return }
        named.append(line)
    }
}

/// Tests that find out what the band does and can be told, one question to a group. The
/// first question is the buzz the band gives by itself when it hears a gesture: which of
/// its settings is behind it. Everything here reads or plays; nothing changes a setting.
struct BandTestsScreen: View {
    @ObservedObject private var tests = BandTests.shared
    @ObservedObject private var controller = SessionController.shared
    @State private var copied = false

    private var ready: Bool { controller.snapshot.state == .streaming }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !ready {
                    Text("Connect the band to run these.").font(.bodyText).foregroundStyle(Color.muted)
                }
                PanelGroup("The band's own patterns", caption: tests.patternAnswer ?? "The band keeps these itself. Play each and compare it with the buzz you feel when it hears a gesture.") {
                    ActionRow("Play pattern 1") { controller.performBandPattern(1) }
                    Rule()
                    ActionRow("Play pattern 2") { controller.performBandPattern(2) }
                }
                .disabled(!ready)
                PanelGroup("Named settings", caption: "Asks the band for every setting it can name and reads each one. Takes a few seconds.") {
                    ActionRow(tests.reading ? "Reading…" : "Read named settings") {
                        tests.startReading(); controller.readNamedSettings()
                    }
                    .disabled(!ready || tests.reading)
                    if !tests.named.isEmpty {
                        Rule()
                        lines(tests.named.joined(separator: "\n"))
                    }
                }
                PanelGroup("Settings read on connecting", caption: "The band sends these when it connects.") {
                    lines(tests.settings ?? "Not read yet.")
                }
                PanelGroup(nil, caption: "Copies everything above as text.") {
                    ActionRow(copied ? "Copied" : "Copy results", icon: copied ? .check : .clipboardCopy) {
                        UIPasteboard.general.string = ([tests.patternAnswer, tests.settings] + tests.named).compactMap { $0 }.joined(separator: "\n")
                        copied = true
                    }
                }
            }
            .padding(.horizontal, Metric.gutter).padding(.vertical, 20)
        }
        .page()
        .navigationTitle("Band tests")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func lines(_ text: String) -> some View {
        Text(text).font(.code).foregroundStyle(Color.muted).textSelection(.enabled)
            .padding(.horizontal, Metric.inset).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
