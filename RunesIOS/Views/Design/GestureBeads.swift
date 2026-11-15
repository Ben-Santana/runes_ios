import SwiftUI

// The home ring's eight beads as a live record of what the band is doing, at the top of
// Mappings and in Settings → Developer → Runes lab. The front bead becomes each gesture as it arrives. Gestures stack round the ring
// only while they could still lead to a combo; any other gesture stands alone. When a mapping
// runs, the beads hold for a moment so the motion can be read, then gather into one ball of
// that mapping's colour. Gestures that come to nothing lose their runes.

/// What the beads are showing. Feed it gestures and outcomes; it clears itself between attempts.
@MainActor final class BeadsFeed: ObservableObject {
    struct Outcome: Equatable {
        enum Kind { case matched, missed, faded }
        let kind: Kind
        let at: Date
    }

    /// The live combos of the active profile: what decides whether gestures stack.
    var combos: [[ComboStep]] = []
    /// A gesture on a bead. A release has no bead of its own: it lands on its hold's bead,
    /// whose ring falls.
    struct Bead: Equatable {
        var step: ComboStep
        var born: Date
        var released: Date?
    }

    /// The gestures made, oldest first, and the beads that carry them.
    @Published private(set) var steps: [ComboStep] = []
    private(set) var beads: [Bead] = []
    /// The mapping that last ran.
    private(set) var ran: String?
    /// How many places the ring has turned: one per bead still waiting for more.
    private(set) var turns = 0
    /// The turn the ring was at when `turns` last changed, and when that was.
    private(set) var turnFrom = 0.0
    private(set) var turnedAt = Date.distantPast
    @Published private(set) var outcome: Outcome?
    /// Index into `ScoreTint` for the mapping that last ran.
    private(set) var tint = 0

    /// How long a started combo may wait for its next gesture, and a lone gesture for its mapping.
    static let patience: TimeInterval = 2.0
    static let glance: TimeInterval = 0.9
    private var pending: Task<Void, Never>?

    func turn(at now: Date) -> Double {
        turnFrom + (Double(turns) - turnFrom) * Ease.back(now.timeIntervalSince(turnedAt) / 0.55)
    }

    func gesture(_ step: ComboStep) {
        let now = Date(), grown = steps + [step]
        // It joins the stack only if the stack could still become a combo.
        let joins = !steps.isEmpty && outcome == nil && leads(grown)
        let next = joins ? grown : [step]
        let open = leads(next) && !combos.contains { $0.count == next.count && fits(next, $0) }
        if joins {
            turnFrom = turn(at: now)
            let finger = step.gesture.finger
            if step.gesture.isRelease, let held = beads.lastIndex(where: { $0.step.gesture.isHold && $0.step.gesture.finger == finger && $0.released == nil }) {
                beads[held].released = now
            } else {
                beads.append(Bead(step: step, born: now))
            }
        } else {
            // A fresh start: the beads are alike, so the ring can be anywhere.
            turnFrom = 0
            beads = [Bead(step: step, born: now)]
        }
        turns = open ? beads.count : beads.count - 1; turnedAt = now
        outcome = nil
        steps = next
        after(open ? Self.patience : Self.glance) { $0.end(open ? .missed : .faded) }
    }

    /// A mapping ran on the gestures showing.
    func matched(_ id: String, tint: Int) {
        guard !steps.isEmpty, outcome?.kind != .matched else { return }
        let now = Date()
        // The last bead stays at the front to be read.
        turnFrom = turn(at: now); turns = beads.count - 1; turnedAt = now
        ran = id
        self.tint = tint
        outcome = Outcome(kind: .matched, at: now)
        after(BeadsCanvas.show + BeadsCanvas.play) { $0.clear() }
    }

    private func end(_ kind: Outcome.Kind) {
        guard !steps.isEmpty else { return }
        outcome = Outcome(kind: kind, at: Date())
        after(0.6) { $0.clear() }
    }

    private func clear() {
        beads = []; turns = 0; turnFrom = 0; turnedAt = .distantPast
        steps = []
    }

    /// Whether `steps` is the start, or the whole, of some combo.
    private func leads(_ steps: [ComboStep]) -> Bool { combos.contains { fits(steps, $0) } }
    private func fits(_ steps: [ComboStep], _ combo: [ComboStep]) -> Bool {
        steps.count <= combo.count && zip(combo, steps).allSatisfy { $0.matches($1) }
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

    var body: some View {
        // The canvas is given plain values: nothing read only inside a drawing closure is tracked.
        BeadsCanvas(beads: feed.beads, turns: feed.turns, turnFrom: feed.turnFrom, turnedAt: feed.turnedAt,
                    outcome: feed.outcome, tint: ScoreTint.fill(feed.tint))
            .accessibilityElement()
            .accessibilityLabel("Recent gestures")
            .accessibilityValue(feed.steps.isEmpty ? "None" : feed.steps.map(\.name).joined(separator: ", "))
    }
}

/// The beads, fed by the band through `store`. With `idle` set, a line under them says what
/// they are doing: the gestures so far and the hand for the one that comes next, then what
/// they came to. Without it the beads stand alone.
struct BeadsStage: View {
    @ObservedObject var feed: BeadsFeed
    @ObservedObject var store: MappingStore
    var idle: String?
    @State private var heardThrough = 0

    var body: some View {
        VStack(spacing: 0) {
            GestureBeads(feed: feed)
            if let idle { spoken(idle) }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: feed.steps.count) { _, count in count > 0 }
        .sensoryFeedback(.success, trigger: feed.outcome) { _, outcome in outcome?.kind == .matched }
        .onAppear {
            heardThrough = store.recent.last?.id ?? 0
            feed.combos = liveCombos
        }
        .onChange(of: store.active.combos) { _, _ in feed.combos = liveCombos }
        .onChange(of: store.recent) { _, recent in
            for gesture in recent where gesture.id > heardThrough { feed.gesture(gesture.step) }
            heardThrough = recent.last?.id ?? heardThrough
        }
        .onChange(of: store.lastFired?.at) { _, _ in
            if let fired = store.lastFired { feed.matched(fired.id, tint: Self.tint(for: fired.id, in: store)) }
        }
    }

    private var liveCombos: [[ComboStep]] { store.active.combos.filter(\.isLive).compactMap(\.steps) }

    /// A mapping's name: its gesture, the name it was given, or its place among the combos.
    static func title(_ mapping: Mapping, in store: MappingStore) -> String {
        if let kind = mapping.motion { return kind.name }
        if let name = mapping.name, !name.isEmpty { return name }
        return "Spell \((store.active.combos.firstIndex { $0.id == mapping.id } ?? 0) + 1)"
    }

    /// A mapping's colour. Mappings have none of their own yet, so each takes one by its place in the profile.
    static func tint(for id: String, in store: MappingStore) -> Int {
        store.active.mappings.firstIndex { $0.id == id } ?? 0
    }

    /// The gesture that would carry the beads on, when every combo they could become agrees on it.
    private var next: ComboStep? {
        let shown = feed.steps
        guard !shown.isEmpty, feed.outcome == nil else { return nil }
        let ahead = liveCombos.filter { $0.count > shown.count && zip($0, shown).allSatisfy { $0.matches($1) } }.map { $0[shown.count] }
        guard let first = ahead.first, ahead.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private func spoken(_ idle: String) -> some View {
        let line: (title: String, detail: String?, quiet: Bool) = {
            guard !feed.steps.isEmpty else { return (idle, nil, true) }
            switch feed.outcome?.kind {
            case .matched:
                guard let mapping = store.active.mappings.first(where: { $0.id == feed.ran }) else { return ("Done", nil, false) }
                return (Self.title(mapping, in: store), mapping.actions.first?.label(profiles: store.library.profiles), false)
            case .missed: return ("Left unfinished.", nil, true)
            case .faded: return ("Nothing is mapped to that.", nil, true)
            case nil: return (feed.steps.map(\.name).joined(separator: " · "), nil, false)
            }
        }()
        let next = next
        return VStack(spacing: 2) {
            Text(line.title).font(line.quiet ? .caption : line.detail == nil && next == nil ? .label : line.detail == nil ? .caption : .heading)
                .foregroundStyle(line.quiet || next != nil ? Color.muted : Color.ink)
            if let detail = line.detail { Text(detail).font(.caption).foregroundStyle(Color.muted) }
            if let next {
                HStack(spacing: 6) {
                    Text("Then").foregroundStyle(Color.muted)
                    StepIcon(step: next, size: 20)
                    Text(next.name.prefix(1).lowercased() + next.name.dropFirst())
                }
                .font(.label)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, minHeight: 44)
        .id(line.title).transition(.opacity)
        .animation(.standard, value: line.title)
        .accessibilityElement(children: .combine)
    }
}

/// Everything that moves, at one instant.
private struct BeadsMoment {
    /// How many places the ring has turned.
    var turn = 0.0
    /// Coming to nothing: runes fading, the sideways shake in points, the beads' dip.
    var drop = 0.0, shake = 0.0, sink = 0.0
    /// 0...1: the beat before a match plays, when the gesture is held up to be read.
    var present = 0.0
    /// Rune opacity, and how far the beads have taken the colour (Reduce Motion only).
    var runes = 1.0, colour = 0.0
    /// 0...1: the beads drawn into the centre and faded into one ball.
    var gather = 0.0
    var ball: (grown: Double, squat: Double, lift: Double)?
    /// Rings on the ground.
    var ripples: [(radius: Double, alpha: Double)] = []
}

private struct BeadsCanvas: View {
    let beads: [BeadsFeed.Bead]
    let turns: Int
    let turnFrom: Double
    let turnedAt: Date
    let outcome: BeadsFeed.Outcome?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long a matched gesture is held up before the match plays, and how long that takes.
    static let show = 0.45
    static let play = 2.3
    private static let place = Double.pi / 4
    private static let ring = 49.0, ball = 13.0

    var body: some View {
        // Wide enough for the ripple; as tall as a ring seen from this angle needs.
        Color.clear.aspectRatio(1.8, contentMode: .fit).overlay {
            GeometryReader { proxy in
                TimelineView(.animation) { timeline in
                    Canvas { context, size in draw(&context, size, moment(at: timeline.date), at: timeline.date) }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    // MARK: Timing

    private func moment(at now: Date) -> BeadsMoment {
        var m = BeadsMoment()
        m.turn = turnFrom + (Double(turns) - turnFrom) * Ease.back(now.timeIntervalSince(turnedAt) / 0.55)
        guard let outcome else { return m }
        let t = now.timeIntervalSince(outcome.at)
        guard outcome.kind == .matched else {
            // Come to nothing: the runes go. A broken combo also shakes and dips.
            guard t < 1.2 else { return m }
            m.drop = Ease.in(t / 0.5)
            if outcome.kind == .missed, !reduceMotion {
                m.shake = 9 * sin(t * 42) * exp(-5 * t)
                m.sink = sin(.pi * Ease.clamp(t / 0.8))
            }
            return m
        }
        // Once the match has played the beads stay bare until the feed clears them a moment later.
        guard t < Self.show + Self.play else { m.runes = 0; return m }
        m.present = Ease.out(t / 0.15) * (1 - Ease.clamp((t - Self.show) / 0.15))
        let T = t - Self.show
        guard T >= 0 else { return m }
        if reduceMotion {
            // No movement: the beads take the colour and give it back.
            m.runes = 1 - Ease.clamp(T / 0.2)
            m.colour = Ease.clamp(T / 0.2) * (1 - Ease.clamp((T - 1.2) / 0.4))
            return m
        }
        gather(&m, T)
        return m
    }

    /// The beads fall into the centre as one ball, which lands with a bounce and three rings.
    private func gather(_ m: inout BeadsMoment, _ T: Double) {
        let landed = 0.38, fades = landed + 1.0, land = T - landed
        m.runes = 1 - Ease.clamp(T / 0.2)
        m.gather = Ease.inOut(T / 0.35) * (1 - Ease.inOut((T - fades) / 0.4))
        let grown = Ease.out((m.gather - 0.5) / 0.5)
        if land < 0 {
            m.ball = (grown, 1 - 0.06 * Ease.inOut(T / landed), 0)
        } else {
            m.ball = (grown, 1 + 0.16 * exp(-6 * land) * sin(18 * land) - 0.06 * exp(-10 * land), 20 * exp(-3 * land) * abs(sin(8.5 * land)))
        }
        for (echo, strength) in [0.85, 0.6, 0.4].enumerated() {
            let age = (land - 0.13 * Double(echo)) / 0.9
            if age > 0, age < 1 { m.ripples.append((34 + 54 * Ease.out(age), (1 - age) * strength)) }
        }
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, _ m: BeadsMoment, at now: Date) {
        let scale = size.width / 230
        let transform = CGAffineTransform(translationX: size.width / 2, y: size.height * 0.6).scaledBy(x: scale, y: scale)
        func iso(_ x: Double, _ y: Double, _ z: Double) -> CGPoint { RingGeometry.project(x, y, z).applying(transform) }
        func ground(_ x: Double, _ y: Double, _ radius: Double) -> Path {
            var circle = Path()
            circle.addLines((0..<64).map { iso(x + cos(Double($0) / 64 * 2 * .pi) * radius, y + sin(Double($0) / 64 * 2 * .pi) * radius, 6) })
            circle.closeSubpath()
            return circle
        }
        let flat = sin(RingGeometry.elevation), ball = Self.ball * scale
        let hair = StrokeStyle(lineWidth: 1.25)
        let carried = self.beads
        func age(_ index: Int) -> Double { index < carried.count ? now.timeIntervalSince(carried[index].born) : 10 }

        // The ground, under everything, in the mapping's colour.
        for ripple in m.ripples {
            context.stroke(ground(0, 0, ripple.radius), with: .color(tint.opacity(ripple.alpha)), style: StrokeStyle(lineWidth: 1.5))
        }

        let front = min(max(turns, 0), 7)
        let radius = Self.ring * (1 - m.gather)
        func angle(_ index: Int) -> Double { Self.place + (m.turn - Double(index)) * Self.place }
        let beads = (0..<8).map { index -> (index: Int, x: Double, y: Double, z: Double) in
            var z = 8 - 5 * m.sink + 10 * m.gather
            if index < carried.count {
                let age = age(index)
                if !reduceMotion { z += 9 * exp(-5.5 * age) * sin(2 * .pi * 2.6 * age) }
                // All of them rise to be read.
                z += 4 * m.present
            }
            return (index, cos(angle(index)) * radius, sin(angle(index)) * radius, z)
        }
        .sorted { $0.x + $0.y < $1.x + $1.y }
        let apart = 1 - Ease.smooth((m.gather - 0.55) / 0.4)

        // Shadows first, so no bead is drawn under another bead's shadow.
        for bead in beads {
            let r = ball * max(0.45, 0.8 - max(0, bead.z - 8) / 60), taken = m.colour
            let shadow = Self.ellipse(iso(bead.x, bead.y, 6), r, r * flat)
            context.stroke(shadow, with: .color(Color.ink.opacity(0.3 * apart * (1 - taken))), style: StrokeStyle(lineWidth: 1))
            if taken > 0 { context.stroke(shadow, with: .color(tint.opacity(0.45 * apart * taken)), style: StrokeStyle(lineWidth: 1)) }
        }
        for bead in beads {
            let filled = bead.index < carried.count ? Ease.clamp(age(bead.index) / 0.15) * (1 - m.drop) : 0
            let taken = m.colour
            var centre = iso(bead.x, bead.y, bead.z + Self.ball)
            centre.x += m.shake * (bead.index < carried.count ? 1 : 0.3)
            let r = ball * (bead.index == front && bead.index < carried.count ? 1 + 0.14 * m.present : 1)
            let body = Self.ellipse(centre, r, r)
            context.fill(body, with: .color(Color.paper.opacity(apart)))
            if taken > 0 { context.fill(body, with: .color(tint.opacity(taken * apart))) }
            // A bead is in full ink only while it carries a rune, and has no outline once it takes the colour.
            let shown = filled * m.runes
            context.stroke(body, with: .color(Color.ink.opacity((0.4 + 0.6 * shown) * apart * (1 - taken))), style: hair)
            if shown > 0.01 {
                let mark = carried[bead.index]
                let pop = reduceMotion ? 1 : Ease.back(age(bead.index) / 0.3)
                // A release is the hold's ring let go: on the hold's own bead, it falls from the head of the stave.
                var gesture = mark.step.gesture, fall = 1.0
                if let released = mark.released {
                    gesture = gesture.finger == "middle" ? .releaseMiddle : .releaseIndex
                    if !reduceMotion { fall = Ease.in(now.timeIntervalSince(released) / 0.26) }
                }
                let k = r * 2 * pop / 24
                let rune = Self.wrap(GestureRune.path(gesture, fall: fall), scale: k, facing: Self.facing(angle(bead.index)), centre: centre, radius: r)
                // Softer than the bead's own outline, as a mark in its surface.
                context.stroke(rune, with: .color(Color.ink.opacity(0.7 * shown)), style: StrokeStyle(lineWidth: 1.5 * k, lineCap: .round, lineJoin: .round))
            }
        }

        // Gathered: one ball of colour where the eight were, standing on the ground as they do.
        if let gathered = m.ball, gathered.grown > 0 {
            let r = ball * (0.6 + 1.3 * gathered.grown) * gathered.squat
            var centre = iso(0, 0, 6)
            centre.y -= gathered.lift + r * 0.92
            let shade = r * 0.8 * max(0.45, 1 - gathered.lift / 70)
            context.stroke(Self.ellipse(iso(0, 0, 6), shade, shade * flat), with: .color(tint.opacity(0.45 * gathered.grown)), style: StrokeStyle(lineWidth: 1))
            context.fill(Self.ellipse(centre, r, r), with: .color(tint.opacity(gathered.grown)))
        }
    }

    // MARK: Runes on a sphere

    /// Where on a bead its rune sits, as a unit vector in view space (x right, y up, z toward
    /// the eye). The rune leans out from the ring, tipped up to meet the eye, so the front bead
    /// shows it square on and it slides round toward the edge as the bead travels. It is never
    /// carried further round than can still be read.
    private static func facing(_ angle: Double) -> SIMD3<Double> {
        let e = RingGeometry.elevation, s = 0.5.squareRoot(), near = s * (cos(angle) + sin(angle))
        let outward = SIMD3(cos(e) * s * (cos(angle) - sin(angle)), cos(e) * sin(e) * (1 - near), cos(e) * cos(e) * near + sin(e) * sin(e))
        // Half way between facing out and facing the eye: gestures stack along the side of the
        // ring, where a rune facing fully outward would be seen edge on.
        let between = outward * 0.5 + SIMD3(0, 0, 0.5)
        let out = between / (between * between).sum().squareRoot()
        let furthest = 0.9
        guard out.z < cos(furthest) else { return out }
        let across = (out.x * out.x + out.y * out.y).squareRoot()
        guard across > 1e-6 else { return SIMD3(0, 0, 1) }
        return SIMD3(out.x / across * sin(furthest), out.y / across * sin(furthest), cos(furthest))
    }

    /// A rune in its 24-unit box laid on a bead's surface around `facing`, upright against the
    /// world's vertical: distances from the rune's centre become arcs, so it curves with the bead.
    private static func wrap(_ rune: Path, scale: Double, facing n: SIMD3<Double>, centre: CGPoint, radius: Double) -> Path {
        let vertical = SIMD3(0, cos(RingGeometry.elevation), sin(RingGeometry.elevation))
        let lean = vertical - n * (vertical * n).sum()
        let length = (lean * lean).sum().squareRoot()
        let up = length > 1e-6 ? lean / length : SIMD3(0, 1, 0)
        let right = SIMD3(up.y * n.z - up.z * n.y, up.z * n.x - up.x * n.z, up.x * n.y - up.y * n.x)
        func place(_ point: CGPoint) -> CGPoint {
            let u = (point.x - 12) * scale / radius, v = (12 - point.y) * scale / radius, arc = (u * u + v * v).squareRoot()
            let on = arc < 1e-6 ? n : n * cos(arc) + (right * u + up * v) * (sin(arc) / arc)
            return CGPoint(x: centre.x + radius * on.x, y: centre.y - radius * on.y)
        }
        func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        var wrapped = Path(), last = CGPoint.zero, start = CGPoint.zero
        rune.forEach { element in
            switch element {
            case .move(let to):
                wrapped.move(to: place(to)); last = to; start = to
            case .line(let to):
                // A straight stroke bends too, so it is laid down in short pieces.
                for step in 1...6 { wrapped.addLine(to: place(mix(last, to, Double(step) / 6))) }
                last = to
            case .quadCurve(let to, let control):
                for step in 1...8 {
                    let t = Double(step) / 8
                    wrapped.addLine(to: place(mix(mix(last, control, t), mix(control, to, t), t)))
                }
                last = to
            case .curve(let to, let control1, let control2):
                for step in 1...8 {
                    let t = Double(step) / 8
                    let a = mix(last, control1, t), b = mix(control1, control2, t), c = mix(control2, to, t)
                    wrapped.addLine(to: place(mix(mix(a, b, t), mix(b, c, t), t)))
                }
                last = to
            case .closeSubpath:
                wrapped.closeSubpath(); last = start
            }
        }
        return wrapped
    }

    private static func ellipse(_ centre: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - rx, y: centre.y - ry, width: 2 * rx, height: 2 * ry))
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
