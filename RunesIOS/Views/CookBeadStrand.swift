import SwiftUI

// Cook's Strand look. The band's loop seen from the side, and a bead is a step: the one
// showing is large in the middle with its number, the ones done trail off behind it with
// a dot in each, and the ones to come wait ahead, smaller the further round they are.
// Each step on moves the whole strand a place. A step with a time counting lifts off the
// line, full of ink that runs down, with its time over it and its place under it, and
// stays lifted as it moves back, so everything on the go is in the one line. While a
// time waits to be started so it lands with another, a small bead runs along the line
// from under that one to the middle.

struct StrandFace: View {
    let session: CookSession
    let plan: StationPlan
    let now: Date
    let actions: CookActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the line is, from the top.
    private static let line: CGFloat = 116
    private static let sizes: [CGFloat] = [62, 40, 26, 17, 11, 8, 6, 5]

    /// How far from the middle a bead that many places from now is, as a share of half the width.
    private static func away(_ places: Int) -> CGFloat {
        CGFloat(places.signum()) * (1 - CGFloat(pow(0.64, Double(abs(places)))))
    }

    var body: some View {
        let strand = Beads.strand(steps: session.count, now: session.mark)
        let selected = session.selectedTimer.flatMap { $0.isLive ? $0 : nil }
        GeometryReader { geo in
            let middle = geo.size.width / 2, half = middle - 8
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.rule).frame(height: Metric.hairline).offset(y: Self.line)
                ForEach(0..<Beads.count, id: \.self) { index in
                    let places = index - strand.now
                    bead(strand.marks[index], places: places, selected: selected)
                        .position(x: middle + Self.away(places) * half, y: Self.line)
                        .zIndex(Double(Beads.count - abs(places)))
                }
                // The wait before starting, as a bead on its way to the middle.
                if let landing = session.landing(at: now), let along = session.approach(at: now),
                   let from = strand.marks.firstIndex(of: .step(landing.with.step)) {
                    // From the edge of the mark the lifted bead leaves on the line.
                    let start = middle + Self.away(from - strand.now) * half + 16
                    Bead(size: 11, ink: 1, stroke: Color.ink)
                        .position(x: start + (middle - start) * CGFloat(along), y: Self.line)
                        .animation(reduceMotion ? nil : .linear(duration: 0.5), value: along)
                    Text("START IN \(DurationFinder.clock(landing.wait))").font(ticketFont(11, .bold)).monospacedDigit().fixedSize()
                        .position(x: middle, y: Self.line + 46)
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.7, bounce: 0.18), value: strand.now)
            .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.25), value: session.timers.filter(\.isLive).map(\.id))
        }
        .frame(height: 176)
    }

    @ViewBuilder private func bead(_ mark: Beads.Mark?, places: Int, selected: CookTimer?) -> some View {
        let size = Self.sizes[min(abs(places), Self.sizes.count - 1)]
        switch mark {
        case .step(let step): stepBead(step, places: places, size: size, selected: selected)
        // Getting ready is done by the time a step shows.
        case .ready: Bead(size: size, ink: Bead.dot, stroke: Color.muted)
        case .done: Bead(size: size, stroke: Color.muted)
        case nil: Bead(size: size, stroke: Color.faint, weight: 1)
        }
    }

    private func stepBead(_ step: Int, places: Int, size: CGFloat, selected: CookTimer?) -> some View {
        let timer = session.timers.filter { $0.step == step && $0.isLive }.min { $0.remaining(at: now) < $1.remaining(at: now) }
        let ringing = timer?.isRinging(at: now) ?? false, paused = timer?.isPaused ?? false
        let left = timer.map { ringing ? 0 : $0.remaining(at: now) }
        let share = timer.map { $0.total > 0 ? Double($0.remaining(at: now)) / Double($0.total) : 0 }
        let here = places == 0
        // The time of the step showing that has not been started.
        let waiting = here && timer == nil && session.pickedTimer == nil && session.durations.indices.contains(session.slot) ? session.durations[session.slot].seconds : nil
        let chosen = timer.map { $0.id == selected?.id } ?? (waiting != nil)
        // A bead with a time counting stands off the line by its own height and a little.
        let lift: CGFloat = timer == nil ? 0 : max(26, size * 0.5 + 14)
        let wide = max(size, timer == nil ? size : 24)
        return ZStack {
            // Where it stood, as the ring marks the wrist under a pod that is lifted.
            if timer != nil { Ellipse().stroke(Color.faint, lineWidth: 1).frame(width: wide * 0.7, height: wide * 0.2) }
            ZStack {
                Bead(size: wide, ink: share.map(Bead.level) ?? (places < 0 ? Bead.dot : 0),
                     stroke: here || timer != nil ? Color.ink : Color.muted, weight: here ? 2.5 : 1.5, ringed: chosen,
                     lively: timer != nil && !paused && !ringing, urgent: (left ?? 99) <= 60, rattling: ringing,
                     tap: here ? session.step * 100 + session.beatIndex + (session.landing(at: now) == nil ? 0 : 50) : 0)
                // The step's number, which reads on paper and on ink alike.
                if abs(places) <= 1, places >= 0 || timer != nil {
                    Text(String(format: "%02d", step + 1)).font(ticketFont(here ? 20 : 13, .bold))
                        .foregroundStyle(Color.white).blendMode(.difference).opacity(here ? 1 : 0.7)
                }
            }
            .compositingGroup()
            .opacity(paused ? 0.55 : 1)
            .offset(y: -lift)
            if let out = left ?? waiting {
                Text(DurationFinder.clock(out)).font(ticketFont(here ? 20 : 12, .bold)).monospacedDigit().fixedSize()
                    .foregroundStyle(timer == nil || paused ? Color.muted : Color.ink)
                    .contentTransition(.numericText(countsDown: true))
                    .offset(y: -lift - wide / 2 - (here ? 20 : 13))
            }
            if timer != nil, !here {
                Text(plan.spot(step: step).vessel.uppercased()).font(ticketFont(10, .semibold)).foregroundStyle(Color.muted).fixedSize()
                    .offset(y: abs(places).isMultiple(of: 2) ? 30 : 17)
            }
        }
        .frame(width: wide, height: wide)
        .contentShape(Rectangle().inset(by: -8))
        .onTapGesture {
            if let timer { actions.toggleTimer(timer.id) } else if waiting != nil { actions.toggle(session.slot) } else if !here { actions.go(step, nil) }
        }
        .onLongPressGesture(minimumDuration: 0.5) { if let timer { actions.cancelTimer(timer.id) } }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("Step \(step + 1), \(plan.spot(step: step).vessel), " + (left.map { ringing ? "time’s up" : "\(DurationFinder.short($0)) left" + (paused ? ", paused" : "") }
                            ?? waiting.map { "\(DurationFinder.short($0)), not started" } ?? (here ? "this step" : places < 0 ? "done" : "to come")))
    }
}
