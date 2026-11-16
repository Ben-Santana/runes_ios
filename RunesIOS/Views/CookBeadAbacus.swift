import SwiftUI

// Cook's Abacus look. Every place the recipe uses is a rod, and the eight beads rest at
// the near end of the rods. Starting a time pushes a bead out along its rod, as far as
// the time is long, and it slides to the bar at the far end as the time runs down: two
// beads level with each other will be done together. A time not yet started is an open
// bead waiting where it would begin. When it should wait so as to land with another, a
// dashed line drops from it across the rods, and the moment to start is when the bead
// that is counting reaches the line.

struct AbacusFace: View {
    let session: CookSession
    let plan: StationPlan
    let now: Date
    let actions: CookActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let row: CGFloat = 46
    /// Where the rod runs in its row, under the place's name.
    private static let rod: CGFloat = 31

    var body: some View {
        let stations = session.stations(plan, at: now)
        let selected = session.selectedTimer.flatMap { $0.isLive ? $0 : nil }
        // A rod is as long as the longest time the recipe has, or one made longer since.
        let written = session.recipe.steps.indices.flatMap { session.recipe.durations(step: $0) }.map(\.seconds).max() ?? 0
        let longest = max(60, written, session.timers.filter(\.isLive).map(\.total).max() ?? 0)
        GeometryReader { geo in
            let bar = geo.size.width - 64, far: CGFloat = 62
            // A bead whose time is up rests against the bar, not on it.
            let x = { (seconds: Int) -> CGFloat in bar - 15 - CGFloat(Beads.reach(seconds, of: longest)) * (bar - 15 - far) }
            let height = CGFloat(stations.count) * Self.row
            ZStack(alignment: .topLeading) {
                ForEach(Array(stations.enumerated()), id: \.offset) { index, station in
                    let chosen = station.timer.map { $0.id == selected?.id } ?? (station.waiting != nil)
                    rod(station, resting: Beads.count / stations.count + (index < Beads.count % stations.count ? 1 : 0), chosen: chosen, bar: bar, width: geo.size.width, x: x)
                        .offset(y: CGFloat(index) * Self.row)
                }
                // The bar every bead is headed for.
                Rectangle().fill(Color.ink).frame(width: 2, height: height - 8).offset(x: bar - 1, y: 12)
                // The line to wait for.
                if session.landing(at: now) != nil, let waiting = stations.first(where: \.here)?.waiting {
                    Path { path in path.move(to: CGPoint(x: x(waiting), y: 12)); path.addLine(to: CGPoint(x: x(waiting), y: height + 4)) }
                        .stroke(Color.ink, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .transition(.opacity)
                }
                scale(longest, bar: bar, x: x).offset(y: height + 4)
            }
        }
        .frame(height: CGFloat(stations.count) * Self.row + 22)
        .padding(.horizontal, Metric.gutter + 4)
        .animation(reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.2), value: stations.map { $0.timer?.id })
        .animation(reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.2), value: stations.map(\.waiting))
    }

    private func rod(_ station: Station, resting: Int, chosen: Bool, bar: CGFloat, width: CGFloat, x: @escaping (Int) -> CGFloat) -> some View {
        let timer = station.timer
        let ringing = timer?.isRinging(at: now) ?? false, paused = timer?.isPaused ?? false
        let left = timer.map { ringing ? 0 : $0.remaining(at: now) }
        let share = timer.map { $0.total > 0 ? Double($0.remaining(at: now)) / Double($0.total) : 0 }
        let out = left ?? station.waiting
        return ZStack(alignment: .topLeading) {
            Text(station.vessel.uppercased()).font(ticketFont(11, station.here ? .bold : .semibold))
                .foregroundStyle(station.here || timer != nil ? Color.ink : Color.muted)
            Rectangle().fill(station.here ? Color.ink : Color.rule).frame(width: bar, height: station.here ? 1.5 : Metric.hairline)
                .offset(y: Self.rod - (station.here ? 0.75 : 0.5))
            ForEach(0..<max(1, resting), id: \.self) { bead in
                // The outermost bead at rest is the one that goes out.
                if bead == max(1, resting) - 1, let out {
                    Bead(size: 28, ink: share.map(Bead.level) ?? 0, stroke: Color.ink, weight: timer == nil ? 2 : 1.5, ringed: chosen,
                         lively: timer != nil && !paused && !ringing, urgent: (left ?? 99) <= 60, rattling: ringing,
                         tap: station.here ? session.step * 100 + session.beatIndex + (session.landing(at: now) == nil ? 0 : 50) : 0)
                        .opacity(paused ? 0.55 : 1)
                        .offset(x: x(out) - 14, y: Self.rod - 14)
                        .animation(reduceMotion ? nil : .linear(duration: 0.5), value: out)
                } else {
                    Bead(size: 12, stroke: Color.faint, weight: 1).offset(x: 2 + CGFloat(bead) * 15, y: Self.rod - 6)
                }
            }
            if let out {
                Text(DurationFinder.clock(out)).font(ticketFont(17, chosen ? .bold : .semibold)).monospacedDigit()
                    .foregroundStyle(ringing ? Color.paper : timer == nil || paused ? Color.muted : Color.ink)
                    .contentTransition(.numericText(countsDown: true))
                    .padding(.horizontal, 4).background(ringing ? Color.ink : Color.clear)
                    .frame(width: width - bar - 8, alignment: .trailing)
                    .offset(x: bar + 8, y: Self.rod - 11)
            }
        }
        .frame(width: width, height: Self.row, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { if let timer { actions.toggleTimer(timer.id) } else if station.waiting != nil { actions.toggle(session.slot) } }
        .onLongPressGesture(minimumDuration: 0.5) { if let timer { actions.cancelTimer(timer.id) } }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(station.vessel + ", " + (left.map { ringing ? "time’s up" : "\(DurationFinder.short($0)) left" + (paused ? ", paused" : "") }
                            ?? station.waiting.map { "\(DurationFinder.short($0)), not started" } ?? (station.here ? "this step" : "idle")))
    }

    /// Minutes left along the rods, so a bead's place can be read.
    private func scale(_ longest: Int, bar: CGFloat, x: @escaping (Int) -> CGFloat) -> some View {
        let marks = [1, 2, 5, 10, 20, 30, 60, 120, 240].filter { $0 * 60 <= longest }
        return ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.self) { minutes in
                Text("\(minutes)").font(ticketFont(10)).foregroundStyle(Color.muted).fixedSize()
                    .frame(width: 30).offset(x: x(minutes * 60) - 15)
            }
            Text("0").font(ticketFont(10)).foregroundStyle(Color.muted).frame(width: 30).offset(x: x(0) - 15)
            Text("MIN").font(ticketFont(10)).foregroundStyle(Color.muted).offset(x: bar + 14)
        }
        .accessibilityHidden(true)
    }
}
