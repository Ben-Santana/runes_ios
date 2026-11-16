import SwiftUI

// Cook's Loop look. The band's own ring, standing on its ground as on the home screen, but
// seen from higher up and with depth, so it opens into a loop: the beads at the back are
// smaller and lighter, the ones in front larger, and a cord runs through them. A bead is a place the recipe uses, spread round the eight;
// the ones between are left faint. The ring turns, with a small overshoot, to bring the
// place of the step showing to the front, and turns to a place whose time is up. The
// front bead is lifted and carries the step's number on its surface. A time counting is
// ink standing in its bead, running out, which slops as the ring turns.
//
// The one figure that matters is set on the ground inside the ring, as large as the ring
// allows and drawn with the ground's own perspective, like lettering on a floor: the time
// the band's gestures are on, the wait before a start, or NOW when that wait is over. Each place away from the front is named beside its bead with
// its time. A spark runs round the cord from a time that is counting to the front and
// arrives at the moment to start. Under the ring one line says what the figure is, and
// what will need the cook next.

struct LoopFace: View {
    let session: CookSession
    let plan: StationPlan
    let now: Date
    let actions: CookActions
    /// Places the ring has turned, counted on and never wrapped, so it turns the short way.
    @State private var turns = 0
    @State private var turnFrom = 0.0
    @State private var turnedAt = Date.distantPast
    @State private var tappedAt = Date.distantPast
    @State private var chosenAt = Date.distantPast
    @State private var appeared = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let place = Double.pi / 4, ring = 62.0, ball = 12.5
    private static let height: CGFloat = 248, foot: CGFloat = 136
    /// How high the ring is seen from, in radians: higher than the home ring, so there is
    /// ground inside it to set the figure on.
    private static let elevation = 0.82
    /// How much larger a thing is drawn for each unit nearer the eye.
    private static let depth = 0.0034

    /// What the canvas is given to draw: plain values, worked out from the session.
    private struct Scene {
        var stations: [Station]
        var slots: [Int]
        /// The station at the front, and the one the gestures are on.
        var facing: Int?
        var selected: Int?
        var ringing: Int?
        /// The wait before a start: the slot it runs from and how far it has come.
        var runner: (from: Int, along: Double)?
        /// The figure standing in the ring, whether it is said in ink, and the step's number.
        var figure: String
        var loud: Bool
        var number: String?
    }

    /// The figure and the line under the ring: what the cook most needs to know.
    private struct Reading {
        var figure: String
        var loud: Bool
        var line: String
        var urgent = false
    }

    private func reading(_ chosen: CookTimer?) -> Reading {
        let place = plan.spot(step: chosen?.step ?? session.step).vessel.uppercased()
        if let chosen {
            if chosen.isRinging(at: now) { return Reading(figure: "0:00", loud: true, line: "\(place) · TIME’S UP", urgent: true) }
            return Reading(figure: DurationFinder.clock(chosen.remaining(at: now)), loud: !chosen.isPaused,
                           line: "\(place) · \(chosen.isPaused ? "PAUSED" : chosen.label.uppercased())")
        }
        guard session.pickedTimer == nil, session.durations.indices.contains(session.slot) else {
            return Reading(figure: "\(session.step + 1)/\(session.count)", loud: false, line: "\(place) · STEP \(session.step + 1) OF \(session.count)")
        }
        let time = session.durations[session.slot], label = (time.label ?? "step \(session.step + 1)").uppercased()
        if let landing = session.landing(at: now) {
            return Reading(figure: DurationFinder.clock(landing.wait), loud: true, line: "START THE \(label) IN · LANDS WITH \(landing.with.label.uppercased())")
        }
        if let with = session.due(at: now) {
            return Reading(figure: "NOW", loud: true, line: "START THE \(label) · LANDS WITH \(with.label.uppercased())", urgent: true)
        }
        return Reading(figure: DurationFinder.clock(time.seconds), loud: false, line: "\(place) · \(label) · NOT STARTED")
    }

    var body: some View {
        let stations = session.stations(plan, at: now)
        let slots = Beads.slots(for: stations.count)
        // A time that is up comes to the front, whichever step is showing.
        let rung = session.ringing(at: now).first
        let ringing = stations.firstIndex { rung != nil && $0.timer?.id == rung?.id }
        let facing = ringing ?? stations.firstIndex(where: \.here)
        let chosen = rung ?? session.selectedTimer.flatMap { $0.isLive ? $0 : nil }
        let selected = stations.firstIndex { chosen != nil && $0.timer?.id == chosen?.id } ?? stations.firstIndex { $0.waiting != nil }
        let runner: (from: Int, along: Double)? = session.landing(at: now).flatMap { landing in
            guard let from = stations.firstIndex(where: { $0.timer?.id == landing.with.id }), let along = session.approach(at: now) else { return nil }
            return (slots[from], along)
        }
        let reading = reading(chosen)
        let here = ringing == nil && !session.finished && !session.gathering
        let scene = Scene(stations: stations, slots: slots, facing: facing, selected: selected, ringing: ringing.map { slots[$0] }, runner: runner,
                          figure: reading.figure, loud: reading.loud, number: here ? "\(session.step + 1)" : nil)
        let front = facing.map { slots[$0] }
        // What ends soonest among the rest: the next thing to need a hand.
        let starting = chosen == nil && (session.landing(at: now) != nil || session.due(at: now) != nil)
        let next = starting ? nil : session.running(at: now).first { $0.id != chosen?.id }
        VStack(spacing: 0) {
            GeometryReader { proxy in
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
                    Canvas { context, size in draw(&context, size, scene, at: reduceMotion ? now : timeline.date) }
                }
                // Room under the ring for its ripples to run out over the page.
                .frame(height: Self.height + 50)
                .allowsHitTesting(false)
                Color.clear.contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { touched($0.location, width: proxy.size.width, scene) })
            }
            .frame(height: Self.height)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(reading.figure + ", " + reading.line.lowercased())
            .accessibilityValue(stations.map { station in
                station.vessel + ": " + (station.timer.map { $0.isRinging(at: now) ? "time’s up" : "\(DurationFinder.short($0.remaining(at: now))) left" } ?? (station.here ? "this step" : "idle"))
            }.joined(separator: ", "))
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(reading.line).font(ticketFont(12, .bold)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if let next {
                    Text("NEXT \(plan.spot(step: next.step).vessel.uppercased()) \(DurationFinder.clock(next.remaining(at: now)))")
                        .font(ticketFont(12)).monospacedDigit().foregroundStyle(Color.muted).lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, Metric.gutter + 4)
            .accessibilityHidden(true)
        }
        .onChange(of: front, initial: true) { was, front in
            guard let front else { return }
            guard was != nil, was != front else { turns = front; turnFrom = Double(front); return }
            let at = Date()
            turnFrom = turn(at: at)
            turns += Beads.shortest(from: ((turns % Beads.count) + Beads.count) % Beads.count, to: front)
            turnedAt = at
        }
        .onChange(of: session.step * 100 + session.beatIndex) { _, _ in tappedAt = Date() }
        .onChange(of: selected) { _, _ in chosenAt = Date() }
        .onChange(of: reading.urgent) { _, urgent in if urgent { tappedAt = Date() } }
    }

    /// How far the ring has turned at a moment, in places.
    private func turn(at date: Date) -> Double {
        reduceMotion ? Double(turns) : turnFrom + (Double(turns) - turnFrom) * BeadEase.back(date.timeIntervalSince(turnedAt) / 0.55)
    }

    private static func apart(_ a: Int, _ b: Int) -> Double { Double(abs(Beads.shortest(from: a, to: b))) }

    private func scale(_ width: CGFloat) -> CGFloat { min(1.9, width / 232) }

    /// A point of the ring's world on the page, and how large things there are drawn:
    /// the home ring's own view, with what is nearer the eye made larger about the middle.
    private static func project(_ x: Double, _ y: Double, _ z: Double, width: CGFloat, scale: CGFloat) -> (point: CGPoint, size: Double) {
        let half = 0.5.squareRoot()
        let near = 1 + (x + y) * half * depth
        return (CGPoint(x: width / 2 + (x - y) * half * scale * near, y: foot + ((x + y) * half * sin(elevation) - z * cos(elevation)) * scale * near), near)
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, _ scene: Scene, at date: Date) {
        let scale = scale(size.width), still = reduceMotion
        func at(_ x: Double, _ y: Double, _ z: Double) -> (point: CGPoint, size: Double) { Self.project(x, y, z, width: size.width, scale: scale) }
        /// A circle on the ground, or at any height, from one angle round to another.
        func loop(_ radius: Double, z: Double = 6, from: Double = 0, to: Double = 2 * .pi) -> Path {
            var circle = Path()
            circle.addLines((0...72).map { step in
                let a = from + (to - from) * Double(step) / 72
                return at(cos(a) * radius, sin(a) * radius, z).point
            })
            return circle
        }
        let t = date.timeIntervalSinceReferenceDate
        let turn = turn(at: date)
        let front = scene.facing.map { scene.slots[$0] }
        let sinceTap = date.timeIntervalSince(tappedAt), sinceTurn = date.timeIntervalSince(turnedAt)
        let beat = t.truncatingRemainder(dividingBy: 1.4), age = date.timeIntervalSince(appeared)
        // The ink slops against the way the ring turned, and settles.
        let slop = still || sinceTurn > 2 ? 0 : (Double(turns) > turnFrom ? -1 : 1) * 0.42 * exp(-3 * sinceTurn) * cos(9 * sinceTurn)

        // The ground, under everything: the rings a tap sends out, and a time that is up.
        if !still {
            for echo in 0..<2 {
                let passed = sinceTap - Double(echo) * 0.12
                guard passed > 0, passed < 0.9 else { continue }
                let spread = 1 - pow(1 - passed / 0.9, 2)
                context.stroke(loop(Self.ring + 10 + 36 * spread), with: .color(Color.ink.opacity((1 - passed / 0.9) * (echo == 0 ? 0.45 : 0.25))), lineWidth: 1)
            }
            if scene.ringing != nil {
                for echo in 0..<3 {
                    let passed = (beat - Double(echo) * 0.13) / 0.95
                    guard passed > 0, passed < 1 else { continue }
                    context.stroke(loop(Self.ring + 10 + 52 * BeadEase.out(passed)), with: .color(Color.ink.opacity((1 - passed) * [0.6, 0.4, 0.25][echo])), lineWidth: 1.25)
                }
            }
        }

        // The figure, on the ground inside the ring: far letters smaller, near ones larger.
        let figure = BeadSphere.outline(scene.figure)
        let inside = Self.ring - Self.ball - 2
        let fit = 2 * inside / hypot(figure.box.width, figure.box.height * 1.15)
        let written = BeadSphere.laid(figure.path) { point in
            let across = (point.x - figure.box.midX) * fit, toward = (point.y - figure.box.midY) * fit * 1.15
            return at((across + toward) * 0.5.squareRoot(), (toward - across) * 0.5.squareRoot(), 6).point
        }
        context.fill(written, with: .color((scene.loud ? Color.ink : Color.faint).opacity(still ? 1 : BeadEase.clamp((age - 0.2) / 0.35))))

        func angle(_ slot: Double) -> Double { Self.place + (turn - slot) * Self.place }
        struct Pod { var slot: Int; var x: Double; var y: Double; var lift: Double; var station: Int?; var shown: Double }
        let pods = (0..<Beads.count).map { slot -> Pod in
            let index = scene.slots.firstIndex(of: slot)
            var lift = 0.0
            if let index {
                let station = scene.stations[index]
                if index == scene.facing { lift += 5 + (still ? 0 : 1.1 * sin(t * 2 * .pi / 3.2)) }
                if let timer = station.timer, !timer.isPaused, !still {
                    let left = timer.end.timeIntervalSince(date)
                    if left > 0 {
                        // The ring's breath when connected; quicker through the last minute.
                        let quick = left <= 60
                        lift += (quick ? 1.8 : 1.0) * (1 + sin(t * 2 * .pi / (quick ? 1.1 : 4.6) + Double(slot))) / 2
                        lift += 8 * BeadEase.bounce(Double(timer.total) - left)
                    }
                }
            }
            if !still {
                if let front { lift += 6 * BeadEase.bounce(sinceTap - Self.apart(slot, front) * 0.045) }
                if let ringing = scene.ringing { lift += 9 * BeadEase.bounce(beat - Self.apart(slot, ringing) * 0.045) }
            }
            // The beads rise into place one after another round the ring, from the front.
            let order = front.map { Self.apart(slot, $0) } ?? Double(slot)
            let shown = still ? 1 : BeadEase.smooth((age - 0.04 * order) / 0.45)
            lift -= 16 * (1 - shown)
            return Pod(slot: slot, x: cos(angle(Double(slot))) * Self.ring, y: sin(angle(Double(slot))) * Self.ring, lift: lift, station: index, shown: shown)
        }
        .sorted { $0.x + $0.y < $1.x + $1.y }

        func stroke(_ pod: Pod) -> Color {
            guard let index = pod.station else { return Color.faint }
            let station = scene.stations[index]
            return station.timer != nil || station.here || index == scene.facing ? Color.ink : Color.muted
        }

        // Shadows first, so no bead is drawn under another bead's shadow.
        for pod in pods {
            let foot = at(pod.x, pod.y, 6)
            BeadDraw.shadow(&context, at: foot.point, radius: Self.ball * scale * foot.size, lift: pod.lift, stroke: stroke(pod),
                            flat: sin(Self.elevation), alpha: pod.shown)
        }

        var centres: [Int: (point: CGPoint, r: Double)] = [:]
        func bead(_ pod: Pod) {
            let place = at(pod.x, pod.y, 8 + pod.lift + Self.ball)
            let centre = place.point, r = Self.ball * scale * place.size
            centres[pod.slot] = (centre, r)
            // Further off, a bead is lighter as well as smaller.
            let far = 0.62 + 0.38 * BeadEase.clamp((place.size - 0.8) / 0.4)
            guard let index = pod.station else {
                BeadDraw.body(&context, at: centre, radius: r, stroke: Color.faint, alpha: pod.shown * far)
                return
            }
            let station = scene.stations[index]
            var level = 0.0
            if let timer = station.timer, timer.total > 0 {
                level = timer.isRinging(at: date) ? 1 : (timer.paused.map(Double.init) ?? max(0, timer.end.timeIntervalSince(date))) / Double(timer.total)
            }
            let alpha = pod.shown * (station.timer?.isPaused == true ? 0.55 : 1) * (station.timer == nil && index != scene.facing ? far : 1)
            BeadDraw.body(&context, at: centre, radius: r, stroke: stroke(pod), level: min(1, level), tilt: slop, alpha: alpha)
            // The step's number on the bead its ticket hangs from, tipped up to meet the eye.
            if index == scene.facing, let number = scene.number {
                BeadDraw.mark(&context, number, at: centre, radius: r, facing: SIMD3(0, 0.3, 0.954), alpha: pod.shown)
            }
            if index == scene.selected {
                let settle = still ? 1 : BeadEase.back(date.timeIntervalSince(chosenAt) / 0.3)
                context.stroke(BeadDraw.circle(centre, r + 11 - 6 * settle), with: .color(Color.ink.opacity(min(1, settle) * pod.shown)), lineWidth: BeadDraw.hair)
            }
        }

        // From the back forward: the far side of the cord and its beads, then the near side.
        let cord = Color.ink.opacity(0.28 * (still ? 1 : BeadEase.clamp((age - 0.3) / 0.4)))
        context.stroke(loop(Self.ring, z: 8 + Self.ball, from: .pi * 0.75, to: .pi * 1.75), with: .color(cord), lineWidth: 1)
        for pod in pods where pod.x + pod.y < -1 { bead(pod) }
        context.stroke(loop(Self.ring, z: 8 + Self.ball, from: -.pi * 0.25, to: .pi * 0.75), with: .color(cord), lineWidth: 1)
        // The wait before a start, running round the cord to the front.
        if let runner = scene.runner, let front {
            let slot = Double(runner.from) + Double(Beads.shortest(from: runner.from, to: front)) * runner.along
            let spark = at(cos(angle(slot)) * Self.ring, sin(angle(slot)) * Self.ring, 8 + Self.ball)
            context.fill(BeadDraw.circle(spark.point, 2.8 * scale * spark.size), with: .color(Color.ink))
        }
        for pod in pods where pod.x + pod.y >= -1 { bead(pod) }

        // What each place away from the front is, beside its bead, quiet while the ring turns.
        let settled = still ? 1 : BeadEase.clamp((sinceTurn - 0.3) / 0.25) * BeadEase.clamp((age - 0.5) / 0.3)
        guard settled > 0.01 else { return }
        var words = context
        words.opacity = settled
        for (index, station) in scene.stations.enumerated() where index != scene.facing {
            guard let bead = centres[scene.slots[index]] else { continue }
            let centre = bead.point, r = bead.r
            let lit = station.timer != nil || station.here
            let name = Text(station.vessel.uppercased()).font(ticketFont(10, .semibold)).foregroundStyle(lit ? Color.ink : Color.muted)
            let time = station.timer.map { timer in
                Text(DurationFinder.clock(timer.isRinging(at: date) ? 0 : timer.remaining(at: date))).font(ticketFont(14, .bold)).monospacedDigit()
                    .foregroundStyle(timer.isPaused ? Color.muted : Color.ink)
            }
            let side = centre.x - size.width / 2
            if abs(side) < 24 {
                if let time { words.draw(time, at: CGPoint(x: centre.x, y: centre.y - r - 5), anchor: .bottom) }
                words.draw(name, at: CGPoint(x: centre.x, y: centre.y - r - (time == nil ? 5 : 22)), anchor: .bottom)
            } else {
                let x = centre.x + (side < 0 ? -1 : 1) * (r + 8), anchor: UnitPoint = side < 0 ? .trailing : .leading
                words.draw(name, at: CGPoint(x: x, y: centre.y - (time == nil ? 0 : 9)), anchor: anchor)
                if let time { words.draw(time, at: CGPoint(x: x, y: centre.y + 7), anchor: anchor) }
            }
        }
    }

    // MARK: Touch

    /// A touch on a bead starts, pauses or stops what is at that place; anywhere else in
    /// the ring it is the timer gesture, on the figure.
    private func touched(_ point: CGPoint, width: CGFloat, _ scene: Scene) {
        let scale = scale(width)
        let nearest = scene.stations.indices.map { index -> (index: Int, far: Double, r: Double) in
            let angle = Self.place + Double(turns - scene.slots[index]) * Self.place
            let place = Self.project(cos(angle) * Self.ring, sin(angle) * Self.ring, 8 + Self.ball, width: width, scale: scale)
            return (index, hypot(place.point.x - point.x, place.point.y - point.y), Self.ball * scale * place.size)
        }
        .min { $0.far < $1.far }
        guard let nearest, nearest.far < nearest.r + 12 else { actions.perform(.timer); return }
        let station = scene.stations[nearest.index]
        if let timer = station.timer { actions.toggleTimer(timer.id) } else if station.waiting != nil { actions.toggle(session.slot) }
    }
}
