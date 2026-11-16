import SwiftUI

// Cook's Stations look. The top of the screen is the pans this recipe uses, drawn from
// above: the skillet, the pot, the oven, the board. One with a timer going is solid ink
// with its time in it and shows that it is cooking. So an alarm is known by which pan it
// is, not by a name to match up. Under the plan the step is printed as a ticket, in one width of
// letter like a kitchen printer's, a sentence at a time. Where each step happens is
// worked out from its words (Cook/Stations.swift). A tap on a place starts, pauses or
// stops what is there; a hold clears it.

private func ticketFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

/// A line of dashes, where a ticket would tear.
private struct Perforation: View {
    var body: some View {
        Rectangle().fill(Color.clear).frame(height: 1)
            .overlay(Rectangle().stroke(Color.ink, style: StrokeStyle(lineWidth: 1, dash: [2, 5])).frame(height: 1))
            .accessibilityHidden(true)
    }
}

struct StationsPage: View {
    let session: CookSession
    let actions: CookActions

    var body: some View {
        let plan = StationPlan(steps: session.recipe.steps)
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            VStack(spacing: 0) {
                shelf(plan, now: context.date).padding(.horizontal, Metric.gutter).padding(.top, 6)
                Ticket(session: session, plan: plan, now: context.date).padding(.top, 16)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: The pans

    /// The places this recipe uses, in the order it comes to them. A kitchen has more,
    /// but an empty burner is nothing to look at.
    private func places(_ plan: StationPlan) -> [StationPlan.Place] {
        var seen: [StationPlan.Place] = []
        for spot in plan.spots where !seen.contains(spot.place) { seen.append(spot.place) }
        return seen
    }

    private func shelf(_ plan: StationPlan, now: Date) -> some View {
        let used = places(plan)
        let columns = used.count == 3 ? 3 : used.count == 1 ? 1 : 2
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 12) {
            ForEach(used, id: \.self) { place in pan(place, plan, now) }
        }
    }

    /// What is at a place now: the timer going there, whether the step showing is there,
    /// and a time of that step waiting to be started.
    private struct Scene {
        var vessel: String?
        var timer: CookTimer?
        var here = false
        var waiting: Int?
    }

    private func scene(_ place: StationPlan.Place, _ plan: StationPlan, _ now: Date) -> Scene {
        let live = session.timers.filter { $0.isLive && plan.spot(step: $0.step).place == place }
        let timer = live.min { $0.remaining(at: now) < $1.remaining(at: now) }
        let here = !session.finished && !session.gathering && plan.spot(step: session.step).place == place
        let waiting = here && timer == nil ? session.durations.first?.seconds : nil
        return Scene(vessel: here ? plan.spot(step: session.step).vessel : timer.map { plan.spot(step: $0.step).vessel } ?? plan.vessel(at: place),
                     timer: timer, here: here, waiting: waiting)
    }

    private func pan(_ place: StationPlan.Place, _ plan: StationPlan, _ now: Date) -> some View {
        let scene = scene(place, plan, now)
        let ringing = scene.timer?.isRinging(at: now) ?? false, paused = scene.timer?.isPaused ?? false
        let left = scene.timer.map { ringing ? 0 : $0.remaining(at: now) }
        let kind: Vessel.Kind = place == .oven ? .oven : place == .counter ? (scene.vessel == "Board" ? .board : .bowl) : scene.vessel == "Pot" ? .pot : .skillet
        return VStack(spacing: 4) {
            Vessel(kind: kind, on: scene.timer != nil, here: scene.here, lively: scene.timer != nil && !paused && !ringing, rattling: ringing,
                   text: left.map(DurationFinder.clock) ?? scene.waiting.map(DurationFinder.clock) ?? (scene.here ? "now" : ""),
                   quiet: left == nil || paused)
                .frame(height: 128)
            Text(scene.vessel ?? "").font(.label).foregroundStyle(scene.here || scene.timer != nil ? Color.ink : Color.muted)
        }
        .contentShape(Rectangle())
        .onTapGesture { if let timer = scene.timer { actions.toggleTimer(timer.id) } else if scene.waiting != nil { actions.toggle(session.slot) } }
        .onLongPressGesture(minimumDuration: 0.5) { if let timer = scene.timer { actions.cancelTimer(timer.id) } }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel((scene.vessel ?? "") + ", " + (left.map { ringing ? "time’s up" : "\(DurationFinder.short($0)) left" } ?? (scene.here ? "this step" : "idle")))
    }
}

/// A utensil drawn in line, the way a good cookbook draws them. A skillet from above with
/// its rim, a riveted handle and the hole it hangs by; a pot with two loop handles and a
/// lid with its knob; an oven from the front with a door, a window and knobs; a bowl with
/// a spoon in it; a board with a knife on it. Idle it is a quiet outline. With a timer
/// going, what is in it is ink, with the time in it, and it shows that it is cooking:
/// steam off a pot, fat spitting from a skillet, heat over an oven. When its time is up
/// it rattles until it is stopped. With Reduce Motion it holds still.
private struct Vessel: View {
    enum Kind { case skillet, pot, oven, bowl, board }
    let kind: Kind
    let on: Bool
    let here: Bool
    let lively: Bool
    let rattling: Bool
    let text: String
    let quiet: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let radius: CGFloat = 44

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !(lively || rattling))) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: 0) {
                Canvas { canvas, size in if lively, !reduceMotion { life(&canvas, size, t) } }
                    .frame(height: 28)
                ZStack {
                    Canvas { canvas, size in draw(&canvas, size) }
                    Text(text)
                        .font(.geist(text.count > 4 ? 19 : 23, .medium, relativeTo: .title2)).monospacedDigit().tracking(-0.8)
                        .foregroundStyle(on ? Color.paper : quiet ? Color.muted : Color.ink).opacity(on && quiet ? 0.6 : 1)
                        .contentTransition(.numericText(countsDown: true))
                        .offset(y: kind == .oven ? 8 : 0)
                }
                .frame(height: 100)
                // A lid that rattles: a few degrees either way, fast.
                .rotationEffect(.degrees(rattling && !reduceMotion ? sin(t * 38) * 3.5 : 0))
            }
            .frame(maxWidth: .infinity)
            .animation(.entrance, value: on)
        }
    }

    private func draw(_ canvas: inout GraphicsContext, _ size: CGSize) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2), r = Self.radius
        let line = on || here ? Color.ink : Color.muted
        let weight: CGFloat = here ? 2.5 : 1.5
        let style = StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round)
        let thin = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        // Shapes are laid out round the origin, then turned and moved to the middle.
        func placed(_ path: Path, turned degrees: Double = 0) -> Path {
            path.applying(CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: degrees * .pi / 180))
        }
        func circle(_ radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> Path {
            Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        func outlined(_ path: Path, _ stroke: StrokeStyle) {
            canvas.fill(path, with: .color(Color.paper))
            canvas.stroke(path, with: .color(line), style: stroke)
        }
        switch kind {
        case .skillet:
            // The handle first, so the pan sits on top of where it joins.
            outlined(placed(Path(roundedRect: CGRect(x: r - 6, y: -6.5, width: 58, height: 13), cornerRadius: 6.5), turned: 24), style)
            canvas.stroke(placed(circle(2.4, x: r + 44), turned: 24), with: .color(line), style: thin)
            outlined(placed(circle(r)), style)
            canvas.fill(placed(circle(1.6, x: r + 4, y: -2.5), turned: 24), with: .color(line))
            canvas.fill(placed(circle(1.6, x: r + 4, y: 2.5), turned: 24), with: .color(line))
            // The cooking surface inside the rim: ink when something is in it.
            if on { canvas.fill(placed(circle(r - 7)), with: .color(Color.ink)) }
            else { canvas.stroke(placed(circle(r - 7)), with: .color(line), style: thin) }
        case .pot:
            for side in [-1.0, 1.0] {
                outlined(placed(Path(roundedRect: CGRect(x: side * (r + 4) - 9, y: -13, width: 18, height: 26), cornerRadius: 8)), style)
            }
            outlined(placed(circle(r)), style)
            if on {
                canvas.fill(placed(circle(r - 7)), with: .color(Color.ink))
            } else {
                // The lid on, with its knob, unless a time is waiting to be read there.
                canvas.stroke(placed(circle(r - 7)), with: .color(line), style: thin)
                if text.isEmpty { outlined(placed(circle(8)), style); canvas.fill(placed(circle(2)), with: .color(line)) }
            }
        case .oven:
            let body = CGRect(x: -56, y: -44, width: 112, height: 88)
            outlined(placed(Path(roundedRect: body, cornerRadius: 12)), style)
            canvas.stroke(placed(Path { $0.move(to: CGPoint(x: -56, y: -24)); $0.addLine(to: CGPoint(x: 56, y: -24)) }), with: .color(line), style: thin)
            for knob in 0..<3 { canvas.stroke(placed(circle(3.5, x: -42 + CGFloat(knob) * 13, y: -34)), with: .color(line), style: thin) }
            canvas.stroke(placed(Path { $0.move(to: CGPoint(x: 24, y: -34)); $0.addLine(to: CGPoint(x: 44, y: -34)) }), with: .color(line), style: style)
            // The door's window: ink while something is in there.
            let window = placed(Path(roundedRect: CGRect(x: -44, y: -14, width: 88, height: 48), cornerRadius: 8))
            if on { canvas.fill(window, with: .color(Color.ink)) } else { canvas.stroke(window, with: .color(line), style: thin) }
        case .bowl:
            outlined(placed(circle(r - 2)), style)
            if on { canvas.fill(placed(circle(r - 10)), with: .color(Color.ink)) }
            else { canvas.stroke(placed(circle(r - 10)), with: .color(line), style: thin) }
            // A spoon left in it, its handle over the rim.
            outlined(placed(Path(roundedRect: CGRect(x: 14, y: -3.5, width: 46, height: 7), cornerRadius: 3.5), turned: -38), style)
            outlined(placed(Path(ellipseIn: CGRect(x: 2, y: -8, width: 20, height: 16)), turned: -38), style)
        case .board:
            outlined(placed(Path(roundedRect: CGRect(x: -54, y: -36, width: 108, height: 72), cornerRadius: 10)), style)
            canvas.stroke(placed(circle(4.5, x: 42, y: -24)), with: .color(line), style: thin)
            // A knife across it: the blade in outline, the handle solid.
            let blade = Path { path in
                path.move(to: CGPoint(x: -40, y: 4)); path.addQuadCurve(to: CGPoint(x: 8, y: -6), control: CGPoint(x: -18, y: -8))
                path.addLine(to: CGPoint(x: 8, y: 5)); path.closeSubpath()
            }
            outlined(placed(blade, turned: -14), StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            canvas.fill(placed(Path(roundedRect: CGRect(x: 8, y: -6, width: 30, height: 11), cornerRadius: 4), turned: -14), with: .color(line))
        }
    }

    /// What rises off it while it cooks.
    private func life(_ canvas: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let middle = size.width / 2
        switch kind {
        case .pot:
            // Steam: three wisps that waver as they climb and thin out at the top.
            for wisp in 0..<3 {
                let x = middle + CGFloat(wisp - 1) * 20
                var path = Path()
                var y = size.height
                path.move(to: CGPoint(x: x + sin(t * 3 + Double(wisp)) * 2, y: y))
                while y > 2 {
                    y -= 3
                    path.addLine(to: CGPoint(x: x + sin(Double(y) / 6 + t * 3 + Double(wisp) * 2) * 4, y: y))
                }
                canvas.stroke(path, with: .linearGradient(Gradient(colors: [Color.ink, Color.ink.opacity(0)]), startPoint: CGPoint(x: x, y: size.height),
                                                           endPoint: CGPoint(x: x, y: 0)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        case .skillet:
            // Fat spitting: dots that jump up off the pan and are gone.
            for spit in 0..<7 {
                let phase = (t * 1.6 + Double(spit) * 0.37).truncatingRemainder(dividingBy: 1)
                let x = middle + CGFloat(sin(Double(spit) * 2.4)) * 34
                let y = size.height - CGFloat(sin(phase * .pi)) * (14 + CGFloat(spit % 3) * 5)
                canvas.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 3, width: 3, height: 3)), with: .color(Color.ink.opacity(1 - phase)))
            }
        case .oven:
            // Heat: lines that shimmer above it.
            for line in 0..<3 {
                var path = Path()
                let y = size.height - 6 - CGFloat(line) * 8
                var x = middle - 36
                path.move(to: CGPoint(x: x, y: y))
                while x < middle + 36 {
                    x += 3
                    path.addLine(to: CGPoint(x: x, y: y + sin(Double(x) / 7 + t * 4 + Double(line)) * 2.2))
                }
                canvas.stroke(path, with: .color(Color.ink.opacity(0.9 - Double(line) * 0.3)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        case .bowl, .board:
            break
        }
    }
}

// MARK: The ticket

/// The step as a ticket off the printer: its number and where it happens, one sentence
/// in capitals, the amounts it calls for, and what follows. A new sentence feeds out
/// from under the tear line.
private struct Ticket: View {
    let session: CookSession
    let plan: StationPlan
    let now: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let beats = session.beats, index = session.beatIndex, sentence = beats[index]
        let uses = Ingredients.uses(in: sentence, of: session.recipe.ingredients).map(\.text)
        let spot = plan.spot(step: session.step)
        VStack(alignment: .leading, spacing: 0) {
            Perforation()
            HStack(spacing: 10) {
                Text(String(format: "%02d/%02d", session.step + 1, session.count))
                Text(spot.vessel.uppercased())
                Spacer()
                if beats.count > 1 { Text("\(index + 1) OF \(beats.count)").foregroundStyle(Color.muted) }
            }
            .font(ticketFont(13, .semibold)).padding(.top, 12)
            VStack(alignment: .leading, spacing: 10) {
                Text(sentence.uppercased())
                    .font(ticketFont(sentence.count < 60 ? 24 : sentence.count < 110 ? 20 : 17, .bold)).lineSpacing(2)
                    .minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
                if !uses.isEmpty {
                    VStack(alignment: .leading, spacing: 2) { ForEach(uses.prefix(3), id: \.self) { Text($0.uppercased()) } }
                        .font(ticketFont(15))
                }
                // When to start this so it is done with what is already on.
                if let landing = session.landing(at: now) {
                    Text("START IN \(DurationFinder.clock(landing.wait)) · LANDS WITH \(landing.with.label.uppercased())")
                        .font(ticketFont(15, .semibold)).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .overlay(Rectangle().strokeBorder(Color.ink, lineWidth: 1.5))
                }
            }
            .padding(.top, 10)
            .id("\(session.step).\(index)")
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            Spacer(minLength: 10)
            Perforation()
            HStack(spacing: 10) {
                Text(session.isLast && index == beats.count - 1 ? "LAST" : "NEXT")
                if index < beats.count - 1 {
                    Text(beats[index + 1].uppercased()).lineLimit(1)
                } else if !session.isLast {
                    Text(String(format: "%02d", session.step + 2) + " " + plan.spot(step: session.step + 1).vessel.uppercased()).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(ticketFont(13)).foregroundStyle(Color.muted).padding(.top, 10)
        }
        .padding(.horizontal, Metric.gutter + 4)
        .clipped()
        .animation(reduceMotion ? nil : .entrance, value: index)
        .animation(reduceMotion ? nil : .entrance, value: session.step)
        .accessibilityElement(children: .combine)
    }
}

// MARK: The receipt

/// The cook, printed: what was made, each step and where it was done, how long it took,
/// and the notes to keep. It is what the finished screen shows in this look.
struct CookReceipt: View {
    let session: CookSession
    /// When the cook ended; now, while it is on the finished screen.
    var ended = Date()
    /// Nil for a receipt from the past, which is only read.
    let addNote: (() -> Void)?
    @State private var bow: BandGesture?

    var body: some View {
        let plan = StationPlan(steps: session.recipe.steps)
        let minutes = max(1, Int(ended.timeIntervalSince(session.started) / 60))
        VStack(alignment: .leading, spacing: 0) {
            // The ring of beads signs the receipt, and takes a bow when it is printed.
            HairlineRing(phase: .connected, gesture: bow).frame(height: 150).frame(maxWidth: .infinity)
                .padding(.bottom, 6).accessibilityHidden(true)
                .onAppear { bow = BandGesture(id: 1, kind: .doubleTap, finger: 2, at: Date()) }
            Text(session.recipe.title.uppercased()).font(ticketFont(22, .bold)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(session.started.formatted(date: .abbreviated, time: .shortened).uppercased())
                Spacer()
                Text((session.recipe.yield ?? "").uppercased())
            }
            .font(ticketFont(13)).padding(.top, 6)
            Perforation().padding(.vertical, 12)
            ForEach(Array(session.recipe.steps.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 8) {
                    Text(String(format: "%02d", index + 1))
                    Text(plan.spot(step: index).vessel.uppercased())
                    Text(String(repeating: ".", count: 40)).lineLimit(1).foregroundStyle(Color.faint)
                    Text("DONE").fixedSize()
                }
                .font(ticketFont(15)).padding(.vertical, 3)
            }
            Perforation().padding(.vertical, 12)
            HStack {
                Text("TOTAL")
                Spacer()
                Text("\(minutes) MIN")
            }
            .font(ticketFont(22, .bold))
            if let notes = session.recipe.notes, !notes.isEmpty {
                Perforation().padding(.vertical, 12)
                ForEach(notes, id: \.self) { Text("* " + $0.uppercased()).font(ticketFont(13)).padding(.vertical, 2).fixedSize(horizontal: false, vertical: true) }
            }
            Perforation().padding(.vertical, 12)
            if let addNote {
                Button(action: addNote) { Text("+ ADD A NOTE FOR NEXT TIME").font(ticketFont(13, .semibold)).frame(minHeight: Metric.tap) }
                    .buttonStyle(PressRow())
            }
            // A bar code, because a receipt has one: the same recipe always prints the same.
            Canvas { context, size in
                var seed = UInt64(truncatingIfNeeded: session.recipe.title.hashValue) | 1, x: CGFloat = 0
                while x < size.width {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let width = CGFloat(1 + (seed >> 60) % 3)
                    context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(Color.ink))
                    x += width + CGFloat(1 + (seed >> 56) % 4)
                }
            }
            .frame(height: 44).padding(.top, 8).accessibilityHidden(true)
            Text("ENJOY.").font(ticketFont(13, .semibold)).frame(maxWidth: .infinity).padding(.top, 10)
        }
        .padding(.horizontal, Metric.gutter + 4).padding(.vertical, 20)
    }
}
