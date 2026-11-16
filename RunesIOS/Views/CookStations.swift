import SwiftUI

// Cook's Stations look. The top of the screen is a plan of the kitchen: the hob's four
// burners, the oven and the counter, with each thing on the go sitting where it really
// is and its time in the ring of its own burner. So an alarm is known by where it is, not
// by a name to match up. Under the plan the step is printed as a ticket, in one width of
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
                kitchen(plan, now: context.date).padding(.horizontal, Metric.gutter).padding(.top, 12)
                Ticket(session: session, plan: plan, now: context.date).padding(.top, 16)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: The plan

    private func kitchen(_ plan: StationPlan, now: Date) -> some View {
        VStack(spacing: 10) {
            VStack(spacing: 10) {
                HStack(spacing: 10) { burner(.backLeft, plan, now); burner(.backRight, plan, now) }
                HStack(spacing: 10) { burner(.frontLeft, plan, now); burner(.frontRight, plan, now) }
            }
            .padding(10)
            .overlay(RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.ink, lineWidth: 1.5))
            HStack(spacing: 10) { bench(.oven, plan, now); bench(.counter, plan, now) }
        }
    }

    /// What is at a place now: the timer going there, whether the step showing is there,
    /// and a time of that step waiting to be started.
    private struct Scene {
        var vessel: String?
        var timer: CookTimer?
        var here = false
        var waiting: Int?
        var selected = false
    }

    private func scene(_ place: StationPlan.Place, _ plan: StationPlan, _ now: Date) -> Scene {
        let live = session.timers.filter { $0.isLive && plan.spot(step: $0.step).place == place }
        let timer = live.min { $0.remaining(at: now) < $1.remaining(at: now) }
        let here = !session.finished && !session.gathering && plan.spot(step: session.step).place == place
        let waiting = here && timer == nil ? session.durations.first?.seconds : nil
        return Scene(vessel: here ? plan.spot(step: session.step).vessel : timer.map { plan.spot(step: $0.step).vessel } ?? plan.vessel(at: place),
                     timer: timer, here: here, waiting: waiting, selected: timer != nil && timer?.id == session.selectedTimer?.id)
    }

    private func act(_ scene: Scene) {
        if let timer = scene.timer { actions.toggleTimer(timer.id) } else if scene.waiting != nil { actions.toggle(session.slot) }
    }

    private func burner(_ place: StationPlan.Place, _ plan: StationPlan, _ now: Date) -> some View {
        let scene = scene(place, plan, now)
        let ringing = scene.timer?.isRinging(at: now) ?? false, paused = scene.timer?.isPaused ?? false
        let left = scene.timer.map { ringing ? 0 : $0.remaining(at: now) }
        let remaining = scene.timer.map { 1 - $0.progress(at: now) } ?? 0
        return ZStack {
            if scene.vessel == nil {
                Circle().strokeBorder(Color.faint, style: StrokeStyle(lineWidth: Metric.hairline, dash: [2, 4])).padding(14)
            } else {
                Circle().strokeBorder(scene.here ? Color.ink : Color.rule, lineWidth: scene.here ? 2.5 : Metric.hairline)
                if ringing {
                    Circle().fill(Color.ink).padding(7)
                } else if scene.timer != nil {
                    Circle().trim(from: 0, to: max(0.01, remaining))
                        .stroke(paused ? Color.muted : Color.ink, style: StrokeStyle(lineWidth: scene.selected || scene.here ? 8 : 4, lineCap: .butt))
                        .rotationEffect(.degrees(-90)).padding(scene.selected || scene.here ? 9 : 7)
                        .animation(.linear(duration: 0.5), value: remaining)
                }
                VStack(spacing: 1) {
                    if let left {
                        Text(DurationFinder.clock(left)).font(.geist(26, .medium, relativeTo: .title2)).monospacedDigit().tracking(-0.8)
                            .contentTransition(.numericText(countsDown: true)).animation(.standard, value: left)
                    } else if let waiting = scene.waiting {
                        Text(DurationFinder.clock(waiting)).font(.geist(26, .medium, relativeTo: .title2)).monospacedDigit().tracking(-0.8)
                            .foregroundStyle(Color.muted)
                    }
                    Text(scene.vessel ?? "").font(.caption).lineLimit(1)
                        .foregroundStyle(ringing ? Color.paper.opacity(0.75) : scene.here ? Color.ink : Color.muted)
                }
                .foregroundStyle(ringing ? Color.paper : paused ? Color.muted : Color.ink)
            }
        }
        .aspectRatio(1, contentMode: .fit).frame(maxWidth: 150)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { act(scene) }
        .onLongPressGesture(minimumDuration: 0.5) { if let timer = scene.timer { actions.cancelTimer(timer.id) } }
        .animation(.standard, value: scene.here)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(scene.vessel.map { "\($0), " + (left.map { ringing ? "time’s up" : "\(DurationFinder.short($0)) left" } ?? (scene.here ? "this step" : "idle")) } ?? "Empty burner")
    }

    private func bench(_ place: StationPlan.Place, _ plan: StationPlan, _ now: Date) -> some View {
        let scene = scene(place, plan, now)
        let ringing = scene.timer?.isRinging(at: now) ?? false
        let left = scene.timer.map { ringing ? 0 : $0.remaining(at: now) }
        let remaining = scene.timer.map { 1 - $0.progress(at: now) } ?? 0
        let used = scene.vessel != nil
        return VStack(alignment: .leading, spacing: 5) {
            Text(scene.vessel ?? (place == .oven ? "Oven" : "Counter")).font(.caption).opacity(0.75)
            Text(left.map(DurationFinder.clock) ?? scene.waiting.map(DurationFinder.clock) ?? (scene.here ? "now" : "–"))
                .font(.geist(24, .medium, relativeTo: .title2)).monospacedDigit().tracking(-0.6)
                .opacity(left == nil && !scene.here ? 0.35 : 1)
            GeometryReader { geo in
                Rectangle().fill(ringing ? Color.paper : Color.ink).frame(width: geo.size.width * remaining, height: 3)
                    .animation(.linear(duration: 0.5), value: remaining)
            }
            .frame(height: 3)
        }
        .foregroundStyle(ringing ? Color.paper : Color.ink)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background { if ringing { RoundedRectangle(cornerRadius: Metric.panel).fill(Color.ink) } }
        .overlay(RoundedRectangle(cornerRadius: Metric.panel)
            .strokeBorder(scene.here ? Color.ink : used ? Color.rule : Color.faint, lineWidth: scene.here ? 2.5 : Metric.hairline))
        .contentShape(Rectangle())
        .onTapGesture { act(scene) }
        .onLongPressGesture(minimumDuration: 0.5) { if let timer = scene.timer { actions.cancelTimer(timer.id) } }
        .animation(.standard, value: scene.here)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
