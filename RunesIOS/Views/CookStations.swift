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
        let kind: Vessel.Kind = place == .oven ? .oven : place == .counter ? .counter : scene.vessel == "Pot" ? .pot : .skillet
        return VStack(spacing: 4) {
            Vessel(kind: kind, on: scene.timer != nil, here: scene.here, lively: scene.timer != nil && !paused && !ringing, rattling: ringing,
                   text: left.map(DurationFinder.clock) ?? scene.waiting.map(DurationFinder.clock) ?? (scene.here ? "now" : ""),
                   quiet: left == nil || paused)
                .frame(height: 124)
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

/// A pan seen from above, drawn in ink: a skillet with its handle, a pot with its ears, an
/// oven with its knobs, a board. Idle it is an outline; with a timer going it is solid,
/// with the time in it, and it shows it is cooking: steam off a pot, fat spitting round
/// a skillet, heat shimmering over an oven. When its time is up it rattles until it is
/// stopped. With Reduce Motion it holds still.
private struct Vessel: View {
    enum Kind { case skillet, pot, oven, counter }
    let kind: Kind
    let on: Bool
    let here: Bool
    let lively: Bool
    let rattling: Bool
    let text: String
    let quiet: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let round: CGFloat = 84

    private func piece<S: InsettableShape>(_ shape: S) -> some View {
        shape.fill(on ? Color.ink : Color.paper)
            .overlay(shape.strokeBorder(on || here ? Color.ink : Color.faint, lineWidth: here ? 3 : 1.5))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !(lively || rattling))) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: 2) {
                Canvas { canvas, size in if lively, !reduceMotion { life(&canvas, size, t) } }
                    .frame(height: 30)
                ZStack {
                    switch kind {
                    case .skillet:
                        piece(Capsule()).frame(width: 40, height: 11).offset(x: Self.round / 2 + 14)
                        piece(Circle()).frame(width: Self.round, height: Self.round)
                    case .pot:
                        piece(Capsule()).frame(width: 12, height: 24).offset(x: -Self.round / 2 - 3)
                        piece(Capsule()).frame(width: 12, height: 24).offset(x: Self.round / 2 + 3)
                        piece(Circle()).frame(width: Self.round, height: Self.round)
                    case .oven:
                        piece(RoundedRectangle(cornerRadius: 14)).frame(width: 112, height: 80)
                        HStack(spacing: 5) { ForEach(0..<3, id: \.self) { _ in Circle().fill(on ? Color.paper : Color.faint).frame(width: 5, height: 5) } }
                            .offset(x: -36, y: -28)
                    case .counter:
                        piece(RoundedRectangle(cornerRadius: 9)).frame(width: 112, height: 72)
                        Circle().strokeBorder(on ? Color.paper : Color.faint, lineWidth: 1.5).frame(width: 9, height: 9).offset(x: 42, y: -24)
                    }
                    Text(text)
                        .font(.geist(text.count > 4 ? 20 : 24, .medium, relativeTo: .title2)).monospacedDigit().tracking(-0.8)
                        .foregroundStyle(on ? Color.paper : quiet ? Color.muted : Color.ink).opacity(on && quiet ? 0.6 : 1)
                        .contentTransition(.numericText(countsDown: true))
                }
                .frame(height: Self.round + 4)
                // A lid that rattles: a few degrees either way, fast.
                .rotationEffect(.degrees(rattling && !reduceMotion ? sin(t * 38) * 3.5 : 0))
            }
            .frame(maxWidth: .infinity)
            .animation(.entrance, value: on)
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
        case .counter:
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
    let addNote: () -> Void

    var body: some View {
        let plan = StationPlan(steps: session.recipe.steps)
        let minutes = max(1, Int(Date().timeIntervalSince(session.started) / 60))
        VStack(alignment: .leading, spacing: 0) {
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
            Button(action: addNote) { Text("+ ADD A NOTE FOR NEXT TIME").font(ticketFont(13, .semibold)).frame(minHeight: Metric.tap) }
                .buttonStyle(PressRow())
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
