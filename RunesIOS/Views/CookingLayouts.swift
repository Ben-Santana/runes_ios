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
    private struct Pot: Identifiable {
        var id: String
        var timer: CookTimer?
        var label: String
        var seconds: Int
        var step: Int
        var slot: Int
    }

    /// Timers in the order they were started, so one stays on its burner as pages turn,
    /// then the times this step has that aren't going.
    private var pots: [Pot] {
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

    private func selected(_ pot: Pot) -> Bool {
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
