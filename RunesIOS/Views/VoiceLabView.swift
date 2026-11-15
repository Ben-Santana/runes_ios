import SwiftUI

/// Settings → Developer → Runes lab. The app's soft voice, to tune by ear: write a line,
/// pick a voice, move pace and pitch, and switch the softening off to hear what it does.
/// Only Premium voices are offered; the rest sound robotic.
struct VoiceLabScreen: View {
    @StateObject private var voice = SoftVoice()
    @State private var text = "Hello. I'm here whenever you need me. Take your time… there's no rush at all."
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Something to say", text: $text, axis: .vertical)
                        .font(.bodyText).lineLimit(3...8)
                        .padding(Metric.inset).panel()
                    Button(voice.speaking ? "Stop" : "Speak") {
                        voice.speaking ? voice.stop() : voice.speak(text)
                    }
                    .buttonStyle(.primary)
                    .disabled(!voice.speaking && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                PanelGroup("Tuning") {
                    slider("Pace", value: $voice.pace, low: "Slower", high: "Quicker")
                    Rule()
                    slider("Pitch", value: $voice.pitch, low: "Lower", high: "Higher")
                    Rule()
                    Toggle(isOn: $voice.softening) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Softening").font(.bodyText)
                            Text("Takes the hiss and edge off, adds warmth and a little room.").font(.caption).foregroundStyle(Color.muted)
                        }
                    }
                    .toggleStyle(HairlineSwitch())
                    .padding(.horizontal, Metric.inset).padding(.vertical, 10)
                    .onChange(of: voice.softening) { voice.shapeFilter() }
                    Rule()
                    ActionRow("Reset tuning", icon: .rotateCcw) { voice.pace = 0.5; voice.pitch = 0.5; voice.softening = true }
                }

                PanelGroup("Voice", caption: "Only Premium voices show here. To add one: Accessibility › Read & Speak › Voices, pick a language, then download a voice marked Premium.") {
                    if voice.options.isEmpty {
                        Text("No Premium voice is downloaded yet.").font(.bodyText).foregroundStyle(Color.muted).panelRow()
                        Rule()
                    }
                    ForEach(voice.options) { option in
                        Button {
                            voice.voiceID = option.id
                            voice.speak(text)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.name).font(.bodyText)
                                    Text(Locale.current.localizedString(forIdentifier: option.language) ?? option.language)
                                        .font(.caption).foregroundStyle(Color.muted)
                                }
                                Spacer()
                                if option.id == voice.voiceID { LucideIcon(.check, size: 16) }
                            }
                            .panelRow(height: Metric.rowTall)
                        }
                        .buttonStyle(PressRow())
                        Rule()
                    }
                    ActionRow("Download voices in Settings", icon: .arrowRight) { openVoiceSettings() }
                }
            }
            .padding(Metric.gutter)
        }
        .page()
        .navigationTitle("Runes lab").navigationBarTitleDisplayMode(.inline)
        .onDisappear { voice.stop() }
        // Voices downloaded in Settings appear on return.
        .onChange(of: phase) { _, now in if now == .active { voice.reload() } }
    }

    /// The voices page itself has no public link. This undocumented one opens Accessibility
    /// › Read & Speak where the system honours it, and Settings otherwise.
    private func openVoiceSettings() {
        let deep = URL(string: "App-prefs:ACCESSIBILITY&path=SPEECH_TITLE")!
        openURL(deep) { opened in
            if !opened, let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, low: String, high: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.bodyText)
            Slider(value: value, in: 0...1)
            HStack { Text(low); Spacer(); Text(high) }.font(.caption).foregroundStyle(Color.muted)
        }
        .padding(.horizontal, Metric.inset).padding(.vertical, 12)
    }
}

#if DEBUG
#Preview { NavigationStack { VoiceLabScreen() } }
#endif
