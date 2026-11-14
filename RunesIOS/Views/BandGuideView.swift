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
    /// The page as a fraction while it is being swiped.
    @State private var position = 0.0
    @State private var page: Int? = 0
    /// When each plate last came into view, so its lesson starts from the beginning.
    @State private var entered = Array(repeating: Date().timeIntervalSinceReferenceDate, count: Plate.allCases.count)
    /// Temporary, while the hand drawings are being compared.
    @AppStorage(GuideHandStyle.key) private var handStyle = GuideHandStyle.line

    private var current: Int { page ?? 0 }
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
                    .onScrollGeometryChange(for: Double.self) { $0.contentOffset.x / max(1, $0.containerSize.width) } action: { old, value in
                        position = value
                        for plate in Plate.allCases where abs(value - Double(plate.rawValue)) < 1 && abs(old - Double(plate.rawValue)) >= 1 {
                            entered[plate.rawValue] = Date().timeIntervalSinceReferenceDate
                        }
                    }
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || scenePhase != .active)) { context in
                        BeadTheatre(position: position, time: context.date.timeIntervalSinceReferenceDate, entered: entered, style: handStyle, still: reduceMotion)
                    }
                    .frame(height: stage)
                    .allowsHitTesting(false)
                }
                if current == Plate.wear.rawValue || current == Plate.gestures.rawValue {
                    HairlineSegments(selection: $handStyle, options: GuideHandStyle.allCases, title: \.title)
                        .padding(.horizontal, Metric.gutter).padding(.bottom, 16)
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
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.font(.label) } }
        }
    }
}

/// Temporary: the hand drawings being compared in the guide.
enum GuideHandStyle: String, CaseIterable, Hashable {
    case line, drawn, solid, beads
    static let key = "guideHandStyle"
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    /// How far out the band's side beads sit, to hug each drawing's wrist.
    var reach: Double { switch self { case .line, .solid: 43; case .drawn: 37; case .beads: 38 } }
    /// The wrist bone, from the middle of the band.
    var bone: CGPoint { switch self { case .line, .solid: CGPoint(x: 39, y: -23); case .drawn: CGPoint(x: 31, y: -27); case .beads: CGPoint(x: 31, y: -24) } }
    /// How far below the band the forearm has faded out.
    var armEnd: Double { self == .line ? 71 : 50 }
    /// The bone is shown as a dashed level across the wrist, or as a small bead on its edge.
    var boneIsLevel: Bool { self == .line || self == .solid }
}

/// The brand hand drawn large, carrying on into a forearm. Its fingers are Lucide's, a little
/// longer: four columns with round tips, each placed by the centre of its tip, so a finger can dip.
private enum GuideHand {
    static let scale = 7.6, top = 26.0, wristX = 13.6
    static let rest = [5.0, 3, 5, 7.3]
    /// The heel of the hand and the forearm; then the thumb side.
    static let sides = ["M22 14C22 17.6 20.9 20 19.6 21.8C18.9 22.8 18.6 23.8 18.6 25C18.6 28 18.8 31.5 19.2 35.5",
                        "M7 15L5.24 13.24a2 2 0 0 0-2.83 2.82L6.01 19.66C7.4 21 8.2 22.6 8.2 24.5C8.2 27.5 7.9 31 7.4 35.5"].map(SVGPath.cached)
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

    /// The hand and forearm as one closed shape, for filling.
    static func whole(_ tips: [Double]) -> Path {
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
        var path = fingers(tips, dividers: false)
        path.addCurve(to: point(19.6, 21.8), control1: point(22, 17.6), control2: point(20.9, 20))
        path.addCurve(to: point(18.6, 25), control1: point(18.9, 22.8), control2: point(18.6, 23.8))
        path.addCurve(to: point(19.2, 35.5), control1: point(18.6, 28), control2: point(18.8, 31.5))
        path.addLine(to: point(7.4, 35.5))
        path.addCurve(to: point(8.2, 24.5), control1: point(7.9, 31), control2: point(8.2, 27.5))
        path.addCurve(to: point(6.01, 19.66), control1: point(8.2, 22.6), control2: point(7.4, 21))
        path.addLine(to: point(2.41, 16.06))
        path.addArc(center: point(3.83, 14.65), radius: 2, startAngle: .degrees(135), endAngle: .degrees(315), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// A hand drawn from life, seen from the back: one outline for the palm, thumb and forearm,
/// and four tapered fingers that fan out. Its origin is the middle of the wrist.
private enum DrawnHand {
    static let scale = 0.86, bandY = 46.0
    static let body = SVGPath.cached("M-48 330C-63.7 310 -46.7 240 -46 210C-45.3 180 -45 169.2 -44 150C-43 130.8 -41.3 112.5 -40 95C-38.7 77.5 -37.1 58.5 -36 45C-34.9 31.5 -33.5 22.8 -33.5 14C-33.5 5.2 -34.2 -1 -36 -8C-37.8 -15 -40.5 -21.5 -44 -28C-47.5 -34.5 -52.8 -40.8 -57 -47C-61.2 -53.2 -65.7 -59.2 -69 -65C-72.3 -70.8 -75.5 -77.3 -77 -82C-78.5 -86.7 -79.2 -90.3 -78 -93C-76.8 -95.7 -73 -98.8 -70 -98C-67 -97.2 -63 -92.3 -60 -88C-57 -83.7 -54.5 -76.8 -52 -72C-49.5 -67.2 -46.7 -59 -45 -59C-43.3 -59 -42.8 -65.5 -42 -72C-41.2 -78.5 -43.7 -91.8 -40 -98C-36.3 -104.2 -27.3 -107 -20 -109C-12.7 -111 -3.5 -110.8 4 -110C11.5 -109.2 18.8 -107.3 25 -104C31.2 -100.7 37.5 -96.7 41 -90C44.5 -83.3 45.3 -73.3 46 -64C46.7 -54.7 46 -43 45 -34C44 -25 41.6 -17.7 40 -10C38.4 -2.3 36.3 5.3 35.5 12C34.7 18.7 34.8 21.7 35 30C35.2 38.3 35.5 49.5 36.5 62C37.5 74.5 39.8 90.3 41 105C42.2 119.7 43.2 132.5 44 150C44.8 167.5 45.3 180 46 210C46.7 240 63.7 310 48 330C32.3 350 -32.3 350 -48 330Z")
    /// Each finger: where it leaves the palm, its lean in degrees, its length, and its width at each end.
    static let fingers: [(x: Double, y: Double, lean: Double, length: Double, base: Double, tip: Double)] =
        [(-31, -90, -9, 64, 10.3, 8.4), (-9, -96, -2, 72, 10.3, 8.6), (13.5, -93, 5, 65, 9.8, 8.1), (34, -82, 14, 50, 8.8, 7.2)]
    static let knuckles = SVGPath.cached(fingers.map { "M\($0.x - 5) \($0.y + 1)q5 -4 10 0" }.joined())

    static func tip(_ index: Int, curled: Double) -> CGPoint {
        let finger = fingers[index], lean = finger.lean * .pi / 180, length = finger.length * (1 - 0.42 * curled)
        return CGPoint(x: finger.x + sin(lean) * length, y: finger.y - cos(lean) * length)
    }
    static func finger(_ index: Int, curled: Double) -> Path {
        let finger = fingers[index], lean = finger.lean * .pi / 180, end = tip(index, curled: curled)
        let across = CGPoint(x: cos(lean), y: sin(lean))
        var path = Path()
        path.move(to: CGPoint(x: finger.x - across.x * finger.base, y: finger.y - across.y * finger.base))
        path.addLine(to: CGPoint(x: end.x - across.x * finger.tip, y: end.y - across.y * finger.tip))
        path.addArc(center: end, radius: finger.tip, startAngle: .degrees(finger.lean + 180), endAngle: .degrees(finger.lean + 360), clockwise: false)
        path.addLine(to: CGPoint(x: finger.x + across.x * finger.base, y: finger.y + across.y * finger.base))
        path.closeSubpath()
        return path
    }
}

/// A hand made of the app's own parts: a bead at each fingertip and knuckle, joined by hairlines.
/// Points are measured from the middle of the band. The thumb comes first, then the four fingers.
private enum BeadHand {
    static let hub = CGPoint(x: 0, y: -20)
    static let knuckles = [CGPoint(x: -38, y: -56), CGPoint(x: -25, y: -100), CGPoint(x: -4, y: -106), CGPoint(x: 16, y: -101), CGPoint(x: 34, y: -89)]
    static let tips = [CGPoint(x: -70, y: -96), CGPoint(x: -36, y: -168), CGPoint(x: -5, y: -180), CGPoint(x: 22, y: -168), CGPoint(x: 50, y: -140)]
    /// Where a finger and the thumb come to when they touch.
    static let pinch = (finger: CGPoint(x: -52, y: -118), thumb: CGPoint(x: -64, y: -106))
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
    let style: GuideHandStyle
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

        func mixed(with other: Bead, by f: Double) -> Bead {
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * f }
            return Bead(x: mix(x, other.x), y: mix(y, other.y), radius: mix(radius, other.radius),
                        opacity: mix(opacity, other.opacity), dark: mix(dark, other.dark), charge: mix(charge, other.charge),
                        light: f < 0.5 ? light : other.light, depth: mix(depth, other.depth),
                        shadow: mix(shadow, other.shadow), lift: mix(lift, other.lift))
        }
    }

    private static let ringScale = 1.55
    /// Where the band sits, just past the wrist bone.
    private static let wristY = GuideHand.top + 26.2 * GuideHand.scale
    private static let columnWidth = 78.0
    private static let rowY = 150.0
    /// Seconds each gesture, light and lap of the loops below is shown.
    private static let gestureBeat = 1.5, lightBeat = 2.2, chargeLoop = 6.0

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
                bead.lift += hop * 26; bead.radius *= 1 + hop * 0.12
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
    /// How far the finger making the gesture is pressed to the thumb at a point in its beat, 0…1.
    private func pressed(at into: Double) -> Double {
        guard !still else { return 0 }
        func dip(_ from: Double, _ to: Double) -> Double { into > from && into < to ? pow(sin(.pi * (into - from) / (to - from)), 2) : 0 }
        if move.held { return min(1, max(0, min(into - 0.1, 0.88 - into) / 0.1)) }
        return move.twice ? dip(0.1, 0.36) + dip(0.44, 0.7) : dip(0.14, 0.5)
    }
    private var press: Double { pressed(at: gesture.into) }
    /// The band answers a moment after the finger lands.
    private var answer: Double { pressed(at: gesture.into - 0.06) }
    /// The signal on its way from the finger to the band while it travels, 0…1.
    private var signal: Double? {
        guard !still else { return nil }
        let starts = move.held ? [0.1] : move.twice ? [0.1, 0.44] : [0.14]
        return starts.map { (gesture.into - $0 - 0.04) / 0.1 }.first { $0 > 0 && $0 < 1 }
    }
    private var lightIndex: Int { Int(clock(.light) / Self.lightBeat) % Plate.lights.count }
    private func glow(of light: (colour: Color, blink: Double?, name: String)) -> Double {
        guard let blink = light.blink, !still else { return 1 }
        let wave = sin(clock(.light) * 2 * .pi * blink)
        return light.colour == .white ? 0.5 + 0.5 * wave : (wave > 0 ? 1 : 0.1)
    }
    /// How far down the forearm the band is from its place: it slides on once as the plate arrives.
    private var wearOffset: Double {
        guard !still else { return 0 }
        let x = max(0, clock(.wear) - 0.45) * 1.9
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
    private func band(centre: Double, offset: Double) -> [Bead] {
        (0..<8).map { index in
            let angle = Double(index) * .pi / 4, front = sin(angle)
            return Bead(x: centre + cos(angle) * style.reach, y: Self.wristY + offset + front * 13,
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
        case .wear: return band(centre: centre, offset: wearOffset)
        case .gestures:
            // The band stays on the wrist; the bead nearest the finger that moved lights with it.
            return band(centre: centre, offset: 0).enumerated().map { index, bead in
                var bead = bead
                bead.charge = answer * (index == litBead ? 1 : abs(index - litBead) == 1 ? 0.35 : 0)
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
        layer.stroke(Path(ellipseIn: body), with: .color(.ink.opacity(0.75)), lineWidth: bead.radius > 30 ? 1.5 : 1)
        guard bead.charge > 0.01 else { return }
        let dot = body.insetBy(dx: bead.radius * 0.6, dy: bead.radius * 0.6).offsetBy(dx: 0, dy: -bead.radius * 0.06)
        layer.fill(Path(ellipseIn: dot), with: .color((bead.light ?? .ink).opacity(bead.charge)))
    }

    // MARK: The hand

    /// Draws the hand in the chosen style, then the wrist bone (wearing plate only) and the
    /// signal running from the finger to the band (gestures plate only).
    private func drawHand(in canvas: inout GraphicsContext, centre: Double, shown: Double, wear: Double, gesturing: Double) {
        let ink = Color.ink.opacity(shown), paper = Color.paper.opacity(shown)
        let wrist = CGPoint(x: centre, y: Self.wristY), finger = move.finger, down = press * gesturing
        let fading = GraphicsContext.Shading.linearGradient(Gradient(colors: [ink, ink.opacity(0)]),
                                                            startPoint: CGPoint(x: 0, y: wrist.y + style.armEnd - 22), endPoint: CGPoint(x: 0, y: wrist.y + style.armEnd))
        let hairline = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        let faint = StrokeStyle(lineWidth: 0.8, lineCap: .round)
        let bone = CGPoint(x: wrist.x + style.bone.x, y: wrist.y + style.bone.y)
        var level = Path()
        level.move(to: CGPoint(x: wrist.x - style.reach - 8, y: bone.y)); level.addLine(to: CGPoint(x: bone.x + 16, y: bone.y))
        let dashes = StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 4])
        /// The fingertip that is pressing, and the way from it down to the band.
        var tip = CGPoint.zero, route = [CGPoint]()
        /// The colour of marks drawn on top of the hand.
        var mark = Color.ink

        switch style {
        case .line, .solid:
            let place = CGAffineTransform(translationX: centre - GuideHand.wristX * GuideHand.scale, y: GuideHand.top).scaledBy(x: GuideHand.scale, y: GuideHand.scale)
            var tips = GuideHand.rest
            tips[finger] += 4.5 * down
            tip = CGPoint(x: 8 + 4 * Double(finger), y: tips[finger]).applying(place)
            route = [tip, CGPoint(x: 8 + 4 * Double(finger), y: 16).applying(place)]
            if style == .solid {
                mark = .paper
                if wear > 0.01 { canvas.stroke(level, with: .color(.muted.opacity(wear)), style: dashes) }
                let whole = GuideHand.whole(tips).applying(place)
                canvas.fill(whole, with: fading)
                // The lines between the fingers, and of the palm, are cut out of the fill.
                var dividers = GuideHand.fingers(tips)
                for path in GuideHand.contours { dividers.addPath(path) }
                var inside = canvas
                inside.clip(to: whole)
                inside.stroke(dividers.applying(place), with: .color(paper.opacity(0.55)), style: faint)
                if wear > 0.01 { inside.stroke(level, with: .color(.paper.opacity(wear)), style: dashes) }
            } else {
                for path in [GuideHand.fingers(tips)] + GuideHand.sides { canvas.stroke(path.applying(place), with: fading, style: hairline) }
                for path in GuideHand.contours { canvas.stroke(path.applying(place), with: .color(ink.opacity(0.3)), style: faint) }
                if wear > 0.01 { canvas.stroke(level, with: .color(.muted.opacity(wear)), style: dashes) }
            }
        case .drawn:
            let place = CGAffineTransform(translationX: wrist.x, y: wrist.y - DrawnHand.bandY * DrawnHand.scale).scaledBy(x: DrawnHand.scale, y: DrawnHand.scale)
            let shapes = [DrawnHand.body] + (0..<4).map { DrawnHand.finger($0, curled: $0 == finger ? down : 0) }
            // Every shape is stroked and then filled with paper, which leaves one outline around them all.
            for shape in shapes { canvas.stroke(shape.applying(place), with: fading, style: StrokeStyle(lineWidth: 2.4, lineJoin: .round)) }
            for shape in shapes { canvas.fill(shape.applying(place), with: .color(paper)) }
            canvas.stroke(DrawnHand.knuckles.applying(place), with: .color(ink.opacity(0.3)), style: faint)
            tip = DrawnHand.tip(finger, curled: down).applying(place)
            route = [tip, CGPoint(x: DrawnHand.fingers[finger].x, y: DrawnHand.fingers[finger].y + 20).applying(place)]
        case .beads:
            func at(_ point: CGPoint) -> CGPoint { CGPoint(x: wrist.x + point.x, y: wrist.y + point.y) }
            func toward(_ from: CGPoint, _ to: CGPoint) -> CGPoint { CGPoint(x: from.x + (to.x - from.x) * down, y: from.y + (to.y - from.y) * down) }
            var tips = BeadHand.tips
            // The finger and the thumb come together, as they do for a real gesture.
            tips[0] = toward(tips[0], BeadHand.pinch.thumb); tips[finger + 1] = toward(tips[finger + 1], BeadHand.pinch.finger)
            var bones = Path()
            for index in tips.indices {
                bones.move(to: at(BeadHand.hub)); bones.addLine(to: at(BeadHand.knuckles[index])); bones.addLine(to: at(tips[index]))
            }
            // The palm, as a line through the knuckles.
            bones.move(to: at(BeadHand.knuckles[0]))
            for knuckle in BeadHand.knuckles.dropFirst() { bones.addLine(to: at(knuckle)) }
            canvas.stroke(bones, with: .color(ink.opacity(0.45)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            var arm = Path()
            for side in [-1.0, 1.0] { arm.move(to: CGPoint(x: wrist.x + side * 30, y: wrist.y - 36)); arm.addLine(to: CGPoint(x: wrist.x + side * 33, y: wrist.y + style.armEnd)) }
            canvas.stroke(arm, with: fading, style: hairline)
            for index in tips.indices {
                let pressing = index == 0 || index == finger + 1
                for (point, radius) in [(BeadHand.knuckles[index], 3.5), (tips[index], index == 0 ? 8.5 : 7.5)] {
                    let body = CGRect(x: wrist.x + point.x - radius, y: wrist.y + point.y - radius, width: radius * 2, height: radius * 2)
                    var layer = canvas
                    layer.opacity = shown
                    RingGeometry.drawBall(in: &layer, body: body, stroke: .ink, lineWidth: 1, charge: radius > 4 && pressing ? down : 0)
                }
            }
            canvas.fill(Path(ellipseIn: CGRect(x: wrist.x - 5, y: wrist.y + BeadHand.hub.y - 5, width: 10, height: 10)), with: .color(paper))
            canvas.stroke(Path(ellipseIn: CGRect(x: wrist.x - 5, y: wrist.y + BeadHand.hub.y - 5, width: 10, height: 10)), with: .color(ink), lineWidth: 1)
            tip = at(tips[finger + 1])
            route = [tip, at(BeadHand.knuckles[finger + 1]), at(BeadHand.hub)]
        }

        if style != .beads, down > 0.01 {
            // A pressed fingertip fills, the way a bead does.
            let radius = style == .drawn ? 4.5 : 5.5
            canvas.fill(Path(ellipseIn: CGRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2)), with: .color(mark.opacity(down)))
        }
        if wear > 0.01 {
            if !style.boneIsLevel {
                let body = CGRect(x: bone.x - 4.5, y: bone.y - 4.5, width: 9, height: 9)
                canvas.fill(Path(ellipseIn: body), with: .color(.paper.opacity(wear)))
                canvas.stroke(Path(ellipseIn: body), with: .color(.ink.opacity(wear)), lineWidth: 1)
                var leader = Path()
                leader.move(to: CGPoint(x: bone.x + 9, y: bone.y)); leader.addLine(to: CGPoint(x: bone.x + 20, y: bone.y))
                canvas.stroke(leader, with: .color(.rule.opacity(wear)), lineWidth: 1)
            }
        }
        if gesturing > 0.5, let signal {
            // The signal runs down the finger to the bead that hears it.
            let lit = band(centre: centre, offset: 0)[litBead]
            let stops = route + [CGPoint(x: lit.x, y: lit.y - lit.radius - 4)]
            let leg = signal * Double(stops.count - 1), index = min(stops.count - 2, Int(leg)), along = leg - Double(index)
            let from = stops[index], to = stops[index + 1]
            let dot = CGPoint(x: from.x + (to.x - from.x) * along, y: from.y + (to.y - from.y) * along)
            let colour = style == .solid && index == 0 ? Color.paper : Color.ink
            canvas.fill(Path(ellipseIn: CGRect(x: dot.x - 2.5, y: dot.y - 2.5, width: 5, height: 5)), with: .color(colour.opacity(sin(.pi * signal))))
        }
    }

    private func drawBackdrop(in canvas: inout GraphicsContext, centre: Double, weight: (Plate) -> Double) {
        // One hand serves the wearing and the gestures plates, and stays put between them.
        let wear = weight(.wear), gesturing = weight(.gestures), shown = min(1, wear.squareRoot() + gesturing.squareRoot())
        if shown > 0.01 {
            drawHand(in: &canvas, centre: centre, shown: shown, wear: wear, gesturing: gesturing.squareRoot())
        }
        if wear > 0.01 {
            // The band's line, at the front where you can see it.
            var line = Path()
            line.move(to: CGPoint(x: centre, y: Self.wristY + wearOffset + 29))
            line.addLine(to: CGPoint(x: centre, y: Self.wristY + wearOffset + 39))
            canvas.stroke(line, with: .color((style == .solid ? Color.paper : .ink).opacity(wear)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
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
        write("wrist bone", at: CGPoint(x: centre + style.bone.x + (style.boneIsLevel ? 22 : 25), y: Self.wristY + style.bone.y), anchor: .leading, opacity: weight(.wear))
        write("line faces you", at: CGPoint(x: centre, y: Self.wristY + (style == .line ? wearOffset + 53 : style.armEnd + 12)), opacity: weight(.wear))
        if still {
            write(Plate.moves.map(\.name).joined(separator: " · "), at: CGPoint(x: centre, y: 296), strong: true, opacity: weight(.gestures))
            row(Plate.lights.map { ($0.name, $0.blink == nil ? nil : "blinking") }, opacity: weight(.light))
        } else {
            write(Plate.moves[gesture.index].name, at: CGPoint(x: centre, y: 296), strong: true, opacity: weight(.gestures))
            write(Plate.lights[lightIndex].name, at: CGPoint(x: centre, y: 262), strong: true, opacity: weight(.light))
        }
        row(Plate.holds.map { ($0.name, "\(Int($0.seconds)) s") }, opacity: weight(.button))
        write("\(Int(chargeLevel * 100))%", at: CGPoint(x: centre, y: 214), strong: true, opacity: weight(.charging))
    }
}
