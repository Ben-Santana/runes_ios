import SwiftUI

/// One lesson of the band guide.
private struct GuidePlate {
    let title: String
    let message: String

    static let all: [GuidePlate] = [
        GuidePlate(title: "Your band", message: "It reads your wrist when your fingers move."),
        GuidePlate(title: "Where to wear it", message: "Writing hand, just past the wrist bone. Line facing you, snug."),
        GuidePlate(title: "Gestures", message: "A finger against your thumb. Keep your arm relaxed."),
        GuidePlate(title: "The light", message: "Press the button once to see the charge."),
        GuidePlate(title: "The button", message: "How long you hold it decides what it does."),
        GuidePlate(title: "Charging", message: "The charger clips under the band. Use a wall adapter."),
    ]
}

/// An optional guide to the band, told by its own eight beads. Each plate is one lesson;
/// swiping moves the same beads into the next shape, so nothing is ever a new picture.
/// Timings and colours follow Meta's published instructions for the band.
struct BandGuidePage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var position = 0.0
    @State private var page: Int? = 0

    private var current: Int { min(GuidePlate.all.count - 1, max(0, Int(position.rounded()))) }

    private func advance() {
        guard current < GuidePlate.all.count - 1 else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.55)) { page = current + 1 }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(Array(GuidePlate.all.enumerated()), id: \.offset) { index, plate in
                                VStack(alignment: .leading, spacing: 10) {
                                    Color.clear.frame(height: BeadTheatre.height)
                                    Text(plate.title).font(.display).tracking(-0.6).fixedSize(horizontal: false, vertical: true)
                                        .accessibilityAddTraits(.isHeader)
                                    Text(plate.message).font(.bodyText).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, Metric.gutter)
                                .frame(width: geometry.size.width, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { advance() }
                                .id(index)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $page)
                    .scrollIndicators(.hidden)
                    .onScrollGeometryChange(for: Double.self) { $0.contentOffset.x / max(1, $0.containerSize.width) } action: { _, value in
                        position = value
                    }
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
                        BeadTheatre(position: position, time: context.date.timeIntervalSinceReferenceDate, still: reduceMotion)
                    }
                    .frame(height: BeadTheatre.height)
                    .allowsHitTesting(false)
                }
                HStack(spacing: 6) {
                    ForEach(GuidePlate.all.indices, id: \.self) { index in
                        Capsule().fill(index == current ? Color.ink : Color.faint)
                            .frame(width: index == current ? 16 : 6, height: 6)
                    }
                }
                .animation(.standard, value: current)
                .padding(.bottom, 16)
                .accessibilityElement().accessibilityLabel("Page \(current + 1) of \(GuidePlate.all.count)")
                Button(current == GuidePlate.all.count - 1 ? "Done" : "Next") {
                    if current == GuidePlate.all.count - 1 { dismiss() } else { advance() }
                }
                .buttonStyle(.primary)
                .padding(.horizontal, Metric.gutter).padding(.bottom, 12)
            }
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
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.font(.label) } }
        }
        .tint(Color.ink)
    }
}

/// Eight beads acting out the guide. `position` is the page, fractional while swiping; the
/// beads glide between each plate's arrangement and every plate adds its own few strokes.
private struct BeadTheatre: View {
    static let height: CGFloat = 330
    let position: Double
    let time: Double
    let still: Bool

    /// One bead on stage.
    private struct Bead {
        var x = 0.0, y = 0.0, radius = 12.0
        var opacity = 1.0
        /// 0 is the app's hairline bead; 1 is a dark bead, the body of a light.
        var dark = 0.0
        /// How full the centre is, 0…1.
        var charge = 0.0
        var light: Color?
        var depth = 0.0
        /// Where its shadow falls, if it has one; fixed while the bead lifts.
        var floor: Double?

        func mixed(with other: Bead, by f: Double) -> Bead {
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * f }
            return Bead(x: mix(x, other.x), y: mix(y, other.y), radius: mix(radius, other.radius),
                        opacity: mix(opacity, other.opacity), dark: mix(dark, other.dark), charge: mix(charge, other.charge),
                        light: f < 0.5 ? light : other.light, depth: mix(depth, other.depth),
                        floor: floor.map { mix($0, other.floor ?? other.y + other.radius) } ?? other.floor.map { mix(y + radius, $0) })
        }
    }

    private static let hand = LucideData.hand.map(SVGPath.cached)
    private static let wrist = ["M8.5 21.2V27.5", "M17.5 21.2V27.5"].map(SVGPath.cached)

    var body: some View {
        Canvas { canvas, size in
            let last = GuidePlate.all.count - 1
            let clamped = min(Double(last), max(0, position))
            let from = min(last, Int(clamped)), to = min(last, from + 1)
            let fraction = clamped - Double(from)
            let eased = fraction * fraction * (3 - 2 * fraction)
            func weight(_ plate: Int) -> Double { let w = max(0, 1 - abs(clamped - Double(plate))); return w * w }

            let a = beads(for: from, in: size), b = beads(for: to, in: size)
            let stage = zip(a, b).map { $0.mixed(with: $1, by: eased) }

            drawBackdrop(in: &canvas, size: size, weight: weight)
            for bead in stage { drawShadow(of: bead, in: &canvas) }
            for bead in stage.sorted(by: { $0.depth < $1.depth }) { draw(bead, in: &canvas) }
            drawCaptions(in: &canvas, size: size, weight: weight)
        }
        .accessibilityHidden(true)
    }

    private var t: Double { still ? 0 : time }

    // MARK: Arrangements

    private func ring(_ size: CGSize, scale: Double, rotation: Double, centreY: Double) -> [Bead] {
        (0..<8).map { index in
            let angle = Double(index) * .pi / 4 + rotation
            let x = cos(angle) * RingGeometry.radius, y = sin(angle) * RingGeometry.radius
            let flat = RingGeometry.project(x, y, 10)
            let ground = RingGeometry.project(x, y, 0)
            return Bead(x: size.width / 2 + flat.x * scale, y: centreY + flat.y * scale, radius: RingGeometry.ballRadius * scale,
                        depth: x + y, floor: centreY + (ground.y + 14) * scale)
        }
    }

    private func beads(for plate: Int, in size: CGSize) -> [Bead] {
        let centre = size.width / 2
        switch plate {
        case 0:
            // The band: its ring, breathing and slowly turning.
            return ring(size, scale: 1.55, rotation: t * 0.35, centreY: 175).enumerated().map { index, bead in
                var bead = bead
                bead.y -= still ? 0 : 5 * sin(t * 1.5 + Double(index) * .pi / 4)
                return bead
            }
        case 1:
            // Around the wrist, just below the hand.
            return (0..<8).map { index in
                let angle = Double(index) * .pi / 4 + t * 0.5
                let front = sin(angle)
                return Bead(x: centre + 8 + cos(angle) * 46, y: 262 + front * 9, radius: 8.5 + front * 1.2,
                            opacity: front < 0 ? 0.35 : 1, charge: 0.25, depth: front)
            }
        case 2:
            // Listening: the bead under the finger that moved jumps.
            let beat = still ? 0.0 : (t / 1.5).truncatingRemainder(dividingBy: 4)
            let gesture = Int(beat), into = beat - Double(gesture)
            let finger = [1, 2, 1, 3][gesture]
            return ring(size, scale: 1.55, rotation: .pi / 4, centreY: 170).enumerated().map { index, bead in
                var bead = bead
                guard index == finger, !still else { return bead }
                let kick = exp(-into * 5) * abs(cos(into * (gesture == 2 ? 18 : 9)))
                bead.y -= 22 * kick; bead.charge = kick
                return bead
            }
        case 3:
            // One bead becomes the light; the rest orbit quietly.
            let phase = lightPhase
            return (0..<8).map { index in
                if index == 0 {
                    return Bead(x: centre, y: 165 - (still ? 0 : 6 * phase.glow), radius: 44, dark: 1, charge: phase.glow, light: phase.colour, depth: 10)
                }
                let angle = Double(index) * 2 * .pi / 7 + t * 0.4
                return Bead(x: centre + cos(angle) * 118, y: 165 + sin(angle) * 34, radius: 5, opacity: 0.5, depth: sin(angle))
            }
        case 4:
            // Four holds, one bead each.
            return (0..<8).map { index in
                guard index < 4 else {
                    return Bead(x: centre + (Double(index) - 5.5) * 30, y: 286, radius: 3, opacity: 0)
                }
                return Bead(x: centre + (Double(index) - 1.5) * 78, y: 150, radius: 20, charge: 0.2, depth: Double(index))
            }
        default:
            // Charging: the row fills, orange until it is nearly full.
            let level = chargeLevel
            return (0..<8).map { index in
                let filled = level * 8 > Double(index)
                return Bead(x: centre + (Double(index) - 3.5) * 38, y: 160, radius: 13, dark: filled ? 1 : 0,
                            charge: filled ? 1 : 0, light: filled ? (level > 0.8 ? .green : .orange) : nil, depth: Double(index))
            }
        }
    }

    /// The charging plate fills over five seconds, then rests full for one.
    private var chargeLevel: Double { still ? 1 : min(1, (t / 5).truncatingRemainder(dividingBy: 1.2)) }

    /// The light plate's cycle: green, orange, blinking orange, flashing white.
    private var lightPhase: (colour: Color, glow: Double, name: String) {
        let step = still ? 0 : Int(t / 2.2) % 4
        switch step {
        case 0: return (.green, 1, "Over 80%")
        case 1: return (.orange, 1, "20 to 80%")
        case 2: return (.orange, sin(t * 2 * .pi * 1.6) > 0 ? 1 : 0.1, "Under 20%")
        default: return (.white, 0.5 + 0.5 * sin(t * 2 * .pi * 1.1), "On, or ready to pair")
        }
    }

    // MARK: Drawing

    /// A soft contact shadow that spreads and fades as the bead rises off it.
    private func drawShadow(of bead: Bead, in canvas: inout GraphicsContext) {
        guard let floor = bead.floor, bead.opacity > 0.01 else { return }
        let height = max(0, floor - bead.y - bead.radius)
        let spread = bead.radius * (0.8 + height / 90)
        canvas.fill(Path(ellipseIn: CGRect(x: bead.x - spread, y: floor - spread * 0.3, width: spread * 2, height: spread * 0.6)),
                    with: .color(.ink.opacity(0.1 * bead.opacity * max(0.3, 1 - height / 70))))
    }

    private func draw(_ bead: Bead, in canvas: inout GraphicsContext) {
        guard bead.opacity > 0.01, bead.radius > 0.5 else { return }
        var layer = canvas
        layer.opacity = bead.opacity
        let body = CGRect(x: bead.x - bead.radius, y: bead.y - bead.radius, width: bead.radius * 2, height: bead.radius * 2)
        if let light = bead.light, bead.dark > 0.5, bead.radius > 20 {
            for halo in 1...4 {
                let reach = bead.radius + Double(halo) * 10
                layer.fill(Path(ellipseIn: CGRect(x: bead.x - reach, y: bead.y - reach, width: reach * 2, height: reach * 2)),
                           with: .color(light.opacity(0.06 * bead.charge)))
            }
        }
        layer.fill(Path(ellipseIn: body), with: .color(.paper))
        if bead.dark > 0.01 { layer.fill(Path(ellipseIn: body), with: .color(.black.opacity(bead.dark))) }
        layer.stroke(Path(ellipseIn: body), with: .color(.ink.opacity(0.75)), lineWidth: bead.radius > 30 ? 1.5 : 1)
        guard bead.charge > 0.01 else { return }
        let dot = body.insetBy(dx: bead.radius * 0.6, dy: bead.radius * 0.6).offsetBy(dx: 0, dy: -bead.radius * 0.06)
        layer.fill(Path(ellipseIn: dot), with: .color((bead.light ?? .ink).opacity(bead.charge)))
    }

    private func drawBackdrop(in canvas: inout GraphicsContext, size: CGSize, weight: (Int) -> Double) {
        let centre = size.width / 2
        // Plate 1: the hand, drawn large, with the wrist running down under the beads.
        let hand = weight(1)
        if hand > 0.01 {
            let scale = 9.2
            let place = CGAffineTransform(translationX: centre - 13 * scale + 8, y: 52).scaledBy(x: scale, y: scale)
            for path in Self.hand + Self.wrist {
                canvas.stroke(path.applying(place), with: .color(.ink.opacity(hand)),
                              style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
            // The wrist bone, and where "just past it" is.
            canvas.stroke(Path(ellipseIn: CGRect(x: centre - 44, y: 238, width: 9, height: 9)), with: .color(.muted.opacity(hand)), lineWidth: 1)
        }
        // Plate 2: a ripple under the bead that jumped.
        let listen = weight(2)
        if listen > 0.01, !still {
            let into = (t / 1.5).truncatingRemainder(dividingBy: 1)
            let reach = 30 + into * 120
            canvas.stroke(Path(ellipseIn: CGRect(x: centre - reach, y: 196 - reach * 0.32, width: reach * 2, height: reach * 0.64)),
                          with: .color(.ink.opacity(listen * (1 - into) * 0.4)), lineWidth: 1)
        }
        // Plate 4: each hold as an arc, an eighth of a turn per second.
        let holds = weight(4)
        if holds > 0.01 {
            for (index, seconds) in [1.0, 2, 3, 8].enumerated() {
                let x = centre + (Double(index) - 1.5) * 78
                let sweep = still ? 1 : min(1, (t.truncatingRemainder(dividingBy: 6)) / (0.5 + seconds * 0.45))
                var arc = Path()
                arc.addArc(center: CGPoint(x: x, y: 150), radius: 29, startAngle: .degrees(-90),
                           endAngle: .degrees(-90 + 360 * seconds / 8 * sweep), clockwise: false)
                canvas.stroke(Path(ellipseIn: CGRect(x: x - 29, y: 121, width: 58, height: 58)), with: .color(.rule.opacity(holds)), lineWidth: 1)
                canvas.stroke(arc, with: .color(.ink.opacity(holds)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
    }

    private func drawCaptions(in canvas: inout GraphicsContext, size: CGSize, weight: (Int) -> Double) {
        let centre = size.width / 2
        var layer = canvas
        let wear = weight(1)
        if wear > 0.01 {
            layer.opacity = wear
            layer.draw(Text("wrist bone").font(.caption).foregroundStyle(Color.muted), at: CGPoint(x: centre - 52, y: 242), anchor: .trailing)
            layer.draw(Text("band").font(.caption).foregroundStyle(Color.muted), at: CGPoint(x: centre + 66, y: 262), anchor: .leading)
        }
        let listen = weight(2)
        if listen > 0.01 {
            let names = ["Tap index", "Tap middle", "Double tap", "Hold"]
            let gesture = still ? 0 : Int((t / 1.5).truncatingRemainder(dividingBy: 4))
            layer.opacity = listen
            layer.draw(Text(names[gesture]).font(.label), at: CGPoint(x: centre, y: 296), anchor: .center)
        }
        let lightWeight = weight(3)
        if lightWeight > 0.01 {
            layer.opacity = lightWeight
            layer.draw(Text(lightPhase.name).font(.label), at: CGPoint(x: centre, y: 262), anchor: .center)
        }
        let holds = weight(4)
        if holds > 0.01 {
            layer.opacity = holds
            for (index, hold) in [("1 s", "Wake"), ("2 s", "On"), ("3 s", "Pair"), ("8 s", "Off")].enumerated() {
                let x = centre + (Double(index) - 1.5) * 78
                layer.draw(Text(hold.1).font(.label), at: CGPoint(x: x, y: 204), anchor: .center)
                layer.draw(Text(hold.0).font(.caption).foregroundStyle(Color.muted), at: CGPoint(x: x, y: 224), anchor: .center)
            }
        }
        let charging = weight(5)
        if charging > 0.01 {
            layer.opacity = charging
            let percent = Int(chargeLevel * 100)
            layer.draw(Text("\(percent)%").font(.label).monospacedDigit(), at: CGPoint(x: centre, y: 214), anchor: .center)
        }
    }
}
