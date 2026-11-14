import SwiftUI

// The home ring's eight beads as a live record of what the band is doing: a candidate to
// replace the strip of recent gestures at the top of Mappings, tried in Settings → Developer →
// Runes lab. The front bead becomes each gesture as it arrives and the ring turns one place
// to offer the next. The moment a mapping runs, the beads gather into one ball in that
// mapping's colour, which bounces as a ripple spreads over the ground. Gestures that come
// to nothing shake, lose their glyphs and the ring winds back.

/// What the beads are showing. Feed it gestures and outcomes; it clears itself between attempts.
@MainActor final class BeadsFeed: ObservableObject {
    /// The gestures of the attempt in progress, oldest first; at most eight.
    @Published private(set) var steps: [ComboStep] = []
    /// Bumped when a mapping runs, and when an attempt comes to nothing.
    @Published private(set) var matches = 0
    @Published private(set) var misses = 0
    /// Index into `ScoreTint` for the mapping that last ran.
    @Published private(set) var tint = 0

    /// How long an attempt may sit before it counts as come to nothing.
    static let patience: TimeInterval = 2.5
    private var pending: Task<Void, Never>?

    func gesture(_ step: ComboStep) {
        // A full ring starts again with the new gesture.
        steps = steps.count >= 8 ? [step] : steps + [step]
        after(Self.patience) { $0.missed() }
    }

    func matched(tint: Int) {
        guard !steps.isEmpty else { return }
        self.tint = tint
        matches += 1
        after(0.6) { $0.steps = [] }
    }

    func missed() {
        guard !steps.isEmpty else { return }
        misses += 1
        after(0.6) { $0.steps = [] }
    }

    private func after(_ delay: TimeInterval, _ action: @escaping (BeadsFeed) -> Void) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled, let self { action(self) }
        }
    }
}

struct GestureBeads: View {
    @ObservedObject var feed: BeadsFeed

    @State private var born: [Date] = []
    @State private var turnFrom = 0.0
    @State private var turnedAt = Date.distantPast
    @State private var outcome: BeadsOutcome?

    var body: some View {
        // The canvas is given plain values: state read only inside a drawing closure is not tracked.
        BeadsCanvas(steps: feed.steps, tint: ScoreTint.fill(feed.tint), born: born, turnFrom: turnFrom, turnedAt: turnedAt, outcome: outcome)
            .onChange(of: feed.steps) { old, new in
                let now = Date()
                turnFrom = BeadsCanvas.turn(from: turnFrom, to: Double(old.count), since: turnedAt, now: now)
                turnedAt = now
                if new.count == old.count + 1, Array(new.dropLast()) == old { born.append(now) }
                else { born = new.map { _ in now } }
            }
            .onChange(of: feed.matches) { _, _ in outcome = BeadsOutcome(matched: true, at: Date()) }
            .onChange(of: feed.misses) { _, _ in outcome = BeadsOutcome(matched: false, at: Date()) }
            .accessibilityElement()
            .accessibilityLabel("Recent gestures")
            .accessibilityValue(feed.steps.isEmpty ? "None" : feed.steps.map(\.name).joined(separator: ", "))
    }
}

private struct BeadsOutcome: Equatable {
    let matched: Bool
    let at: Date
}

/// Everything that moves, at one instant.
private struct BeadsMoment {
    /// How many places the ring has turned.
    var turn = 0.0
    /// A miss: glyphs fading away, the sideways shake in points, and the beads' dip.
    var drop = 0.0, shake = 0.0, sink = 0.0
    /// 0...1 gathered into one ball, and that ball's colour, size and height.
    var merge = 0.0, colour = 0.0, flood = 0.0
    var squat = 1.0, lift = 0.0
    var ripples: [(reach: Double, alpha: Double)] = []
}

private struct BeadsCanvas: View {
    let steps: [ComboStep]
    let tint: Color
    /// When each step arrived.
    let born: [Date]
    /// The turn the ring was at when the steps last changed, and when that was.
    let turnFrom: Double
    let turnedAt: Date
    let outcome: BeadsOutcome?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let place = Double.pi / 4
    private static let ring = 49.0, ball = 13.0

    var body: some View {
        // Wide enough for the ripple; as tall as a ring seen from this angle needs.
        Color.clear.aspectRatio(1.8, contentMode: .fit).overlay {
            GeometryReader { proxy in
                TimelineView(.animation(paused: reduceMotion && outcome == nil)) { timeline in
                    Canvas { context, size in
                        let now = reduceMotion ? Date() : timeline.date
                        draw(&context, size, moment(at: now), at: now)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    static func turn(from: Double, to: Double, since: Date, now: Date) -> Double {
        from + (to - from) * Ease.back(now.timeIntervalSince(since) / 0.55)
    }

    private func moment(at now: Date) -> BeadsMoment {
        var m = BeadsMoment()
        m.turn = Self.turn(from: turnFrom, to: Double(steps.count), since: turnedAt, now: now)
        guard let outcome else { return m }
        let t = now.timeIntervalSince(outcome.at)
        guard outcome.matched else {
            guard t < 1.2 else { return m }
            m.drop = Ease.in(t / 0.5)
            if !reduceMotion {
                m.shake = 9 * sin(t * 42) * exp(-5 * t)
                m.sink = sin(.pi * Ease.clamp(t / 0.8))
            }
            return m
        }
        // A match: gather at once, colour, land with a bounce and a ripple, then part again.
        let landed = 0.38, fades = landed + 1.0
        guard t < fades + 0.6 else { return m }
        m.merge = Ease.inOut(t / 0.35) * (1 - Ease.inOut((t - fades) / 0.4))
        m.flood = Ease.out((t - 0.18) / 0.25)
        m.colour = m.flood * (1 - Ease.clamp((t - fades) / 0.4))
        guard !reduceMotion else { return m }
        let land = t - landed
        if land < 0 {
            m.squat = 1 - 0.06 * Ease.inOut(t / landed)
        } else {
            m.squat = 1 + 0.16 * exp(-6 * land) * sin(18 * land) - 0.06 * exp(-10 * land)
            m.lift = 20 * exp(-3 * land) * abs(sin(8.5 * land))
        }
        for (echo, strength) in [0.6, 0.4, 0.25].enumerated() {
            let age = (land - 0.13 * Double(echo)) / 0.9
            if age > 0, age < 1 { m.ripples.append((reach: Ease.out(age), alpha: (1 - age) * strength)) }
        }
        return m
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, _ m: BeadsMoment, at now: Date) {
        let scale = size.width / 230
        let transform = CGAffineTransform(translationX: size.width / 2, y: size.height * 0.6).scaledBy(x: scale, y: scale)
        func iso(_ x: Double, _ y: Double, _ z: Double) -> CGPoint { RingGeometry.project(x, y, z).applying(transform) }
        let flat = sin(RingGeometry.elevation), ball = Self.ball * scale
        let hair = StrokeStyle(lineWidth: 1.25)
        func age(_ index: Int) -> Double { index < born.count ? now.timeIntervalSince(born[index]) : 10 }

        // The ground, under everything.
        for ripple in m.ripples {
            let reach = 34 + (88 - 34) * ripple.reach
            var circle = Path()
            circle.addLines((0..<64).map { iso(cos(Double($0) / 64 * 2 * .pi) * reach, sin(Double($0) / 64 * 2 * .pi) * reach, 6) })
            circle.closeSubpath()
            context.stroke(circle, with: .color(Color.ink.opacity(ripple.alpha)), style: hair)
        }

        let held = TriggerRules.held(steps).steps
        let beads = (0..<8).map { index -> (index: Int, x: Double, y: Double, z: Double) in
            // Bead `index` is at the front when the ring has turned `index` places.
            let angle = Self.place + (m.turn - Double(index)) * Self.place
            var z = 8 - 5 * m.sink + 10 * m.merge
            if index < steps.count {
                let age = age(index)
                if !reduceMotion { z += 9 * exp(-5.5 * age) * sin(2 * .pi * 2.6 * age) }
                // Beads gestured with a finger down float until it lifts.
                if held[index], !steps[index].gesture.isRelease { z += 6 * Ease.clamp(age / 0.35) * (1 - m.drop) }
            }
            return (index, cos(angle) * Self.ring * (1 - m.merge), sin(angle) * Self.ring * (1 - m.merge), z)
        }
        .sorted { $0.x + $0.y < $1.x + $1.y }
        let apart = 1 - Ease.smooth((m.merge - 0.55) / 0.4)

        // Shadows first, so no bead is drawn under another bead's shadow.
        for bead in beads {
            let r = ball * max(0.45, 0.8 - max(0, bead.z - 8) / 60)
            context.stroke(Self.ellipse(iso(bead.x, bead.y, 6), r, r * flat), with: .color(Color.ink.opacity(0.3 * apart)), style: StrokeStyle(lineWidth: 1))
        }
        for bead in beads {
            let filled = bead.index < steps.count ? Ease.clamp(age(bead.index) / 0.15) * (1 - m.drop) : 0
            var centre = iso(bead.x, bead.y, bead.z + Self.ball)
            centre.x += m.shake * (bead.index < steps.count ? 1 : 0.3)
            let body = Self.ellipse(centre, ball, ball)
            context.fill(body, with: .color(Color.paper.opacity(apart)))
            context.stroke(body, with: .color(Color.ink.opacity((0.4 + 0.6 * filled) * apart)), style: hair)
            if filled > 0.01 {
                let gesture = steps[bead.index].gesture
                let pop = reduceMotion ? 1 : Ease.back(age(bead.index) / 0.3)
                mark(gesture, at: centre, unit: ball * 0.36 * pop * (gesture.isHold || gesture.isRelease ? 0.8 : 1),
                     alpha: filled * (1 - Ease.clamp((m.merge - 0.25) / 0.4)), in: context)
            }
        }

        // Gathered: one ball where the eight were, standing on the ground as they do.
        if m.merge > 0.5 {
            let grown = Ease.out((m.merge - 0.5) / 0.5)
            let r = ball * (0.6 + 1.3 * grown) * m.squat
            var centre = iso(0, 0, 6)
            centre.y -= m.lift + r * 0.92
            let shade = r * 0.8 * max(0.45, 1 - m.lift / 70)
            context.stroke(Self.ellipse(iso(0, 0, 6), shade, shade * flat), with: .color(Color.ink.opacity(0.3 * grown)), style: StrokeStyle(lineWidth: 1))
            let body = Self.ellipse(centre, r, r)
            context.fill(body, with: .color(Color.paper.opacity(grown)))
            if m.colour > 0 { context.fill(Self.ellipse(centre, r * m.flood, r * m.flood), with: .color(tint.opacity(m.colour * grown))) }
            context.stroke(body, with: .color(Color.ink.opacity(grown)), style: hair)
        }
    }

    // MARK: Glyphs

    private static func ellipse(_ centre: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - rx, y: centre.y - ry, width: 2 * rx, height: 2 * ry))
    }

    /// One step's glyph: index solid, middle open, a pair for a double tap, a soft arrowhead
    /// for a swipe, a diamond or square for the wrist.
    private func mark(_ gesture: GestureKind, at point: CGPoint, unit: CGFloat, alpha: Double, in context: GraphicsContext) {
        if let single = gesture == .doubleTapIndex ? GestureKind.tapIndex : gesture == .doubleTapMiddle ? .tapMiddle : nil {
            for side in [-1.0, 1.0] {
                mark(single, at: CGPoint(x: point.x + side * unit * 1.2, y: point.y), unit: unit * 0.8, alpha: alpha, in: context)
            }
            return
        }
        let ink = GraphicsContext.Shading.color(Color.ink.opacity(alpha))
        let paper = GraphicsContext.Shading.color(Color.paper.opacity(alpha))
        let line = StrokeStyle(lineWidth: max(1.5, unit * 0.36), lineCap: .round, lineJoin: .round)
        func open(_ path: Path) { context.fill(path, with: paper); context.stroke(path, with: ink, style: line) }
        func diamond(_ half: CGFloat) -> Path {
            var path = Path()
            path.addLines([CGPoint(x: point.x, y: point.y - half), CGPoint(x: point.x + half, y: point.y),
                           CGPoint(x: point.x, y: point.y + half), CGPoint(x: point.x - half, y: point.y)])
            path.closeSubpath()
            return path
        }
        switch gesture {
        case .tapIndex, .doubleTapIndex, .holdIndex, .releaseIndex:
            context.fill(Self.ellipse(point, unit * 1.15, unit * 1.15), with: ink)
        case .tapMiddle, .doubleTapMiddle, .holdMiddle, .releaseMiddle:
            open(Self.ellipse(point, unit, unit))
        case .swipeUp, .swipeDown, .swipeLeft, .swipeRight:
            let v: CGVector = gesture == .swipeUp ? CGVector(dx: 0, dy: -1) : gesture == .swipeDown ? CGVector(dx: 0, dy: 1)
                : gesture == .swipeLeft ? CGVector(dx: -1, dy: 0) : CGVector(dx: 1, dy: 0)
            let h = unit * 1.3
            func p(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
                CGPoint(x: point.x + (v.dx * along - v.dy * across) * h, y: point.y + (v.dy * along + v.dx * across) * h)
            }
            var arrow = Path()
            arrow.addLines([p(0.9, 0), p(-0.65, 0.9), p(-0.65, -0.9)]); arrow.closeSubpath()
            context.fill(arrow, with: ink)
            context.stroke(arrow, with: ink, style: StrokeStyle(lineWidth: unit * 0.5, lineJoin: .round))
        case .rotation: open(diamond(unit * 1.3))
        case .movement: context.fill(diamond(unit * 1.4), with: ink)
        case .air: open(Path(CGRect(x: point.x - unit, y: point.y - unit, width: 2 * unit, height: 2 * unit)))
        }
    }
}

/// Curves over 0...1; anything outside is held at the ends.
private enum Ease {
    static func clamp(_ t: Double) -> Double { min(1, max(0, t)) }
    static func out(_ t: Double) -> Double { 1 - pow(1 - clamp(t), 3) }
    static func `in`(_ t: Double) -> Double { pow(clamp(t), 3) }
    static func inOut(_ t: Double) -> Double { let t = clamp(t); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func smooth(_ t: Double) -> Double { let t = clamp(t); return t * t * (3 - 2 * t) }
    /// Ease out with a small overshoot.
    static func back(_ t: Double) -> Double { let t = clamp(t) - 1; return 1 + 2.4 * t * t * t + 1.4 * t * t }
}
