import SwiftUI

// A combo as beads on a string: each step a bead carrying its rune, hung from the top of the
// combo page in the order the steps are made. The string between two beads is the time allowed
// between their steps, so a longer time hangs them further apart, and a spark runs down it at
// that pace. While the combo is on the string hangs loose in a slight wind. Turned off, time stops:
// the string is a straight line, the beads solid and iced over, and the wind and its leaves stay where they were.

/// What the string is asked to show.
struct BeadStringScene {
    /// Whether another bead can still be added: a dashed ring waits at the end of the string.
    var showsEnd = true
    /// The bead the pad would change; nil when the pad adds to the end.
    var selected: Int?
    /// Seconds allowed between steps; nil when there is no limit.
    var interval: Double?
    /// 0...1: where that time sits among the choices.
    var tempo = 0.5
    /// Time stopped: the combo is turned off.
    var frozen = false
    /// Whether a finger is still down between step i and the next.
    var bridges: [Bool] = []
    var listening = false
    /// How much of the canvas the string may use; the rest lies under the pad.
    var width: CGFloat = 0
    /// Where across the canvas the string hangs from.
    var hang: CGFloat = 0
    /// Reduce Motion: the string hangs straight and nothing drifts.
    var still = false
}

/// The string's moving parts. The canvas steps it every frame; the page tells it what changed.
final class BeadString {
    enum Hit: Equatable { case bead(Int), end }
    fileprivate typealias Point = SIMD2<Double>

    fileprivate struct Bead {
        var step: ComboStep
        var pos = Point(), prev = Point()
        /// Extra string above it, let out when a neighbour leaves and taken back in.
        var slack = 0.0
        var yaw = 0.0, spin = 0.0
        var born = -10.0
        /// Where it flies in from, and when it reached the string.
        var from: Point?
        var landed = -10.0
        /// The step it carried before it was changed, and when it turned over.
        var was: ComboStep?
        var turned = -10.0
        /// How far from its place it is drawn while beads change places, sprung back to nothing.
        var shift = Point(), drift = Point()
    }
    fileprivate struct Ghost { var step: ComboStep; var pos: Point; var vel: Point; var yaw: Double; var born: Double; var radius: Double }
    fileprivate struct Mote { var leaf: Bool; var pos: Point; var speed: Double; var seed: Double; var size: Double }
    fileprivate struct Ripple { var at: Point; var born: Double }

    fileprivate var beads: [Bead] = []
    /// The end of the string: the ring that waits for the next bead, or a knot.
    fileprivate var tail = Bead(step: ComboStep(.tapIndex))
    fileprivate var ghosts: [Ghost] = []
    fileprivate var motes: [Mote] = []
    fileprivate var ripples: [Ripple] = []
    /// Seconds since the string appeared, and the wind's own time, which stops when frozen.
    fileprivate var clock = 0.0, air = 0.0
    fileprivate var radius = 0.0, gap = 0.0
    fileprivate var frozen = false, frostAt = -10.0, straight = 0.0
    fileprivate var selection: Int?, selectedAt = -10.0
    /// Where everything was last drawn, for touches.
    fileprivate var shown: [Point] = [], shownTail = Point(), anchor = Point()
    private var showsEnd = true
    private var tailReach = 0.0
    private var last: Date?
    private var laid = false
    private var size = CGSize.zero
    private var seed: UInt64 = 0x9E3779B97F4A7C15

    /// Where the next bead added comes from: the key that was touched.
    var origin: CGPoint?
    /// A bead held under a finger, drawn there instead of on the string.
    fileprivate var held: (index: Int, at: Point)?

    fileprivate static let flight = 0.46
    fileprivate static let tone = Color.muted
    private static let gravity = 1500.0

    // MARK: Changes

    /// Brings the beads in line with `steps`, working out what happened so it can be shown:
    /// one added, one taken off, one changed, or two trading places.
    func sync(_ steps: [ComboStep]) {
        let old = beads.map(\.step)
        defer { origin = nil }
        guard old != steps else { return }
        guard laid else { beads = steps.map { Bead(step: $0) }; return }
        if steps.count == old.count + 1, Array(steps.dropLast()) == old {
            add(steps[old.count])
        } else if steps.count == old.count - 1, let index = old.indices.first(where: { i in var cut = old; cut.remove(at: i); return cut == steps }) {
            remove(index)
        } else if steps.count == old.count {
            let changed = steps.indices.filter { steps[$0] != old[$0] }
            if changed.count > 1, changed.map({ old[$0] }).sorted(by: Self.before) == changed.map({ steps[$0] }).sorted(by: Self.before) {
                reorder(changed, to: steps)
            } else {
                for index in changed { beads[index].was = old[index]; beads[index].turned = clock; beads[index].step = steps[index] }
            }
        } else {
            // Something else rewrote the steps: start the string again.
            beads = steps.map { Bead(step: $0) }
            laid = false
        }
    }

    private func add(_ step: ComboStep) {
        var bead = Bead(step: step)
        bead.pos = tail.pos; bead.prev = tail.prev
        // Added in a hurry, the ring is still on the last bead: start below it, not on it.
        if let last = beads.last, distance(last.pos, tail.pos) < radius {
            bead.pos = last.pos + Point(0, radius); bead.prev = bead.pos
        }
        bead.born = clock
        bead.yaw = -1.1
        if let origin { bead.from = Point(origin.x, origin.y) } else { bead.landed = clock }
        beads.append(bead)
        // The ring gives up its place and is let down again below the new bead.
        tail.slack = -tailReach
    }

    private func remove(_ index: Int) {
        let gone = beads.remove(at: index)
        let at = shown.indices.contains(index) ? shown[index] : gone.pos
        ghosts.append(Ghost(step: gone.step, pos: at, vel: Point(70 + 60 * random(), -190), yaw: gone.yaw, born: clock, radius: radius))
        // The string it sat on is taken in, not snapped.
        let pitch = 2 * radius + gap
        if index < beads.count { beads[index].slack += pitch } else { tail.slack += pitch }
    }

    /// The same beads in new places. Each keeps where it is drawn and whatever it was doing,
    /// and is sprung to its new place, so moves made in a hurry run into each other.
    private func reorder(_ changed: [Int], to steps: [ComboStep]) {
        guard shown.count == beads.count else { for index in changed { beads[index].step = steps[index] }; return }
        let before = beads, drawn = shown
        var free = changed
        for index in changed {
            guard let slot = free.firstIndex(where: { before[$0].step == steps[index] }) else { continue }
            let from = free.remove(at: slot)
            beads[index].step = steps[index]
            beads[index].yaw = before[from].yaw; beads[index].spin = before[from].spin
            beads[index].was = before[from].was; beads[index].turned = before[from].turned
            beads[index].shift = drawn[from] - (drawn[index] - before[index].shift)
            // Stepping aside as they pass: down the string goes by the right, up by the left.
            beads[index].drift = before[from].drift + Point((from < index ? 1 : -1) * radius * 22, 0)
        }
    }
    private static func before(_ a: ComboStep, _ b: ComboStep) -> Bool { String(describing: a) < String(describing: b) }

    // MARK: Touches

    func hit(_ point: CGPoint) -> Hit? {
        let p = Point(point.x, point.y)
        if let index = shown.indices.min(by: { distance(shown[$0], p) < distance(shown[$1], p) }), distance(shown[index], p) < radius + 8 {
            return .bead(index)
        }
        if showsEnd, distance(shownTail, p) < radius * 0.62 + 16 { return .end }
        return nil
    }

    func hold(_ index: Int, at point: CGPoint) { held = (index, Point(point.x, point.y)) }
    /// Let go, the bead springs back to its place on the string.
    func release() { held = nil }

    /// The place on the string nearest a point, for a bead dragged there.
    func slot(_ point: CGPoint) -> Int {
        let pitch = max(1, 2 * radius + gap)
        let place = Int(((Double(point.y) - anchor.y - lead) / pitch).rounded())
        return min(max(0, place), max(0, beads.count - 1))
    }

    /// A touch on the air beside the string pushes it away.
    func poke(_ point: CGPoint) {
        let p = Point(point.x, point.y)
        ripples.append(Ripple(at: p, born: clock))
        func push(_ bead: inout Bead) {
            let away = bead.pos - p, far = max(1, distance(bead.pos, p))
            bead.prev -= away / far * 4.5 * exp(-far / 90)
        }
        for index in beads.indices { push(&beads[index]) }
        push(&tail)
    }

    // MARK: Time

    fileprivate func step(to date: Date, size: CGSize, scene: BeadStringScene) {
        let dt = last.map { min(0.05, max(0, date.timeIntervalSince($0))) } ?? 0
        last = date
        clock += dt
        self.size = size
        showsEnd = scene.showsEnd
        tailReach = tailLength(scene)
        // The string is carried across when the pad opens or closes, and swings as it goes.
        let hang = Double(scene.hang)
        anchor = Point(laid && !scene.still ? anchor.x + (hang - anchor.x) * (1 - exp(-dt * 7)) : hang, -6)

        let off = scene.frozen
        if !laid { frozen = off; straight = off ? 1 : 0 }
        else if off != frozen { frozen = off; frostAt = clock }
        straight += ((frozen ? 1 : 0) - straight) * (1 - exp(-dt * 6))
        air += dt * (1 - straight)
        if scene.selected != selection { selection = scene.selected; selectedAt = clock }

        // Every bead as large as the string's length allows; the time between steps sets the gaps.
        let places = Double(max(3, beads.count + (scene.showsEnd ? 1 : 0)))
        let share = 0.3 + 0.9 * scene.tempo
        let wanted = min(34, (size.height - 66) / (places * (2 + share)))
        if laid {
            let ease = 1 - exp(-dt * 10)
            radius += (wanted - radius) * ease; gap += (wanted * share - gap) * ease
        } else {
            radius = wanted; gap = wanted * share
            lay(scene)
        }

        let moving = !scene.still && straight < 0.999
        if moving {
            let h = 1.0 / 120
            for _ in 0..<min(6, max(1, Int((dt / h).rounded()))) { advance(h, scene) }
        } else {
            for index in beads.indices { beads[index].pos = rest(index); beads[index].prev = beads[index].pos; beads[index].yaw = 0; beads[index].spin = 0; beads[index].slack = 0 }
            tail.pos = restTail(scene); tail.prev = tail.pos; tail.slack = 0
        }

        for index in beads.indices where beads[index].from != nil && beads[index].landed < 0 && clock - beads[index].born >= Self.flight {
            beads[index].landed = clock
            beads[index].prev.y -= 3
        }
        for index in ghosts.indices {
            ghosts[index].vel.y += 1700 * dt
            ghosts[index].pos += ghosts[index].vel * dt
            ghosts[index].yaw += 7 * dt
        }
        ghosts.removeAll { clock - $0.born > 0.7 }
        for index in beads.indices where beads[index].shift != Point() || beads[index].drift != Point() {
            for _ in 0..<4 {
                let h = dt / 4
                beads[index].drift += (beads[index].shift * -260 - beads[index].drift * 27) * h
                beads[index].shift += beads[index].drift * h
            }
            if (beads[index].shift * beads[index].shift).sum() < 0.01, (beads[index].drift * beads[index].drift).sum() < 1 {
                beads[index].shift = Point(); beads[index].drift = Point()
            }
        }
        ripples.removeAll { clock - $0.born > 0.6 }
        drift(dt * (1 - straight), scene)

        let settle = scene.still ? 1 : Curve.smooth(straight)
        shown = beads.indices.map { index in
            let bead = beads[index]
            let at = bead.pos + (rest(index) - bead.pos) * settle
            if let held, held.index == index {
                // Up and down it follows the finger between the string's ends; sideways it only leans.
                let lean = radius * 0.5
                let top = rest(0).y - lean, bottom = rest(beads.count - 1).y + lean
                let to = Point(at.x + min(lean, max(-lean, held.at.x - at.x)), min(bottom, max(top, held.at.y)))
                // Kept as an offset, so letting go springs it home.
                beads[index].shift = to - at; beads[index].drift = Point()
                return to
            }
            return at + bead.shift
        }
        shownTail = tail.pos + (restTail(scene) - tail.pos) * settle
    }

    private var lead: Double { 50 + radius }
    private func rest(_ index: Int) -> Point { anchor + Point(0, lead + Double(index) * (2 * radius + gap)) }
    private func tailLength(_ scene: BeadStringScene) -> Double {
        beads.isEmpty ? lead : radius + gap * 0.6 + (scene.showsEnd ? radius * 0.62 : 6)
    }
    private func restTail(_ scene: BeadStringScene) -> Point {
        (beads.isEmpty ? anchor : rest(beads.count - 1)) + Point(0, tailLength(scene))
    }

    /// The first frame: the string is let go from one side and swings down into place.
    private func lay(_ scene: BeadStringScene) {
        let swing = Point(-sin(0.3), cos(0.3))
        for index in beads.indices {
            beads[index].pos = anchor + swing * (lead + Double(index) * (2 * radius + gap))
            beads[index].prev = beads[index].pos
            beads[index].landed = -10; beads[index].born = -10; beads[index].from = nil
        }
        tail.pos = (beads.last?.pos ?? anchor) + swing * tailLength(scene); tail.prev = tail.pos
        motes = (0..<7).map { index in
            Mote(leaf: index >= 4, pos: Point(random() * Double(scene.width), 14 + random() * Double(size.height - 28)),
                 speed: 34 + 40 * random(), seed: random() * 20, size: index >= 4 ? 7 + 3 * random() : 18 + 22 * random())
        }
        laid = true
    }

    private var gust: Double { max(0, sin(air * 0.31) + sin(air * 0.53 + 1.7) - 0.7) }
    private func wind(_ y: Double) -> Double { 40 + 35 * sin(air * 0.9 - y * 0.01) + 150 * gust }

    private func advance(_ h: Double, _ scene: BeadStringScene) {
        func move(_ bead: inout Bead, _ push: Double) {
            let velocity = (bead.pos - bead.prev) * 0.985
            bead.prev = bead.pos
            bead.pos += velocity + Point(push, Self.gravity) * (h * h)
        }
        for index in beads.indices {
            move(&beads[index], wind(beads[index].pos.y))
            // Each bead turns a little on the string, with the wind and with its own swing.
            let across = (beads[index].pos.x - beads[index].prev.x) / h
            let twist = 4.2 * sin(air * 0.8 + Double(index) * 1.9) + 2 * sin(air * 1.9 + Double(index) * 0.7) + across * 0.03
            beads[index].spin += (twist - 15 * beads[index].yaw - 2.6 * beads[index].spin) * h
            beads[index].yaw += beads[index].spin * h
            beads[index].slack *= exp(-h * 9)
        }
        move(&tail, wind(tail.pos.y) * 1.5)
        tail.slack *= exp(-h * 9)

        let pitch = 2 * radius + gap
        for _ in 0..<8 {
            for index in beads.indices {
                let above = index == 0 ? anchor : beads[index - 1].pos
                let length = (index == 0 ? lead : pitch) + beads[index].slack
                let apart = beads[index].pos - above, far = max(0.001, distance(beads[index].pos, above))
                let pull = apart * ((far - length) / far)
                if index == 0 { beads[index].pos -= pull } else { beads[index].pos -= pull * 0.5; beads[index - 1].pos += pull * 0.5 }
            }
            let above = beads.last?.pos ?? anchor
            let apart = tail.pos - above, far = max(0.001, distance(tail.pos, above))
            let pull = apart * ((far - max(0, tailLength(scene) + tail.slack)) / far)
            if beads.isEmpty { tail.pos -= pull } else { tail.pos -= pull * 0.85; beads[beads.count - 1].pos += pull * 0.15 }
        }
    }

    /// Wind lines and leaves cross the stage and come round again.
    private func drift(_ dt: Double, _ scene: BeadStringScene) {
        guard dt > 0 else { return }
        for index in motes.indices {
            let mote = motes[index]
            motes[index].pos.x += mote.speed * (1 + 1.2 * gust) * dt
            if mote.leaf { motes[index].pos.y += (10 + 9 * sin(air * 1.3 + mote.seed)) * dt }
            if motes[index].pos.x > Double(scene.width) + 30 || motes[index].pos.y > Double(size.height) + 12 {
                motes[index].pos = Point(-30 - 50 * random(), 14 + random() * Double(size.height - 28) * (mote.leaf ? 0.7 : 1))
                motes[index].seed = random() * 20
            }
        }
    }

    private func random() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(1 << 53)
    }
    private func distance(_ a: Point, _ b: Point) -> Double { ((a - b) * (a - b)).sum().squareRoot() }

    // MARK: Drawing

    fileprivate func draw(_ context: inout GraphicsContext, _ scene: BeadStringScene) {
        // The string is drawn in grey so the page's controls below it lead.
        let ink = Self.tone
        if !scene.still { drawWind(&context, scene) }
        for ripple in ripples {
            let u = (clock - ripple.born) / 0.6
            context.stroke(Self.circle(ripple.at, 6 + 38 * Curve.out(u)), with: .color(ink.opacity(0.35 * (1 - u))), lineWidth: 1)
        }

        // The string, heavier where a finger stays down from one step to the next.
        let points = [anchor] + shown + [shownTail]
        for index in 0..<(points.count - 1) {
            var line = Path()
            line.move(to: Self.cg(points[index])); line.addLine(to: Self.cg(points[index + 1]))
            let held = index >= 1 && index < shown.count && index - 1 < scene.bridges.count && scene.bridges[index - 1]
            // Above the first bead the string fades away instead of ending at an edge.
            let shade: GraphicsContext.Shading = index == 0
                ? .linearGradient(Gradient(colors: [ink.opacity(0), ink.opacity(0.55)]), startPoint: Self.cg(points[0]),
                                  endPoint: Self.cg(points[0] + (points[1] - points[0]) * 0.8))
                : .color(ink.opacity(held ? 1 : 0.55))
            context.stroke(line, with: shade, style: StrokeStyle(lineWidth: held ? 2.5 : 1.25, lineCap: .round))
        }

        // The time between steps, run down the string: a spark that sets each bead off in turn.
        var pulse = [Double](repeating: 0, count: shown.count)
        if let time = scene.interval, shown.count > 1, !scene.still, straight < 0.05 {
            let legs = Double(shown.count - 1)
            let phase = clock.truncatingRemainder(dividingBy: legs * time + 1.8)
            for index in shown.indices where phase >= Double(index) * time { pulse[index] = exp(-7 * (phase - Double(index) * time)) }
            if phase < legs * time {
                let leg = min(shown.count - 2, Int(phase / time)), along = phase / time - Double(leg)
                context.fill(Self.circle(shown[leg] + (shown[leg + 1] - shown[leg]) * along, 2.25), with: .color(ink))
            }
        }

        var flying: [Int] = []
        for index in beads.indices {
            let bead = beads[index]
            if bead.from != nil, bead.landed < 0 { flying.append(index); continue }
            let centre = shown[index], frost = frost(index)
            let grown = bead.from == nil ? Curve.back((clock - bead.born) / 0.35) : 1
            let r = radius * grown * (1 + 0.07 * pulse[index]) * (held?.index == index ? 1.12 : 1)
            let sinceLanding = clock - bead.landed
            if bead.from != nil, sinceLanding < 0.45 {
                let u = sinceLanding / 0.45
                context.stroke(Self.circle(centre, radius + 18 * Curve.out(u)), with: .color(ink.opacity(0.5 * (1 - u))), lineWidth: 1)
            }
            if frost > 0 { drawFrost(&context, at: centre, radius: r, frost: frost, seed: index) }
            drawBead(&context, bead, at: centre, radius: r, frost: frost, carved: Curve.clamp(sinceLanding / 0.4), alpha: 1)
            if selection == index {
                let settle = Curve.back((clock - selectedAt) / 0.3)
                context.stroke(Self.circle(centre, r + 11 - 6 * settle), with: .color(Color.ink.opacity(settle)), lineWidth: 1.25)
            }
            if let axis = bead.step.axis {
                let label = axis.rawValue.uppercased() + (bead.step.gesture == .rotation ? " " + (bead.step.direction ?? .any).arrow : "")
                context.draw(Text(label).font(.label).foregroundStyle(ink), at: CGPoint(x: centre.x + r + 12 + 6 * frost, y: centre.y), anchor: .leading)
            }
        }

        drawTail(&context, scene)

        for ghost in ghosts {
            let fade = 1 - Curve.clamp((clock - ghost.born) / 0.6)
            var bead = Bead(step: ghost.step); bead.yaw = ghost.yaw
            drawBead(&context, bead, at: ghost.pos, radius: ghost.radius * (0.7 + 0.3 * fade), frost: frozen ? 1 : 0, carved: 1, alpha: fade)
        }
        // A bead on its way from the pad: thrown in an arc, and still blank until it lands.
        for index in flying {
            guard let from = beads[index].from else { continue }
            let t = Curve.clamp((clock - beads[index].born) / Self.flight), e = Curve.inOut(t)
            let at = from + (shown[index] - from) * e - Point(0, 46 * sin(.pi * t))
            drawBead(&context, beads[index], at: at, radius: radius * (0.45 + 0.55 * e), frost: frost(index), carved: 0, alpha: Curve.clamp(t / 0.15))
        }
    }

    /// How far a bead has turned solid. Frost runs down the string a bead at a time, and thaws the same way.
    private func frost(_ index: Int) -> Double {
        let u = Curve.clamp((clock - frostAt - Double(index) * 0.06) / 0.28)
        return frozen ? u : 1 - u
    }

    /// Ice round a frozen bead: a ring of crystals that grow out of it, each a spike with two barbs.
    private func drawFrost(_ context: inout GraphicsContext, at centre: Point, radius r: Double, frost: Double, seed: Int) {
        let grown = Curve.out(frost)
        var ice = Path()
        let spikes = 14
        for spike in 0..<spikes {
            // Uneven, the same every time for the same bead.
            let wobble = sin(Double(spike * 7 + seed * 13) * 1.7)
            let angle = (Double(spike) + 0.25 * wobble) / Double(spikes) * 2 * .pi
            let length = (spike.isMultiple(of: 2) ? 7 + 2 * wobble : 3.5 + wobble) * grown
            let out = Point(cos(angle), sin(angle)), across = Point(-out.y, out.x)
            let foot = centre + out * (r + 3.5), tip = foot + out * length
            ice.move(to: Self.cg(foot)); ice.addLine(to: Self.cg(tip))
            if spike.isMultiple(of: 2) {
                let knee = foot + out * (length * 0.5)
                for side in [-1.0, 1.0] {
                    ice.move(to: Self.cg(knee)); ice.addLine(to: Self.cg(knee + (out * 0.7 + across * side) * (length * 0.3)))
                }
            }
        }
        context.stroke(ice, with: .color(Self.tone.opacity(0.55 * frost)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        // A glint that passes slowly round the ring, the one thing still moving.
        let glint = clock * 0.5 + Double(seed) * 1.3
        let at = centre + Point(cos(glint), sin(glint)) * (r + 13)
        var star = Path()
        let size = 2.5 + 1.5 * sin(clock * 2.2 + Double(seed))
        star.move(to: CGPoint(x: at.x - size, y: at.y)); star.addLine(to: CGPoint(x: at.x + size, y: at.y))
        star.move(to: CGPoint(x: at.x, y: at.y - size)); star.addLine(to: CGPoint(x: at.x, y: at.y + size))
        context.stroke(star, with: .color(Self.tone.opacity(0.7 * frost)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }

    private func drawBead(_ context: inout GraphicsContext, _ bead: Bead, at centre: Point, radius r: Double, frost: Double, carved: Double, alpha: Double) {
        guard r > 0.5 else { return }
        let ink = Self.tone, paper = Color.paper
        let body = Self.circle(centre, r)
        context.fill(body, with: .color(paper.opacity(alpha)))
        if frost > 0 { context.fill(body, with: .color(ink.opacity(frost * alpha))) }
        context.stroke(body, with: .color(ink.opacity(alpha)), lineWidth: 1.25)

        // A changed bead turns right round on the string: the old rune leaves by one side, the new arrives by the other.
        let turn = Curve.clamp((clock - bead.turned) / 0.5)
        let angle = bead.yaw + (turn < 1 ? Curve.inOut(turn) * 2 * .pi : 0)
        let step = turn < 0.5 ? bead.was ?? bead.step : bead.step
        let toward = cos(angle)
        guard carved > 0.01, toward > 0.05 else { return }
        let k = r * 2 / 24
        var rune = RuneSphere.wrap(GestureRune.path(step.gesture), scale: k, facing: SIMD3(sin(angle), 0, toward), centre: Self.cg(centre), radius: r)
        if carved < 1 { rune = rune.trimmedPath(from: 0, to: carved) }
        let seen = min(1, toward * 2.5) * alpha
        let style = StrokeStyle(lineWidth: 1.15 * k, lineCap: .round, lineJoin: .round)
        if frost < 1 { context.stroke(rune, with: .color(ink.opacity(0.85 * seen * (1 - frost))), style: style) }
        if frost > 0 { context.stroke(rune, with: .color(paper.opacity(seen * frost)), style: style) }
    }

    private func drawTail(_ context: inout GraphicsContext, _ scene: BeadStringScene) {
        let ink = Self.tone
        guard scene.showsEnd else {
            // Full: the string is knotted off.
            context.fill(Self.circle(shownTail, 2.5), with: .color(ink))
            return
        }
        let waiting = scene.selected == nil
        let r = radius * 0.62 * (scene.listening && !scene.still ? 1 + 0.08 * sin(clock * 5) : 1)
        let colour = waiting ? ink : Color.faint
        context.fill(Self.circle(shownTail, r), with: .color(Color.paper))
        context.stroke(Self.circle(shownTail, r), with: .color(colour), style: StrokeStyle(lineWidth: 1.25, dash: [3, 3.5], dashPhase: -air * 5))
        var plus = Path()
        let arm = r * 0.36
        plus.move(to: CGPoint(x: shownTail.x - arm, y: shownTail.y)); plus.addLine(to: CGPoint(x: shownTail.x + arm, y: shownTail.y))
        plus.move(to: CGPoint(x: shownTail.x, y: shownTail.y - arm)); plus.addLine(to: CGPoint(x: shownTail.x, y: shownTail.y + arm))
        context.stroke(plus, with: .color(colour), style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
    }

    private func drawWind(_ context: inout GraphicsContext, _ scene: BeadStringScene) {
        let width = Double(scene.width)
        for mote in motes {
            // Each fades in at one edge and out at the other.
            let fade = sin(.pi * Curve.clamp((mote.pos.x + 20) / (width + 40)))
            guard fade > 0.01 else { continue }
            if mote.leaf {
                let length = mote.size, turn = mote.seed + air * 1.4 + 0.8 * sin(air * 2.3 + mote.seed)
                // Tumbling: the leaf is seen now flat, now edge on.
                let flat = max(0.18, abs(cos(air * 1.9 + mote.seed)))
                var leaf = Path()
                leaf.move(to: CGPoint(x: -length / 2, y: 0))
                leaf.addQuadCurve(to: CGPoint(x: length / 2, y: 0), control: CGPoint(x: 0, y: -length * 0.45))
                leaf.addQuadCurve(to: CGPoint(x: -length / 2, y: 0), control: CGPoint(x: 0, y: length * 0.45))
                leaf.move(to: CGPoint(x: -length * 0.8, y: 0)); leaf.addLine(to: CGPoint(x: length / 2, y: 0))
                let placed = CGAffineTransform(translationX: mote.pos.x, y: mote.pos.y).rotated(by: turn).scaledBy(x: 1, y: flat)
                context.stroke(leaf.applying(placed), with: .color(Color.muted.opacity(0.75 * fade)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
            } else {
                var line = Path()
                for piece in 0...10 {
                    let along = Double(piece) / 10
                    let point = CGPoint(x: mote.pos.x - mote.size * (1 - along), y: mote.pos.y + 2.2 * sin(along * 4 + air * 2.4 + mote.seed))
                    if piece == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                context.stroke(line, with: .color(Color.muted.opacity(0.4 * fade)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private static func cg(_ point: Point) -> CGPoint { CGPoint(x: point.x, y: point.y) }
    private static func circle(_ centre: Point, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
    }
}

/// The string, drawn and moved every frame.
struct BeadStringView: View {
    let string: BeadString
    let scene: BeadStringScene

    var body: some View {
        TimelineView(.animation) { timeline in
            // The canvas is given plain values: nothing read only inside a drawing closure is tracked.
            Canvas { context, size in
                string.step(to: timeline.date, size: size, scene: scene)
                string.draw(&context, scene)
            }
        }
    }
}

/// A rune in its 24-unit box laid on a ball seen square on, around the unit vector `facing`
/// (x right, y up, z toward the eye): distances from the rune's centre become arcs, so it
/// curves with the bead and slides toward the edge as the bead turns.
enum RuneSphere {
    static func wrap(_ rune: Path, scale: Double, facing n: SIMD3<Double>, centre: CGPoint, radius: Double) -> Path {
        let vertical = SIMD3<Double>(0, 1, 0)
        let lean = vertical - n * (vertical * n).sum()
        let length = (lean * lean).sum().squareRoot()
        let up = length > 1e-6 ? lean / length : vertical
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
}

/// Curves over 0...1; anything outside is held at the ends.
private enum Curve {
    static func clamp(_ t: Double) -> Double { min(1, max(0, t)) }
    static func out(_ t: Double) -> Double { 1 - pow(1 - clamp(t), 3) }
    static func inOut(_ t: Double) -> Double { let t = clamp(t); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func smooth(_ t: Double) -> Double { let t = clamp(t); return t * t * (3 - 2 * t) }
    /// Ease out with a small overshoot.
    static func back(_ t: Double) -> Double { let t = clamp(t) - 1; return 1 + 2.4 * t * t * t + 1.4 * t * t }
}
