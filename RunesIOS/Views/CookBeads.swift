import SwiftUI
import UIKit
import CoreText

// Cook drawn with the band's eight beads, in the hand the rest of the app draws them:
// equal beads of paper inside a hairline, standing on the ground the ring stands on, moved
// by the ring's own bounce and turn. Empty is nothing yet. The ring's dot is here. A time
// counting is ink standing in the bead, running out as the time does. A thin ring that
// settles round a bead is the one the band's gestures act on.
//
// Three looks arrange the beads differently (CookBeadLoop, CookBeadAbacus,
// CookBeadStrand). This file has what they share: the bead, the step's ticket with its
// sentences as beads, what shows when a time is up, the ingredients as beads to fill, and
// the wrist dial as a loop of beads.

/// Curves over 0...1; anything outside is held at the ends. The same ones the ring and
/// the bead strings elsewhere in the app move by.
enum BeadEase {
    static func clamp(_ t: Double) -> Double { min(1, max(0, t)) }
    static func out(_ t: Double) -> Double { 1 - pow(1 - clamp(t), 3) }
    static func inOut(_ t: Double) -> Double { let t = clamp(t); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func smooth(_ t: Double) -> Double { let t = clamp(t); return t * t * (3 - 2 * t) }
    /// Ease out with a small overshoot.
    static func back(_ t: Double) -> Double { let t = clamp(t) - 1; return 1 + 2.4 * t * t * t + 1.4 * t * t }
    /// The ring's damped bounce: up at once, settled in under a second.
    static func bounce(_ tau: Double) -> Double { tau <= 0 ? 0 : exp(-5.5 * tau) * sin(2 * .pi * 2.6 * tau) }
}

/// How a bead is drawn everywhere in Cook: the ring's pod. Paper inside a hairline, and
/// nothing else at rest. A time counting is ink standing in it like liquid in a glass
/// ball, its surface seen a little from above, running out as the time does.
enum BeadDraw {
    static let hair: CGFloat = 1.25

    static func circle(_ centre: CGPoint, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
    }

    /// `level` is how full of ink it is, 0...1. `dot` is the ring's charge mark, 0...1.
    static func body(_ context: inout GraphicsContext, at centre: CGPoint, radius r: Double, stroke: Color,
                     level: Double = 0, dot: Double = 0, alpha: Double = 1) {
        guard r > 0.5, alpha > 0.005 else { return }
        let body = circle(centre, r)
        context.fill(body, with: .color(Color.paper.opacity(alpha)))
        if level > 0.01 { ink(&context, at: centre, radius: r, level: level, alpha: alpha) }
        context.stroke(body, with: .color(stroke.opacity(alpha)), lineWidth: hair)
        if dot > 0.01 {
            let d = r * 0.32
            context.fill(circle(CGPoint(x: centre.x, y: centre.y - r * 0.12), d), with: .color(Color.ink.opacity(dot * alpha)))
        }
    }

    private static func ink(_ context: inout GraphicsContext, at centre: CGPoint, radius r: Double, level: Double, alpha: Double) {
        var inside = context
        inside.clip(to: circle(centre, r - 0.3))
        let shade = GraphicsContext.Shading.color(Color.ink.opacity(alpha))
        guard level < 0.995 else { inside.fill(circle(centre, r), with: shade); return }
        let top = centre.y + r - 2 * r * level
        let half = max(0, r * r - (top - centre.y) * (top - centre.y)).squareRoot()
        inside.fill(Path(CGRect(x: centre.x - r, y: top, width: 2 * r, height: centre.y + r - top)), with: shade)
        // The surface, an ellipse as the ring's shadows are, with its near edge picked out.
        let deep = half * 0.26
        inside.fill(Path(ellipseIn: CGRect(x: centre.x - half, y: top - deep, width: 2 * half, height: 2 * deep)), with: shade)
        var edge = Path()
        edge.addLines((0...24).map { step in
            let a = Double(step) / 24 * .pi
            return CGPoint(x: centre.x + cos(a) * half, y: top + sin(a) * deep)
        })
        inside.stroke(edge, with: .color(Color.paper.opacity(0.5 * alpha)), lineWidth: 0.9)
    }

    /// A number laid on the bead's surface round `facing`, as the gesture beads carry their
    /// runes: softer than the outline, and read on paper and on ink alike.
    static func mark(_ context: inout GraphicsContext, _ text: String, at centre: CGPoint, radius r: Double,
                     facing: SIMD3<Double> = SIMD3(0, 0, 1), alpha: Double = 1) {
        guard r > 4, facing.z > 0.05, alpha > 0.01 else { return }
        let wrapped = BeadSphere.wrap(BeadSphere.digits(text), scale: r * 2 / 24, facing: facing, centre: centre, radius: r)
        var over = context
        over.blendMode = .difference
        over.fill(wrapped, with: .color(Color.white.opacity(0.85 * min(1, facing.z * 2.5) * alpha)))
    }

    /// The mark a bead leaves on the ground under it, as the ring draws it.
    static func shadow(_ context: inout GraphicsContext, at foot: CGPoint, radius r: Double, lift: Double, stroke: Color, alpha: Double = 1) {
        let wide = r * max(0.45, 0.8 - max(0, lift) / 60)
        let path = Path(ellipseIn: CGRect(x: foot.x - wide, y: foot.y - wide * sin(RingGeometry.elevation), width: 2 * wide, height: 2 * wide * sin(RingGeometry.elevation)))
        context.stroke(path, with: .color(stroke.opacity(0.35 * alpha * max(0.25, 1 - max(0, lift) / 20))), lineWidth: 0.9)
    }
}

/// Figures as shapes, and shapes laid on a ball. The wrapping is the one the gesture beads
/// and the rune balls use upstream; when the branches meet, theirs serves here too.
enum BeadSphere {
    private static var cache: [String: Path] = [:]

    /// A short number in the icons' 24-unit box, centred, in the app's own face.
    static func digits(_ text: String) -> Path {
        if let known = cache[text] { return known }
        let size: CGFloat = text.count > 1 ? 11.5 : 14
        let font = CTFontCreateWithName((UIFont(name: "Geist-Medium", size: size)?.fontName ?? UIFont.systemFont(ofSize: size, weight: .medium).fontName) as CFString, size, nil)
        var path = Path(), x: CGFloat = 0
        for unit in Array(text.utf16) {
            var character = unit, glyph = CGGlyph()
            guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { continue }
            // Font outlines have y upward; the page has it downward.
            var place = CGAffineTransform(translationX: x, y: 0).scaledBy(x: 1, y: -1)
            if let outline = CTFontCreatePathForGlyph(font, glyph, &place) { path.addPath(Path(outline)) }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            x += advance.width - 0.3
        }
        let box = path.boundingRect
        let centred = path.applying(CGAffineTransform(translationX: 12 - box.midX, y: 12 - box.midY))
        cache[text] = centred
        return centred
    }

    /// A shape in its 24-unit box laid on a ball seen square on, around the unit vector
    /// `facing` (x right, y up, z toward the eye): distances from the middle become arcs,
    /// so it curves with the bead and slides toward the edge as the bead turns.
    static func wrap(_ shape: Path, scale: Double, facing n: SIMD3<Double>, centre: CGPoint, radius: Double) -> Path {
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
        shape.forEach { element in
            switch element {
            case .move(let to):
                wrapped.move(to: place(to)); last = to; start = to
            case .line(let to):
                for step in 1...4 { wrapped.addLine(to: place(mix(last, to, Double(step) / 4))) }
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

/// One bead by itself, where there is no ring round it: on a rod, beside an ingredient,
/// on the dial. `level` is how full of ink it is.
struct Bead: View {
    var size: CGFloat
    var level: Double = 0
    /// The ring's charge mark: here, or done.
    var dot = false
    var stroke = Color.ink
    /// A ring round it: the one the gestures act on.
    var ringed = false
    /// Its time is up: it shakes, then rests, then shakes again.
    var rattling = false
    /// Changes when a gesture lands on it; the bead answers once.
    var tap = 0
    @State private var tapped: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moving = (rattling || tapped != nil) && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let since = moving ? tapped.map { timeline.date.timeIntervalSince($0) } : nil
            let beat = t.truncatingRemainder(dividingBy: 1.3)
            BeadFigure(level: level, dot: dot ? 1 : 0, stroke: stroke, ring: ringed ? 1 : 0,
                       shake: moving && rattling ? 5 * sin(beat * 42) * exp(-5 * beat) : 0,
                       swell: 1 + 0.1 * BeadEase.bounce(since ?? 0),
                       ripple: moving && rattling ? beat / 0.8 : since.map { $0 / 0.7 })
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.3), value: level)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: ringed)
        .onChange(of: tap) { _, _ in
            let at = Date()
            tapped = at
            Task { try? await Task.sleep(for: .seconds(0.9)); if tapped == at { tapped = nil } }
        }
        .accessibilityHidden(true)
    }
}

/// The drawing of one bead, with what can change smoothly kept as numbers.
private struct BeadFigure: View, Animatable {
    var level: Double
    var dot: Double
    let stroke: Color
    var ring: Double
    let shake: Double
    let swell: Double
    /// 0...1 while a ring spreads from it and fades.
    let ripple: Double?
    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(level, AnimatablePair(dot, ring)) }
        set { level = newValue.first; dot = newValue.second.first; ring = newValue.second.second }
    }

    var body: some View {
        // Drawn into room round the bead, so its rings are not cut off.
        GeometryReader { proxy in
            let r = Double(min(proxy.size.width, proxy.size.height)) / 2 - 1
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2 + shake, y: size.height / 2)
                if let ripple, ripple > 0, ripple < 1 {
                    context.stroke(BeadDraw.circle(centre, r + 16 * BeadEase.out(ripple)), with: .color(Color.ink.opacity(0.5 * (1 - ripple))), lineWidth: 1)
                }
                BeadDraw.body(&context, at: centre, radius: r * swell, stroke: stroke, level: level, dot: dot)
                if ring > 0.01 {
                    context.stroke(BeadDraw.circle(centre, r + 11 - 6 * ring), with: .color(Color.ink.opacity(min(1, ring))), lineWidth: BeadDraw.hair)
                }
            }
            .frame(width: proxy.size.width + 40, height: proxy.size.height + 40)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
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
                Circle().strokeBorder(sentence <= index ? Color.ink : Color.muted, lineWidth: 1.25)
                    .background(Circle().fill(sentence == index ? Color.ink : Color.clear))
                    .frame(width: 8, height: 8)
            }
        }
        .animation(.standard, value: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sentence \(index + 1) of \(count)")
    }
}

// MARK: The cooking page

/// The page while a step shows: the beads, in the look chosen, and the step's ticket. A
/// time that is up takes the ticket's place until it is stopped. The strand hangs down the
/// leading edge with the ticket beside it; the other looks sit over the ticket.
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
            if look == .strand {
                HStack(alignment: .top, spacing: 0) {
                    StrandFace(session: session, plan: plan, now: now, actions: actions).frame(width: 104)
                    // Clear of the mark the wrist's buzz leaves at the top of the page.
                    reading(plan, now).padding(.leading, -14).padding(.top, 34)
                }
            } else {
                VStack(spacing: 0) {
                    if look == .abacus { AbacusFace(session: session, plan: plan, now: now, actions: actions).padding(.top, 14) }
                    else { LoopFace(session: session, plan: plan, now: now, actions: actions) }
                    reading(plan, now).padding(.top, 14)
                }
            }
        }
    }

    private func reading(_ plan: StationPlan, _ now: Date) -> some View {
        let rung = session.ringing(at: now)
        return VStack(spacing: 0) {
            ZStack {
                if let first = rung.first {
                    let durations = session.recipe.durations(step: first.step)
                    let cue = durations.indices.contains(first.slot) ? StepDetails.cue(for: durations[first.slot], in: session.recipe.steps[first.step]) : nil
                    TimeUp(timer: first, place: plan.spot(step: first.step).vessel, others: rung.count - 1, cue: cue, controls: controls, stop: actions.stopRinging)
                        .transition(.opacity)
                } else {
                    Ticket(session: session, plan: plan, now: now, beads: true)
                }
            }
            .clipped()
            .animation(reduceMotion ? nil : .entrance, value: rung.isEmpty)
            Spacer(minLength: 0)
        }
    }
}

/// A time that is up, where the step was, as the alarm shows one ringing: where it is in
/// large type, what to check, and one round button that stops it.
struct TimeUp: View {
    let timer: CookTimer
    /// Where it is: "Air fryer".
    let place: String
    /// How many more are up as well.
    let others: Int
    var cue: String? = nil
    let controls: CookControls
    let stop: () -> Void
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("Time’s up" + (others > 0 ? " · and \(others) more" : "")).font(.heading).foregroundStyle(Color.muted)
                Text(place).font(.geist(44, .medium, relativeTo: .largeTitle)).tracking(-1.2).lineLimit(1).minimumScaleFactor(0.5)
                if let cue {
                    Text("Check: \(cue)").font(.bodyText).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 12)
            Button(action: stop) {
                VStack(spacing: 10) {
                    if let trigger = controls.trigger(for: .timer) { TriggerGlyphs(steps: trigger.steps, size: 26) }
                    Text("Stop").font(.geist(30, .medium, relativeTo: .title)).tracking(-0.6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    Circle().strokeBorder(Color.rule, lineWidth: Metric.hairline).scaleEffect(breathe ? 1.04 : 0.96)
                    Circle().strokeBorder(Color.ink, lineWidth: 1.5).padding(14)
                }
                .contentShape(Circle())
            }
            .buttonStyle(PressRow())
            .frame(maxHeight: 210)
            .padding(.vertical, 18)
            if let trigger = controls.trigger(for: .addMinute) {
                HStack(spacing: 6) {
                    TriggerGlyphs(steps: trigger.steps, size: 15)
                    Text("Another minute").font(.caption)
                }
                .foregroundStyle(Color.muted)
            }
        }
        .padding(.horizontal, Metric.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Time’s up at the \(place.lowercased()), step \(timer.step + 1)" + (cue.map { ". Check: \($0)" } ?? ""))
        .accessibilityHint("Stops the timer.")
        .accessibilityAction(.default, stop)
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
                    HStack(spacing: 8) {
                        ForEach(0..<Beads.count, id: \.self) { index in
                            Bead(size: 30, level: fills[index], stroke: fills[index] > 0 ? Color.ink : Color.muted).arrive(index)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 26)
                    Text("Get everything out.").font(.geist(32, relativeTo: .title)).tracking(-0.5)
                    Text(["\(session.ready.count) of \(items.count) out", session.recipe.yield].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).monospacedDigit().foregroundStyle(Color.muted)
                        .contentTransition(.numericText()).padding(.top, 8).padding(.bottom, 18)
                    // What a later step needs ready, said now while there is time.
                    let first = StepDetails.headStarts(in: session.recipe.steps)
                    if !first.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Start first").font(.label)
                            ForEach(first, id: \.self) { Text($0).font(.geist(20, relativeTo: .title3)).fixedSize(horizontal: false, vertical: true) }
                        }
                        .padding(.bottom, 20)
                    }
                    // What was written down the last time, read before it is too late to use.
                    if let notes = session.recipe.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Remember").font(.label)
                            ForEach(notes.suffix(2), id: \.self) { Text($0).font(.bodyText).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true) }
                        }
                        .padding(.bottom, 20)
                    }
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        Hairline(delay: 0.02 * Double(index))
                        row(index, item).id(index)
                    }
                    Hairline()
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 24).padding(.bottom, 16)
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
                Bead(size: 20, level: out ? 1 : 0, stroke: out || marked ? Color.ink : Color.muted, ringed: marked, tap: out ? 1 : 0)
                    .padding(.horizontal, 6)
                Text(line.name).strikethrough(out, color: Color.muted).foregroundStyle(out ? Color.muted : Color.ink)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(line.amount ?? "").monospacedDigit().foregroundStyle(Color.muted).lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
            }
            .font(.geist(20, relativeTo: .title3))
            .padding(.vertical, 14).contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item)
        .accessibilityAddTraits(out ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: The wrist dial

/// The wrist dial as the loop of eight, shown while the index finger is pinched and
/// held: ink rises in the beads clockwise from the top as the wrist turns, a bead for an
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
        // The bead the ink has reached, which the ring settles round.
        let level = fills.reduce(0, +)
        let head = level <= 0 ? -1 : (Int(level.rounded(.up)) - 1) % Beads.count
        GeometryReader { geo in
            let side = max(160, min(geo.size.width - 56, geo.size.height - 150))
            let bead = side * 0.17, radius = (side - bead) / 2 - 6
            VStack(spacing: 18) {
                Text(label).font(.heading).foregroundStyle(Color.muted)
                ZStack {
                    ForEach(0..<Beads.count, id: \.self) { index in
                        let fill = fills.indices.contains(index) ? fills[index] : 0
                        ZStack {
                            Bead(size: bead, level: min(1, fill), stroke: fill > 0 ? Color.ink : Color.muted, ringed: index == head)
                            // A second turn of the dial marks the bead again with the ring's dot, in paper.
                            Circle().fill(Color.paper).frame(width: bead * 0.3, height: bead * 0.3).scaleEffect(CGFloat(min(1, max(0, fill - 1))))
                        }
                        .modifier(OnLoop(angle: Double(index) * .pi / 4 - .pi / 2, radius: open || reduceMotion ? radius : radius * 0.7))
                    }
                    // Sized to stay inside the beads, however many digits the time has.
                    FlapDigits(text: value, size: side * (value.count <= 4 ? 0.2 : value.count == 5 ? 0.17 : 0.125))
                }
                .frame(width: side, height: side)
                .opacity(open ? 1 : 0)
                Text(hint).font(.label).foregroundStyle(Color.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.paper)
        .onAppear { withAnimation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.15)) { open = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setting \(label) to \(value)")
    }
}
