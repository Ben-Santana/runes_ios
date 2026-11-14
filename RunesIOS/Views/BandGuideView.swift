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
    /// Each gesture and the bead that jumps for it.
    static let moves: [(name: String, bead: Int, twice: Bool)] =
        [("Tap index", 1, false), ("Tap middle", 2, false), ("Double tap", 1, true), ("Hold", 3, false)]
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
                        BeadTheatre(position: position, time: context.date.timeIntervalSinceReferenceDate, entered: entered, still: reduceMotion)
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
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.font(.label) } }
        }
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

        func mixed(with other: Bead, by f: Double) -> Bead {
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * f }
            return Bead(x: mix(x, other.x), y: mix(y, other.y), radius: mix(radius, other.radius),
                        opacity: mix(opacity, other.opacity), dark: mix(dark, other.dark), charge: mix(charge, other.charge),
                        light: f < 0.5 ? light : other.light, depth: mix(depth, other.depth),
                        shadow: mix(shadow, other.shadow), lift: mix(lift, other.lift))
        }
    }

    /// The wearing lesson as a short loop: the band comes up the forearm loose, stops against
    /// the wrist bone, tightens, shows its line, and its sensors wake one after another.
    private struct Wearing {
        /// How far down the forearm the band is, and how loose, 0…1.
        var offset = 0.0, loose = 0.0
        /// The bone's label, its nudge as the band meets it, and the line, each 0…1.
        var bone = 1.0, knock = 0.0, line = 1.0
        /// The angle around the band of the sensor waking now.
        var sense: Double?

        init(at elapsed: Double?) {
            guard let elapsed else { return }
            let e = elapsed.truncatingRemainder(dividingBy: 8)
            func ramp(_ a: Double, _ b: Double) -> Double { let x = min(1, max(0, (e - a) / (b - a))); return x * x * (3 - 2 * x) }
            /// Eases away from 0, runs a little past 1 and settles.
            func spring(_ x: Double) -> Double { x <= 0 ? 0 : 1 - exp(-4 * x) * (cos(5 * x) + 0.8 * sin(5 * x)) }
            let leaving = ramp(6.8, 7.6), shown = 1 - ramp(6.4, 6.8)
            offset = 60 * (1 - spring(e - 0.5) + leaving)
            loose = max(1 - spring((e - 2.1) * 1.6), ramp(6.5, 7))
            knock = exp(-pow((e - 1.13) / 0.16, 2))
            bone = ramp(1, 1.4) * shown
            line = ramp(3, 3.5) * shown
            if e > 3.7, e < 4.9 { sense = -0.4 + (e - 3.7) / 1.2 * (.pi + 0.8) }
        }
    }

    private static let hand = LucideData.hand.map(SVGPath.cached)
    /// The forearm, in the hand's 24-unit drawing: its top, where it has faded out, and its sides.
    private static let armTop = 21.2, armEnd = 36.0, armLeft = 8.5, armRight = 17.5
    private static let forearm = [armLeft, armRight].map { SVGPath.cached("M\($0) \(armTop)V\(armEnd)") }
    private static let ringScale = 1.55
    /// Drawn large and close on the wrist; the fingertips fade out at the top.
    private static let handScale = 10.0
    private static let handTop = -30.0
    /// Where the band sits, a little below the palm.
    private static let wristY = handTop + 24.4 * handScale
    /// The wrist bone, on the little-finger side just above the band.
    private static let boneY = wristY - 26
    private static let armHalfWidth = (armRight - armLeft) / 2 * handScale
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
    private var lightIndex: Int { Int(clock(.light) / Self.lightBeat) % Plate.lights.count }
    private func glow(of light: (colour: Color, blink: Double?, name: String)) -> Double {
        guard let blink = light.blink, !still else { return 1 }
        let wave = sin(clock(.light) * 2 * .pi * blink)
        return light.colour == .white ? 0.5 + 0.5 * wave : (wave > 0 ? 1 : 0.1)
    }
    private var wearing: Wearing { Wearing(at: still ? nil : clock(.wear)) }
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

    private func beads(for plate: Plate, centre: Double) -> [Bead] {
        switch plate {
        case .meet:
            let t = clock(.meet)
            return ring(centre: centre, rotation: t * 0.35, y: 175).enumerated().map { index, bead in
                var bead = bead
                bead.lift += still ? 0 : 5 + 5 * sin(t * 1.5 + Double(index) * .pi / 4)
                return bead
            }
        case .wear:
            let story = wearing
            return (0..<8).map { index in
                // Three beads across the front and one at each side; the other three are behind the arm.
                let angle = Double(index) * .pi / 4, front = sin(angle)
                let woken = story.sense.map { 0.8 * exp(-pow(angle - $0, 2) * 5) } ?? 0
                return Bead(x: centre + cos(angle) * (Self.armHalfWidth + 3 + 14 * story.loose),
                            y: Self.wristY + story.offset + front * (12 + 5 * story.loose),
                            radius: 9.5 + front * 4.5, opacity: front < -0.01 ? 0 : 1, charge: 0.2 + woken, depth: front)
            }
        case .gestures:
            let now = gesture, played = Plate.moves[now.index]
            return ring(centre: centre, rotation: .pi / 4, y: 170).enumerated().map { index, bead in
                var bead = bead
                guard index == played.bead, !still else { return bead }
                let kick = exp(-now.into * 7.5) * abs(cos(now.into * (played.twice ? 27 : 13.5)))
                bead.lift += 22 * kick; bead.charge = kick
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

    private func drawBackdrop(in canvas: inout GraphicsContext, centre: Double, weight: (Plate) -> Double) {
        let wear = weight(.wear)
        if wear > 0.01 {
            let story = wearing, ink = Color.ink.opacity(wear)
            let place = CGAffineTransform(translationX: centre - (Self.armLeft + Self.armRight) / 2 * Self.handScale, y: Self.handTop)
                .scaledBy(x: Self.handScale, y: Self.handScale)
            let stroke = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
            // Close on the wrist: the fingertips and the forearm fade out of the picture.
            let fade = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [.init(color: ink.opacity(0), location: 0), .init(color: ink, location: 0.17),
                                 .init(color: ink, location: 0.82), .init(color: ink.opacity(0), location: 1)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: Self.designHeight))
            for path in Self.hand + Self.forearm { canvas.stroke(path.applying(place), with: fade, style: stroke) }
            var bone = Path()
            bone.addArc(center: CGPoint(x: centre + Self.armHalfWidth, y: Self.boneY), radius: 7 + 3 * story.knock,
                        startAngle: .degrees(-75), endAngle: .degrees(75), clockwise: false)
            canvas.stroke(bone, with: .color(ink), style: StrokeStyle(lineWidth: 1.4 + story.knock, lineCap: .round))
            // The band's line, at the front where you can see it.
            let lineTop = Self.wristY + story.offset + 33
            var line = Path()
            line.move(to: CGPoint(x: centre, y: lineTop))
            line.addLine(to: CGPoint(x: centre, y: lineTop + 12 * story.line))
            canvas.stroke(line, with: .color(ink.opacity(story.line)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            var leader = Path()
            leader.move(to: CGPoint(x: centre - Self.armHalfWidth - 8, y: lineTop + 6))
            leader.addLine(to: CGPoint(x: centre - 7, y: lineTop + 6))
            canvas.stroke(leader, with: .color(.rule.opacity(wear * story.line)), lineWidth: 1)
        }
        let listen = weight(.gestures)
        if listen > 0.01, !still {
            // A ripple under the bead that jumped.
            let reach = 30 + gesture.into * 120
            canvas.stroke(Path(ellipseIn: CGRect(x: centre - reach, y: 196 - reach * 0.32, width: reach * 2, height: reach * 0.64)),
                          with: .color(.ink.opacity(listen * (1 - gesture.into) * 0.4)), lineWidth: 1)
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
        let story = wearing
        write("wrist bone", at: CGPoint(x: centre + Self.armHalfWidth + 18, y: Self.boneY), anchor: .leading, opacity: weight(.wear) * story.bone)
        write("line faces you", at: CGPoint(x: centre - Self.armHalfWidth - 14, y: Self.wristY + story.offset + 39), anchor: .trailing, opacity: weight(.wear) * story.line)
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
