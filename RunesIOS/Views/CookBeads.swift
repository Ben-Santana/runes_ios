import SwiftUI

// Cook drawn with the band's eight beads. A bead is the ring's pod laid flat: paper inside
// a hairline, with ink in it. Empty is nothing yet. A dot in the middle is here or done,
// as a pod on the ring has when it is charged. Full of ink is a time counting, and the
// ink runs down to the dot as the time does. Rings spread from a bead that is counting,
// and one whose time is up rattles until it is stopped. A second ring round a bead is the
// one the band's gestures act on. A bead that takes a gesture gives under it once and
// sends a ripple out, as the ring does for a tap.
//
// Three looks arrange the same eight differently (CookBeadLoop, CookBeadAbacus,
// CookBeadStrand). This file has what they share: the bead, the step's ticket with its
// sentences as beads, the ticket for a time that is up, the ingredients as beads to fill,
// and the wrist dial as a loop of beads.

struct Bead: View {
    var size: CGFloat
    /// How wide the ink in it is, as a share of the bead: nothing, the dot, or all of it.
    var ink: Double = 0
    var stroke = Color.muted
    var weight: CGFloat = 1.5
    /// A second ring round it: the one the gestures act on.
    var ringed = false
    /// Counting: rings spread from it, faster once `urgent`.
    var lively = false
    var urgent = false
    /// Its time is up.
    var rattling = false
    /// How the ink moves when its amount changes: slowly for a time running down.
    var pour = Animation.linear(duration: 0.5)
    /// Changes when a gesture lands on it; the bead answers once.
    var tap = 0
    @State private var tapped: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The dot's width as a share of the bead's, as the band's ring draws it.
    static let dot = 0.32

    /// The ink for a share of a time left: all of it at the start, down to the dot.
    static func level(_ share: Double) -> Double { dot + (1 - dot) * min(1, max(0, share)).squareRoot() }
    /// The ink for a share of a count done, by area, so half done looks half full.
    static func part(_ share: Double) -> Double { min(1, max(0, share)).squareRoot() }

    var body: some View {
        let moving = (lively || rattling || tapped != nil) && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Seconds since the last gesture landed, while the bead is still answering it.
            let since = reduceMotion ? nil : tapped.map { context.date.timeIntervalSince($0) }
            ZStack {
                Circle().fill(Color.paper)
                Circle().fill(Color.ink).scaleEffect(CGFloat(rattling ? 1 : ink))
                Circle().strokeBorder(rattling ? Color.ink : stroke, lineWidth: weight)
            }
            .frame(width: size, height: size)
            .background { if lively || rattling, moving { ripples(t) } }
            .background { if let since { shock(since) } }
            .overlay { Circle().strokeBorder(Color.ink, lineWidth: 1.5).padding(-6).opacity(ringed ? 1 : 0) }
            // The ring's own damped bounce, as a give in the bead's size.
            .scaleEffect(1 + 0.12 * CGFloat(since.map { $0 <= 0 ? 0 : exp(-5.5 * $0) * sin(2 * .pi * 2.6 * $0) } ?? 0))
            .offset(x: rattling && !reduceMotion ? sin(t * 38) * 2.5 : 0)
        }
        .animation(pour, value: ink)
        .animation(.standard, value: ringed)
        .onChange(of: tap) { _, _ in
            let at = Date()
            tapped = at
            Task { try? await Task.sleep(for: .seconds(0.9)); if tapped == at { tapped = nil } }
        }
        .accessibilityHidden(true)
    }

    /// The ripple one gesture sends out: two rings, the second a moment behind.
    private func shock(_ since: Double) -> some View {
        ZStack {
            ForEach(0..<2, id: \.self) { echo in
                let local = since - Double(echo) * 0.12
                if local > 0, local < 0.8 {
                    let spread = 1 - pow(1 - local / 0.8, 2)
                    Circle().stroke(Color.ink.opacity((1 - local / 0.8) * (echo == 0 ? 0.55 : 0.3)), lineWidth: 1)
                        .frame(width: size + 44 * CGFloat(spread), height: size + 44 * CGFloat(spread))
                }
            }
        }
    }

    /// Hairline rings that leave the bead and fade, like the ripples a tap sends over the
    /// band's ring. Two at a time, half a beat apart.
    private func ripples(_ t: Double) -> some View {
        let period = rattling ? 0.7 : urgent ? 1.1 : 2.6
        let spread: CGFloat = rattling ? 22 : 13
        return ZStack {
            ForEach(0..<2, id: \.self) { echo in
                let phase = (t / period + Double(echo) * 0.5).truncatingRemainder(dividingBy: 1)
                Circle().stroke(Color.ink.opacity(0.5 * (1 - phase)), lineWidth: 1)
                    .frame(width: size + 2 * spread * CGFloat(phase), height: size + 2 * spread * CGFloat(phase))
            }
        }
    }
}

/// Puts a view on a circle about its place. The angle is what animates, so a bead that
/// changes place travels round the loop and does not cut across it.
struct OnLoop: ViewModifier, Animatable {
    /// Radians, from the trailing edge, clockwise on screen.
    var angle: Double
    var radius: CGFloat
    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(angle, radius) }
        set { angle = newValue.first; radius = newValue.second }
    }
    func body(content: Content) -> some View {
        content.offset(x: CGFloat(cos(angle)) * radius, y: CGFloat(sin(angle)) * radius)
    }
}

/// A step's sentences as a row of small beads: ink for the ones read and the one showing.
struct SentenceBeads: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { sentence in
                Circle().strokeBorder(sentence <= index ? Color.ink : Color.muted, lineWidth: 1.5)
                    .background(Circle().fill(sentence <= index ? Color.ink : Color.clear))
                    .frame(width: sentence == index ? 10 : 8, height: sentence == index ? 10 : 8)
            }
        }
        .animation(.standard, value: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sentence \(index + 1) of \(count)")
    }
}

// MARK: The cooking page

/// The page while a step shows: the beads on top, in the look chosen, and the step's
/// ticket under them. A time that is up takes the ticket's place until it is stopped.
struct BeadCookPage: View {
    let session: CookSession
    let look: CookingLook
    let controls: CookControls
    let actions: CookActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let plan = StationPlan(steps: session.recipe.steps)
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let now = context.date
            let rung = session.ringing(at: now)
            VStack(spacing: 0) {
                Group {
                    switch look {
                    case .abacus: AbacusFace(session: session, plan: plan, now: now, actions: actions).padding(.top, 10)
                    case .strand: StrandFace(session: session, plan: plan, now: now, actions: actions)
                    default: LoopFace(session: session, plan: plan, now: now, actions: actions)
                    }
                }
                ZStack {
                    if let first = rung.first {
                        let durations = session.recipe.durations(step: first.step)
                        let cue = durations.indices.contains(first.slot) ? StepDetails.cue(for: durations[first.slot], in: session.recipe.steps[first.step]) : nil
                        TimeUpTicket(timer: first, place: plan.spot(step: first.step).vessel, others: rung.count - 1, cue: cue, controls: controls, stop: actions.stopRinging)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                    } else {
                        Ticket(session: session, plan: plan, now: now, beads: true)
                    }
                }
                .padding(.top, 12)
                .clipped()
                .animation(reduceMotion ? nil : .entrance, value: rung.isEmpty)
                Spacer(minLength: 0)
            }
        }
    }
}

/// A time that is up, printed where the step was: ink from edge to edge, the place in
/// letters to read from across the kitchen, what to check, and how to stop it. A tap stops it.
struct TimeUpTicket: View {
    let timer: CookTimer
    /// Where it is: "Air fryer".
    let place: String
    /// How many more are up as well.
    let others: Int
    var cue: String? = nil
    let controls: CookControls
    let stop: () -> Void

    var body: some View {
        Button(action: stop) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("TIME’S UP")
                    Spacer()
                    Text(String(format: "%02d ", timer.step + 1) + timer.label.uppercased() + (others > 0 ? " +\(others)" : ""))
                }
                .font(ticketFont(13, .semibold))
                Text(place.uppercased()).font(ticketFont(44, .bold)).lineLimit(2).minimumScaleFactor(0.5).padding(.top, 14)
                if let cue {
                    Text("CHECK: \(cue.uppercased())").font(ticketFont(19, .semibold)).lineSpacing(2).padding(.top, 10)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                HStack(spacing: 18) {
                    ForEach([(CookCommand.timer, "STOP"), (.addMinute, "+1 MIN")], id: \.1) { command, word in
                        if let trigger = controls.trigger(for: command) {
                            HStack(spacing: 6) { TriggerGlyphs(steps: trigger.steps, size: 16); Text(word).font(ticketFont(13, .semibold)) }
                        }
                    }
                }
            }
            .foregroundStyle(Color.paper)
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
        .padding(.horizontal, Metric.gutter).padding(.bottom, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time’s up at the \(place.lowercased()), step \(timer.step + 1)" + (cue.map { ". Check: \($0)" } ?? ""))
        .accessibilityHint("Stops the timer.")
    }
}

// MARK: Getting ready

/// Before step one: the eight beads fill as the ingredients are got out, and each line
/// has a bead of its own to fill. The band's up and down move the ring along the list and
/// its timer gesture fills the ringed bead; a tap fills any.
struct BeadGather: View {
    let session: CookSession
    let toggle: (Int) -> Void

    var body: some View {
        let items = session.recipe.ingredients
        let fills = Beads.fills(session.ready.count, of: items.count)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 9) {
                        ForEach(0..<Beads.count, id: \.self) { index in
                            Bead(size: 30, ink: Bead.part(fills[index]), stroke: fills[index] > 0 ? Color.ink : Color.muted)
                        }
                    }
                    .background(Rectangle().fill(Color.rule).frame(height: Metric.hairline))
                    Text("GET EVERYTHING OUT").font(ticketFont(24, .bold)).padding(.top, 18)
                    Text([String(format: "%02d/%02d OUT", session.ready.count, items.count), session.recipe.yield?.uppercased()].compactMap { $0 }.joined(separator: " · "))
                        .font(ticketFont(13)).monospacedDigit().contentTransition(.numericText()).padding(.top, 6).padding(.bottom, 16)
                    // What a later step needs ready, said now while there is time.
                    let first = StepDetails.headStarts(in: session.recipe.steps)
                    if !first.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("START FIRST").font(ticketFont(13, .semibold))
                            ForEach(first, id: \.self) { Text($0.uppercased()).font(ticketFont(17, .bold)).fixedSize(horizontal: false, vertical: true) }
                        }
                        .padding(.bottom, 16)
                    }
                    // What was written down the last time, read before it is too late to use.
                    if let notes = session.recipe.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(notes.suffix(2), id: \.self) { Text("* " + $0.uppercased()).font(ticketFont(12)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true) }
                        }
                        .padding(.bottom, 16)
                    }
                    Perforation()
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in row(index, item).id(index) }
                    Perforation()
                }
                .padding(.horizontal, Metric.gutter + 4).padding(.top, 20).padding(.bottom, 16)
                .animation(.standard, value: session.ready)
                .animation(.standard, value: session.marked)
            }
            .onChange(of: session.marked) { _, marked in withAnimation(.standard) { proxy.scrollTo(marked, anchor: .center) } }
        }
        .sensoryFeedback(.selection, trigger: session.ready)
    }

    private func row(_ index: Int, _ item: String) -> some View {
        let line = Ingredients.split(item), out = session.ready.contains(index), marked = index == session.marked
        return Button { toggle(index) } label: {
            HStack(alignment: .center, spacing: 14) {
                Bead(size: 18, ink: out ? 1 : 0, stroke: out || marked ? Color.ink : Color.muted, ringed: marked)
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.name.uppercased()).font(ticketFont(16, marked ? .bold : .semibold))
                        .strikethrough(out, color: Color.muted).foregroundStyle(out ? Color.muted : Color.ink)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if let amount = line.amount {
                        Text(amount.uppercased()).font(ticketFont(13)).foregroundStyle(Color.muted).contentTransition(.numericText())
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9).padding(.leading, 8).contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item)
        .accessibilityAddTraits(out ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: The wrist dial

/// The wrist dial as the loop of eight, shown while the index finger is pinched and
/// held: ink fills the beads clockwise from the top as the wrist turns, a bead for an
/// eighth of the dial, round the time being set. For people it is a bead each. It moves
/// only as the hand does.
struct BeadDial: View {
    /// How full each of the eight is: up to one on the first turn, up to two on the second.
    let fills: [Double]
    /// What it shows in the middle: "7:30", or "6" people.
    let value: String
    /// What is being set: "Simmer", the step when it has no name, or "Servings".
    let label: String
    /// What letting go does.
    let hint: String
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The bead the ink has reached, which stands a little proud of the rest.
        let level = fills.reduce(0, +)
        let head = level <= 0 ? -1 : (Int(level.rounded(.up)) - 1) % Beads.count
        GeometryReader { geo in
            let side = max(160, min(geo.size.width - 36, geo.size.height - 130))
            let bead = side * 0.2, radius = (side - bead) / 2 - 4
            VStack(spacing: 16) {
                Text(label.uppercased()).font(ticketFont(15, .semibold))
                ZStack {
                    Circle().stroke(Color.rule, lineWidth: Metric.hairline).frame(width: radius * 2, height: radius * 2)
                    ForEach(0..<Beads.count, id: \.self) { index in
                        let fill = fills.indices.contains(index) ? fills[index] : 0
                        ZStack {
                            Bead(size: bead, ink: Bead.part(fill), stroke: fill > 0 ? Color.ink : Color.muted, weight: index == head ? 2.5 : 1.5,
                                 pour: .easeOut(duration: 0.16))
                            // A second turn of the dial opens the bead again from the middle.
                            Circle().fill(Color.paper).frame(width: bead * 0.56, height: bead * 0.56).scaleEffect(CGFloat(Bead.part(fill - 1)))
                        }
                        .scaleEffect(index == head && !reduceMotion ? 1.14 : 1)
                        .modifier(OnLoop(angle: Double(index) * .pi / 4 - .pi / 2, radius: open || reduceMotion ? radius : radius * 0.7))
                    }
                    // Sized to stay inside the beads, however many digits the time has.
                    FlapDigits(text: value, size: side * (value.count <= 4 ? 0.2 : value.count == 5 ? 0.17 : 0.125))
                }
                .frame(width: side, height: side)
                .opacity(open ? 1 : 0)
                .animation(.easeOut(duration: 0.16), value: fills)
                Text(hint.uppercased()).font(ticketFont(13)).foregroundStyle(Color.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.paper)
        .onAppear { withAnimation(.entrance) { open = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setting \(label) to \(value)")
    }
}
