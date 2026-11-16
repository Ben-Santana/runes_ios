import SwiftUI

// Cook's Loop look. The band's loop seen from above, and a bead is a place: the skillet,
// the pot, the oven, the counter, spread round the eight, with the spare beads small
// between them. The loop turns to bring the place of the step showing to the front, over
// the ticket, as the band's ring turns a place for a swipe, and turns to a place whose
// time is up until it is stopped. A place with a time counting is full of ink that runs
// down, and the whole loop draws in through a time's last minute. The middle reads the
// one time the band's gestures are on. While a time waits to be started so it lands with another, a spare bead travels
// from that one's place to the front and arrives at the moment to start.

struct LoopFace: View {
    let session: CookSession
    let plan: StationPlan
    let now: Date
    let actions: CookActions
    /// Places the loop has turned, counted on and never wrapped, so it turns the short way.
    @State private var turned: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let radius: CGFloat = 104

    var body: some View {
        let stations = session.stations(plan, at: now)
        let slots = Beads.slots(for: stations.count)
        // A time that is up comes to the front, whichever step is showing.
        let rung = session.ringing(at: now).first
        let facing = stations.firstIndex { rung != nil && $0.timer?.id == rung?.id } ?? stations.firstIndex(where: \.here)
        let front = facing.map { slots[$0] }
        let turns = turned ?? front ?? 0
        let selected = rung ?? session.selectedTimer.flatMap { $0.isLive ? $0 : nil }
        // The spare bead that carries the wait, and how far along it is, in places.
        let spare = (0..<Beads.count).first { !slots.contains($0) }
        let runner: Double? = session.landing(at: now).flatMap { landing in
            guard let from = stations.firstIndex(where: { $0.timer?.id == landing.with.id }).map({ slots[$0] }), let front,
                  let along = session.approach(at: now) else { return nil }
            return Double(from) + Double(Beads.shortest(from: from, to: front)) * along
        }
        // Through the last minute of the time due next the loop draws in, so its end is seen coming.
        let soonest = session.running(at: now).first.map { $0.remaining(at: now) } ?? 60
        let radius = Self.radius - (reduceMotion ? 0 : 12 * CGFloat(max(0, 60 - soonest)) / 60)
        ZStack {
            Circle().stroke(Color.rule, lineWidth: Metric.hairline).frame(width: radius * 2, height: radius * 2)
            centre(selected)
            ForEach(0..<Beads.count, id: \.self) { slot in
                if let index = slots.firstIndex(of: slot) {
                    let station = stations[index]
                    let chosen = station.timer.map { $0.id == selected?.id } ?? (station.waiting != nil)
                    place(station, front: index == facing, chosen: chosen)
                        .modifier(OnLoop(angle: angle(Double(slot), turns), radius: radius))
                        .zIndex(index == facing ? 2 : 1)
                    if index != facing {
                        // Pushed out by half its own size, so it clears the bead on every side.
                        tag(station).modifier(Beside(angle: angle(Double(slot), turns), radius: radius + (station.timer != nil ? 22 : station.here ? 17 : 13) + 8,
                                                     half: CGSize(width: CGFloat(max(4, station.vessel.count)) * 3.1 + 2, height: station.timer == nil ? 6 : 12)))
                    }
                } else if slot == spare, let runner {
                    Bead(size: 13, ink: 1, stroke: Color.ink).modifier(OnLoop(angle: angle(runner, turns), radius: radius)).zIndex(3)
                } else {
                    Bead(size: 9, stroke: Color.faint, weight: 1).modifier(OnLoop(angle: angle(Double(slot), turns), radius: radius))
                }
            }
        }
        .frame(maxWidth: .infinity).frame(height: 300).padding(.top, 26)
        .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.2), value: stations.map { $0.timer?.id })
        .animation(reduceMotion ? nil : .linear(duration: 0.5), value: runner)
        .animation(reduceMotion ? nil : .linear(duration: 0.5), value: radius)
        .onChange(of: front, initial: true) { _, front in
            guard let front else { return }
            guard let was = turned else { turned = front; return }
            let step = Beads.shortest(from: ((was % Beads.count) + Beads.count) % Beads.count, to: front)
            // The ring's own tween for pods that move.
            withAnimation(reduceMotion ? nil : .spring(duration: 0.7, bounce: 0.18)) { turned = was + step }
        }
    }

    /// Where a slot is: the one the loop has turned to is at the foot, nearest the ticket.
    private func angle(_ slot: Double, _ turns: Int) -> Double { .pi / 2 + (slot - Double(turns)) * .pi / 4 }

    private func place(_ station: Station, front: Bool, chosen: Bool) -> some View {
        let timer = station.timer
        let ringing = timer?.isRinging(at: now) ?? false, paused = timer?.isPaused ?? false
        let left = timer.map { ringing ? 0 : $0.remaining(at: now) }
        let share = timer.map { $0.total > 0 ? Double($0.remaining(at: now)) / Double($0.total) : 0 }
        // The bead answers each sentence turned, and the moment a wait to start is over.
        let tap = front ? session.step * 100 + session.beatIndex + (session.landing(at: now) == nil ? 0 : 50) : 0
        return ZStack {
            Bead(size: front ? 60 : timer != nil ? 44 : station.here ? 34 : 26,
                 ink: share.map(Bead.level) ?? (station.here && !front ? Bead.dot : 0),
                 stroke: station.here || timer != nil ? Color.ink : Color.muted, weight: front || station.here ? 2.5 : 1.5,
                 ringed: chosen, lively: timer != nil && !paused && !ringing, urgent: (left ?? 99) <= 60, rattling: ringing, tap: tap)
            // The step's number in the bead its ticket hangs from, read on paper and on ink alike.
            if front, station.here {
                Text(String(format: "%02d", session.step + 1)).font(ticketFont(20, .bold)).foregroundStyle(Color.white).blendMode(.difference)
            }
        }
            .compositingGroup()
            .opacity(paused ? 0.55 : 1)
            .contentShape(Circle().inset(by: -10))
            .onTapGesture { if let timer { actions.toggleTimer(timer.id) } else if station.waiting != nil { actions.toggle(session.slot) } }
            .onLongPressGesture(minimumDuration: 0.5) { if let timer { actions.cancelTimer(timer.id) } }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel(station.vessel + ", " + (left.map { ringing ? "time’s up" : "\(DurationFinder.short($0)) left" + (paused ? ", paused" : "") } ?? (station.here ? "this step" : "idle")))
    }

    /// What a place away from the front is, and the time left there, outside the loop.
    private func tag(_ station: Station) -> some View {
        let ringing = station.timer?.isRinging(at: now) ?? false
        return VStack(spacing: 1) {
            Text(station.vessel.uppercased()).font(ticketFont(10, .semibold)).foregroundStyle(station.timer == nil && !station.here ? Color.muted : Color.ink)
            if let timer = station.timer {
                Text(DurationFinder.clock(ringing ? 0 : timer.remaining(at: now))).font(ticketFont(11, .semibold)).monospacedDigit()
                    .foregroundStyle(timer.isPaused ? Color.muted : Color.ink)
            }
        }
        .lineLimit(1).fixedSize()
        .accessibilityHidden(true)
    }

    /// The middle of the loop: the one time the gestures are on, where it is, and what it
    /// is doing. On a step with no time it is the step's number.
    private func centre(_ selected: CookTimer?) -> some View {
        let waiting = selected == nil && session.pickedTimer == nil && session.durations.indices.contains(session.slot) ? session.durations[session.slot] : nil
        let ringing = selected?.isRinging(at: now) ?? false
        let place = plan.spot(step: selected?.step ?? session.step).vessel
        let landing = session.landing(at: now)
        let figure = selected.map { DurationFinder.clock(ringing ? 0 : $0.remaining(at: now)) } ?? waiting.map { DurationFinder.clock($0.seconds) } ?? String(format: "%02d", session.step + 1)
        let caption = ringing ? "TIME’S UP" : selected?.isPaused == true ? "PAUSED" : selected.map { $0.label.uppercased() }
            ?? landing.map { "START IN \(DurationFinder.clock($0.wait))" } ?? (waiting == nil ? "STEP \(session.step + 1) OF \(session.count)" : "NOT STARTED")
        return VStack(spacing: 0) {
            Text(place.uppercased()).font(ticketFont(13, .semibold))
            Text(figure)
                .font(.geist(54, .medium, relativeTo: .largeTitle)).monospacedDigit().tracking(-1.8)
                .foregroundStyle(selected == nil || selected?.isPaused == true ? Color.muted : Color.ink)
                .contentTransition(.numericText(countsDown: true)).lineLimit(1).minimumScaleFactor(0.5)
                .animation(.standard, value: figure)
            Text(caption).font(ticketFont(11, landing != nil && selected == nil ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(landing != nil && selected == nil ? Color.ink : Color.muted)
        }
        .frame(width: 136).offset(y: -8)
        .contentShape(Rectangle())
        .onTapGesture { actions.perform(.timer) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(place), \(figure), \(caption.lowercased())")
    }
}

/// Puts a label outside a place on the loop: out along the same angle, and further by
/// half the label's own size, so it clears the bead whichever side it is on.
private struct Beside: ViewModifier, Animatable {
    var angle: Double
    var radius: CGFloat
    var half: CGSize
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    func body(content: Content) -> some View {
        content.offset(x: CGFloat(cos(angle)) * (radius + half.width), y: CGFloat(sin(angle)) * (radius + half.height))
    }
}
