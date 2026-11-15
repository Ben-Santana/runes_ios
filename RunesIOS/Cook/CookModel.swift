import Foundation

// A recipe being cooked: which step is showing, which of the step's timers is selected,
// the timers started so far, and the ingredients ticked off. Pure value types, so they
// are tested without a band or a clock (Tests/CookTests.swift); every method that
// depends on the time takes it.

/// What the band (or a button) can do while cooking.
enum CookCommand: String, Codable, CaseIterable, Identifiable, Sendable {
    case next, previous, timer, addMinute, reset, timerDown, timerUp

    var id: String { rawValue }
    var title: String {
        switch self {
        case .next: "Next step"
        case .previous: "Previous step"
        case .timer: "Start or pause the timer"
        case .addMinute: "Add a minute"
        case .reset: "Reset the timer"
        case .timerDown: "Next timer"
        case .timerUp: "Previous timer"
        }
    }
    var detail: String {
        switch self {
        case .next: "After the last step, finishes the recipe."
        case .previous: "Goes back a step."
        case .timer: "Starts the selected timer, pauses it, and starts it again. When a timer rings, stops it."
        case .addMinute: "Gives the selected timer another minute, also after it rang. On a step with no time, starts a one-minute timer."
        case .reset: "Puts the selected timer back to its full time, not running."
        case .timerDown: "Selects the next timer: this step’s times, then any other timer still going."
        case .timerUp: "Selects the timer before."
        }
    }
}

/// Which gesture or combo does what while cooking.
struct CookControls: Codable, Hashable, Sendable {
    var triggers: [CookCommand: CommandTrigger]

    /// Side swipes turn the page and up and down move between the timers, as on
    /// screen. The index finger runs the selected timer. Double taps, because one pinch
    /// happens by itself when hands are busy with a knife or a pan.
    static let standard = CookControls(gestures: standardGestures)
    private static let standardGestures: [CookCommand: GestureKind] = [
        .next: .swipeRight, .previous: .swipeLeft, .timer: .doubleTapIndex, .addMinute: .doubleTapMiddle,
        .reset: .holdMiddle, .timerDown: .swipeDown, .timerUp: .swipeUp,
    ]
    /// Gestures a command may use on its own. Releases only exist inside combos.
    static let choices = CommandTrigger.singleChoices
    private static let mappingPrefix = "cook:"

    init(triggers: [CookCommand: CommandTrigger]) { self.triggers = triggers }
    init(gestures: [CookCommand: GestureKind]) { triggers = gestures.mapValues(CommandTrigger.gesture) }

    func trigger(for command: CookCommand) -> CommandTrigger? { triggers[command] }
    /// The command's gesture, when it is a single one.
    func gesture(for command: CookCommand) -> GestureKind? { triggers[command]?.gesture }
    func command(for gesture: GestureKind) -> CookCommand? {
        CookCommand.allCases.first { triggers[$0]?.gesture == gesture }
    }
    /// Assigns a trigger; a command that already had it takes this command's old one.
    mutating func setTrigger(_ trigger: CommandTrigger?, for command: CookCommand) { triggers.assign(trigger, to: command) }
    mutating func set(_ gesture: GestureKind?, for command: CookCommand) { setTrigger(gesture.map(CommandTrigger.gesture), for: command) }

    /// The gestures cooking takes; mappings that use one are off until it ends. A double
    /// tap arrives after the tap that began it and a hold ends with a release, so those
    /// are taken with them.
    var reserved: Set<GestureKind> { triggers.reserved }
    /// The triggers as mappings, for the engine that decides which one was made.
    var mappings: [Mapping] { triggers.mappings(prefix: Self.mappingPrefix) }
    /// Whether cooking needs the band's motion streams for a rotation, movement or air step.
    var usesMotion: Bool { triggers.usesMotion }
    func command(forMapping id: String) -> CookCommand? { triggers.command(forMapping: id, prefix: Self.mappingPrefix) }

    private enum Keys: String, CodingKey { case gestures, triggers, version }
    /// 2 added reset and moving between a step's timers. 3 lets a command take a combo.
    private static let version = 3

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let saved = try c.decodeIfPresent([String: CommandTrigger].self, forKey: .triggers) {
            triggers = Dictionary(saved: saved)
            return
        }
        // Saved before a command could take a combo: one gesture each.
        triggers = try c.decode([CookCommand: GestureKind].self, forKey: .gestures).mapValues(CommandTrigger.gesture)
        // Settings saved before a command existed get its usual gesture, if it is free.
        // After that, "None" is a choice and stays.
        if ((try? c.decode(Int.self, forKey: .version)) ?? 1) < 2 {
            for command in [CookCommand.reset, .timerDown, .timerUp] where triggers[command] == nil {
                if let usual = Self.standardGestures[command], self.command(for: usual) == nil { triggers[command] = .gesture(usual) }
            }
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(triggers.saved, forKey: .triggers)
        try c.encode(Self.version, forKey: .version)
    }
}

/// A timer started from a step. It runs from the moment it is started to `end`, unless
/// it is paused; after `end` it rings until it is stopped.
struct CookTimer: Codable, Hashable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    /// The step it belongs to and which of the step's times it is.
    var step: Int
    var slot: Int
    /// "Simmer", or "Step 3" when the step doesn't say.
    var label: String
    var total: Int
    var end: Date
    /// Set when a ringing timer is stopped.
    var stopped = false
    /// Seconds left while paused; nil while it runs. `end` means nothing while paused.
    var paused: Int? = nil

    var isPaused: Bool { paused != nil }
    func remaining(at now: Date) -> Int { paused ?? max(0, Int(end.timeIntervalSince(now).rounded(.up))) }
    func isRunning(at now: Date) -> Bool { paused == nil && end > now }
    func isRinging(at now: Date) -> Bool { paused == nil && end <= now && !stopped }
    /// Running, paused or ringing: anything still worth watching.
    var isLive: Bool { !stopped }
    /// 0 just started → 1 finished.
    func progress(at now: Date) -> Double {
        guard total > 0 else { return 1 }
        let left = paused.map(Double.init) ?? end.timeIntervalSince(now)
        return min(1, max(0, 1 - left / Double(total)))
    }
}

/// What a command did, for the sound and the Lock Screen.
enum CookEvent: Equatable, Sendable {
    case step(Int)
    case finished
    case started(CookTimer)
    case paused(CookTimer)
    case resumed(CookTimer)
    case stopped
    case extended(CookTimer)
    case reset
    /// Another timer was selected; carries its position among the step's times and the
    /// other timers still going.
    case selected(Int)
}

struct CookSession: Codable, Equatable, Sendable {
    var recipe: Recipe
    private(set) var step = 0
    private(set) var timers: [CookTimer] = []
    /// Ingredients ticked off, by position.
    private(set) var ready: Set<Int> = []
    private(set) var finished = false
    var started: Date
    /// Which of the current step's times is selected; nil is the first.
    private var chosen: Int? = nil
    /// A timer from another step, selected instead; it takes the commands until the step changes.
    private var picked: String? = nil

    init(recipe: Recipe, at now: Date = Date()) { self.recipe = recipe; started = now }

    var count: Int { recipe.steps.count }
    var text: String { recipe.steps.indices.contains(step) ? recipe.steps[step] : "" }
    var isLast: Bool { step >= count - 1 }
    var durations: [StepDuration] { recipe.durations(step: step) }

    /// The timer a step without a time of its own was given, while it is going.
    var ownTimer: CookTimer? { timer(step: step, slot: durations.count).flatMap { $0.isLive ? $0 : nil } }
    /// The times this step has: the ones it mentions, and the one it was given.
    var slots: Int { durations.count + (ownTimer == nil ? 0 : 1) }
    /// The one of the current step's times that commands act on. Timers are started,
    /// paused, reset and given a minute one at a time; this says which.
    var slot: Int { slots == 0 ? 0 : min(max(chosen ?? 0, 0), slots - 1) }
    /// The other step's timer that was selected, while it is still going.
    var pickedTimer: CookTimer? { picked.flatMap { id in timers.first { $0.id == id && $0.isLive && $0.step != step } } }
    /// The timer commands act on, once it has been started.
    var selectedTimer: CookTimer? { pickedTimer ?? (slots == 0 ? nil : timer(step: step, slot: slot)) }
    /// Timers still going that belong to other steps, in recipe order. With the step's own
    /// times they are what up and down move between.
    var others: [CookTimer] { timers.filter { $0.isLive && $0.step != step }.sorted { ($0.step, $0.slot) < ($1.step, $1.slot) } }
    /// Where the selection is among the step's times and the others.
    var selection: Int { pickedTimer.flatMap { timer in others.firstIndex { $0.id == timer.id } }.map { slots + $0 } ?? slot }

    func timer(step: Int, slot: Int) -> CookTimer? { timers.last { $0.step == step && $0.slot == slot } }
    func running(at now: Date) -> [CookTimer] { timers.filter { $0.isRunning(at: now) }.sorted { $0.end < $1.end } }
    func ringing(at now: Date) -> [CookTimer] { timers.filter { $0.isRinging(at: now) } }
    /// Timers still counting, paused or ringing, the one with least time left first:
    /// the ones worth showing everywhere.
    func live(at now: Date) -> [CookTimer] {
        timers.filter(\.isLive).sorted { ($0.remaining(at: now), $0.step, $0.slot) < ($1.remaining(at: now), $1.step, $1.slot) }
    }
    /// The next moment something rings, for a wake-up.
    func nextEnd(after now: Date) -> Date? { timers.filter { $0.isRunning(at: now) }.map(\.end).min() }

    @discardableResult
    mutating func apply(_ command: CookCommand, at now: Date = Date()) -> CookEvent? {
        switch command {
        case .next:
            guard !finished else { return nil }
            if isLast { finished = true; return .finished }
            step += 1; chosen = nil; picked = nil
            return .step(step)
        case .previous:
            if finished { finished = false; return .step(step) }
            guard step > 0 else { return nil }
            step -= 1; chosen = nil; picked = nil
            return .step(step)
        case .timer:
            // A ringing timer is the urgent thing, whichever step is showing.
            if !ringing(at: now).isEmpty { stopRinging(at: now); return .stopped }
            guard !finished else { return nil }
            if let other = pickedTimer { return toggle(step: other.step, slot: other.slot, at: now) }
            guard slots > 0 else { return nil }
            return toggle(step: step, slot: slot, at: now)
        case .addMinute:
            if let index = extendable(at: now) { return addMinute(to: timers[index].id, at: now).map(CookEvent.extended) }
            // A step that mentions no time gets a minute of its own to count.
            guard !finished, durations.isEmpty else { return nil }
            timers.removeAll { $0.step == step && $0.slot == 0 }
            let timer = CookTimer(step: step, slot: 0, label: "Step \(step + 1)", total: 60, end: now.addingTimeInterval(60))
            timers.append(timer)
            return .started(timer)
        case .reset:
            guard !finished, let timer = selectedTimer else { return nil }
            cancel(timer.id)
            return .reset
        case .timerDown, .timerUp:
            let others = others, count = slots + others.count
            guard !finished, count > 1 else { return nil }
            // Round and round, so two timers swap with either swipe.
            let next = (selection + (command == .timerDown ? 1 : -1) + count) % count
            if next < slots { chosen = next; picked = nil } else { picked = others[next - slots].id }
            return .selected(next)
        }
    }

    /// The timer another minute goes to: one that is ringing, else the selected one if
    /// it is counting or paused, else, on a step with times of its own, the one with
    /// least time left.
    private func extendable(at now: Date) -> Int? {
        if let ringing = timers.lastIndex(where: { $0.isRinging(at: now) }) { return ringing }
        if let selected = selectedTimer, selected.isLive, !finished { return timers.firstIndex { $0.id == selected.id } }
        guard finished || !durations.isEmpty else { return nil }
        return live(at: now).first.flatMap { soonest in timers.firstIndex { $0.id == soonest.id } }
    }

    /// Another minute for one timer. A timer that already rang starts again with a minute.
    @discardableResult
    mutating func addMinute(to id: String, at now: Date = Date()) -> CookTimer? {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return nil }
        if let left = timers[index].paused {
            timers[index].paused = left + 60
            timers[index].total += 60
        } else {
            let rang = !timers[index].isRunning(at: now)
            timers[index].end = max(timers[index].end, now).addingTimeInterval(60)
            timers[index].total = rang ? 60 : timers[index].total + 60
            timers[index].stopped = false
        }
        return timers[index]
    }

    /// The main button for one of a step's times: start it, pause it, start it again, or
    /// stop it ringing. One that rang and was stopped starts afresh.
    @discardableResult
    mutating func toggle(step: Int, slot: Int, at now: Date = Date()) -> CookEvent? {
        guard let existing = timer(step: step, slot: slot), let index = timers.firstIndex(where: { $0.id == existing.id }),
              existing.isLive else {
            return start(step: step, slot: slot, at: now).map(CookEvent.started)
        }
        if existing.isRinging(at: now) {
            timers[index].stopped = true
            return .stopped
        }
        if let left = existing.paused {
            timers[index].paused = nil
            timers[index].end = now.addingTimeInterval(Double(left))
            return .resumed(timers[index])
        }
        timers[index].paused = existing.remaining(at: now)
        return .paused(timers[index])
    }

    /// Starts one of a step's times from the top. Starting it again replaces the earlier one.
    @discardableResult
    mutating func start(step: Int, slot: Int, at now: Date = Date()) -> CookTimer? {
        let durations = recipe.durations(step: step)
        guard durations.indices.contains(slot) else { return nil }
        timers.removeAll { $0.step == step && $0.slot == slot }
        let duration = durations[slot]
        let timer = CookTimer(step: step, slot: slot, label: duration.label ?? "Step \(step + 1)", total: duration.seconds,
                              end: now.addingTimeInterval(Double(duration.seconds)))
        timers.append(timer)
        return timer
    }

    /// Puts a time back as it was before it was started.
    mutating func reset(step: Int, slot: Int) { timers.removeAll { $0.step == step && $0.slot == slot } }

    mutating func cancel(_ id: String) { timers.removeAll { $0.id == id } }

    mutating func stopRinging(at now: Date = Date()) {
        for index in timers.indices where timers[index].isRinging(at: now) { timers[index].stopped = true }
    }

    /// Selects one of the current step's times.
    mutating func select(slot: Int) {
        guard (0..<slots).contains(slot) else { return }
        chosen = slot; picked = nil
    }

    /// Selects a timer wherever it belongs.
    mutating func pick(_ id: String) {
        guard let timer = timers.first(where: { $0.id == id && $0.isLive }) else { return }
        if timer.step == step { chosen = timer.slot; picked = nil } else { picked = id }
    }

    /// Shows a step, with one of its times selected.
    mutating func go(to index: Int, slot: Int? = nil) {
        guard recipe.steps.indices.contains(index) else { return }
        step = index; finished = false; chosen = slot; picked = nil
    }

    mutating func toggle(ingredient index: Int) {
        guard recipe.ingredients.indices.contains(index) else { return }
        if ready.contains(index) { ready.remove(index) } else { ready.insert(index) }
    }

    /// "Step 3 of 8".
    var position: String { finished ? "Done" : "Step \(step + 1) of \(count)" }
}
