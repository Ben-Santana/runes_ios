import SwiftUI

/// An optional guide to the band itself: how to wear it, what its button does and what its
/// light means. The steps and timings follow Meta's published instructions for the band.
struct BandGuidePage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // The wrist page's own drawing, still: the beads sit where the band goes.
                WristArtwork(state: WristFrame(handBlend: 0), confirmed: true, moving: false, entrance: 1, focus: 1)
                    .padding(.vertical, -24)
                PanelGroup("Wearing it") {
                    GuideRow("On the hand you write with")
                    Rule()
                    GuideRow("The line on the band faces you", "The thicker part sits on top of your wrist.")
                    Rule()
                    GuideRow("Just past your wrist bone", "Snug and comfortable, with the clasp closed.")
                    Rule()
                    GuideRow("Rest your hand", "Gestures work with your arm at your side or in your lap. You don’t need to hold it out.")
                }
                PanelGroup("The button") {
                    GuideRow("Turn on", "Hold for 2 seconds. The light flashes white slowly and the band buzzes.")
                    Rule()
                    GuideRow("Turn off", "Hold for 8 seconds. Let go when the light goes dark and the band buzzes.")
                    Rule()
                    GuideRow("Wake", "After an hour without movement the band switches itself off. Hold for 1 second to wake it.")
                    Rule()
                    GuideRow("Pairing mode", "Hold for 3 seconds until the light flashes white.")
                    Rule()
                    GuideRow("Check the battery", "Press once. The light shows the charge.")
                }
                PanelGroup("The light", caption: "The charge shows when you press the button, or put the band on or take it off its charger.") {
                    GuideRow("Green", "More than 80% charged.", light: .steady(.green))
                    Rule()
                    GuideRow("Orange", "Between 20% and 80%.", light: .steady(.orange))
                    Rule()
                    GuideRow("Orange, blinking", "Under 20%. Charge it soon.", light: .blinking(.orange))
                    Rule()
                    GuideRow("White, flashing", "Turning on, or ready to pair.", light: .blinking(.ink))
                }
                PanelGroup("Charging") {
                    GuideRow("Clip the charger under the band", "It attaches to the thicker part. The light comes on while it charges.")
                    Rule()
                    GuideRow("Plug into a wall adapter", "The USB-C port on a glasses case won’t charge the band.")
                }
                PanelGroup("If it won’t connect") {
                    GuideRow("Restart the band", "Turn it off, then on again. A press that only shows green or orange is a battery check, not a restart.")
                    Rule()
                    GuideRow("Then try again", "Runes retries by itself once the band is back.")
                }
            }
            .padding(Metric.gutter)
        }
        .background(Color.paper)
        .navigationTitle("Your band")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The guide as a sheet, for onboarding.
struct BandGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            BandGuidePage()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
        }
        .tint(Color.ink)
    }
}

/// One line of the guide: what, a sentence of how, and the band's light when that helps.
struct GuideRow: View {
    enum Light {
        case steady(Color), blinking(Color)
    }
    let title: String
    var detail: String?
    var light: Light?

    init(_ title: String, _ detail: String? = nil, light: Light? = nil) {
        self.title = title; self.detail = detail; self.light = light
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let light { dot(light).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 } }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.bodyText)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.inset).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: Metric.rowDense, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The band's light drawn as one of its beads, in the light's own colour: the one place
    /// the app shows colour. A blinking light pulses; Reduce Motion shows it as a ring.
    private func dot(_ light: Light) -> some View {
        BeadLight(light: light)
    }
}

private struct BeadLight: View {
    let light: GuideRow.Light
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = true

    var body: some View {
        ZStack {
            Circle().fill(Color.paper)
            Circle().strokeBorder(Color.ink.opacity(0.7), lineWidth: Metric.hairline)
            switch light {
            case .steady(let colour):
                Circle().fill(colour).frame(width: 8, height: 8)
            case .blinking(let colour):
                if reduceMotion {
                    Circle().strokeBorder(colour, lineWidth: 2).frame(width: 9, height: 9)
                } else {
                    Circle().fill(colour).frame(width: 8, height: 8).opacity(lit ? 1 : 0.12)
                        .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: lit)
                        .onAppear { lit = false }
                }
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
