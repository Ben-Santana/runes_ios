import SwiftUI

// Cook's Loop look. The band's own ring, drawn as the home screen draws it: eight equal
// beads standing on the ground, seen from the same angle. A bead is a place the recipe
// uses, spread round the eight; the ones between are left faint. The ring turns, with the
// small overshoot the gesture beads turn with, to bring the place of the step showing to
// the front, and turns to a place whose time is up. The front bead is lifted and carries
// the ring's dot. A time counting is ink standing in its bead, running out, and the bead
// bobs as the ring breathes when connected. Each sentence turned sends the ring's tap
// through the beads from the front. While a time waits to be started so it lands with
// another, a spark runs round from that one's bead and reaches the front at the moment
// to start. Under the ring, as on the home screen, one line says the one thing: the time
// the band's gestures are on, and where it is.

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

    /// A little wider than the home ring for the same beads, so each place stands clear of the next.
    private static let place = Double.pi / 4, ring = 58.0, ball = 12.0
    private static let height: CGFloat = 206, foot: CGFloat = 134

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
        let scene = Scene(stations: stations, slots: slots, facing: facing, selected: selected, ringing: ringing.map { slots[$0] }, runner: runner)
        let front = facing.map { slots[$0] }
        VStack(spacing: 0) {
            GeometryReader { proxy in
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
                    Canvas { context, size in draw(&context, size, scene, at: reduceMotion ? now : timeline.date) }
                }
                // Room under the ring for its ripples to run out over the page.
                .frame(height: Self.height + 60)
                .allowsHitTesting(false)
                Color.clear.contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { touched($0.location, width: proxy.size.width, scene) })
            }
            .frame(height: Self.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Where things are cooking")
            .accessibilityValue(stations.map { station in
                station.vessel + ": " + (station.timer.map { $0.isRinging(at: now) ? "time’s up" : "\(DurationFinder.short($0.remaining(at: now))) left" } ?? (station.here ? "this step" : "idle"))
            }.joined(separator: ", "))
            // What is up is said where the step was; the line here would only say it twice.
            if rung == nil { readout(chosen).transition(.opacity) }
        }
        .animation(reduceMotion ? nil : .standard, value: rung == nil)
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
        .onChange(of: runner == nil) { _, waiting in if waiting { tappedAt = Date() } }
    }

    /// How far the ring has turned at a moment, in places.
    private func turn(at date: Date) -> Double {
        reduceMotion ? Double(turns) : turnFrom + (Double(turns) - turnFrom) * BeadEase.back(date.timeIntervalSince(turnedAt) / 0.55)
    }

    private static func apart(_ a: Int, _ b: Int) -> Double { Double(abs(Beads.shortest(from: a, to: b))) }

    private func scale(_ width: CGFloat) -> CGFloat { min(1.9, width / 236) }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, _ scene: Scene, at date: Date) {
        let scale = scale(size.width), still = reduceMotion
        let transform = CGAffineTransform(translationX: size.width / 2, y: Self.foot).scaledBy(x: scale, y: scale)
        func iso(_ x: Double, _ y: Double, _ z: Double) -> CGPoint { RingGeometry.project(x, y, z).applying(transform) }
        func ground(_ radius: Double) -> Path {
            var circle = Path()
            circle.addLines((0..<64).map { iso(cos(Double($0) / 64 * 2 * .pi) * radius, sin(Double($0) / 64 * 2 * .pi) * radius, 6) })
            circle.closeSubpath()
            return circle
        }
        let t = date.timeIntervalSinceReferenceDate
        let turn = turn(at: date)
        let front = scene.facing.map { scene.slots[$0] }
        let r = Self.ball * scale
        let sinceTap = date.timeIntervalSince(tappedAt), beat = t.truncatingRemainder(dividingBy: 1.4)
        let age = date.timeIntervalSince(appeared)

        // The ground, under everything: the rings a tap sends out, and a time that is up.
        if !still {
            for echo in 0..<2 {
                let passed = sinceTap - Double(echo) * 0.12
                guard passed > 0, passed < 0.9 else { continue }
                let spread = 1 - pow(1 - passed / 0.9, 2)
                context.stroke(ground(Self.ring + 10 + 40 * spread), with: .color(Color.ink.opacity((1 - passed / 0.9) * (echo == 0 ? 0.45 : 0.25))), lineWidth: 1)
            }
            if scene.ringing != nil {
                for echo in 0..<3 {
                    let passed = (beat - Double(echo) * 0.13) / 0.95
                    guard passed > 0, passed < 1 else { continue }
                    context.stroke(ground(Self.ring + 10 + 60 * BeadEase.out(passed)), with: .color(Color.ink.opacity((1 - passed) * [0.6, 0.4, 0.25][echo])), lineWidth: 1.25)
                }
            }
        }

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
            BeadDraw.shadow(&context, at: iso(pod.x, pod.y, 6), radius: r, lift: pod.lift, stroke: stroke(pod), alpha: pod.shown)
        }
        // The wait before a start, running round to the front behind the beads.
        if let runner = scene.runner, let front {
            let slot = Double(runner.from) + Double(Beads.shortest(from: runner.from, to: front)) * runner.along
            context.fill(BeadDraw.circle(iso(cos(angle(slot)) * Self.ring, sin(angle(slot)) * Self.ring, 8 + Self.ball), 2.6 * scale), with: .color(Color.ink))
        }
        var centres: [Int: CGPoint] = [:]
        for pod in pods {
            let centre = iso(pod.x, pod.y, 8 + pod.lift + Self.ball)
            centres[pod.slot] = centre
            guard let index = pod.station else {
                BeadDraw.body(&context, at: centre, radius: r, stroke: Color.faint, alpha: pod.shown)
                continue
            }
            let station = scene.stations[index]
            var level = 0.0
            if let timer = station.timer, timer.total > 0 {
                level = timer.isRinging(at: date) ? 1 : (timer.paused.map(Double.init) ?? max(0, timer.end.timeIntervalSince(date))) / Double(timer.total)
            }
            BeadDraw.body(&context, at: centre, radius: r, stroke: stroke(pod), level: min(1, level),
                          dot: station.timer == nil && station.here ? 1 : 0, alpha: pod.shown * (station.timer?.isPaused == true ? 0.55 : 1))
            if index == scene.selected {
                let settle = still ? 1 : BeadEase.back(date.timeIntervalSince(chosenAt) / 0.3)
                context.stroke(BeadDraw.circle(centre, r + 11 - 6 * settle), with: .color(Color.ink.opacity(min(1, settle) * pod.shown)), lineWidth: BeadDraw.hair)
            }
        }

        // What each place away from the front is, beside its bead, quiet while the ring turns.
        let settled = still ? 1 : BeadEase.clamp((date.timeIntervalSince(turnedAt) - 0.3) / 0.25) * BeadEase.clamp((age - 0.5) / 0.3)
        guard settled > 0.01 else { return }
        var words = context
        words.opacity = settled
        for (index, station) in scene.stations.enumerated() where index != scene.facing {
            guard let centre = centres[scene.slots[index]] else { continue }
            let name = Text(station.vessel).font(.caption).foregroundStyle(station.timer != nil || station.here ? Color.ink : Color.muted)
            let time = station.timer.map { timer in
                Text(DurationFinder.clock(timer.isRinging(at: date) ? 0 : timer.remaining(at: date))).font(.caption).monospacedDigit()
                    .foregroundStyle(timer.isPaused ? Color.muted : Color.ink)
            }
            let side = centre.x - size.width / 2
            if abs(side) < 24 {
                if let time { words.draw(time, at: CGPoint(x: centre.x, y: centre.y - r - 6), anchor: .bottom) }
                words.draw(name, at: CGPoint(x: centre.x, y: centre.y - r - (time == nil ? 6 : 21)), anchor: .bottom)
            } else {
                let x = centre.x + (side < 0 ? -1 : 1) * (r + 9), anchor: UnitPoint = side < 0 ? .trailing : .leading
                words.draw(name, at: CGPoint(x: x, y: centre.y - (time == nil ? 0 : 8)), anchor: anchor)
                if let time { words.draw(time, at: CGPoint(x: x, y: centre.y + 8), anchor: anchor) }
            }
        }
    }

    // MARK: Touch

    /// A touch on a bead starts, pauses or stops what is at that place.
    private func touched(_ point: CGPoint, width: CGFloat, _ scene: Scene) {
        let scale = scale(width)
        let transform = CGAffineTransform(translationX: width / 2, y: Self.foot).scaledBy(x: scale, y: scale)
        let nearest = scene.stations.indices.map { index -> (index: Int, far: Double) in
            let angle = Self.place + Double(turns - scene.slots[index]) * Self.place
            let centre = RingGeometry.project(cos(angle) * Self.ring, sin(angle) * Self.ring, 8 + Self.ball).applying(transform)
            return (index, hypot(centre.x - point.x, centre.y - point.y))
        }
        .min { $0.far < $1.far }
        guard let nearest, nearest.far < Self.ball * scale + 14 else { return }
        let station = scene.stations[nearest.index]
        if let timer = station.timer { actions.toggleTimer(timer.id) } else if station.waiting != nil { actions.toggle(session.slot) }
    }

    // MARK: The line under the ring

    /// One figure and one line, centred, as the home screen says the band's state.
    private func readout(_ chosen: CookTimer?) -> some View {
        let waiting = chosen == nil && session.pickedTimer == nil && session.durations.indices.contains(session.slot) ? session.durations[session.slot] : nil
        let ringing = chosen?.isRinging(at: now) ?? false
        let place = plan.spot(step: chosen?.step ?? session.step).vessel
        let landing = chosen == nil ? session.landing(at: now) : nil
        let figure = chosen.map { DurationFinder.clock(ringing ? 0 : $0.remaining(at: now)) } ?? waiting.map { DurationFinder.clock($0.seconds) }
        let line: String = {
            if ringing { return "\(place) · time’s up" }
            if let chosen { return "\(place) · \(chosen.isPaused ? "paused" : chosen.label.lowercased())" }
            if let landing { return "Start in \(DurationFinder.clock(landing.wait)), to land with the \(landing.with.label.lowercased())" }
            return waiting == nil ? "Step \(session.step + 1) of \(session.count)" : "\(place) · not started"
        }()
        return VStack(spacing: 2) {
            if let figure {
                Text(figure).font(.geist(48, .medium, relativeTo: .largeTitle)).monospacedDigit().tracking(-1.4)
                    .foregroundStyle(chosen == nil || chosen?.isPaused == true ? Color.muted : Color.ink)
                    .contentTransition(.numericText(countsDown: true)).lineLimit(1).minimumScaleFactor(0.5)
                    .animation(.standard, value: figure)
            } else {
                Text(place).font(.geist(34, .medium, relativeTo: .largeTitle)).tracking(-0.8).lineLimit(1).minimumScaleFactor(0.5)
                    .frame(height: 58)
            }
            Text(line).font(.bodyText).monospacedDigit().foregroundStyle(landing == nil ? Color.muted : Color.ink)
                .contentTransition(.opacity).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, Metric.gutter)
        .contentShape(Rectangle())
        .onTapGesture { actions.perform(.timer) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel([figure, line].compactMap { $0 }.joined(separator: ", "))
    }
}
