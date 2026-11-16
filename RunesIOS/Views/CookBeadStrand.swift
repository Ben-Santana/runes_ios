import SwiftUI

// Cook's Strand look. The recipe hangs as beads on a string down the leading edge, the way
// a set's inscriptions hang in Capture: a bead for each step, carrying its number on its
// surface, with the step being cooked read beside it on the ticket. The string sways a
// little, the beads drop onto it in turn when the page opens, and the bead for the step
// showing has a ring that settles round it and turns right round when it is chosen and
// for each sentence turned. A step done gives up its number. A step with a time counting
// holds ink that runs out, with the time beside it, wherever the cook has got to since.
// While a time waits to be started so it lands with another, a spark runs along the
// string from that one's bead and arrives at the moment to start.

struct StrandFace: View {
    let session: CookSession
    let plan: StationPlan
    let now: Date
    let actions: CookActions
    @State private var chosenAt = Date.distantPast
    @State private var spunAt = Date.distantPast
    @State private var appeared = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the string hangs from the leading edge, and how far down the first bead is.
    private static let hang = 36.0, lead = 22.0

    private func pitch(_ height: CGFloat) -> Double { min(74, (Double(height) - Self.lead - 40) / Double(max(1, session.count))) }
    private func radius(_ pitch: Double) -> Double { min(18, pitch * 0.34) }

    /// The step whose bead the gestures are on: the one showing, unless another step's timer was picked.
    private var chosen: Int { session.pickedTimer?.step ?? session.step }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
                Canvas { context, size in draw(&context, size, at: reduceMotion ? now : timeline.date) }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { touched($0.location, height: proxy.size.height) })
        }
        .onChange(of: chosen) { _, _ in chosenAt = Date() }
        .onChange(of: session.beatIndex) { _, _ in spunAt = Date() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Steps")
        .accessibilityValue("Step \(session.step + 1) of \(session.count)" + session.live(at: now).map { ", step \($0.step + 1) \($0.isRinging(at: now) ? "time’s up" : DurationFinder.short($0.remaining(at: now)) + " left")" }.joined())
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, at date: Date) {
        let still = reduceMotion, ink = Color.ink
        let t = date.timeIntervalSinceReferenceDate, age = date.timeIntervalSince(appeared)
        let count = session.count, pitch = pitch(size.height), r = radius(pitch)
        guard count > 0 else { return }
        let beat = t.truncatingRemainder(dividingBy: 1.3)

        // Each bead drops onto the string in turn when the page opens.
        func grown(_ index: Int) -> Double { still ? 1 : BeadEase.back((age - 0.05 * Double(min(index, 12))) / 0.4) }
        let timers: [CookTimer?] = (0..<count).map { step in
            session.timers.filter { $0.step == step && $0.isLive }.min { $0.remaining(at: date) < $1.remaining(at: date) }
        }
        let centres: [CGPoint] = (0..<count).map { index in
            let depth = min(1, Double(index + 1) / 3)
            var sway = still ? 0 : 2.2 * sin(t * 0.55 - Double(index) * 0.45) * depth
            // A bead whose time is up shakes on the string, rests, and shakes again.
            if !still, timers[index]?.isRinging(at: date) == true { sway += 7 * sin(beat * 42) * exp(-5 * beat) }
            return CGPoint(x: Self.hang + sway, y: Self.lead + Double(index) * pitch + pitch / 2 - (1 - min(1, grown(index))) * 18)
        }

        // The string, fading away above the first bead and knotted off under the last.
        let reach = still ? 1 : min(1, age / 0.5)
        let knot = CGPoint(x: centres[count - 1].x, y: centres[count - 1].y + r + 16)
        let points = [CGPoint(x: Self.hang, y: -6)] + centres + [knot]
        for index in 0..<(points.count - 1) {
            var line = Path()
            line.move(to: points[index]); line.addLine(to: points[index + 1])
            let shade: GraphicsContext.Shading = index == 0
                ? .linearGradient(Gradient(colors: [ink.opacity(0), ink.opacity(0.55)]), startPoint: points[0], endPoint: points[1])
                : .color(ink.opacity(0.55))
            context.stroke(line.trimmedPath(from: 0, to: reach), with: shade, style: StrokeStyle(lineWidth: BeadDraw.hair, lineCap: .round))
        }
        context.fill(BeadDraw.circle(knot, 2.5), with: .color(ink.opacity(0.55 * reach)))

        // The wait before a start, run along the string to the bead it is for.
        if let landing = session.landing(at: date), let along = session.approach(at: date), centres.indices.contains(landing.with.step), centres.indices.contains(session.step) {
            let from = centres[landing.with.step], to = centres[session.step]
            context.fill(BeadDraw.circle(CGPoint(x: from.x + (to.x - from.x) * along, y: from.y + (to.y - from.y) * along), 2.6), with: .color(ink))
        }

        let cooking = !session.finished && !session.gathering
        for index in 0..<count {
            let timer = timers[index], centre = centres[index]
            let here = cooking && index == session.step, done = !cooking || index < session.step
            let ringing = timer?.isRinging(at: date) ?? false, paused = timer?.isPaused ?? false
            var level = 0.0
            if let timer, timer.total > 0 {
                level = ringing ? 1 : (timer.paused.map(Double.init) ?? max(0, timer.end.timeIntervalSince(date))) / Double(timer.total)
            }
            let scale = grown(index) * (here ? 1.08 : 1)
            if ringing, !still {
                let spread = beat / 0.8
                if spread < 1 { context.stroke(BeadDraw.circle(centre, r + 16 * BeadEase.out(spread)), with: .color(ink.opacity(0.5 * (1 - spread))), lineWidth: 1) }
            }
            BeadDraw.body(&context, at: centre, radius: r * scale, stroke: here || timer != nil ? ink : done ? Color.muted : ink.opacity(0.75),
                          level: min(1, level), alpha: min(1, scale) * (paused ? 0.55 : 1))
            // The number it carries, turning with the bead: once round when it is chosen and for each sentence.
            if !done || timer != nil {
                var yaw = still ? 0 : 0.2 * sin(t * 0.7 + Double(index) * 1.9)
                if index == chosen, !still {
                    let spin = date.timeIntervalSince(chosenAt) / 0.55, turn = date.timeIntervalSince(spunAt) / 0.5
                    if spin < 1 { yaw += BeadEase.inOut(spin) * 2 * .pi }
                    if turn < 1, here { yaw += BeadEase.inOut(turn) * 2 * .pi }
                }
                BeadDraw.mark(&context, "\(index + 1)", at: centre, radius: r * scale, facing: SIMD3(sin(yaw), 0, cos(yaw)),
                              alpha: min(1, scale) * (here || timer != nil ? 1 : 0.6))
            }
            if cooking, index == chosen {
                let settle = still ? 1 : BeadEase.back(date.timeIntervalSince(chosenAt) / 0.3)
                context.stroke(BeadDraw.circle(centre, r * 1.08 + 12 - 6 * settle), with: .color(ink.opacity(min(1, settle))), lineWidth: BeadDraw.hair)
            }
            // The time there, beside the bead.
            let waiting = here && timer == nil && session.pickedTimer == nil && session.durations.indices.contains(session.slot) ? session.durations[session.slot].seconds : nil
            if let seconds = timer.map({ ringing ? 0 : $0.remaining(at: date) }) ?? waiting {
                context.draw(Text(DurationFinder.clock(seconds)).font(.geist(13, .medium, relativeTo: .footnote)).monospacedDigit()
                                .foregroundStyle(timer == nil || paused ? Color.muted : ink),
                             at: CGPoint(x: centre.x + r * 1.08 + 10, y: centre.y), anchor: .leading)
            }
        }
    }

    /// A touch on a bead starts, pauses or stops its time, or goes to its step.
    private func touched(_ point: CGPoint, height: CGFloat) {
        let pitch = pitch(height)
        let index = Int(((Double(point.y) - Self.lead) / pitch).rounded(.down))
        guard (0..<session.count).contains(index), abs(Double(point.x) - Self.hang) < radius(pitch) + 22 else { return }
        if let timer = session.timers.filter({ $0.step == index && $0.isLive }).min(by: { $0.remaining(at: now) < $1.remaining(at: now) }) {
            actions.toggleTimer(timer.id)
        } else if index == session.step, !session.durations.isEmpty {
            actions.toggle(session.slot)
        } else if index != session.step {
            actions.go(index, nil)
        }
    }
}
