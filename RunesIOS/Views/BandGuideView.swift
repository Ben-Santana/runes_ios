import SwiftUI

/// The lessons of the band guide, in order. Timings and colours follow Meta's published
/// instructions for the band.
private enum Plate: Int, CaseIterable {
    case meet, wear, gestures, light, button, charging

    var title: String {
        switch self {
        case .meet: "Meet your band"
        case .wear: "Where it sits"
        case .gestures: "Your fingers do the talking"
        case .light: "It answers in light"
        case .button: "One button, four holds"
        case .charging: "Charging up"
        }
    }
    var message: String {
        switch self {
        case .meet: "Eight sensors that pick up the tiny signals in your wrist when your fingers move."
        case .wear: "On the hand you write with, just past the wrist bone. Line facing you, snug like a watch."
        case .gestures: "Tap, hold or swipe a finger on your thumb. Your hand can stay relaxed at your side."
        case .light: "Press the button once and the light shows how much charge is left."
        case .button: "Hold it a little or a lot. How long you hold decides what it does."
        case .charging: "The charger clips on underneath. Plug it into the wall, not a glasses case."
        }
    }
    /// What the picture adds, for VoiceOver.
    var spoken: String {
        switch self {
        case .meet, .wear, .charging: ""
        case .gestures: Self.moves.map(\.name).joined(separator: ", ") + "."
        case .light: "Green: over 80%. Orange: 20 to 80%. Blinking orange: under 20%. Flashing white: turning on, or ready to pair."
        case .button: Self.holds.map { "\($0.name): \(Int($0.seconds)) seconds" }.joined(separator: ". ") + "."
        }
    }

    static let holds: [(seconds: Double, name: String)] = [(1, "Wake"), (2, "On"), (3, "Pair"), (8, "Off")]
    /// Each gesture: the finger that makes it (0 index, 1 middle), and whether it taps twice or stays down.
    static let moves: [(name: String, finger: Int, twice: Bool, held: Bool)] =
        [("Tap index", 0, false, false), ("Tap middle", 1, false, false), ("Double tap", 0, true, false), ("Hold", 1, false, true)]
    /// The band's light: its own colour, how fast it blinks if it does, and what it means.
    static let lights: [(colour: Color, blink: Double?, name: String)] =
        [(.green, nil, "Over 80%"), (.orange, nil, "20 to 80%"), (.orange, 1.6, "Under 20%"), (.white, 1.1, "On, or pairing")]
}

/// An optional guide to the band, told by its own eight beads. Each plate is one lesson;
/// swiping moves the same beads into the next shape.
struct BandGuidePage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var page: Int? = 0
    /// Where the beads are headed and when they set off. They travel at their own pace, a little
    /// behind the page, so each change of arrangement can be watched.
    @State private var travel = (from: 0.0, to: 0.0, since: 0.0)
    /// When the beads last set off for each plate, so its lesson starts from the beginning.
    @State private var entered = Array(repeating: Date().timeIntervalSinceReferenceDate, count: Plate.allCases.count)

    private var current: Int { page ?? 0 }
    /// Seconds the beads take to cross from one plate to the next.
    private static let tempo = 0.6
    /// Where the beads are between plates at a moment in time.
    private func place(at time: Double) -> Double {
        let distance = abs(travel.to - travel.from)
        guard !reduceMotion, distance > 0 else { return travel.to }
        return travel.from + (travel.to - travel.from) * min(1, max(0, (time - travel.since) / (Self.tempo * distance)))
    }
    private var isLast: Bool { current == Plate.allCases.count - 1 }

    var body: some View {
        GeometryReader { geometry in
            // The picture gives way on short screens so the words always have room.
            let stage = min(BeadTheatre.designHeight, max(180, geometry.size.height - 260))
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(Plate.allCases, id: \.rawValue) { plate in
                                VStack(alignment: .leading, spacing: 10) {
                                    Color.clear.frame(height: stage)
                                    Text(plate.title).font(.display).tracking(-0.6).fixedSize(horizontal: false, vertical: true)
                                    Text(plate.message).font(.bodyText).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, Metric.gutter)
                                .frame(width: geometry.size.width, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture(perform: advance)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel([plate.title, plate.message, plate.spoken].filter { !$0.isEmpty }.joined(separator: " "))
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $page)
                    .scrollIndicators(.hidden)
                    .onChange(of: page) { _, new in
                        // Each lesson starts from its beginning as the beads set off for it.
                        let now = Date().timeIntervalSinceReferenceDate, target = new ?? 0
                        travel = (place(at: now), Double(target), now)
                        entered[target] = now
                    }
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || scenePhase != .active)) { context in
                        BeadTheatre(position: place(at: context.date.timeIntervalSinceReferenceDate), time: context.date.timeIntervalSinceReferenceDate, entered: entered, still: reduceMotion)
                    }
                    .frame(height: stage)
                    .allowsHitTesting(false)
                }
                HStack(spacing: 6) {
                    ForEach(Plate.allCases, id: \.rawValue) { plate in
                        Capsule().fill(plate.rawValue == current ? Color.ink : Color.faint)
                            .frame(width: plate.rawValue == current ? 16 : 6, height: 6)
                    }
                }
                .animation(.standard, value: current)
                .padding(.bottom, 16)
                .accessibilityElement().accessibilityLabel("Page \(current + 1) of \(Plate.allCases.count)")
                Button(isLast ? "Done" : "Next") { if isLast { dismiss() } else { advance() } }
                    .buttonStyle(.primary)
                    .padding(.horizontal, Metric.gutter).padding(.bottom, 12)
            }
        }
        .page()
        .navigationTitle("Your band")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func advance() {
        guard !isLast else { return }
        withAnimation(reduceMotion ? nil : .entrance) { page = current + 1 }
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
    }
}

/// The brand hand drawn large, carrying on into a forearm. Its fingers are Lucide's, a little
/// longer: four columns with round tips, each placed by the centre of its tip, so a finger can dip.
private enum GuideHand {
    static let scale = 7.6, top = 26.0, wristX = 13.6
    static let rest = [5.0, 3, 5, 7.3]
    /// The heel of the hand and the forearm; then the edge of the palm that the thumb lies over, and the wrist.
    static let sides = ["M22 14C22 17.6 20.9 20 19.6 21.8C18.9 22.8 18.6 23.8 18.6 25C18.6 28 18.8 31.5 19.2 35.5",
                        "M6 14C5.7 16 5.7 18.3 6.01 19.66C7.4 21 8.2 22.6 8.2 24.5C8.2 27.5 7.9 31 7.4 35.5"].map(SVGPath.cached)
    /// The thumb at rest: where it joins the hand, its direction in degrees and its length.
    static let thumbRest = (root: CGPoint(x: 7.72, y: 18.54), turn: 225.0, reach: 5.5)
    /// For a press of the index or the middle finger: how far down its knuckle comes as it
    /// folds, where its tip ends up in front of the palm, and the thumb reaching over to meet it.
    /// The thumb's root rolls in over the palm, and it shortens as it points toward you.
    static let pinch: [(knuckle: Double, finger: CGPoint, thumb: (root: CGPoint, turn: Double, reach: Double))] =
        [(7.4, CGPoint(x: 8.5, y: 10.9), (CGPoint(x: 9.4, y: 18.2), 269, 4.3)),
         (6.4, CGPoint(x: 11.7, y: 10.6), (CGPoint(x: 9.6, y: 18.2), 288, 4.7))]

    /// A rounded limb from one point to another, which may widen as it comes toward you.
    static func limb(from start: CGPoint, to end: CGPoint, radii: (Double, Double)) -> Path {
        let length = max(0.001, hypot(end.x - start.x, end.y - start.y))
        let across = CGPoint(x: -(end.y - start.y) / length, y: (end.x - start.x) / length)
        let turn = Angle(radians: atan2(end.y - start.y, end.x - start.x))
        var path = Path()
        path.move(to: CGPoint(x: start.x + across.x * radii.0, y: start.y + across.y * radii.0))
        path.addLine(to: CGPoint(x: end.x + across.x * radii.1, y: end.y + across.y * radii.1))
        path.addArc(center: end, radius: radii.1, startAngle: turn + .degrees(90), endAngle: turn - .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: start.x - across.x * radii.0, y: start.y - across.y * radii.0))
        path.addArc(center: start, radius: radii.0, startAngle: turn - .degrees(90), endAngle: turn - .degrees(270), clockwise: true)
        path.closeSubpath()
        return path
    }

    /// The thumb on its way to meet a finger, from 0 at rest to 1 touching: its outline, open
    /// where it joins the hand; the shape it covers; its tip; and the stretch along it, from
    /// its root, over which its outline softens into the palm once it has left the palm's edge.
    static func thumb(meeting finger: Int, by swing: Double) -> (outline: Path, cover: Path, tip: CGPoint, soften: (from: CGPoint, to: CGPoint)) {
        let target = pinch[finger].thumb
        func mix(_ rest: Double, _ met: Double) -> Double { rest + (met - rest) * swing }
        let root = CGPoint(x: mix(thumbRest.root.x, target.root.x), y: mix(thumbRest.root.y, target.root.y))
        let turn = Angle(degrees: mix(thumbRest.turn, target.turn)), reach = mix(thumbRest.reach, target.reach), radius = mix(2, 2.25)
        let along = CGPoint(x: cos(turn.radians), y: sin(turn.radians))
        /// A point `distance` along the thumb from its root, on its near (+1) or far (-1) edge, or down its middle (0).
        func edge(_ distance: Double, _ side: Double) -> CGPoint {
            CGPoint(x: root.x + along.x * distance - along.y * side * radius, y: root.y + along.y * distance + along.x * side * radius)
        }
        func shape(from start: CGPoint, to end: CGPoint) -> Path {
            var path = Path()
            path.move(to: start); path.addLine(to: edge(reach, 1))
            path.addArc(center: edge(reach, 0), radius: radius, startAngle: turn + .degrees(90), endAngle: turn - .degrees(90), clockwise: true)
            path.addLine(to: end)
            return path
        }
        var cover = shape(from: edge(0, 1), to: edge(0, -1))
        cover.closeSubpath()
        return (shape(from: edge(mix(3, 0.42), 1), to: edge(0.42, -1)), cover, edge(reach, 0), (edge(0.42, 0), edge(2.6, 0)))
    }

    /// The lines of the palm.
    static let contours = ["M8.7 15.1c2 .3 3 1.6 3.2 3.7", "M11.1 13.9c2.1-.8 4.7-.8 6.7-.1"].map(SVGPath.cached)

    /// The fingertips from the thumb side across to the little finger, with the lines between the fingers.
    static func fingers(_ tips: [Double], dividers: Bool = true) -> Path {
        let knuckles = [10.5, 10, 11]
        var path = Path()
        path.move(to: CGPoint(x: 6, y: 14)); path.addLine(to: CGPoint(x: 6, y: tips[0]))
        for finger in 0..<4 {
            let x = 6 + 4 * Double(finger)
            path.addArc(center: CGPoint(x: x + 2, y: tips[finger]), radius: 2, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            guard finger < 3 else { break }
            let next = tips[finger + 1], low = max(tips[finger], next)
            if dividers {
                path.move(to: CGPoint(x: x + 4, y: min(tips[finger], next)))
                path.addLine(to: CGPoint(x: x + 4, y: max(knuckles[finger], low + 1)))
                path.move(to: CGPoint(x: x + 4, y: next))
            } else {
                path.addLine(to: CGPoint(x: x + 4, y: next))
            }
        }
        path.addLine(to: CGPoint(x: 22, y: 14))
        return path
    }

}

/// Eight beads acting out the guide. `position` is the page, fractional while swiping: the
/// beads hop from each plate's arrangement to the next, and every plate adds a few strokes
/// of its own. Reduce Motion shows each plate still, with everything it teaches in view.
private struct BeadTheatre: View {
    /// The drawing is laid out at this height and scaled to fit.
    static let designHeight: CGFloat = 330
    let position: Double
    let time: Double
    let entered: [Double]
    let still: Bool

    private struct Bead {
        var x = 0.0, y = 0.0, radius = 0.0
        var opacity = 1.0
        /// 0 is the app's hairline bead; 1 is a dark bead, the body of a light.
        var dark = 0.0
        /// How full the centre is, 0…1.
        var charge = 0.0
        var light: Color?
        var depth = 0.0
        /// Strength of its floor shadow, and how far above the floor it rides.
        var shadow = 0.0, lift = 0.0
        /// 1 is a bead filled with ink.
        var full = 0.0

        func mixed(with other: Bead, by f: Double) -> Bead {
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * f }
            return Bead(x: mix(x, other.x), y: mix(y, other.y), radius: mix(radius, other.radius),
                        opacity: mix(opacity, other.opacity), dark: mix(dark, other.dark), charge: mix(charge, other.charge),
                        light: f < 0.5 ? light : other.light, depth: mix(depth, other.depth),
                        shadow: mix(shadow, other.shadow), lift: mix(lift, other.lift), full: mix(full, other.full))
        }
    }

    private static let ringScale = 1.55
    /// Where the band sits, just past the wrist bone.
    private static let wristY = GuideHand.top + 26.2 * GuideHand.scale
    /// How far out the band's side beads sit, how far above the band the wrist bone is, and how
    /// far below it the forearm has faded out.
    private static let bandReach = 43.0, boneRise = 23.0, armEnd = 71.0
    private static let columnWidth = 78.0
    private static let rowY = 150.0
    /// Seconds each gesture, light and lap of the loops below is shown.
    private static let gestureBeat = 1.35, lightBeat = 2.2, chargeLoop = 6.0

    var body: some View {
        Canvas { canvas, size in
            let scale = size.height / Self.designHeight
            canvas.scaleBy(x: scale, y: scale)
            let width = size.width / scale, centre = width / 2
            let last = Plate.allCases.count - 1
            let clamped = min(Double(last), max(0, position))
            let from = Int(clamped), fraction = clamped - Double(from)
            func weight(_ plate: Plate) -> Double { let w = max(0, 1 - abs(clamped - Double(plate.rawValue))); return w * w }

            let leaving = beads(for: Plate(rawValue: from)!, centre: centre)
            let arriving = beads(for: Plate(rawValue: min(last, from + 1))!, centre: centre)
            let stage = zip(leaving, arriving).enumerated().map { index, pair -> Bead in
                // Each bead sets off a beat after the one before and hops rather than slides.
                let own = min(1, max(0, fraction * 1.5 - Double(index) * 0.07))
                let glide = own * own * (3 - 2 * own), hop = sin(.pi * glide)
                var bead = pair.0.mixed(with: pair.1, by: glide)
                // A bead that is hardly moving stays down.
                let far = min(1, hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y) / 70)
                bead.lift += hop * 28 * far; bead.radius *= 1 + hop * 0.12 * far
                return bead
            }
            drawBackdrop(in: &canvas, centre: centre, weight: weight)
            for bead in stage { drawShadow(of: bead, in: &canvas) }
            for bead in stage.sorted(by: { $0.depth < $1.depth }) { draw(bead, in: &canvas) }
            drawCaptions(in: &canvas, centre: centre, weight: weight)
        }
        .accessibilityHidden(true)
    }

    // MARK: Loops

    /// Seconds since `plate` came into view.
    private func clock(_ plate: Plate) -> Double { still ? 0 : max(0, time - entered[plate.rawValue]) }
    private func column(_ index: Int, of count: Int, centre: Double) -> Double {
        centre + (Double(index) - Double(count - 1) / 2) * Self.columnWidth
    }
    /// Which gesture is showing, and how far into it.
    private var gesture: (index: Int, into: Double) {
        let beat = (clock(.gestures) / Self.gestureBeat).truncatingRemainder(dividingBy: Double(Plate.moves.count))
        return (Int(beat), beat - beat.rounded(.down))
    }
    private var move: (name: String, finger: Int, twice: Bool, held: Bool) { Plate.moves[gesture.index] }
    /// How far the finger making the gesture is pressed to the thumb, 0…1: down quickly, up gently.
    private var press: Double {
        guard !still else { return 0 }
        let into = gesture.into
        func tap(_ from: Double, _ to: Double) -> Double {
            let along = (into - from) / (to - from)
            guard along > 0, along < 1 else { return 0 }
            if along < 0.3 { return 1 - pow(1 - along / 0.3, 3) }
            let up = max(0, (along - 0.5) / 0.5)
            return 1 - up * up * (3 - 2 * up)
        }
        if move.held { return min(1, max(0, min((into - 0.1) / 0.1, (0.92 - into) / 0.1))) }
        return move.twice ? tap(0.08, 0.38) + tap(0.42, 0.72) : tap(0.12, 0.52)
    }
    /// When each press of the gesture lands, and how long its signal takes to reach the band, in beats.
    private var landings: [Double] { move.held ? [0.2] : move.twice ? [0.17, 0.51] : [0.24] }
    private static let signalTime = 0.1
    /// The signal on its way from the finger to the band while it travels, 0…1.
    private var signal: Double? {
        guard !still else { return nil }
        return landings.map { (gesture.into - $0) / Self.signalTime }.first { $0 > 0 && $0 < 1 }
    }
    /// How long ago the band last heard a press, in beats.
    private var sinceHeard: Double? {
        guard !still else { return nil }
        return landings.map { gesture.into - $0 - Self.signalTime }.filter { $0 >= 0 }.min()
    }
    private var lightIndex: Int { Int(clock(.light) / Self.lightBeat) % Plate.lights.count }
    private func glow(of light: (colour: Color, blink: Double?, name: String)) -> Double {
        guard let blink = light.blink, !still else { return 1 }
        let wave = sin(clock(.light) * 2 * .pi * blink)
        return light.colour == .white ? 0.5 + 0.5 * wave : (wave > 0 ? 1 : 0.1)
    }
    /// How far along a step of the wearing plate's arrival is, 0…1. The plate plays once as it
    /// comes into view: the wrist bone's level draws across, the band slides up to it, and the
    /// band's line draws in.
    private func arrived(_ from: Double, _ to: Double) -> Double {
        guard !still else { return 1 }
        let x = min(1, max(0, (clock(.wear) - from) / (to - from)))
        return x * x * (3 - 2 * x)
    }
    /// How far down the forearm a bead of the band still is. The front bead leads and the
    /// others follow it round, so the band settles like a string of beads.
    private func wearOffset(bead index: Int = 2) -> Double {
        guard !still else { return 0 }
        let x = max(0, clock(.wear) - 0.55 - 0.04 * abs(Double(min(index, 4)) - 2)) * 1.9
        return 28 * exp(-4 * x) * (cos(5 * x) + 0.8 * sin(5 * x))
    }
    /// The charging row fills, then rests full for a moment.
    private var chargeLevel: Double { still ? 1 : min(1, (clock(.charging) / Self.chargeLoop).truncatingRemainder(dividingBy: 1) * 1.2) }

    // MARK: Arrangements

    private func ring(centre: Double, rotation: Double, y: Double) -> [Bead] {
        (0..<8).map { index in
            let angle = Double(index) * .pi / 4 + rotation
            let x = cos(angle) * RingGeometry.radius, depth = sin(angle) * RingGeometry.radius
            let flat = RingGeometry.project(x, depth, 10)
            return Bead(x: centre + flat.x * Self.ringScale, y: y + flat.y * Self.ringScale,
                        radius: RingGeometry.ballRadius * Self.ringScale, depth: x + depth, shadow: 1, lift: 10)
        }
    }

    /// The band on the wrist: five beads show across the front and three are behind the arm.
    private func band(centre: Double, offset: (Int) -> Double = { _ in 0 }) -> [Bead] {
        (0..<8).map { index in
            let angle = Double(index) * .pi / 4, front = sin(angle)
            return Bead(x: centre + cos(angle) * Self.bandReach, y: Self.wristY + offset(index) + front * 13,
                        radius: 9 + front * 2.3, opacity: front < -0.01 ? 0 : 1, depth: front)
        }
    }

    /// The bead that lights for the gesture showing.
    private var litBead: Int { move.finger == 0 ? 3 : 2 }

    private func beads(for plate: Plate, centre: Double) -> [Bead] {
        switch plate {
        case .meet:
            let t = clock(.meet)
            return ring(centre: centre, rotation: t * 0.35, y: 175).enumerated().map { index, bead in
                var bead = bead
                bead.lift += still ? 0 : 5 + 5 * sin(t * 1.5 + Double(index) * .pi / 4)
                return bead
            }
        case .wear: return band(centre: centre) { wearOffset(bead: $0) }
        case .gestures:
            // The band stays on the wrist and answers as the signal reaches it. A tap blinks the
            // bead nearest the finger. A hold fills the band with ink, bead by bead, until it lets go.
            let since = sinceHeard, blink = since.map { exp(-$0 * 11) } ?? 0
            return band(centre: centre).enumerated().map { index, bead in
                var bead = bead
                let away = Double(abs(index - litBead))
                if move.held {
                    bead.full = since.map { min(1, max(0, ($0 - 0.03 * away) / 0.05)) * press } ?? 0
                } else {
                    bead.charge = blink * (away == 0 ? 1 : away == 1 ? 0.35 : 0)
                }
                return bead
            }
        case .light:
            // Moving: one bead is the light and the rest orbit. Still: all four lights in a row.
            if still {
                return (0..<8).map { index in
                    guard index < Plate.lights.count else { return Bead(x: centre, y: Self.rowY, opacity: 0) }
                    return Bead(x: column(index, of: Plate.lights.count, centre: centre), y: Self.rowY, radius: 20,
                                dark: 1, charge: 1, light: Plate.lights[index].colour, depth: Double(index))
                }
            }
            let light = Plate.lights[lightIndex], brightness = glow(of: light)
            return (0..<8).map { index in
                if index == 0 {
                    return Bead(x: centre, y: 165, radius: 44, dark: 1, charge: brightness, light: light.colour, depth: 10, lift: 6 * brightness)
                }
                let angle = Double(index) * 2 * .pi / 7 + clock(.light) * 0.4
                return Bead(x: centre + cos(angle) * 118, y: 165 + sin(angle) * 34, radius: 5, opacity: 0.5, depth: sin(angle))
            }
        case .button:
            return (0..<8).map { index in
                guard index < Plate.holds.count else { return Bead(x: centre, y: 286, opacity: 0) }
                return Bead(x: column(index, of: Plate.holds.count, centre: centre), y: Self.rowY, radius: 20, charge: 0.2, depth: Double(index))
            }
        case .charging:
            let level = chargeLevel
            return (0..<8).map { index in
                let filled = level * 8 > Double(index)
                return Bead(x: centre + (Double(index) - 3.5) * 38, y: 160, radius: 13, dark: filled ? 1 : 0,
                            charge: filled ? 1 : 0, light: filled ? (level > 0.8 ? .green : .orange) : nil, depth: Double(index))
            }
        }
    }

    // MARK: Drawing

    /// A soft contact shadow that spreads and fades as the bead rises off it.
    private func drawShadow(of bead: Bead, in canvas: inout GraphicsContext) {
        guard bead.shadow > 0.01, bead.opacity > 0.01 else { return }
        let spread = bead.radius * (0.8 + bead.lift / 90), floor = bead.y + bead.radius * 1.15
        canvas.fill(Path(ellipseIn: CGRect(x: bead.x - spread, y: floor - spread * 0.3, width: spread * 2, height: spread * 0.6)),
                    with: .color(.ink.opacity(0.1 * bead.shadow * bead.opacity * max(0.3, 1 - bead.lift / 70))))
    }

    private func draw(_ bead: Bead, in canvas: inout GraphicsContext) {
        guard bead.opacity > 0.01, bead.radius > 0.5 else { return }
        var layer = canvas
        layer.opacity = bead.opacity
        let body = CGRect(x: bead.x - bead.radius, y: bead.y - bead.lift - bead.radius, width: bead.radius * 2, height: bead.radius * 2)
        if let light = bead.light, bead.dark > 0.5, bead.radius > 30 {
            for halo in 1...4 {
                layer.fill(Path(ellipseIn: body.insetBy(dx: -Double(halo) * 10, dy: -Double(halo) * 10)), with: .color(light.opacity(0.06 * bead.charge)))
            }
        }
        layer.fill(Path(ellipseIn: body), with: .color(.paper))
        // A light's body is black in both appearances, so white reads as white.
        if bead.dark > 0.01 { layer.fill(Path(ellipseIn: body), with: .color(.black.opacity(bead.dark))) }
        if bead.full > 0.01 { layer.fill(Path(ellipseIn: body), with: .color(.ink.opacity(bead.full))) }
        layer.stroke(Path(ellipseIn: body), with: .color(.ink.opacity(0.75)), lineWidth: bead.radius > 30 ? 1.5 : 1)
        guard bead.charge > 0.01 else { return }
        let dot = body.insetBy(dx: bead.radius * 0.6, dy: bead.radius * 0.6).offsetBy(dx: 0, dy: -bead.radius * 0.06)
        layer.fill(Path(ellipseIn: dot), with: .color((bead.light ?? .ink).opacity(bead.charge)))
    }

    // MARK: The hand

    /// Draws the hand, then what each of its plates adds: the wrist bone and the band's line
    /// for wearing; the finger and thumb meeting, their signal and the band's answer for gestures.
    private func drawHand(in canvas: inout GraphicsContext, centre: Double, shown: Double, wear: Double, gesturing: Double) {
        let ink = Color.ink.opacity(shown), paper = Color.paper.opacity(shown), wristY = Self.wristY
        let place = CGAffineTransform(translationX: centre - GuideHand.wristX * GuideHand.scale, y: GuideHand.top).scaledBy(x: GuideHand.scale, y: GuideHand.scale)
        let fading = GraphicsContext.Shading.linearGradient(Gradient(colors: [ink, ink.opacity(0)]),
                                                            startPoint: CGPoint(x: 0, y: wristY + Self.armEnd - 30), endPoint: CGPoint(x: 0, y: wristY + Self.armEnd))
        let hairline = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        func between(_ from: CGPoint, _ to: CGPoint, _ along: Double) -> CGPoint { CGPoint(x: from.x + (to.x - from.x) * along, y: from.y + (to.y - from.y) * along) }
        // At rest the hand is flat. As a finger presses it folds forward at its knuckle, and the
        // thumb swings across the palm to meet it; both come toward you, so they grow a little.
        let finger = move.finger, down = press * gesturing, pinch = GuideHand.pinch[finger]
        var tips = GuideHand.rest
        let straight = CGPoint(x: 8 + 4 * Double(finger), y: tips[finger])
        let knuckle = between(straight, CGPoint(x: straight.x, y: pinch.knuckle), down)
        let pad = between(straight, pinch.finger, down), thumb = GuideHand.thumb(meeting: finger, by: down)
        tips[finger] = knuckle.y
        for path in [GuideHand.fingers(tips)] + GuideHand.sides { canvas.stroke(path.applying(place), with: fading, style: hairline) }
        for path in GuideHand.contours { canvas.stroke(path.applying(place), with: .color(ink.opacity(0.3)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round)) }
        if down > 0.01 {
            let folded = GuideHand.limb(from: knuckle, to: pad, radii: (2, 2 + 0.3 * down)).applying(place)
            var layer = canvas
            layer.opacity = min(1, down * 4)
            layer.fill(folded, with: .color(paper)); layer.stroke(folded, with: .color(ink), style: hairline)
        }
        canvas.fill(thumb.cover.applying(place), with: .color(paper))
        canvas.stroke(thumb.outline.applying(place), with: .linearGradient(Gradient(colors: [ink.opacity(1 - down), ink]),
                      startPoint: thumb.soften.from.applying(place), endPoint: thumb.soften.to.applying(place)), style: hairline)

        if wear > 0.01 {
            // The wrist bone as a level across the wrist; the band sits just below it.
            var level = Path()
            level.move(to: CGPoint(x: centre - Self.bandReach - 8, y: wristY - Self.boneRise))
            level.addLine(to: CGPoint(x: centre + Self.bandReach + 12, y: wristY - Self.boneRise))
            canvas.stroke(level.trimmedPath(from: 0, to: arrived(0.2, 0.6)), with: .color(.muted.opacity(wear)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 4]))
            // The band's line, at the front where you can see it.
            let drawn = arrived(1.2, 1.45), top = wristY + wearOffset() + 29
            var line = Path()
            line.move(to: CGPoint(x: centre, y: top)); line.addLine(to: CGPoint(x: centre, y: top + 10 * drawn))
            canvas.stroke(line, with: .color(.ink.opacity(wear * drawn)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        guard gesturing > 0.01 else { return }
        let touch = between(pad, thumb.tip, 0.5).applying(place), lit = band(centre: centre)[litBead]
        // Where the finger and thumb touch fills, the way a bead does.
        canvas.fill(Path(ellipseIn: CGRect(x: touch.x - 4.5, y: touch.y - 4.5, width: 9, height: 9)), with: .color(.ink.opacity(down * down)))
        if let signal {
            // The signal runs from the touch down through the palm to the bead that hears it.
            var route = Path()
            route.move(to: CGPoint(x: touch.x, y: touch.y + 8))
            route.addQuadCurve(to: CGPoint(x: lit.x, y: lit.y - lit.radius - 5), control: CGPoint(x: touch.x, y: CGPoint(x: 0, y: 21).applying(place).y))
            canvas.stroke(route.trimmedPath(from: max(0, signal - 0.25), to: signal), with: .color(.ink.opacity(gesturing)),
                          style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
    }

    private func drawBackdrop(in canvas: inout GraphicsContext, centre: Double, weight: (Plate) -> Double) {
        // One hand serves the wearing and the gestures plates, and stays put between them.
        let wear = weight(.wear), gesturing = weight(.gestures), shown = min(1, wear.squareRoot() + gesturing.squareRoot())
        if shown > 0.01 {
            drawHand(in: &canvas, centre: centre, shown: shown, wear: wear, gesturing: gesturing.squareRoot())
        }
        let holds = weight(.button)
        if holds > 0.01 {
            // Each hold as an arc, an eighth of a turn per second, drawn at the pace it takes.
            for (index, hold) in Plate.holds.enumerated() {
                let middle = CGPoint(x: column(index, of: Plate.holds.count, centre: centre), y: Self.rowY)
                let sweep = still ? 1 : min(1, clock(.button).truncatingRemainder(dividingBy: 6) / (0.5 + hold.seconds * 0.45))
                var arc = Path()
                arc.addArc(center: middle, radius: 29, startAngle: .degrees(-90), endAngle: .degrees(-90 + 45 * hold.seconds * sweep), clockwise: false)
                canvas.stroke(Path(ellipseIn: CGRect(x: middle.x - 29, y: middle.y - 29, width: 58, height: 58)), with: .color(.rule.opacity(holds)), lineWidth: 1)
                canvas.stroke(arc, with: .color(.ink.opacity(holds)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
    }

    private func drawCaptions(in canvas: inout GraphicsContext, centre: Double, weight: (Plate) -> Double) {
        func write(_ text: String, at point: CGPoint, anchor: UnitPoint = .center, strong: Bool = false, opacity: Double) {
            guard opacity > 0.01 else { return }
            var layer = canvas
            layer.opacity = opacity
            layer.draw(Text(text).font(strong ? .label : .caption).foregroundStyle(strong ? Color.ink : Color.muted), at: point, anchor: anchor)
        }
        /// A name under each bead of a row, with a quieter line below it.
        func row(_ names: [(String, String?)], opacity: Double) {
            for (index, name) in names.enumerated() {
                let x = column(index, of: names.count, centre: centre)
                write(name.0, at: CGPoint(x: x, y: Self.rowY + 54), strong: true, opacity: opacity)
                if let detail = name.1 { write(detail, at: CGPoint(x: x, y: Self.rowY + 74), opacity: opacity) }
            }
        }
        write("wrist bone", at: CGPoint(x: centre + Self.bandReach + 18, y: Self.wristY - Self.boneRise), anchor: .leading, opacity: weight(.wear) * arrived(0.5, 0.75))
        write("line faces you", at: CGPoint(x: centre, y: Self.wristY + wearOffset() + 53), opacity: weight(.wear) * arrived(1.3, 1.55))
        if still {
            write(Plate.moves.map(\.name).joined(separator: " · "), at: CGPoint(x: centre, y: 296), strong: true, opacity: weight(.gestures))
            row(Plate.lights.map { ($0.name, $0.blink == nil ? nil : "blinking") }, opacity: weight(.light))
        } else {
            // Each gesture's name fades in and out with its beat.
            write(move.name, at: CGPoint(x: centre, y: 296), strong: true, opacity: weight(.gestures) * min(1, min(gesture.into, 1 - gesture.into) / 0.08))
            write(Plate.lights[lightIndex].name, at: CGPoint(x: centre, y: 262), strong: true, opacity: weight(.light))
        }
        row(Plate.holds.map { ($0.name, "\(Int($0.seconds)) s") }, opacity: weight(.button))
        write("\(Int(chargeLevel * 100))%", at: CGPoint(x: centre, y: 214), strong: true, opacity: weight(.charging))
    }
}
