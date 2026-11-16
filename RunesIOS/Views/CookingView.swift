import SwiftUI
import UIKit

// The cooking screen: one step at a time in large type, read from across the kitchen.
// Steps are pages; a swipe on the band (or the screen) turns them. Under the step sit
// its timers, all of them at once, as large numbers and nothing else: muted while
// waiting or paused, ink while counting, and ink behind the number when the time is up.
// On a step with more than one, the selected timer has an outline and its time is bold
// in the text; the band's swipe up and down moves the selection and its other gestures
// act on it. By touch, tap a number to start or pause it, hold it to reset it, and swipe
// up on it for another minute; none of that is spelled out on screen, since the band is
// the main way in and its gestures are listed along the bottom. Timers from other steps
// wait on a shelf above the page controls. The phone stays awake here.
//
// That is the Numbers look. The Hob look (CookingLayouts.swift) leaves the pages to the
// words and puts every timer, from any step, in a fixed row of rings under them.

struct CookActions {
    var perform: (CookCommand) -> Void = { _ in }
    /// The main button of one of the step's timers: start, pause, start again, stop ringing.
    var toggle: (_ slot: Int) -> Void = { _ in }
    var reset: (_ slot: Int) -> Void = { _ in }
    var addMinute: (String) -> Void = { _ in }
    /// The same for any timer by id, wherever its step is.
    var toggleTimer: (String) -> Void = { _ in }
    var cancelTimer: (String) -> Void = { _ in }
    var select: (_ slot: Int) -> Void = { _ in }
    var stopRinging: () -> Void = {}
    var addNote: (String) -> Void = { _ in }
    /// Clears the answer to a question.
    var dismissAnswer: () -> Void = {}
    /// Ticks an ingredient off, or back on.
    var tick: (Int) -> Void = { _ in }
    /// Selects a timer without starting or pausing it.
    var pick: (String) -> Void = { _ in }
    var go: (_ step: Int, _ slot: Int?) -> Void = { _, _ in }
    var stop: () -> Void = {}
    var done: () -> Void = {}
}

struct CookingScreen: View {
    @ObservedObject var store: CookStore
    @ObservedObject private var assistant: CookAssistant
    @State private var showIngredients = false
    @State private var appeared = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(store: CookStore) {
        self.store = store
        assistant = store.assistant
    }

    var body: some View {
        Group {
            if let session = store.session {
                CookingView(session: session, controls: store.controls, look: store.cookingLook, dial: store.dial, dialing: store.dialing,
                            asking: assistant.phase, voice: assistant.level, pulse: store.pulse, actions: CookActions(
                    perform: store.perform, toggle: { store.toggleTimer(slot: $0) }, reset: store.resetTimer, addMinute: store.addMinute,
                    toggleTimer: { store.toggleTimer($0) }, cancelTimer: store.cancelTimer,
                    select: store.select, stopRinging: store.stopRinging,
                    addNote: { store.addNote($0, to: session.recipe.id) },
                    dismissAnswer: assistant.dismiss, tick: store.toggle, pick: store.pick,
                    go: { store.go(to: $0, slot: $1) },
                    stop: { store.end(); dismiss() },
                    done: { store.end(); dismiss() }))
            } else {
                Text("Nothing is cooking.").font(.bodyText).foregroundStyle(Color.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .page()
        .navigationTitle(store.session?.recipe.title ?? "Cook").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.session != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { store.ask() } label: { LucideIcon(.mic, size: 20).frame(width: 36, height: 36) }
                        .accessibilityLabel(assistant.isListening ? "Done asking" : "Ask a question")
                }
            }
            if let session = store.session, !session.recipe.ingredients.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button { showIngredients = true } label: { LucideIcon(.listChecks, size: 20).frame(width: 36, height: 36) }
                        .accessibilityLabel("Ingredients")
                }
            }
        }
        .sheet(isPresented: $showIngredients) {
            if let session = store.session {
                IngredientsSheet(session: session, toggle: store.toggle).presentationDetents([.medium, .large])
            }
        }
        // A recipe is read, not touched: the screen must not dim or lock mid-step.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true; appeared = true; store.onScreen = scenePhase == .active }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; appeared = false; store.onScreen = false }
        .onChange(of: scenePhase) { _, phase in store.onScreen = appeared && phase == .active }
    }
}

/// Cooking as values and closures, so previews can show any state.
struct CookingView: View {
    let session: CookSession
    let controls: CookControls
    var look = CookingLook.hob
    /// Whether the wrist dial is on, and the time it shows while the pinch is held.
    var dial = false
    var dialing: Int? = nil
    /// A question being asked or answered, which takes the page's place meanwhile.
    var asking = CookAssistant.Phase.idle
    var voice: Float = 0
    var pulse = CookStore.Pulse()
    var actions = CookActions()
    @State private var drag: CGFloat = 0
    @State private var confirmStop = false
    @State private var noting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let slide = Animation.spring(duration: 0.45, bounce: 0.12)

    var body: some View {
        let now = Date()
        let rung = session.ringing(at: now)
        let ringing = !rung.isEmpty
        VStack(spacing: 0) {
            // The hob look draws the recipe as its line of time, so a long wait ahead is seen coming.
            // The rail look keeps its place down the side instead.
            Group {
                if look == .hob || look == .focus { TimeLine(recipe: session.recipe, step: session.gathering ? -1 : session.step, finished: session.finished) }
                else if look != .rail { StepProgress(count: session.count, step: session.gathering ? -1 : session.step, finished: session.finished, height: look == .poster ? 2 : 3) }
            }
            .padding(.horizontal, Metric.gutter).padding(.top, 4)
            if let first = rung.first, look != .focus {
                let durations = session.recipe.durations(step: first.step)
                let cue = durations.indices.contains(first.slot) ? StepDetails.cue(for: durations[first.slot], in: session.recipe.steps[first.step]) : nil
                TimeUpBand(timer: first, others: rung.count - 1, cue: cue, controls: controls, stop: actions.stopRinging)
                    .padding(.top, 10)
                    .transition(reduceMotion ? .opacity : .wipe)
            }
            HStack(spacing: 0) {
            if look == .rail, !session.finished {
                StepRail(session: session) { actions.go($0, nil) }.frame(width: 40).padding(.leading, 6).transition(.opacity)
            }
            ZStack {
                // The poster look sets the step's number behind its words, as large as the page.
                if look == .poster, !session.finished, !session.gathering {
                    Text(String(format: "%02d", session.step + 1))
                        .font(.geist(236, .medium, relativeTo: .largeTitle)).monospacedDigit().tracking(-14)
                        .foregroundStyle(Color.rule)
                        .contentTransition(.numericText(value: Double(session.step)))
                        .lineLimit(1).fixedSize()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .offset(x: 6, y: 44)
                        .allowsHitTesting(false).accessibilityHidden(true)
                        .transition(.opacity)
                }
                if session.finished { finished.transition(.opacity.combined(with: .scale(scale: 0.96))) }
                else if session.gathering { gather.transition(.opacity) }
                else if look == .focus { focus.transition(.opacity) }
                else { pages.transition(.opacity) }
                // In the focus look a timer whose time is up takes the page: ink from edge to
                // edge, seen from across the kitchen, and still until it is stopped.
                if look == .focus, let first = rung.first {
                    let durations = session.recipe.durations(step: first.step)
                    let cue = durations.indices.contains(first.slot) ? StepDetails.cue(for: durations[first.slot], in: session.recipe.steps[first.step]) : nil
                    TimeUpPanel(timer: first, others: rung.count - 1, cue: cue, controls: controls, stop: actions.stopRinging)
                        .transition(reduceMotion ? .opacity : .wipe)
                }
                if asking != .idle { AskCard(phase: asking, level: voice, dismiss: actions.dismissAnswer).transition(.opacity) }
                if let dialing {
                    if session.gathering {
                        TimerDial(steps: dialing * 5, value: "\(dialing)", label: "Servings", hint: "Let go and the amounts follow").transition(.opacity)
                    } else {
                        let target = session.selectedTimer.flatMap { $0.isLive ? $0 : nil }
                        let named = session.pickedTimer == nil && session.durations.indices.contains(session.slot) ? session.durations[session.slot].label : nil
                        TimerDial(steps: TimerDial.steps(for: dialing), value: DurationFinder.clock(dialing),
                                  label: target?.label ?? named ?? "Step \(session.step + 1)",
                                  hint: dialing == 0 ? (target == nil ? "Turn your wrist to set a time" : "Let go to clear it") : target == nil ? "Let go to start" : "Let go to set")
                            .transition(.opacity)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.standard, value: dialing != nil)
            .animation(.standard, value: asking)
            .animation(reduceMotion ? nil : .entrance, value: session.gathering)
            .animation(reduceMotion ? nil : .entrance, value: session.step)
            }
            if !session.finished { NextPeek(session: session) }
            switch look {
            case .hob: Hob(session: session, actions: actions)
            case .numbers: TimerShelf(session: session, actions: actions)
            case .rail, .poster: TimerBars(session: session, actions: actions)
            case .focus: TimerPile(session: session, actions: actions)
            }
            legend(ringing: ringing, now: now).padding(.top, 16).padding(.bottom, 10).padding(.horizontal, 12)
            if session.finished {
                Button(action: actions.done) { Text("Done") }.buttonStyle(CapsuleAction(filled: true))
                    .padding(.horizontal, Metric.gutter).padding(.top, 6)
            }
            Button(session.finished ? "Cook it again" : "Stop cooking") {
                if session.finished { actions.go(0, nil) } else { confirmStop = true }
            }
            .buttonStyle(.quiet).padding(.bottom, 4)
            // On the button, so the question appears where it was asked.
            .confirmationDialog("Stop cooking?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop cooking", role: .destructive, action: actions.stop)
            } message: { Text("Timers that are running are cancelled.") }
        }
        .overlay(alignment: .topTrailing) { BuzzMark(pulse: pulse).padding(.trailing, Metric.gutter).padding(.top, 26) }
        .animation(reduceMotion ? nil : .entrance, value: session.finished)
        .animation(.entrance, value: ringing)
        .sensoryFeedback(.selection, trigger: session.step)
        .sensoryFeedback(.selection, trigger: session.selection)
        .sensoryFeedback(.warning, trigger: ringing) { _, now in now }
    }

    // MARK: Steps

    /// The step and its neighbours side by side; the next one waits on the right.
    private var pages: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack {
                ForEach(max(0, session.step - 1)...min(session.count - 1, session.step + 1), id: \.self) { index in
                    StepPage(session: session, index: index, numbers: look == .numbers, actions: actions)
                        .frame(width: width)
                        .offset(x: CGFloat(index - session.step) * width + drag)
                        .allowsHitTesting(index == session.step)
                        .accessibilityHidden(index != session.step)
                }
            }
            .frame(width: width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : Self.slide, value: session.step)
            .simultaneousGesture(DragGesture(minimumDistance: 14)
                .onChanged { value in
                    let t = value.translation
                    guard abs(t.width) > abs(t.height) * 1.2, !reduceMotion else { return }
                    // Nothing waits before the first step; past the last is the end, and the page resists.
                    let blocked = t.width < 0 ? session.isLast : session.step == 0
                    drag = blocked ? t.width / 4 : t.width
                }
                .onEnded { value in
                    let dx = value.translation.width, sideways = abs(dx) > abs(value.translation.height) * 1.2
                    withAnimation(reduceMotion ? nil : Self.slide) {
                        drag = 0
                        if sideways, dx < -60 { actions.perform(.next) }
                        else if sideways, dx > 60, session.step > 0 { actions.perform(.previous) }
                    }
                })
        }
    }

    /// One sentence of the step, as large as it goes. Swipes turn it, as the band's do.
    private var focus: some View {
        FocusPage(session: session)
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 14).onEnded { value in
                let dx = value.translation.width
                guard abs(dx) > 60, abs(dx) > abs(value.translation.height) * 1.2 else { return }
                actions.perform(dx < 0 ? .next : .previous)
            })
    }

    /// The ingredients, before step one. A swipe on, like the band's, begins.
    private var gather: some View {
        GatherPage(session: session, toggle: actions.tick)
            .simultaneousGesture(DragGesture(minimumDistance: 14).onEnded { value in
                if value.translation.width < -60, abs(value.translation.width) > abs(value.translation.height) * 1.2 { actions.perform(.next) }
            })
    }

    private var finished: some View {
        // Centred when it fits; with a few notes under it, it scrolls.
        ViewThatFits(in: .vertical) {
            enjoy.frame(maxHeight: .infinity)
            ScrollView { enjoy }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Swipe back to the last step, as the band does.
        .simultaneousGesture(DragGesture(minimumDistance: 14).onEnded { value in
            if value.translation.width > 60, abs(value.translation.width) > abs(value.translation.height) * 1.2 { actions.perform(.previous) }
        })
        .sheet(isPresented: $noting) { NoteSheet(save: actions.addNote) }
    }

    private var enjoy: some View {
        VStack(spacing: 16) {
            FinishedMark().frame(width: 120, height: 120).padding(.bottom, 8)
            Text("Enjoy.").font(.display).tracking(-0.6)
            Text("\(session.recipe.title) · \(max(1, Int(Date().timeIntervalSince(session.started) / 60))) min")
                .font(.bodyText).foregroundStyle(Color.muted).multilineTextAlignment(.center)
            // Storage and reheating matter now, with the pan still on the table, and so
            // does what to change next time.
            NotesBlock(notes: session.recipe.notes ?? []) { noting = true }.padding(.top, 16)
        }
        .padding(.horizontal, Metric.gutter).padding(.vertical, 24)
    }

    // MARK: Controls

    private struct Hint: Identifiable {
        let id: String
        /// Each command's gesture or combo; two when a hint covers a pair, such as either timer.
        let triggers: [CommandTrigger]
        let word: String
    }

    /// Which band gesture does what right now, so nobody has to remember.
    private func hints(ringing: Bool, now: Date) -> [Hint] {
        var result: [Hint] = []
        func add(_ commands: [CookCommand], _ word: String) {
            let triggers = commands.compactMap(controls.trigger)
            if !triggers.isEmpty { result.append(Hint(id: commands[0].rawValue, triggers: triggers, word: word)) }
        }
        guard !session.finished else { add([.previous], "Back"); add([.ask], "Ask"); return result }
        let dialShown = dial && !controls.reserved.contains(.holdIndex)
        if session.gathering {
            add([.next], "Start"); add([.timer], "Tick"); add([.timerUp, .timerDown], "Move")
            if dialShown, session.recipe.servings != nil { result.append(Hint(id: "dial", triggers: [.gesture(.holdIndex)], word: "Servings")) }
            add([.ask], "Ask")
            return result
        }
        add([.next], session.isLast ? "Finish" : "Next")
        let selected = session.selectedTimer
        if ringing { add([.timer], "Stop") }
        else if session.slots > 0 || session.pickedTimer != nil { add([.timer], selected?.isRunning(at: now) == true ? "Pause" : "Start") }
        // The dial does what another minute does and more, so one of the two is named:
        // the minute while something rings, when it is the quick answer.
        if ringing || !dialShown, ringing || !session.live(at: now).isEmpty || session.durations.isEmpty { add([.addMinute], "+1") }
        if selected != nil { add([.reset], "Reset") }
        if session.slots + session.others.count > (session.selection == nil ? 0 : 1) { add([.timerUp, .timerDown], "Timer") }
        // Pinch and hold, then turn the wrist: shown only while no command has that hold.
        if dialShown, !ringing { result.append(Hint(id: "dial", triggers: [.gesture(.holdIndex)], word: "Dial")) }
        add([.ask], asking == .listening ? "Listening" : "Ask")
        return result
    }

    private func legend(ringing: Bool, now: Date) -> some View {
        let items = hints(ringing: ringing, now: now)
        return HStack(spacing: 13) {
            ForEach(items) { hint in
                HStack(spacing: 5) {
                    ForEach(hint.triggers, id: \.self) { TriggerGlyphs(steps: $0.steps) }
                    Text(hint.word).font(.caption).lineLimit(1).fixedSize().padding(.leading, 1)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(hint.triggers.map(\.name).joined(separator: " or ")): \(hint.word)")
            }
        }
        .foregroundStyle(Color.muted)
        .frame(minHeight: 18)
        .animation(.standard, value: items.map { $0.id + $0.word })

    }
}

// MARK: One step

/// A step: its words, which scroll if they must, over its timers, which stay put.
private struct StepPage: View {
    let session: CookSession
    let index: Int
    /// Whether the step's timers are drawn on the page, as large numbers.
    let numbers: Bool
    let actions: CookActions

    private var text: String { session.recipe.steps[index] }
    private var current: Bool { index == session.step }
    /// The time the controls act on; other pages show their first. None while a timer
    /// from another step is selected.
    private var selected: Int { current ? (session.pickedTimer == nil ? session.slot : -1) : 0 }

    /// Short steps are set large; long ones step down so they still fit a screen.
    private var size: CGFloat {
        switch text.count {
        case ..<70: 32
        case ..<140: 28
        case ..<240: 24
        case ..<380: 21
        default: 19
        }
    }

    /// Space between letters at this size.
    private var tracking: CGFloat { size >= 28 ? -0.5 : -0.2 }

    /// One layer of the step's words. The page draws the step several times over, each
    /// laid out identically: once with every time left out, and for each time once plain
    /// and once bold. Moving the selection then only fades one time's plain layer out and
    /// its bold one in, where it stands; no other word is redrawn or moves.
    ///
    /// Bold letters are wider, which would push every word after them along and
    /// sometimes onto another line. So the bold words are set a hair tighter, by exactly
    /// the difference: they take the room the plain ones did, and every layer breaks its
    /// lines in the same places.
    private func layer(_ durations: [StepDuration], time: Int?, bold: Bool) -> AttributedString {
        var result = AttributedString(text)
        result.tracking = tracking
        // A layer for one time shows nothing else.
        if time != nil { result.foregroundColor = .clear }
        // How hot: a hairline under it, so it is found again at a glance. An underline
        // takes no room, so the layers still break their lines alike.
        if time == nil {
            for heat in StepDetails.heat(in: text) {
                if let range = Range(heat, in: result) { result[range].underlineStyle = Text.LineStyle(pattern: .solid, color: Color.muted) }
            }
        }
        for (slot, duration) in durations.enumerated() {
            guard let range = Range(NSRange(location: duration.location, length: duration.length), in: result) else { continue }
            guard slot == time else {
                if time == nil { result[range].foregroundColor = .clear }
                continue
            }
            result[range].foregroundColor = Color.ink
            guard bold else { continue }
            result[range].font = .geist(size, .semibold, relativeTo: .title)
            // Word by word, since a time can be broken across two lines and each line
            // must come out the width it was.
            for word in Self.words(of: duration.phrase) {
                guard let part = Range(NSRange(location: duration.location + word.location, length: word.length), in: result) else { continue }
                let letters = (duration.phrase as NSString).substring(with: word)
                result[part].tracking = tracking - Self.widening(letters, size: size) / CGFloat(max(1, letters.count))
            }
        }
        return result
    }

    private func words(_ content: AttributedString) -> some View {
        Text(content)
            .font(.geist(size, relativeTo: .title))
            .lineSpacing(size >= 28 ? 1 : 3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A phrase's words, each with the spaces after it, as UTF-16 ranges.
    private static func words(of phrase: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0, offset = 0, inSpaces = false
        for character in phrase {
            let space = character == " "
            if inSpaces, !space { ranges.append(NSRange(location: start, length: offset - start)); start = offset }
            inSpaces = space
            offset += character.utf16.count
        }
        if offset > start { ranges.append(NSRange(location: start, length: offset - start)) }
        return ranges
    }

    /// How much wider some words are in bold than in the regular weight, at the size the
    /// text is really drawn (it grows with Dynamic Type).
    private static func widening(_ phrase: String, size: CGFloat) -> CGFloat {
        let scaled = UIFontMetrics(forTextStyle: .title1).scaledValue(for: size)
        guard let regular = UIFont(name: "Geist-Regular", size: scaled), let bold = UIFont(name: "Geist-SemiBold", size: scaled) else { return 0 }
        let text = phrase as NSString
        return text.size(withAttributes: [.font: bold]).width - text.size(withAttributes: [.font: regular]).width
    }

    var body: some View {
        let durations = session.recipe.durations(step: index)
        VStack(spacing: 0) {
            // Drawn directly whenever the words fit, which is nearly always. A scroll view
            // is a different kind of layer and trails a beat behind the timers when the
            // page slides, so it is only used for a step too long for the screen.
            // The cues said again beside the amounts are the first thing to go when room is short.
            ViewThatFits(in: .vertical) {
                reading(durations, cues: true).frame(maxHeight: .infinity, alignment: .top)
                reading(durations, cues: false).frame(maxHeight: .infinity, alignment: .top)
                ScrollView { reading(durations, cues: false) }.scrollBounceBehavior(.basedOnSize)
            }
            // The minute a step without a time was given counts as one of its times.
            let own = session.timer(step: index, slot: durations.count).flatMap { $0.isLive ? $0 : nil }
            let times = durations + (own.map { [StepDuration(seconds: $0.total, location: 0, length: 0, phrase: "", label: nil)] } ?? [])
            if numbers, !times.isEmpty {
                TimerStack(session: session, step: index, durations: times, selected: selected, actions: actions)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The step's number and its words.
    private func reading(_ durations: [StepDuration], cues wanted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Step \(index + 1) of \(session.count)")
                .font(.caption).monospacedDigit().foregroundStyle(Color.muted)
            // The selected timer's time is bold, so the outlined number below is
            // known by its words; the others read as plain text.
            ZStack(alignment: .topLeading) {
                words(layer(durations, time: nil, bold: false))
                    .accessibilityLabel(text)
                ForEach(durations.indices, id: \.self) { slot in
                    words(layer(durations, time: slot, bold: false)).opacity(slot == selected ? 0 : 1)
                    words(layer(durations, time: slot, bold: true)).opacity(slot == selected ? 1 : 0)
                }
                .accessibilityHidden(true)
            }
            .animation(.easeInOut(duration: 0.22), value: selected)
            // Without this the fade's timing would also be applied to where the words
            // are, and they would trail the page when it slides to another step.
            .geometryGroup()
            // What the step uses and doesn't say how much of: no scrolling back to the list.
            // In a long step, set small, how to tell it is done is said again beside them.
            let uses = session.recipe.uses(step: index).map(\.text)
            let cues = wanted && text.count >= 140 ? StepDetails.cues(in: text).map(\.text) : []
            if !uses.isEmpty || !cues.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Rectangle().fill(Color.rule).frame(width: Metric.hairline)
                    VStack(alignment: .leading, spacing: 6) {
                        if !uses.isEmpty { Text(uses.joined(separator: "  ·  ")).foregroundStyle(Color.muted) }
                        ForEach(cues, id: \.self) { Text($0) }
                    }
                    .font(.geist(17, relativeTo: .body)).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel((uses.isEmpty ? "" : "Uses \(uses.joined(separator: ", ")). ") + cues.joined(separator: ". "))
            }
        }
        .padding(.horizontal, Metric.gutter).padding(.top, 28).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Timers

/// A step's timers, all showing, one above the other: numbers and nothing else. With
/// more than one, the selected timer is outlined.
private struct TimerStack: View {
    let session: CookSession
    let step: Int
    let durations: [StepDuration]
    let selected: Int
    let actions: CookActions

    private var many: Bool { durations.count > 1 }
    /// One number is set as large as the page allows; more share the space.
    private var size: CGFloat {
        switch durations.count {
        case ...1: 76
        case 2: 64
        case 3: 50
        default: 42
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(durations.indices, id: \.self) { slot in
                TimerNumber(duration: durations[slot], timer: session.timer(step: step, slot: slot), slot: slot, size: size,
                            outlined: many && slot == selected,
                            position: many ? "Timer \(slot + 1) of \(durations.count)" : "Timer", actions: actions)
            }
        }
        .padding(.horizontal, Metric.gutter).padding(.vertical, 12)
    }
}

/// One timer: its time, large. Muted while it waits or is paused, ink while it counts,
/// and on ink once its time is up, until it is stopped. Tap to start or pause, hold to
/// reset, swipe up for another minute.
private struct TimerNumber: View {
    let duration: StepDuration
    let timer: CookTimer?
    let slot: Int
    let size: CGFloat
    /// The selected one of several.
    let outlined: Bool
    /// "Timer 2 of 3", for VoiceOver.
    let position: String
    let actions: CookActions

    private enum Phase { case waiting, counting, paused, ringing, done }

    private func phase(at now: Date) -> Phase {
        guard let timer else { return .waiting }
        if timer.isRinging(at: now) { return .ringing }
        if timer.isPaused { return .paused }
        return timer.isRunning(at: now) ? .counting : .done
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            number(at: context.date)
        }
    }

    private func number(at now: Date) -> some View {
        let phase = phase(at: now)
        let seconds: Int = switch phase {
        case .waiting, .done: duration.seconds
        case .ringing: 0
        case .counting, .paused: timer?.remaining(at: now) ?? duration.seconds
        }
        let color: Color = phase == .ringing ? .paper : phase == .counting ? .ink : .muted
        let label = "\(position), \(duration.label ?? "step"), \(spoken(phase, seconds))"
        let hint = phase == .counting ? "Pauses it." : phase == .ringing ? "Stops it." : "Starts it."
        let total = timer?.total ?? 0
        return digits(seconds, color: color, ringing: phase == .ringing)
            .contentShape(Rectangle())
            // A tap, not a button: a button would also fire at the end of a swipe.
            .onTapGesture { actions.toggle(slot) }
            .onLongPressGesture(minimumDuration: 0.5) { actions.reset(slot) }
            .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded(swiped))
            .sensoryFeedback(.impact(weight: .light), trigger: phase)
            .sensoryFeedback(.increase, trigger: total)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(outlined ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel(label)
            .accessibilityHint(hint)
            .accessibilityAction(named: "Reset") { actions.reset(slot) }
            .accessibilityAction(named: "Add a minute") { addMinute() }
    }

    /// The time itself, on ink when it is up, inside the outline when it is selected.
    private func digits(_ seconds: Int, color: Color, ringing: Bool) -> some View {
        Text(DurationFinder.clock(seconds))
            .font(.geist(size, .medium, relativeTo: .largeTitle)).monospacedDigit().tracking(-size * 0.033)
            .lineLimit(1).minimumScaleFactor(0.5)
            .contentTransition(.numericText(countsDown: true))
            .animation(.standard, value: seconds)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity).frame(height: size * 1.28)
            // Selected and up at once: the ink draws in a little, so the outline still shows round it.
            .background { if ringing { Ringing().padding(outlined ? 4 : 0).transition(.opacity) } }
            .overlay {
                RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.ink, lineWidth: 1.5)
                    .opacity(outlined ? 1 : 0)
            }
            .animation(.standard, value: outlined)
            .animation(.standard, value: ringing)
            // The number changes every second with its own short animation. Kept in its
            // own geometry, that animation stays on the digits; otherwise it also eases
            // the number's position and a counting timer trails behind the page as it slides.
            .geometryGroup()
    }

    /// A swipe up on the number gives it another minute.
    private func swiped(_ value: DragGesture.Value) {
        let t = value.translation
        if t.height < -36, abs(t.height) > abs(t.width) * 1.2 { addMinute() }
    }

    private func addMinute() {
        if let timer { actions.addMinute(timer.id) }
    }

    private func spoken(_ phase: Phase, _ seconds: Int) -> String {
        let time = DurationFinder.short(seconds)
        switch phase {
        case .waiting: return "\(time), not started"
        case .counting: return "\(time) left"
        case .paused: return "paused at \(time)"
        case .ringing: return "time’s up"
        case .done: return "done"
        }
    }
}

/// A hairline circle that fills clockwise as the time runs out.
struct TimerRing: View {
    let progress: Double
    var lineWidth: CGFloat = 1.5
    var body: some View {
        ZStack {
            Circle().stroke(Color.rule, lineWidth: Metric.hairline)
            Circle().trim(from: 0, to: min(1, max(0.01, progress)))
                .stroke(Color.ink, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: progress)
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

/// Ink behind a number whose time is up, still until it is stopped.
private struct Ringing: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Metric.panel).fill(Color.ink).accessibilityHidden(true)
    }
}

// MARK: Timers from other steps

/// Timers started on other steps, the one with least time left first: the step and the
/// number. Tapping one goes to it; one whose time is up stops.
private struct TimerShelf: View {
    let session: CookSession
    let actions: CookActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let now = context.date
            let timers = session.live(at: now).filter { session.finished || $0.step != session.step }
            VStack(spacing: 0) {
                ForEach(timers) { timer in
                    let ringing = timer.isRinging(at: now)
                    Rule(inset: 0)
                    Button { if ringing { actions.stopRinging() } else { actions.go(timer.step, timer.slot) } } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                if ringing { Circle().fill(Color.ink).frame(width: 8, height: 8) }
                                else if timer.isPaused { LucideIcon(.pause, size: 14).foregroundStyle(Color.muted) }
                                else { TimerRing(progress: timer.progress(at: now), lineWidth: 1.25) }
                            }
                            .frame(width: 18, height: 18)
                            Text("Step \(timer.step + 1)").font(.caption).foregroundStyle(Color.muted)
                            Spacer(minLength: 8)
                            if ringing { LucideIcon(.bellRing, size: 16) }
                            Text(DurationFinder.clock(ringing ? 0 : timer.remaining(at: now)))
                                .font(.geist(22, .medium, relativeTo: .title3)).monospacedDigit()
                                .foregroundStyle(timer.isPaused ? Color.muted : Color.ink)
                                .contentTransition(.numericText(countsDown: true))
                        }
                        .padding(.horizontal, Metric.gutter).frame(minHeight: Metric.row).contentShape(Rectangle())
                        // The one the band's gestures act on, when it was selected from another step.
                        .overlay {
                            RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.ink, lineWidth: 1.5)
                                .padding(.horizontal, Metric.gutter - Metric.inset).padding(.vertical, 3)
                                .opacity(timer.id == session.pickedTimer?.id ? 1 : 0)
                        }
                    }
                    .buttonStyle(PressRow())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityLabel(ringing ? "Step \(timer.step + 1): time’s up for \(timer.label). Stop the timer."
                                        : "Step \(timer.step + 1), \(timer.label), \(DurationFinder.short(timer.remaining(at: now))) \(timer.isPaused ? "left, paused" : "left")")
                }
                Rule(inset: 0)
            }
            .animation(.standard, value: timers.map(\.id))
            .animation(.standard, value: session.pickedTimer?.id)
        }
    }
}

/// One line of what comes next, so the pan for it can be found before the page turns.
private struct NextPeek: View {
    let session: CookSession
    var body: some View {
        let last = session.isLast && !session.gathering
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(last ? "Last step" : session.gathering ? "First" : "Next").font(.geist(12, .medium, relativeTo: .caption)).foregroundStyle(last ? Color.muted : Color.ink)
            if !last {
                Text(session.recipe.steps[session.gathering ? 0 : session.step + 1]).font(.caption).foregroundStyle(Color.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.gutter).padding(.vertical, 10)
        .animation(.standard, value: session.step)
        .animation(.standard, value: session.gathering)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Ingredients

/// The ingredients as a list to tick off while getting things out.
struct IngredientsSheet: View {
    let session: CookSession
    let toggle: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Heading("\(session.ready.count) of \(session.recipe.ingredients.count) ready")
                    ForEach(Array(session.recipe.ingredients.enumerated()), id: \.offset) { index, item in
                        let ready = session.ready.contains(index)
                        if index > 0 { Hairline(delay: 0.03 * Double(index)) }
                        Button { toggle(index) } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle().strokeBorder(ready ? Color.ink : Color.faint, lineWidth: Metric.hairline)
                                        .background(Circle().fill(ready ? Color.ink : Color.clear))
                                    LucideIcon(.check, size: 12, lineWidth: 2).foregroundStyle(Color.paper)
                                        .opacity(ready ? 1 : 0).scaleEffect(ready ? 1 : 0.5)
                                }
                                .frame(width: 22, height: 22)
                                Text(item).font(.bodyText).strikethrough(ready, color: Color.muted)
                                    .foregroundStyle(ready ? Color.muted : Color.ink)
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 13).contentShape(Rectangle())
                        }
                        .buttonStyle(PressRow())
                        .accessibilityAddTraits(ready ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 32)
                .animation(.standard, value: session.ready)
            }
            .sensoryFeedback(.selection, trigger: session.ready)
            .page()
            .navigationTitle("Ingredients").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
        }
        .tint(Color.ink)
    }
}

#if DEBUG
extension PreviewFixtures {
    /// The starter recipe three steps in, with its simmer running and an earlier timer rung.
    /// A step with two times, the second selected: one counting, one paused or its time up.
    @MainActor static func cookTwo(ringing: Bool = false) -> CookStore {
        let now = Date()
        let steak = RecipeParser.parse("""
        Pan steak
        Ingredients
        2 sirloin steaks
        1 knob butter
        Steps
        1. Sear the steaks for 3 minutes without moving them, then turn, add the butter and cook for 2 minutes more.
        2. Rest on a warm plate for 5 minutes.
        """)
        var session = CookSession(recipe: steak, at: now.addingTimeInterval(-300))
        session.start(step: 0, slot: 0, at: now.addingTimeInterval(ringing ? -200 : -64))
        session.select(slot: 1)
        if !ringing { session.toggle(step: 0, slot: 1, at: now.addingTimeInterval(-40)); session.toggle(step: 0, slot: 1, at: now.addingTimeInterval(-9)) }
        else { session.select(slot: 0) }
        return CookStore(preview: [steak, .starter], session: session)
    }

    /// The salmon pasta being cooked: timers from two steps, one of them picked from the band.
    @MainActor static func cookSalmon(_ name: String) -> CookStore {
        let now = Date()
        var session = CookSession(recipe: .salmonPasta, at: now.addingTimeInterval(-1200))
        session.start(step: 0, slot: 0, at: now.addingTimeInterval(name == "cooking-salmon-ringing" ? -500 : -130))
        session.go(to: 1)
        session.start(step: 1, slot: 0, at: now.addingTimeInterval(-65))
        session.go(to: 2)
        session.start(step: 2, slot: 0, at: now.addingTimeInterval(-40))
        if name == "cooking-picked" { session.apply(.timerDown, at: now); session.apply(.timerDown, at: now) }
        if name == "cooking-gather" || name == "cooking-servings" {
            session = CookSession(recipe: .salmonPasta, at: now, gather: true)
            for _ in 0..<3 { session.apply(.timer, at: now) }
            session.apply(.timerDown, at: now)
        }
        if name == "cooking-salmon-done" { session.go(to: session.count - 1); session.apply(.next, at: now) }
        let look: CookingLook = name.hasSuffix("numbers") ? .numbers : name.hasSuffix("rail") ? .rail : name.hasSuffix("poster") ? .poster
            : name.hasSuffix("focus") ? .focus : .hob
        if name.hasPrefix("demo") { session = CookSession(recipe: .salmonPasta, at: now, gather: true) }
        return CookStore(preview: Recipe.samples, session: session, cookingLook: look,
                         dialing: name == "cooking-dial" ? 450 : name == "cooking-servings" ? 6 : nil,
                         asking: name == "cooking-ask" ? .listening : name == "cooking-answer"
                            ? .answered(question: "How much garlic goes in now?", answer: "Three cloves, minced, with the peas and the spinach. The other two go in the sauce at the next step.") : .idle)
    }

    /// The same walkthrough for every look, so recordings of them can be set side by
    /// side: get ready, set servings, three steps with their timers, the dial, a
    /// question, and a timer whose time is up.
    @MainActor static func walkthrough(_ store: CookStore) async {
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        await wait(2)
        for _ in 0..<3 { store.perform(.timer); await wait(0.5) }
        store.demoDial(true); await wait(0.6)
        for _ in 0..<2 { store.turn(15); await wait(0.5) }
        await wait(0.5); store.demoDial(false); await wait(1.2)
        store.perform(.next); await wait(1.6)
        // In the focus look a step is several sentences; page through them to the next step.
        func nextStep() async {
            let from = store.session?.step
            repeat { store.perform(.next); await wait(1.1) } while store.session?.step == from && store.session?.finished == false
        }
        store.perform(.timer); await wait(1.2)
        await nextStep()
        store.perform(.timer); await wait(1.2)
        await nextStep()
        store.perform(.timer); await wait(1)
        store.perform(.timerDown); await wait(0.9)
        store.perform(.timerDown); await wait(0.9)
        store.perform(.timerUp); store.perform(.timerUp); await wait(0.8)
        store.demoDial(true); await wait(0.6)
        for _ in 0..<12 { store.turn(4); await wait(0.12) }
        for _ in 0..<4 { store.turn(-4); await wait(0.18) }
        await wait(0.6); store.demoDial(false); await wait(1.4)
        store.assistant.show(.listening, level: 0.2); await wait(0.5)
        for level in [0.7, 0.4, 0.9, 0.5, 0.2] as [Float] { store.assistant.show(.listening, level: level); await wait(0.25) }
        store.assistant.show(.thinking(question: "How much garlic goes in now?")); await wait(0.9)
        store.assistant.show(.answered(question: "How much garlic goes in now?", answer: "Three cloves, minced, with the peas and the spinach. The other two go in the sauce at the next step."))
        await wait(3.4)
        store.assistant.show(.idle); await wait(1)
        store.demoExpire(); await wait(3)
        store.stopRinging(); await wait(1.2)
        store.perform(.next); await wait(2)
    }

    /// Recipes with nothing cooking, some cooked before.
    @MainActor static func cookShelf() -> CookStore {
        var salmon = Recipe.salmonPasta, starter = Recipe.starter
        salmon.cooked = 3; salmon.lastCooked = Date().addingTimeInterval(-86_400)
        starter.cooked = 1
        return CookStore(preview: [salmon, starter] + cook().recipes.dropFirst(), session: nil)
    }

    @MainActor static func cook(step: Int = 2, ringing: Bool = false, finished: Bool = false,
                                listLook: CookListLook = .contents, cookingLook: CookingLook = .hob) -> CookStore {
        let now = Date()
        var session = CookSession(recipe: .starter, at: now.addingTimeInterval(-900))
        session.go(to: 1)
        session.start(step: 1, slot: 0, at: now.addingTimeInterval(ringing ? -125 : -20))
        session.go(to: 2)
        session.start(step: 2, slot: 0, at: now.addingTimeInterval(-272))
        session.toggle(ingredient: 0); session.toggle(ingredient: 1); session.toggle(ingredient: 4)
        session.go(to: step)
        if finished { session.go(to: session.count - 1); session.apply(.next, at: now) }
        let carbonara = RecipeParser.parse("""
        Carbonara
        Serves 2
        Ingredients
        200 g spaghetti
        100 g guanciale
        2 eggs
        50 g pecorino
        Steps
        1. Boil the pasta for 10 minutes.
        2. Fry the guanciale for 5 minutes until crisp.
        3. Toss everything together off the heat.
        """)
        return CookStore(preview: [.starter, carbonara], session: session, listLook: listLook, cookingLook: cookingLook)
    }
}

#Preview("Cooking · two timers") { NavigationStack { CookingScreen(store: PreviewFixtures.cookTwo()) } }
#Preview("Cooking") { NavigationStack { CookingScreen(store: PreviewFixtures.cook()) } }
#Preview("Cooking · ringing") { NavigationStack { CookingScreen(store: PreviewFixtures.cook(step: 1, ringing: true)) } }
#Preview("Cooking · done") { NavigationStack { CookingScreen(store: PreviewFixtures.cook(finished: true)) } }
#Preview("Cook") { NavigationStack { CookScreen(store: PreviewFixtures.cook(), path: .constant([])) } }
#endif
