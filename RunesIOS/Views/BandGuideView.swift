import SwiftUI

/// What the band's light is doing on the guide's stage.
enum BandLight: Equatable {
    /// Resting: the band is on and its light is dark.
    case dark
    /// A short press: the charge, as green, orange or blinking orange.
    case charge(Double)
    case waking
    /// Slow white flash, with a buzz.
    case turningOn
    /// Quick white flash.
    case pairing
    /// Goes dark, with a buzz.
    case turningOff

    /// What a press of `seconds` does, following Meta's instructions for the band.
    static func after(hold seconds: Double, charge: Double) -> BandLight {
        switch seconds {
        case ..<1: .charge(charge)
        case ..<2: .waking
        case ..<3: .turningOn
        case ..<8: .pairing
        default: .turningOff
        }
    }

    var title: String {
        switch self {
        case .dark: "Try the button"
        case .charge(let level): level > 0.8 ? "Green: over 80%" : level >= 0.2 ? "Orange: 20% to 80%" : "Blinking orange: under 20%"
        case .waking: "1 second: wake"
        case .turningOn: "2 seconds: on"
        case .pairing: "3 seconds: pairing"
        case .turningOff: "8 seconds: off"
        }
    }
    var detail: String {
        switch self {
        case .dark: "Press and hold below, the way you would hold the band’s button."
        case .charge: "A short press shows the charge. So does putting the band on its charger."
        case .waking: "The band switches itself off after an hour without movement. This wakes it."
        case .turningOn: "The light flashes white slowly and the band buzzes."
        case .pairing: "The light flashes white quickly. The band is ready to be set up."
        case .turningOff: "Let go when the light goes dark and the band buzzes."
        }
    }
    var buzzes: Bool { self == .turningOn || self == .turningOff }
}

/// An optional guide to the band itself. The top is a stage: one large bead standing in for
/// the band's light, a button to hold like the band's own, and a charge to drag. Below it,
/// how to wear the band and how to charge it. Timings and colours follow Meta's published
/// instructions for the band.
struct BandGuidePage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var light = BandLight.dark
    @State private var since = Date()
    @State private var holdingSince: Date?
    @State private var charge = 0.65

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                stage
                PanelGroup("The light", caption: "Drag to see the light at any charge. On the band it shows when you press the button, or put it on or take it off its charger.") {
                    VStack(spacing: 6) {
                        HStack {
                            Text("Charge").font(.bodyText)
                            Spacer()
                            Text("\(Int(charge * 100))%").font(.bodyText).monospacedDigit().foregroundStyle(Color.muted)
                        }
                        Slider(value: $charge, in: 0.02...1).tint(Color.ink).accessibilityLabel("Charge")
                            .onChange(of: charge) { _, level in show(.charge(level)) }
                    }
                    .padding(.horizontal, Metric.inset).padding(.vertical, 10)
                    Rule()
                    GuideRow("Green", "More than 80% charged.", light: .steady(.green))
                    Rule()
                    GuideRow("Orange", "Between 20% and 80%.", light: .steady(.orange))
                    Rule()
                    GuideRow("Orange, blinking", "Under 20%. Charge it soon.", light: .blinking(.orange))
                    Rule()
                    GuideRow("White, flashing", "Turning on, or ready to pair.", light: .blinking(.white))
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Wearing it").padding(.leading, 2)
                    // The wrist page's own drawing, still: the beads sit where the band goes.
                    WristArtwork(state: WristFrame(handBlend: 0), confirmed: true, moving: false, entrance: 1, focus: 1)
                        .padding(.vertical, -28)
                    VStack(spacing: 0) {
                        GuideRow("On the hand you write with")
                        Rule()
                        GuideRow("The line on the band faces you", "The thicker part sits on top of your wrist.")
                        Rule()
                        GuideRow("Just past your wrist bone", "Snug and comfortable, with the clasp closed.")
                        Rule()
                        GuideRow("Rest your hand", "Gestures work with your arm at your side or in your lap. You don’t need to hold it out.")
                    }
                    .panel()
                }
                PanelGroup("Charging") {
                    GuideRow("Clip the charger under the band", "It attaches to the thicker part. The light comes on while it charges.")
                    Rule()
                    GuideRow("Plug into a wall adapter", "The USB-C port on a glasses case won’t charge the band.")
                }
                PanelGroup("If it won’t connect") {
                    GuideRow("Restart the band", "Hold for 8 seconds to turn it off, then 2 seconds to turn it on. A press that only shows green or orange is a battery check, not a restart.")
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

    private func show(_ next: BandLight) {
        light = next; since = Date()
    }

    // MARK: Stage

    /// The inverted panel: the band's light as one large bead, what it means, and the button.
    private var stage: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion && holdingSince == nil)) { context in
                let held = holdingSince.map { context.date.timeIntervalSince($0) }
                let showing = held.map { BandLight.after(hold: $0, charge: charge) } ?? light
                VStack(alignment: .leading, spacing: 0) {
                    BeadStage(light: showing, age: held == nil ? context.date.timeIntervalSince(since) : 0,
                              time: context.date.timeIntervalSinceReferenceDate, still: reduceMotion)
                        .frame(height: 190)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(held.map { String(format: "%.1f s", min($0, 9.9)) + " · " + showing.title } ?? showing.title)
                            .font(.heading).monospacedDigit()
                        Text(showing.detail).font(.caption).opacity(0.7).fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: 34, alignment: .top)
                    }
                    .padding(.horizontal, 16)
                    HoldTrack(held: held).padding(.horizontal, 16).padding(.top, 14)
                }
            }
            Text(holdingSince == nil ? "Press and hold" : "Let go to see what it does")
                .font(.label)
                .frame(maxWidth: .infinity, minHeight: Metric.row)
                .foregroundStyle(holdingSince == nil ? Color.ink : Color.paper)
                .background(holdingSince == nil ? Color.paper : Color.paper.opacity(0.18), in: RoundedRectangle(cornerRadius: Metric.control))
                .padding(16)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if holdingSince == nil { holdingSince = Date() } }
                    .onEnded { _ in
                        guard let start = holdingSince else { return }
                        holdingSince = nil
                        show(.after(hold: Date().timeIntervalSince(start), charge: charge))
                    })
                .sensoryFeedback(.impact(weight: .medium), trigger: holdingSince == nil)
                .accessibilityLabel("Hold to see what the band’s button does")
                .accessibilityAddTraits(.isButton)
        }
        .foregroundStyle(Color.paper)
        .background(Color.ink, in: RoundedRectangle(cornerRadius: Metric.panel))
        // The stage is always dark so a white light reads as white in either appearance.
        .environment(\.colorScheme, .light)
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

/// One of the band's beads, large, carrying its light. It floats over a small shadow; a
/// flashing light lifts and drops it, and a buzz sends ripples out across the floor.
private struct BeadStage: View {
    let light: BandLight
    /// Seconds this light has been showing.
    let age: Double
    let time: Double
    let still: Bool

    private var colour: Color {
        switch light {
        case .charge(let level): level > 0.8 ? .green : .orange
        case .dark, .turningOff: .clear
        default: .white
        }
    }
    /// 0…1 brightness right now.
    private var glow: Double {
        func flash(_ hertz: Double) -> Double { still ? 1 : 0.5 + 0.5 * sin(time * 2 * .pi * hertz) }
        switch light {
        case .dark, .turningOff: return 0
        case .charge(let level): return level < 0.2 ? (still ? 1 : (sin(time * 2 * .pi * 1.6) > 0 ? 1 : 0.08)) : 1
        case .waking: return min(1, age / 0.4)
        case .turningOn: return flash(0.8)
        case .pairing: return flash(3)
        }
    }

    var body: some View {
        Canvas { canvas, size in
            let floor = size.height - 34, radius = 36.0
            // The bead rides its light: up as it brightens, down as it dims.
            let float = still ? 0 : 5 * sin(time * 1.7) + 7 * glow
            let centre = CGPoint(x: size.width / 2, y: floor - radius - 16 - float)

            if light.buzzes, !still {
                for ring in 0..<3 {
                    let spread = (age - Double(ring) * 0.16) / 0.9
                    guard spread > 0, spread < 1 else { continue }
                    let width = radius * (1.3 + spread * 3.4)
                    canvas.stroke(Path(ellipseIn: CGRect(x: centre.x - width, y: floor - width * 0.2, width: width * 2, height: width * 0.4)),
                                  with: .color(.paper.opacity((1 - spread) * 0.55)), lineWidth: 1)
                }
            }
            let shadow = radius * (0.95 - float / 60)
            canvas.fill(Path(ellipseIn: CGRect(x: centre.x - shadow, y: floor - shadow * 0.18, width: shadow * 2, height: shadow * 0.36)),
                        with: .color(.paper.opacity(0.14)))

            if glow > 0.02 {
                for halo in 1...4 {
                    let reach = radius + Double(halo) * 9
                    canvas.fill(Path(ellipseIn: CGRect(x: centre.x - reach, y: centre.y - reach, width: reach * 2, height: reach * 2)),
                                with: .color(colour.opacity(0.07 * glow)))
                }
            }
            let body = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            canvas.fill(Path(ellipseIn: body), with: .color(.ink))
            canvas.stroke(Path(ellipseIn: body), with: .color(.paper.opacity(0.85)), lineWidth: 1.25)
            let dot = body.insetBy(dx: radius * 0.62, dy: radius * 0.62).offsetBy(dx: 0, dy: -radius * 0.08)
            if glow <= 0.02 {
                canvas.stroke(Path(ellipseIn: dot), with: .color(.paper.opacity(0.35)), lineWidth: 1)
            } else {
                canvas.fill(Path(ellipseIn: dot), with: .color(colour.opacity(0.15 + 0.85 * glow)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// How long the button has been held, against the four holds that mean something.
private struct HoldTrack: View {
    let held: Double?
    private static let marks: [(Double, String)] = [(1, "Wake"), (2, "On"), (3, "Pair"), (8, "Off")]
    private static let span = 9.0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.paper.opacity(0.25)).frame(height: Metric.hairline).offset(y: 5)
                Rectangle().fill(Color.paper).frame(width: width * min(1, (held ?? 0) / Self.span), height: 3).offset(y: 4)
                ForEach(Self.marks, id: \.0) { seconds, name in
                    let reached = (held ?? 0) >= seconds
                    VStack(spacing: 4) {
                        Rectangle().fill(Color.paper.opacity(reached ? 1 : 0.5)).frame(width: Metric.hairline, height: 11)
                        Text(name).font(.caption).opacity(reached ? 1 : 0.55)
                        Text("\(Int(seconds)) s").font(.caption).monospacedDigit().opacity(0.4)
                    }
                    .frame(width: 44)
                    .position(x: width * seconds / Self.span, y: 28)
                }
            }
        }
        .frame(height: 56)
        .accessibilityHidden(true)
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
        HStack(alignment: .center, spacing: 12) {
            if let light { BeadLight(light: light) }
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
}

/// The band's light as a small dark bead in the light's own colour: the one place the app
/// shows colour. A blinking light flashes and the bead rises and falls with it; with Reduce
/// Motion it is a still ring.
private struct BeadLight: View {
    let light: GuideRow.Light
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = true

    var body: some View {
        ZStack {
            Circle().fill(Color.black)
            Circle().strokeBorder(Color.faint, lineWidth: Metric.hairline)
            switch light {
            case .steady(let colour):
                Circle().fill(colour).frame(width: 9, height: 9)
            case .blinking(let colour):
                if reduceMotion {
                    Circle().strokeBorder(colour, lineWidth: 2).frame(width: 10, height: 10)
                } else {
                    Circle().fill(colour).frame(width: 9, height: 9).opacity(lit ? 1 : 0.1)
                }
            }
        }
        .frame(width: 24, height: 24)
        .offset(y: blinks && !reduceMotion ? (lit ? -3 : 3) : 0)
        .animation(blinks && !reduceMotion ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : nil, value: lit)
        .onAppear { if blinks { lit = false } }
        .accessibilityHidden(true)
    }

    private var blinks: Bool {
        if case .blinking = light { return true }
        return false
    }
}
