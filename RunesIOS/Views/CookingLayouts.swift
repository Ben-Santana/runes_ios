import SwiftUI

// Cooking's Hob look and the time's-up band.
//
// The hob is a fixed row of four rings under the pages, like pans on burners. Every
// timer still going sits there, whichever step started it, with its time inside and what
// it is for underneath; the times of the step showing wait there too, not yet started.
// The pages slide above; the rings stay where they are. This step's rings are ink, other
// steps' muted with their step number, the one the band acts on has a second ring round
// it, and one whose time is up is a solid disc. By touch: tap to start, pause or stop,
// hold to reset, swipe up for another minute.

struct Hob: View {
    let session: CookSession
    let actions: CookActions
    private static let burners = 4

    /// Something on a burner: a timer, or one of this step's times waiting to be started.
    struct Pot: Identifiable {
        var id: String
        var timer: CookTimer?
        var label: String
        var seconds: Int
        var step: Int
        var slot: Int
    }

    /// Timers in the order they were started, so one stays on its burner as pages turn,
    /// then the times this step has that aren't going.
    var pots: [Pot] {
        var result = session.timers.filter(\.isLive).map {
            Pot(id: $0.id, timer: $0, label: $0.label, seconds: $0.total, step: $0.step, slot: $0.slot)
        }
        guard !session.finished else { return result }
        for (slot, duration) in session.durations.enumerated() where session.timer(step: session.step, slot: slot)?.isLive != true {
            result.append(Pot(id: "\(session.step).\(slot)", timer: nil, label: duration.label ?? "Step \(session.step + 1)",
                              seconds: duration.seconds, step: session.step, slot: slot))
        }
        return result
    }

    /// With more timers than burners, the ones that stay: this step's and the selected
    /// one first, since the rings are the only way to touch them. The last burner counts the rest.
    private func fitting(_ pots: [Pot]) -> [Pot] {
        let needed = pots.filter { $0.step == session.step || selected($0) }.map(\.id)
        let keep = Set((needed + pots.map(\.id).filter { !needed.contains($0) }).prefix(Self.burners - 1))
        return pots.filter { keep.contains($0.id) }
    }

    func selected(_ pot: Pot) -> Bool {
        if let timer = pot.timer { return session.selectedTimer?.id == timer.id }
        return session.pickedTimer == nil && pot.slot == session.slot
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let pots = pots
            let shown = pots.count > Self.burners ? fitting(pots) : pots
            // With nothing on it the hob isn't drawn, and the step has the room.
            if !pots.isEmpty { VStack(spacing: 0) {
                Rule(inset: 0)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<Self.burners, id: \.self) { index in
                        Group {
                            if index < shown.count {
                                let pot = shown[index]
                                Burner(timer: pot.timer, label: pot.label, seconds: pot.seconds, step: pot.step, slot: pot.slot,
                                       own: pot.step == session.step && !session.finished,
                                       selected: pots.count > 1 && !session.finished && selected(pot), now: context.date, actions: actions)
                                    .id(pot.id)
                                    .transition(.opacity)
                            } else {
                                Burner.empty(more: index == Self.burners - 1 ? pots.count - shown.count : 0)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
            }
            .animation(.standard, value: pots.map(\.id))
            .transition(.opacity) }
        }
    }
}

// MARK: Rail and Poster

/// Every timer as a line that runs out: what it is for, its time, and a hairline of ink
/// that shortens toward the leading edge as the time goes. The selected one is drawn
/// heavier, one waiting to be started is faint, and one whose time is up turns to ink.
/// Touch is the hob's: tap to start, pause or stop, hold to reset, swipe up for a minute.
struct TimerBars: View {
    let session: CookSession
    let actions: CookActions

    var body: some View {
        let hob = Hob(session: session, actions: actions)
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let pots = hob.pots
            VStack(spacing: 0) {
                ForEach(pots.prefix(4)) { pot in
                    bar(pot, selected: pots.count > 1 && !session.finished && hob.selected(pot), now: context.date)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Metric.gutter).padding(.top, pots.isEmpty ? 0 : 4)
            .animation(.standard, value: pots.map(\.id))
        }
    }

    private func bar(_ pot: Hob.Pot, selected: Bool, now: Date) -> some View {
        let timer = pot.timer
        let ringing = timer?.isRinging(at: now) ?? false, paused = timer?.isPaused ?? false
        let left = ringing ? 0 : timer?.remaining(at: now) ?? pot.seconds
        let remaining = timer.map { 1 - $0.progress(at: now) } ?? 1
        let own = pot.step == session.step && !session.finished
        return VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pot.label).font(.label)
                if !own { Text("step \(pot.step + 1)").font(.caption).opacity(0.7) }
                if paused { LucideIcon(.pause, size: 12) }
                Spacer(minLength: 8)
                Text(ringing ? "Time’s up" : DurationFinder.clock(left))
                    .font(.geist(22, .medium, relativeTo: .title3)).monospacedDigit()
                    .contentTransition(.numericText(countsDown: true)).animation(.standard, value: left)
            }
            .foregroundStyle(ringing ? Color.paper : timer == nil || paused || !own ? Color.muted : Color.ink)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.rule).frame(height: Metric.hairline)
                    Rectangle().fill(timer == nil ? Color.faint : Color.ink)
                        .frame(width: max(0, geo.size.width * remaining), height: selected ? 3 : 1.5)
                        .animation(.linear(duration: 0.5), value: remaining)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 3).opacity(ringing ? 0 : 1)
        }
        .padding(.vertical, 9).padding(.horizontal, ringing ? Metric.inset : 0)
        .background { if ringing { RoundedRectangle(cornerRadius: Metric.panel).fill(Color.ink) } }
        .animation(.standard, value: ringing)
        .animation(.standard, value: selected)
        .contentShape(Rectangle())
        .onTapGesture { if let timer { actions.toggleTimer(timer.id) } else { actions.toggle(pot.slot) } }
        .onLongPressGesture(minimumDuration: 0.5) { if let timer { actions.cancelTimer(timer.id) } }
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            let t = value.translation
            if let timer, t.height < -30, abs(t.height) > abs(t.width) * 1.2 { actions.addMinute(timer.id) }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(pot.label), step \(pot.step + 1), \(ringing ? "time’s up" : paused ? "paused at \(DurationFinder.short(left))" : timer == nil ? "\(DurationFinder.short(left)), not started" : "\(DurationFinder.short(left)) left")")
    }
}

/// The recipe down the leading edge: a line with a point for each step. The step showing
/// is a filled circle with its number, the ones done are ink, the ones ahead faint, and a
/// step with a timer still going wears a ring. The ink runs down the line as far as the
/// cook has got. A tap on a point goes to that step.
struct StepRail: View {
    let session: CookSession
    let go: (Int) -> Void
    private static let node: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let count = session.count
            let gap = min(54, (geo.size.height - 48) / CGFloat(max(1, count - 1)))
            let here = session.gathering ? -1 : session.step
            ZStack(alignment: .top) {
                Rectangle().fill(Color.rule).frame(width: Metric.hairline, height: gap * CGFloat(max(0, count - 1))).offset(y: 24)
                Rectangle().fill(Color.ink).frame(width: 1.5, height: gap * CGFloat(max(0, here))).offset(y: 24)
                ForEach(0..<count, id: \.self) { index in
                    Button { go(index) } label: { point(index, here: here) }
                        .buttonStyle(PressRow())
                        .offset(y: 24 + gap * CGFloat(index) - Self.node / 2)
                        .accessibilityLabel("Step \(index + 1)")
                }
            }
            .frame(width: geo.size.width)
            .animation(.standard, value: here)
        }
    }

    private func point(_ index: Int, here: Int) -> some View {
        let timed = session.timers.contains { $0.isLive && $0.step == index }
        return ZStack {
            if index == here {
                Circle().fill(Color.ink)
                Text("\(index + 1)").font(.geist(12, .medium, relativeTo: .caption)).monospacedDigit().foregroundStyle(Color.paper)
            } else {
                if timed { Circle().strokeBorder(Color.ink, lineWidth: 1.5).frame(width: 16, height: 16) }
                Circle().fill(index < here ? Color.ink : Color.paper).frame(width: 7, height: 7)
                Circle().strokeBorder(index < here ? Color.ink : Color.faint, lineWidth: Metric.hairline).frame(width: 7, height: 7)
            }
        }
        .frame(width: Self.node, height: Self.node).contentShape(Rectangle())
    }
}

// MARK: Focus

/// One thing to do at a time: a sentence of the step, set as large as it goes, with the
/// amounts it calls for under it. The rest of the step waits its turn; marks at the top
/// say how many sentences the step has and which this is.
struct FocusPage: View {
    let session: CookSession

    var body: some View {
        let beats = session.beats, index = session.beatIndex
        let sentence = beats[index]
        let uses = Ingredients.uses(in: sentence, of: session.recipe.ingredients).map(\.text)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Step \(session.step + 1)").font(.label)
                Text("of \(session.count)").font(.caption).foregroundStyle(Color.muted)
                Spacer()
                if beats.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(beats.indices, id: \.self) { beat in
                            Capsule().fill(beat == index ? Color.ink : beat < index ? Color.ink.opacity(0.45) : Color.faint)
                                .frame(width: beat == index ? 18 : 6, height: 3)
                        }
                    }
                    .animation(.standard, value: index)
                    .accessibilityHidden(true)
                }
            }
            .padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 22) {
                SetType(text: words(sentence), size: size(sentence))
                if !uses.isEmpty {
                    // The number first and in ink: it is what the eye comes back for.
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(uses, id: \.self) { use in
                            let line = Ingredients.split(use)
                            (Text(line.amount.map { $0 + " " } ?? "").foregroundStyle(Color.ink).fontWeight(.medium) + Text(line.name).foregroundStyle(Color.muted))
                        }
                    }
                    .font(.geist(22, relativeTo: .title3)).monospacedDigit()
                }
            }
            .id("\(session.step).\(index)")
            .transition(.opacity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.gutter).padding(.top, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.entrance, value: index)
        .animation(.entrance, value: session.step)
        .accessibilityElement(children: .combine)
    }

    private func size(_ text: String) -> CGFloat {
        switch text.count { case ..<45: 50; case ..<80: 42; case ..<130: 34; default: 28 }
    }

    /// The sentence with how hot underlined, as on the other pages.
    private func words(_ sentence: String) -> AttributedString {
        var result = AttributedString(sentence)
        for heat in StepDetails.heat(in: sentence) {
            if let range = Range(heat, in: result) { result[range].underlineStyle = Text.LineStyle(pattern: .solid, color: Color.muted) }
        }
        return result
    }
}

/// A sentence that sets itself: each line rises into place a moment after the one above,
/// once, when the sentence arrives.
private struct SetType: View {
    let text: AttributedString
    let size: CGFloat
    @State private var set = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(.geist(size, .medium, relativeTo: .title)).tracking(-0.9).lineSpacing(1)
            .minimumScaleFactor(0.55)
            .textRenderer(LineRise(progress: set || reduceMotion ? 1 : 0))
            .onAppear { withAnimation(.easeOut(duration: 0.5)) { set = true } }
    }
}

private struct LineRise: TextRenderer, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let lines = Array(layout)
        // Each line starts a little after the one before and takes the same time to arrive.
        let lag = 0.16, span = 1 + lag * Double(max(0, lines.count - 1))
        for (index, line) in lines.enumerated() {
            let arrived = min(1, max(0, progress * span - lag * Double(index)))
            var copy = context
            copy.opacity = arrived
            copy.translateBy(x: 0, y: (1 - arrived) * 18)
            copy.draw(line)
        }
    }
}

/// Everything on the go at once, as a pile of blocks across the foot of the screen. What
/// is due soonest is at the bottom and the largest, so the size of a block says how soon
/// it wants attention. A time not started yet is an outline; one that is counting floods
/// with ink from the leading edge, and a line along its foot simmers while it counts,
/// harder in its last minute, and shortens as the time goes. Touch is the hob's.
struct TimerPile: View {
    let session: CookSession
    let actions: CookActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hob = Hob(session: session, actions: actions)
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let now = context.date
            let pots = hob.pots
            // Waiting ones on top, then the counting ones, the most time left first.
            let order = pots.filter { $0.timer == nil } + pots.filter { $0.timer != nil }.sorted { left($0, now) > left($1, now) }
            let shown = Array(order.suffix(4))
            VStack(spacing: 3) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, pot in
                    block(pot, rank: shown.count - 1 - index, selected: pots.count > 1 && !session.finished && hob.selected(pot), now: now)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.top, shown.isEmpty ? 0 : 6)
            .animation(.entrance, value: shown.map(\.id))
        }
    }

    private func left(_ pot: Hob.Pot, _ now: Date) -> Int {
        pot.timer.map { $0.isRinging(at: now) ? 0 : $0.remaining(at: now) } ?? pot.seconds
    }

    private func block(_ pot: Hob.Pot, rank: Int, selected: Bool, now: Date) -> some View {
        let timer = pot.timer
        let ringing = timer?.isRinging(at: now) ?? false, paused = timer?.isPaused ?? false
        let counting = timer != nil && !paused
        let seconds = left(pot, now)
        let remaining = timer.map { 1 - $0.progress(at: now) } ?? 1
        let own = pot.step == session.step && !session.finished
        let height: CGFloat = rank == 0 ? 108 : rank == 1 ? 62 : 46
        let digits: CGFloat = rank == 0 ? 62 : rank == 1 ? 32 : 22
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pot.label).font(rank == 0 ? .heading : .label).lineLimit(1)
                if rank < 2 {
                    Text(ringing ? "Time’s up" : paused ? "Paused" : timer == nil ? "Ready" : own ? "Counting" : "Step \(pot.step + 1)")
                        .font(.caption).opacity(0.7)
                }
            }
            Spacer(minLength: 8)
            Text(DurationFinder.clock(seconds))
                .font(.geist(digits, .medium, relativeTo: .largeTitle)).monospacedDigit().tracking(-digits * 0.04)
                .lineLimit(1).minimumScaleFactor(0.5)
                .contentTransition(.numericText(countsDown: true)).animation(.standard, value: seconds)
        }
        .foregroundStyle(counting ? Color.paper : Color.ink)
        .padding(.leading, Metric.gutter + (selected ? 8 : 0)).padding(.trailing, Metric.gutter)
        .frame(height: height)
        .background {
            // Ink floods in from the leading edge when the timer starts.
            Rectangle().fill(Color.ink).scaleEffect(x: counting ? 1 : 0, anchor: .leading)
            Rectangle().strokeBorder(Color.ink, lineWidth: 1.5).opacity(counting ? 0 : 1)
        }
        .overlay(alignment: .leading) {
            // The one the band's gestures act on.
            Rectangle().fill(counting ? Color.paper : Color.ink).frame(width: 5).padding(.vertical, 10).padding(.leading, 9).opacity(selected ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            if counting, !ringing {
                Simmer(remaining: remaining, urgent: seconds <= 60, still: reduceMotion)
                    .frame(height: 10).padding(.horizontal, Metric.gutter).padding(.bottom, rank == 0 ? 10 : 3)
            }
        }
        .animation(.entrance, value: counting)
        .animation(.entrance, value: rank)
        .animation(.standard, value: selected)
        .contentShape(Rectangle())
        .onTapGesture { if let timer { actions.toggleTimer(timer.id) } else { actions.toggle(pot.slot) } }
        .onLongPressGesture(minimumDuration: 0.5) { if let timer { actions.cancelTimer(timer.id) } }
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            let t = value.translation
            if let timer, t.height < -30, abs(t.height) > abs(t.width) * 1.2 { actions.addMinute(timer.id) }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(pot.label), step \(pot.step + 1), \(ringing ? "time’s up" : paused ? "paused at \(DurationFinder.short(seconds))" : timer == nil ? "\(DurationFinder.short(seconds)), not started" : "\(DurationFinder.short(seconds)) left")")
    }
}

/// A line that simmers: a slow ripple while a timer counts, quicker and taller in its
/// last minute, as long as the share of time that is left. It is the one thing in Cook
/// that moves by itself, because it stands for something that is cooking by itself.
/// With Reduce Motion it is a straight line.
private struct Simmer: View {
    let remaining: Double
    let urgent: Bool
    let still: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
            Canvas { canvas, size in
                let phase = still ? 0 : context.date.timeIntervalSinceReferenceDate * (urgent ? 7 : 2.4)
                let height = still ? 0 : (urgent ? 3.2 : 1.6)
                let width = size.width * min(1, max(0, remaining)), middle = size.height / 2
                var path = Path()
                path.move(to: CGPoint(x: 0, y: middle))
                var x: CGFloat = 0
                while x <= width {
                    let y = middle + height * (sin(Double(x) / 9 + phase) * 0.7 + sin(Double(x) / 23 - phase * 0.6) * 0.3)
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += 3
                }
                canvas.stroke(path, with: .color(Color.paper), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The one timer that matters now, as a slab across the bottom: an outline while it
/// waits to be started, solid ink while it counts, with its time as large as the slab.
/// The others are a line of names and times above it; a tap on one brings it down.
struct TimerSlab: View {
    let session: CookSession
    let actions: CookActions

    var body: some View {
        let hob = Hob(session: session, actions: actions)
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let pots = hob.pots, now = context.date
            let main = pots.first(where: hob.selected) ?? pots.first { $0.timer?.isRinging(at: now) == true }
                ?? pots.filter { $0.timer != nil }.min { ($0.timer?.remaining(at: now) ?? .max) < ($1.timer?.remaining(at: now) ?? .max) } ?? pots.first
            VStack(alignment: .leading, spacing: 10) {
                let others = pots.filter { $0.id != main?.id }
                if !others.isEmpty {
                    HStack(spacing: 16) {
                        ForEach(others.prefix(3)) { pot in
                            Button { if let timer = pot.timer { actions.pick(timer.id) } else { actions.select(pot.slot) } } label: {
                                HStack(spacing: 6) {
                                    Text(pot.label).foregroundStyle(Color.muted)
                                    Text(DurationFinder.clock(pot.timer.map { $0.isRinging(at: now) ? 0 : $0.remaining(at: now) } ?? pot.seconds))
                                        .monospacedDigit().foregroundStyle(pot.timer == nil ? Color.muted : Color.ink)
                                }
                                .font(.label).frame(minHeight: 28).contentShape(Rectangle())
                            }
                            .buttonStyle(PressRow())
                        }
                        Spacer(minLength: 0)
                    }
                }
                if let main { slab(main, now: now) }
            }
            .padding(.horizontal, Metric.gutter).padding(.top, pots.isEmpty ? 0 : 6)
            .animation(.standard, value: pots.map(\.id))
            .animation(.standard, value: main?.id)
        }
    }

    private func slab(_ pot: Hob.Pot, now: Date) -> some View {
        let timer = pot.timer
        let ringing = timer?.isRinging(at: now) ?? false, paused = timer?.isPaused ?? false
        let counting = timer != nil && !paused
        let left = ringing ? 0 : timer?.remaining(at: now) ?? pot.seconds
        let remaining = timer.map { 1 - $0.progress(at: now) } ?? 1
        let own = pot.step == session.step && !session.finished
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pot.label).font(.heading).lineLimit(1)
                Text(ringing ? "Time’s up" : paused ? "Paused" : timer == nil ? "Ready" : own ? "Counting" : "Step \(pot.step + 1)")
                    .font(.caption).opacity(0.7)
            }
            Spacer(minLength: 8)
            Text(DurationFinder.clock(left))
                .font(.geist(58, .medium, relativeTo: .largeTitle)).monospacedDigit().tracking(-2.5)
                .lineLimit(1).minimumScaleFactor(0.5)
                .contentTransition(.numericText(countsDown: true)).animation(.standard, value: left)
        }
        .foregroundStyle(counting ? Color.paper : Color.ink)
        .padding(.horizontal, 18).frame(height: 104)
        .background {
            RoundedRectangle(cornerRadius: Metric.panel).fill(counting ? Color.ink : Color.clear)
            RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.ink, lineWidth: 1.5)
        }
        // The time left, as a line along the foot of the slab that shortens.
        .overlay(alignment: .bottomLeading) {
            GeometryReader { geo in
                Rectangle().fill(counting ? Color.paper : Color.ink).frame(width: max(0, (geo.size.width - 36) * remaining), height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.horizontal, 18).padding(.bottom, 12)
                    .animation(.linear(duration: 0.5), value: remaining)
            }
            .opacity(timer == nil || ringing ? 0 : 1)
        }
        .animation(.standard, value: counting)
        .contentShape(Rectangle())
        .onTapGesture { if let timer { actions.toggleTimer(timer.id) } else { actions.toggle(pot.slot) } }
        .onLongPressGesture(minimumDuration: 0.5) { if let timer { actions.cancelTimer(timer.id) } }
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            let t = value.translation
            if let timer, t.height < -30, abs(t.height) > abs(t.width) * 1.2 { actions.addMinute(timer.id) }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(pot.label), \(ringing ? "time’s up" : paused ? "paused at \(DurationFinder.short(left))" : timer == nil ? "\(DurationFinder.short(left)), not started" : "\(DurationFinder.short(left)) left")")
    }
}

/// What the band was just told to do, drawn as the same rhythm: a dot for a tap, a dash
/// for a long buzz, bars that climb or fall for a rise or a fade. It shows once and goes,
/// so the wrist and the screen say the same thing at the same moment.
struct BuzzMark: View {
    let pulse: CookStore.Pulse
    @State private var shown = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(pulse.pattern.prefix(12).enumerated()), id: \.offset) { _, buzz in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(Self.bars(buzz).enumerated()), id: \.offset) { _, bar in
                        Capsule().fill(Color.ink).frame(width: bar.width, height: bar.height)
                    }
                }
            }
        }
        .frame(height: 12, alignment: .bottom)
        .opacity(shown ? 1 : 0)
        .animation(.standard, value: shown)
        .task(id: pulse.id) {
            guard pulse.id > 0 else { return }
            shown = true
            try? await Task.sleep(for: .milliseconds(1400))
            shown = false
        }
        .accessibilityHidden(true)
    }

    private static func bars(_ buzz: BandBuzz) -> [CGSize] {
        let dot = CGSize(width: 4, height: 4)
        switch buzz {
        case .tap: return [dot]
        case .double: return [dot, dot]
        case .triple: return [dot, dot, dot]
        case .long: return [CGSize(width: 16, height: 4)]
        case .buzz: return [CGSize(width: 9, height: 4)]
        case .rise: return [CGSize(width: 3, height: 4), CGSize(width: 3, height: 8), CGSize(width: 3, height: 12)]
        case .fade: return [CGSize(width: 3, height: 12), CGSize(width: 3, height: 8), CGSize(width: 3, height: 4)]
        case .flutter: return Array(repeating: CGSize(width: 2, height: 6), count: 5)
        case .heartbeat: return [dot, dot, CGSize(width: 6, height: 0), dot, dot]
        }
    }
}

// MARK: Getting ready

/// Before step one: everything the recipe needs, in type large enough to read from across
/// the counter, to tick off as it is got out. The band's up and down move the mark along
/// the list and its timer gesture ticks the marked line; a tap ticks any line.
struct GatherPage: View {
    let session: CookSession
    let toggle: (Int) -> Void

    var body: some View {
        let items = session.recipe.ingredients
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Get everything out.").font(.geist(32, relativeTo: .title)).tracking(-0.5)
                    Text(["\(session.ready.count) of \(items.count) out", session.recipe.yield].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).monospacedDigit().foregroundStyle(Color.muted)
                        .contentTransition(.numericText()).padding(.top, 8).padding(.bottom, 18)
                    // What a later step needs ready, said now while there is time.
                    let first = StepDetails.headStarts(in: session.recipe.steps)
                    if !first.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Start first").font(.label)
                            ForEach(first, id: \.self) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Circle().fill(Color.ink).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 5 }
                                    Text(line).font(.geist(20, relativeTo: .title3)).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.bottom, 20)
                    }
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        Hairline(delay: 0.02 * Double(index))
                        row(index, item).id(index)
                    }
                    Hairline()
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 28).padding(.bottom, 16)
                .animation(.standard, value: session.ready)
                .animation(.standard, value: session.marked)
            }
            .onChange(of: session.marked) { _, marked in withAnimation(.standard) { proxy.scrollTo(marked, anchor: .center) } }
        }
        .sensoryFeedback(.selection, trigger: session.ready)
    }

    private func row(_ index: Int, _ item: String) -> some View {
        let line = Ingredients.split(item), out = session.ready.contains(index)
        return Button { toggle(index) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(line.amount ?? "").monospacedDigit().foregroundStyle(Color.muted)
                    .lineLimit(1).minimumScaleFactor(0.6).frame(width: 96, alignment: .trailing)
                    .contentTransition(.numericText())
                Text(line.name).strikethrough(out, color: Color.muted).foregroundStyle(out ? Color.muted : Color.ink)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                LucideIcon(.check, size: 16).opacity(out ? 1 : 0)
            }
            .font(.geist(20, relativeTo: .title3))
            .padding(.vertical, 14).contentShape(Rectangle())
            // The line the band's gestures are on.
            .overlay(alignment: .leading) {
                Capsule().fill(Color.ink).frame(width: 2.5).padding(.vertical, 10).offset(x: -Metric.gutter + 6)
                    .opacity(index == session.marked ? 1 : 0)
            }
        }
        .buttonStyle(PressRow())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item)
        .accessibilityAddTraits(out ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: A question

/// A question and its answer, in the page's place while they last: what was heard, a
/// hairline, and the answer in type large enough to read from the stove. A tap clears it.
struct AskCard: View {
    let phase: CookAssistant.Phase
    /// How loud the voice is while listening; the line under the words follows it.
    var level: Float = 0
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch phase {
                case .idle:
                    EmptyView()
                case .listening:
                    Text("Listening").font(.caption).foregroundStyle(Color.muted)
                    Text("Ask about this recipe.").font(.geist(32, relativeTo: .title)).tracking(-0.5)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.rule).frame(height: Metric.hairline)
                        Rectangle().fill(Color.ink).frame(height: 2).scaleEffect(x: CGFloat(min(1, max(0, level))), anchor: .leading)
                    }
                    .animation(.standard, value: level)
                    .accessibilityHidden(true)
                    Text("How much, how hot, how long, what can stand in for what. Let go when you’re done.")
                        .font(.bodyText).foregroundStyle(Color.muted)
                case .thinking(let question):
                    Text(question.isEmpty ? "Heard you." : question).font(.heading).foregroundStyle(Color.muted)
                    Hairline()
                    Text("Thinking").font(.caption).foregroundStyle(Color.muted)
                case .answered(let question, let answer):
                    Text(question).font(.label).foregroundStyle(Color.muted)
                    Hairline()
                    Text(answer).font(.geist(answer.count < 140 ? 28 : 22, relativeTo: .title)).tracking(-0.4).lineSpacing(3)
                    Text("Answered on this phone from the recipe. It can be wrong: trust the recipe and your thermometer.")
                        .font(.caption).foregroundStyle(Color.muted)
                case .failed(let message):
                    Text(message).font(.heading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metric.gutter).padding(.top, 28).padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper)
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Clears it.")
    }
}

// MARK: The wrist dial

/// The timer's dial, shown while the index finger is pinched and held: a ring of ticks
/// that turns one tick for each step of the wrist under a fixed mark, round the time the
/// timer will be set to. It moves only as the hand does.
struct TimerDial: View {
    /// What the dial is on, in steps from nothing: the ring has turned one tick for each.
    let steps: Int
    /// What it shows in the middle: "7:30", or "6" people.
    let value: String
    /// What is being set: "Simmer", the step when it has no name, or "Servings".
    let label: String
    /// What letting go does.
    let hint: String
    private static let size: CGFloat = 264

    /// Steps of the dial from nothing to a time, one tick each.
    static func steps(for seconds: Int) -> Int {
        seconds < 120 ? seconds / 10 : seconds < 900 ? 12 + (seconds - 120) / 30 : 38 + (seconds - 900) / 60
    }

    var body: some View {
        VStack(spacing: 22) {
            Text(label).font(.label)
            ZStack {
                Canvas { context, size in
                    let centre = CGPoint(x: size.width / 2, y: size.height / 2), radius = min(size.width, size.height) / 2
                    for tick in 0..<60 {
                        let angle = Double(tick) * .pi / 30, long = tick % 5 == 0
                        let inner = radius - (long ? 16 : 8)
                        var path = Path()
                        path.move(to: CGPoint(x: centre.x + sin(angle) * inner, y: centre.y - cos(angle) * inner))
                        path.addLine(to: CGPoint(x: centre.x + sin(angle) * radius, y: centre.y - cos(angle) * radius))
                        context.stroke(path, with: .color(long ? Color.ink : Color.faint), lineWidth: Metric.hairline)
                    }
                }
                .rotationEffect(.degrees(Double(steps) * 6))
                .animation(.standard, value: steps)
                Capsule().fill(Color.ink).frame(width: 2.5, height: 26).offset(y: -Self.size / 2 + 4)
                Text(value)
                    .font(.geist(64, .medium, relativeTo: .largeTitle)).monospacedDigit().tracking(-2)
                    .lineLimit(1).minimumScaleFactor(0.5).frame(width: Self.size - 70)
                    .contentTransition(.numericText(value: Double(steps)))
                    .animation(.standard, value: steps)
            }
            .frame(width: Self.size, height: Self.size)
            Text(hint).font(.caption).foregroundStyle(Color.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setting \(label) to \(value)")
    }
}

private struct Burner: View {
    let timer: CookTimer?
    let label: String
    let seconds: Int
    let step: Int
    let slot: Int
    /// Belongs to the step showing.
    let own: Bool
    let selected: Bool
    let now: Date
    let actions: CookActions
    static let size: CGFloat = 64

    private enum Phase { case waiting, counting, paused, ringing }

    private var phase: Phase {
        guard let timer else { return .waiting }
        return timer.isRinging(at: now) ? .ringing : timer.isPaused ? .paused : .counting
    }

    /// An empty burner; the last one counts the timers that didn't fit.
    static func empty(more: Int) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().strokeBorder(Color.rule, style: StrokeStyle(lineWidth: Metric.hairline, dash: [2, 4]))
                if more > 0 { Text("+\(more)").font(.label).monospacedDigit().foregroundStyle(Color.muted) }
            }
            .frame(width: size, height: size).padding(5)
            Text(" ").font(.caption)
            Text(" ").font(.caption)
        }
        .accessibilityHidden(more == 0)
        .accessibilityLabel("\(more) more timers")
    }

    var body: some View {
        let phase = phase
        let left = phase == .waiting ? seconds : phase == .ringing ? 0 : timer?.remaining(at: now) ?? seconds
        let progress = timer?.progress(at: now) ?? 0
        VStack(spacing: 6) {
            ZStack {
                Circle().strokeBorder(Color.rule, lineWidth: Metric.hairline)
                if phase == .ringing {
                    Circle().fill(Color.ink).transition(.opacity)
                } else if timer != nil {
                    Circle().trim(from: 0, to: min(1, max(0.01, progress)))
                        .stroke(own ? Color.ink : Color.muted, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(1)
                        .animation(.linear(duration: 0.5), value: progress)
                }
                Text(DurationFinder.clock(left))
                    .font(.geist(left >= 3600 ? 13 : 16, .medium, relativeTo: .body)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6).frame(width: Self.size - 12)
                    .foregroundStyle(phase == .ringing ? Color.paper : phase == .counting ? Color.ink : Color.muted)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.standard, value: left)
                if phase == .paused { LucideIcon(.pause, size: 10).foregroundStyle(Color.muted).offset(y: 17) }
            }
            .frame(width: Self.size, height: Self.size)
            .padding(5)
            .overlay { Circle().strokeBorder(Color.ink, lineWidth: 1.5).opacity(selected ? 1 : 0) }
            .animation(.standard, value: selected)
            .animation(.standard, value: phase)
            .geometryGroup()
            Text(label).font(.caption).foregroundStyle(own ? Color.ink : Color.muted).lineLimit(1)
            Text(own ? " " : "Step \(step + 1)").font(.caption).foregroundStyle(Color.muted).lineLimit(1)
        }
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        // A tap, not a button: a button would also fire at the end of a swipe.
        .onTapGesture { if let timer { actions.toggleTimer(timer.id) } else { actions.toggle(slot) } }
        .onLongPressGesture(minimumDuration: 0.5) { if let timer { actions.cancelTimer(timer.id) } }
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            let t = value.translation
            if let timer, t.height < -30, abs(t.height) > abs(t.width) * 1.2 { actions.addMinute(timer.id) }
        })
        .sensoryFeedback(.impact(weight: .light), trigger: phase)
        .sensoryFeedback(.increase, trigger: timer?.total ?? 0)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(label), step \(step + 1), \(spoken(phase, left))")
        .accessibilityHint(phase == .counting ? "Pauses it." : phase == .ringing ? "Stops it." : "Starts it.")
        .accessibilityAction(named: "Reset") { if let timer { actions.cancelTimer(timer.id) } }
        .accessibilityAction(named: "Add a minute") { if let timer { actions.addMinute(timer.id) } }
    }

    private func spoken(_ phase: Phase, _ left: Int) -> String {
        let time = DurationFinder.short(left)
        switch phase {
        case .waiting: return "\(time), not started"
        case .counting: return "\(time) left"
        case .paused: return "paused at \(time)"
        case .ringing: return "time’s up"
        }
    }
}

// MARK: Time's up

/// Across the top while a timer's time is up, whichever step is showing: what it was for
/// and which gestures stop it or give it a minute. Ink that draws in from the leading
/// edge and then holds still. Tapping it stops the timer.
struct TimeUpBand: View {
    let timer: CookTimer
    /// How many more are up as well.
    let others: Int
    /// How to tell it is done, when the step says: "until deeply browned".
    var cue: String? = nil
    let controls: CookControls
    let stop: () -> Void

    var body: some View {
        Button(action: stop) {
            HStack(spacing: 12) {
                LucideIcon(.bellRing, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Time’s up").font(.label)
                    Text("\(timer.label) · step \(timer.step + 1)" + (others > 0 ? " · and \(others) more" : ""))
                        .font(.caption).opacity(0.72).lineLimit(1)
                    if let cue { Text("Check: \(cue)").font(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                hint(.timer, "Stop")
                hint(.addMinute, "+1")
            }
            .foregroundStyle(Color.paper)
            .padding(.horizontal, Metric.inset).padding(.vertical, 10).frame(minHeight: 56)
            .background(Color.ink, in: RoundedRectangle(cornerRadius: Metric.panel))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
        .padding(.horizontal, Metric.gutter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time’s up for \(timer.label), step \(timer.step + 1)" + (cue.map { ". Check: \($0)" } ?? ""))
        .accessibilityHint("Stops the timer.")
    }

    @ViewBuilder private func hint(_ command: CookCommand, _ word: String) -> some View {
        if let trigger = controls.trigger(for: command) {
            HStack(spacing: 4) {
                TriggerGlyphs(steps: trigger.steps, size: 14)
                Text(word).font(.caption).lineLimit(1).fixedSize()
            }
        }
    }
}

/// The focus look's time's up: the page given over to it. What it was for, as large as
/// the page allows, what to check, and how to stop it. A tap stops the timer.
struct TimeUpPanel: View {
    let timer: CookTimer
    let others: Int
    var cue: String? = nil
    let controls: CookControls
    let stop: () -> Void

    var body: some View {
        Button(action: stop) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    LucideIcon(.bellRing, size: 18)
                    Text("Time’s up").font(.label)
                    Spacer()
                    Text("step \(timer.step + 1)" + (others > 0 ? " · and \(others) more" : "")).font(.caption).opacity(0.7)
                }
                Spacer(minLength: 12)
                Text(timer.label).font(.geist(68, .medium, relativeTo: .largeTitle)).tracking(-2.5).lineLimit(2).minimumScaleFactor(0.5)
                if let cue {
                    Text("Check: \(cue)").font(.geist(24, relativeTo: .title2)).lineSpacing(2).padding(.top, 10)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                HStack(spacing: 18) {
                    ForEach([(CookCommand.timer, "Stop"), (.addMinute, "+1")], id: \.1) { command, word in
                        if let trigger = controls.trigger(for: command) {
                            HStack(spacing: 5) { TriggerGlyphs(steps: trigger.steps, size: 16); Text(word).font(.label) }
                        }
                    }
                }
            }
            .foregroundStyle(Color.paper)
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.ink, in: RoundedRectangle(cornerRadius: Metric.panel))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
        .padding(.horizontal, Metric.gutter).padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time’s up for \(timer.label), step \(timer.step + 1)" + (cue.map { ". Check: \($0)" } ?? ""))
        .accessibilityHint("Stops the timer.")
    }
}

/// Uncovers a view from its leading edge.
private struct Wipe: ViewModifier {
    let amount: CGFloat
    func body(content: Content) -> some View {
        content.mask(Rectangle().scaleEffect(x: amount, anchor: .leading))
    }
}

extension AnyTransition {
    /// Draws in from the leading edge and fades out.
    static var wipe: AnyTransition {
        .asymmetric(insertion: .modifier(active: Wipe(amount: 0), identity: Wipe(amount: 1)), removal: .opacity)
    }
}
