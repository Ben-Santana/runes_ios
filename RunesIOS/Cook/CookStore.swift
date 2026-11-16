import Foundation
import UIKit
import UserNotifications

/// The sound for something that happened while cooking; the session turns it into a voice.
enum CookCue: Sendable {
    case step, start, pause, extend, stop, reset, select, ring, soon, finish, nothing
    /// The next sentence of the same step.
    case beat
    /// An ingredient ticked off, or back on.
    case tick, untick
    /// The dial taken hold of, and each step of it, counted from nothing.
    case dialOpen, dial(Int)
    /// Servings changed.
    case serve
    /// A question: listening, answered, not answered.
    case listen, answer, sorry

    /// The voice and pitch it is played with, from the sounds the rest of Runes uses.
    /// Turning the dial climbs a five-note scale, so a longer time is heard as a higher note.
    var sound: (voice: SoundVoice, pitch: Double) {
        switch self {
        case .step: return (.wood, 392)
        case .beat: return (.tick, 523)
        case .start: return (.pip, 523)
        case .pause: return (.soft, 330)
        case .extend: return (.pip, 659)
        case .stop: return (.soft, 392)
        case .reset: return (.droplet, 330)
        case .select: return (.tick, 440)
        case .ring: return (.bell, 784)
        case .soon: return (.soft, 523)
        case .finish: return (.resolve, 392)
        case .nothing: return (.tap, 196)
        case .tick: return (.pop, 523)
        case .untick: return (.tap, 330)
        case .dialOpen: return (.lift, 392)
        case .dial(let steps):
            let note = max(0, steps) % 15
            return (.pluck, 262 * pow(2, Double([0, 2, 4, 7, 9][note % 5]) / 12 + Double(note / 5)))
        case .serve: return (.marimba, 392)
        case .listen: return (.blip, 659)
        case .answer: return (.glass, 784)
        case .sorry: return (.soft, 262)
        }
    }
}

/// How the recipe list and the cooking screen are drawn. Temporary: each is being tried
/// on the phone, and the ones not chosen go.
enum CookListLook: String, Codable, CaseIterable, Sendable {
    case contents, ledger
    var title: String { self == .contents ? "Contents" : "Ledger" }
}
enum CookingLook: String, Codable, CaseIterable, Sendable {
    case stations, focus, hob, rail, poster, numbers
    var title: String {
        switch self { case .stations: "Stations"; case .focus: "Focus"; case .hob: "Hob"; case .rail: "Rail"; case .poster: "Poster"; case .numbers: "Numbers" }
    }
    /// Whether a step is read a sentence at a time.
    var paces: Bool { self == .focus || self == .stations }
}

/// What reaches the wrist while cooking.
enum CookBuzz: String, Codable, CaseIterable, Sendable {
    case off, timers, all
    var title: String {
        switch self { case .off: "Off"; case .timers: "Timers"; case .all: "Everything" }
    }
}

/// Saved recipes and the one being cooked. While a recipe is being cooked its gestures
/// are taken here and mappings that use them are off. Timers are absolute end times, so
/// they survive the phone locking and the app being closed: each one also schedules a
/// notification, which rings whether or not Runes is running.
@MainActor
final class CookStore: ObservableObject {
    static let shared = CookStore()
    private static let key = "runes.cook.v1"
    /// The ids of the premade recipes this phone has been given.
    private static let samplesKey = "runes.cook.samples"
    private nonisolated static let notificationPrefix = "cook.timer."

    private struct Saved: Codable {
        var recipes: [Recipe]
        var controls: CookControls?
        var sounds: Bool?
        var session: CookSession?
        // Kept as text, so a look that is later removed doesn't stop the recipes loading.
        var buzz: String?
        var dial: Bool?
        var spoken: Bool?
        var reads: Bool?
        var listLook: String?
        var cookingLook: String?
    }

    @Published private(set) var recipes: [Recipe]
    @Published private(set) var controls: CookControls { didSet { configureDecider(); motionChanged() } }
    /// Sounds for steps and timers while Runes is open. A finished timer always notifies.
    @Published private(set) var sounds: Bool
    /// A finished timer buzzes the band until it is stopped; "everything" also taps it for each command.
    @Published private(set) var buzz: CookBuzz
    /// The wrist dial: pinch the index finger and hold, turn the wrist to set the selected
    /// timer, let go. It keeps the band's motion sensors on while a recipe is being cooked.
    @Published private(set) var dial: Bool
    /// What the band was just told to do, so the screen can show the same rhythm.
    struct Pulse: Equatable {
        var id = 0
        var pattern: [BandBuzz] = []
    }
    @Published private(set) var pulse = Pulse()
    private var pulsing: Task<Void, Never>?

    /// Buzzes the wrist, one after another, and shows the pattern.
    private func wrist(_ pattern: [BandBuzz]) {
        guard !pattern.isEmpty else { return }
        pulse = Pulse(id: pulse.id + 1, pattern: pattern)
        guard !previewOnly else { return }
        pulsing?.cancel()
        pulsing = Task { [weak self] in
            for buzz in pattern {
                guard !Task.isCancelled else { return }
                self?.onBuzz?(buzz)
                try? await Task.sleep(for: .milliseconds(buzz == .long ? 650 : 420))
            }
        }
    }

    /// Hears a question about the recipe and answers it.
    let assistant: CookAssistant
    /// Whether its answers are said aloud as well as shown.
    @Published private(set) var spoken: Bool
    /// Whether each step is said aloud as it arrives.
    @Published private(set) var reads: Bool
    /// What the dial shows while the pinch is held: seconds on a timer, or people to cook
    /// for while the ingredients are being got out.
    @Published private(set) var dialing: Int?
    private var servingTurn = 0.0
    /// Told to start and stop reading the wrist's turn.
    var onDial: ((Bool) -> Void)?
    private var dialTime = DialTime()
    /// Off while a command has the index hold to itself.
    private var dialUsable: Bool { dial && !controls.reserved.contains(.holdIndex) }
    @Published private(set) var listLook: CookListLook
    @Published private(set) var cookingLook: CookingLook
    @Published private(set) var session: CookSession? { didSet { if (oldValue == nil) != (session == nil) { motionChanged() } } }

    /// Told whether cooking needs the band's motion streams: only while a recipe is being
    /// cooked and one of its combos has a rotation, movement or air step.
    var onMotionDemand: ((Bool) -> Void)? { didSet { motionOn = motionWanted; onMotionDemand?(motionOn) } }
    private var motionOn = false
    private var motionWanted: Bool { session != nil && (controls.usesMotion || dialUsable) }
    private func motionChanged() {
        guard !previewOnly, motionWanted != motionOn else { return }
        motionOn = motionWanted
        onMotionDemand?(motionOn)
    }

    /// Told which gestures cooking holds (none when nothing is being cooked).
    var onReserve: ((Set<GestureKind>) -> Void)? { didSet { onReserve?(reservedNow) } }
    /// Shows the recipe on the Live Activity (nil restores band status), with an optional alert.
    var onActivity: ((CookActivityState?, LiveAlert?) -> Void)? { didSet { if session != nil { show() } } }
    var onCue: ((CookCue) -> Void)?
    var onBuzz: ((BandBuzz) -> Void)?
    /// Told while a timer is counting or ringing. The session then keeps the shared audio
    /// engine going, which keeps Runes awake behind a locked phone to ring it.
    var onLive: ((Bool) -> Void)? { didSet { live = wantsLive; onLive?(live) } }
    private var live = false
    private var wantsLive: Bool { ringTask != nil || session?.timers.contains { $0.isRunning(at: Date()) } ?? false }
    private func liveChanged() {
        guard !previewOnly, wantsLive != live else { return }
        live = wantsLive
        onLive?(live)
    }
    /// True while the cooking screen is in front; it shows a ringing timer itself.
    var onScreen = false

    private var previewOnly = false
    /// Decides which command a band gesture completes, combos included.
    private let decider = TriggerDecider()
    private var wake: Timer?
    private var ringTask: Task<Void, Never>?
    private var scheduled: Set<String> = []
    private var askedToNotify = false

    private var reservedNow: Set<GestureKind> {
        guard session != nil, !yielded else { return [] }
        return controls.reserved.union(SwitchControls.reserved(switchMapping)).union(dialUsable ? [.holdIndex, .releaseIndex] : [])
    }
    /// The switch-controls combo, while this is the app the band switches to and from and
    /// its controls are selected. Set by `ControlSwitch`.
    var switchMapping: Mapping? {
        didSet { if switchMapping != oldValue { configureDecider(); if !previewOnly { onReserve?(reservedNow) } } }
    }
    /// True while the regular mappings have the band though a recipe is being cooked. Timers keep running.
    var yielded = false { didSet { if yielded != oldValue, !previewOnly { onReserve?(reservedNow) } } }
    private func configureDecider() {
        if !previewOnly { decider.configure(SwitchControls.adding(switchMapping, to: controls.mappings)) }
    }

    private init() {
        var saved = Saved(recipes: Recipe.samples)
        var added: [Recipe] = []
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = decoded
            // A premade recipe added since reaches someone who already has recipes, once;
            // deleting it keeps it gone. The first one was there from the start.
            let given = Set(UserDefaults.standard.stringArray(forKey: Self.samplesKey) ?? [Recipe.starter.id])
            added = Recipe.samples.filter { sample in !given.contains(sample.id) && !saved.recipes.contains { $0.id == sample.id } }
            saved.recipes.insert(contentsOf: added, at: 0)
        }
        UserDefaults.standard.set(Recipe.samples.map(\.id), forKey: Self.samplesKey)
        recipes = saved.recipes
        controls = saved.controls ?? .standard
        sounds = saved.sounds ?? true
        buzz = saved.buzz.flatMap(CookBuzz.init) ?? .timers
        dial = saved.dial ?? true
        spoken = saved.spoken ?? true
        reads = saved.reads ?? false
        assistant = CookAssistant()
        listLook = saved.listLook.flatMap(CookListLook.init) ?? .contents
        cookingLook = saved.cookingLook.flatMap(CookingLook.init) ?? .stations
        session = saved.session
        session?.paced = cookingLook.paces
        scheduled = Set((saved.session?.timers ?? []).map { Self.notificationPrefix + $0.id })
        decider.onFire = { [weak self] id in
            guard let self else { return }
            if id == SwitchControls.mappingID { if self.session != nil { ControlSwitch.shared.toggle() }; return }
            guard let command = self.controls.command(forMapping: id) else { return }
            self.perform(command)
        }
        decider.configure(controls.mappings)
        assistant.speaks = spoken
        assistant.recipe = { [weak self] in self?.session }
        assistant.onResult = { [weak self] answered in
            guard let self, self.sounds else { return }
            self.onCue?(answered ? .answer : .sorry)
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.woke() }
        }
        arm()
        if !added.isEmpty { persist() }
    }

    #if DEBUG
    /// Fixed state for screenshots and previews; never saved.
    init(preview recipes: [Recipe], session: CookSession? = nil, listLook: CookListLook = .contents, cookingLook: CookingLook = .hob, dialing: Int? = nil,
         asking: CookAssistant.Phase = .idle) {
        self.recipes = recipes; controls = .standard; sounds = true; buzz = .timers; dial = true; self.dialing = dialing
        spoken = true; reads = false; assistant = CookAssistant(preview: asking)
        self.listLook = listLook; self.cookingLook = cookingLook; self.session = session; previewOnly = true
        self.session?.paced = cookingLook.paces
    }
    #endif

    // MARK: Recipes

    func recipe(_ id: String) -> Recipe? { recipes.first { $0.id == id } }

    /// Adds a recipe, or replaces the one with the same id. New recipes go first.
    func save(_ recipe: Recipe) {
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) { recipes[index] = recipe } else { recipes.insert(recipe, at: 0) }
        persist()
    }

    /// Keeps a note with a recipe, such as what to change next time. It joins the one being cooked too.
    func addNote(_ text: String, to id: String) {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty, let index = recipes.firstIndex(where: { $0.id == id }) else { return }
        recipes[index].notes = (recipes[index].notes ?? []) + [note]
        if session?.recipe.id == id { session?.recipe.notes = recipes[index].notes }
        persist()
    }

    func delete(_ id: String) {
        if session?.recipe.id == id { end() }
        recipes.removeAll { $0.id == id }
        persist()
    }

    func setTrigger(_ trigger: CommandTrigger?, for command: CookCommand) {
        controls.setTrigger(trigger, for: command)
        persist()
        if !previewOnly { onReserve?(reservedNow) }
    }
    func setSounds(_ on: Bool) { sounds = on; persist() }
    func setBuzz(_ value: CookBuzz) { buzz = value; persist() }
    func setSpoken(_ on: Bool) { spoken = on; assistant.speaks = on; persist() }
    func setReads(_ on: Bool) { reads = on; persist() }
    func setDial(_ on: Bool) {
        dial = on; persist(); motionChanged()
        if !previewOnly { onReserve?(reservedNow) }
    }
    func setListLook(_ look: CookListLook) { listLook = look; persist() }
    func setCookingLook(_ look: CookingLook) { cookingLook = look; session?.paced = look.paces; persist() }

    /// What a link gave: the recipe its page publishes for search engines, or, when it
    /// publishes none, the page as the text a reader sees.
    enum Fetched { case recipe(Recipe), page(String) }

    /// Fetches a page and reads its recipe, or its text.
    func fetch(_ url: URL) async throws -> Fetched {
        var request = URLRequest(url: url, timeoutInterval: 20)
        // Recipe sites turn away clients that don't look like a browser.
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let data: Data
        do { (data, _) = try await URLSession(configuration: configuration).data(for: request) }
        catch { throw CookError.unreachable }
        guard data.count < 8_000_000, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw CookError.noRecipe }
        if let recipe = RecipeParser.recipe(fromHTML: html, source: url.absoluteString) { return .recipe(recipe) }
        let text = RecipeImporter.text(fromHTML: html)
        // A page that turned the request away, or one drawn entirely by scripts.
        guard text.count > 300 else { throw CookError.noRecipe }
        return .page(text)
    }

    // MARK: Cooking

    /// Starts cooking, with the ingredients already got out ticked.
    func start(_ recipe: Recipe, ready: Set<Int> = []) {
        guard recipe.isUsable else { return }
        if session != nil { end() }
        // With things still to get out, cooking opens on the ingredients.
        var fresh = CookSession(recipe: recipe, gather: ready.count < recipe.ingredients.count)
        for index in ready { fresh.toggle(ingredient: index) }
        fresh.paced = cookingLook.paces
        session = fresh
        changed()
    }

    /// Stops cooking: timers are cancelled and the gestures go back to mappings.
    func end() {
        guard let finished = session else { return }
        session = nil
        if finished.finished, let index = recipes.firstIndex(where: { $0.id == finished.recipe.id }) {
            recipes[index].cooked += 1; recipes[index].lastCooked = Date()
        }
        ringTask?.cancel(); ringTask = nil
        if dialing != nil { dialing = nil; onDial?(false) }
        assistant.dismiss()
        warned = []; called = []; pendingStart = nil
        persist(); arm(); syncNotifications(); liveChanged()
        guard !previewOnly else { return }
        onReserve?(reservedNow)
        onActivity?(nil, nil)
    }

    func perform(_ command: CookCommand) {
        guard var current = session else { return }
        if command == .ask { ask(); return }
        // Anything else means the cook has moved on from the answer.
        if assistant.isBusy { assistant.dismiss() }
        let target = current.selectedTimer
        let event = current.apply(command)
        session = current
        react(to: event, about: target)
    }

    /// Starts listening for a question, or ends one being asked.
    func ask() {
        guard session != nil, !previewOnly else { return }
        if assistant.isListening { assistant.finish() } else {
            assistant.listen()
            if sounds { onCue?(.listen) }
            if buzz != .off { wrist([.tap]) }
        }
    }

    /// Takes a band gesture that is one of cooking's while a recipe is being cooked.
    /// Returns false to let mappings handle it.
    func consume(_ gesture: BandGesture) -> Bool {
        guard session != nil, let kind = GestureKind(gesture), reservedNow.contains(kind) else { return false }
        if dialUsable, kind == .holdIndex { beginDial(); return true }
        if dialUsable, kind == .releaseIndex { endDial(); return true }
        decider.receive(kind)
        // Asked with a hold, the question lasts as long as the hold does.
        if assistant.isListening, let held = controls.trigger(for: .ask)?.steps.last?.gesture,
           (held == .holdIndex && kind == .releaseIndex) || (held == .holdMiddle && kind == .releaseMiddle) { assistant.finish() }
        return true
    }

    /// Takes a rotation or movement from the band's motion while a recipe is being cooked
    /// and one of its combos uses it. Returns false to let mappings have it.
    func consume(_ step: ComboStep) -> Bool {
        guard session != nil, reservedNow.contains(step.gesture) else { return false }
        decider.receive(step)
        return true
    }

    // MARK: The wrist dial

    private func beginDial() {
        guard let session, !session.finished, dialing == nil else { return }
        // Getting ready, the dial is how many to cook for.
        if session.gathering { guard session.recipe.servings != nil else { return } }
        dialTime = DialTime(); servingTurn = 0
        dialing = session.gathering ? session.recipe.servings : session.dialSeconds(at: Date())
        onDial?(true)
        if sounds { onCue?(.dialOpen) }
        if buzz != .off { onBuzz?(.tap) }
    }

    /// Degrees the wrist turned while the pinch is held. Each step of the dial ticks.
    func turn(_ degrees: Double) {
        guard let showing = dialing, degrees.isFinite else { return }
        var next = showing
        if session?.gathering == true {
            // A person for every fifteen degrees: coarse, since there are few to choose from.
            servingTurn += degrees
            let people = Int((servingTurn / 15).rounded(.towardZero))
            servingTurn -= Double(people) * 15
            next = min(99, max(1, showing + people))
        } else {
            next = dialTime.turn(degrees, from: showing)
        }
        guard next != showing else { return }
        dialing = next
        if sounds { onCue?(session?.gathering == true ? .dial(next * 2) : .dial(DialTime.steps(for: next))) }
        // A tap on the wrist for each whole minute passed, like the detents of a real dial.
        if buzz != .off, session?.gathering != true, next % 60 == 0 { onBuzz?(.tap) }
    }

    private func endDial() {
        guard let seconds = dialing else { return }
        dialing = nil
        onDial?(false)
        guard var current = session else { return }
        if current.gathering {
            let before = current.recipe.servings
            current.serve(seconds); session = current
            if current.recipe.servings != before, sounds { onCue?(.serve) }
            changed()
            return
        }
        let target = current.selectedTimer
        guard let event = current.dial(to: seconds) else {
            // Held and let go without a turn: the time left is counted out on the wrist.
            if buzz != .off, let target, target.isLive { wrist(DialTime.count(seconds)) }
            return
        }
        session = current
        react(to: event, about: target)
    }

    #if DEBUG
    /// For the recorded walkthrough: holds and lets go of the dial, and ends a timer early.
    func demoDial(_ held: Bool) { if held { beginDial() } else { endDial() } }
    func demoExpire() {
        guard var current = session, let first = current.live(at: Date()).first else { return }
        current.expire(first.id); session = current
    }
    #endif

    /// The band's orientation, for air steps in cooking's combos.
    func orientation(_ q: [Double]) {
        if motionOn { decider.orientation(q) }
    }

    /// The main button of one of the current step's timers: start, pause, start again, stop ringing.
    func toggleTimer(slot: Int) {
        guard var current = session else { return }
        current.select(slot: slot)
        let event = current.toggle(step: current.step, slot: slot)
        session = current
        react(to: event)
    }
    func resetTimer(slot: Int) {
        guard var current = session, current.timer(step: current.step, slot: slot) != nil else { return }
        current.select(slot: slot)
        current.reset(step: current.step, slot: slot)
        session = current
        react(to: .reset)
    }
    func select(slot: Int) {
        guard var current = session, current.slot != slot else { return }
        current.select(slot: slot); session = current
        react(to: .selected(current.slot))
    }
    /// Any timer's main button, wherever its step is: it is selected and started, paused or stopped.
    func toggleTimer(_ id: String) {
        guard var current = session, let timer = current.timers.first(where: { $0.id == id }) else { return }
        current.pick(id)
        let event = current.toggle(step: timer.step, slot: timer.slot)
        session = current
        react(to: event)
    }
    func cancelTimer(_ id: String) {
        guard var current = session, let timer = current.timers.first(where: { $0.id == id }) else { return }
        current.cancel(id); session = current
        react(to: .reset, about: timer)
    }
    /// Selects a timer, wherever its step is, without starting or pausing it.
    func pick(_ id: String) {
        guard var current = session, current.selectedTimer?.id != id else { return }
        current.pick(id); session = current
        react(to: .selected(current.selection ?? 0))
    }
    func addMinute(to id: String) {
        guard var current = session, let timer = current.addMinute(to: id) else { return }
        session = current
        react(to: .extended(timer))
    }
    func stopRinging() {
        guard var current = session, !current.ringing(at: Date()).isEmpty else { return }
        current.stopRinging(); session = current
        react(to: .stopped)
    }
    /// Shows a step, optionally with one of its timers selected.
    func go(to step: Int, slot: Int? = nil) {
        guard var current = session else { return }
        current.go(to: step, slot: slot); session = current
        changed()
    }
    func toggle(ingredient index: Int) {
        guard var current = session else { return }
        current.toggle(ingredient: index); session = current
        if sounds, !previewOnly { onCue?(current.ready.contains(index) ? .tick : .untick) }
        persist()
    }

    /// `about` is the timer a reset took away, which the session no longer has.
    private func react(to event: CookEvent?, about gone: CookTimer? = nil) {
        guard let session else { return }
        var alert: LiveAlert?
        let cue: CookCue
        switch event {
        case .step:
            // A new step sounds different from the next sentence of the same one.
            cue = session.step == heard && !session.gathering ? .beat : .step
            heard = session.gathering ? -1 : session.step
            alert = LiveAlert(title: session.position, body: session.gathering ? session.recipe.title : session.text)
            if reads, !previewOnly, !session.gathering { assistant.read("Step \(session.step + 1). \(session.text)") }
        case .finished:
            cue = .finish; alert = LiveAlert(title: "Recipe finished", body: session.recipe.title)
        case .started(let timer):
            cue = .start; alert = LiveAlert(title: "Timer started", body: "\(timer.label) · \(DurationFinder.short(timer.total))")
            askToNotify()
        case .paused(let timer):
            cue = .pause; alert = LiveAlert(title: "Timer paused", body: "\(timer.label) · \(DurationFinder.clock(timer.remaining(at: Date()))) left")
        case .resumed(let timer):
            cue = .start; alert = LiveAlert(title: "Timer started again", body: "\(timer.label) · \(DurationFinder.clock(timer.remaining(at: Date()))) left")
        case .reset:
            cue = .reset; alert = LiveAlert(title: "Timer reset", body: gone.map { "\($0.label) · step \($0.step + 1)" } ?? session.position)
        case .selected(let position):
            // Getting ready, the same event is a tick: the count of things out says which way.
            cue = !session.gathering || session.ready.count == out ? .select : session.ready.count > out ? .tick : .untick
            let body: String
            if let other = session.pickedTimer {
                body = "\(other.label) · step \(other.step + 1)"
            } else {
                let duration = session.durations.indices.contains(session.slot) ? session.durations[session.slot] : nil
                body = [duration?.label ?? session.selectedTimer?.label, duration?.short].compactMap { $0 }.joined(separator: " · ")
            }
            alert = LiveAlert(title: "Timer \(position + 1) of \(session.slots + session.others.count)", body: body)
        case .stopped:
            cue = .stop
        case .extended(let timer):
            cue = .extend; alert = LiveAlert(title: "One more minute", body: "\(timer.label) · \(DurationFinder.clock(timer.remaining(at: Date()))) left")
        case nil:
            cue = .nothing
        }
        if sounds, !previewOnly { onCue?(cue) }
        out = session.ready.count
        // The wrist is told about timers always, and about pages too when set to everything.
        if let event, buzz == .all || (buzz == .timers && event.isTimer) { wrist([event.wrist]) }
        // With Runes open the screen shows the change; an alert is for a locked phone.
        changed(alert: UIApplication.shared.applicationState == .active ? nil : alert)
    }

    private func changed(alert: LiveAlert? = nil) {
        persist()
        guard !previewOnly else { return }
        arm(); syncNotifications(); liveChanged()
        onReserve?(reservedNow)
        show(alert: alert)
    }

    // MARK: Timers

    /// The step last announced and the number of ingredients out, to tell a new step from
    /// a new sentence and a tick from a move.
    private var heard = -1
    private var out = 0

    /// Timers already given their minute's notice.
    private var warned: Set<String> = []
    /// A minute before a timer of three minutes or more ends: time to find the colander.
    private func notices(at now: Date) -> [(timer: CookTimer, time: Date)] {
        (session?.running(at: now) ?? []).filter { $0.total >= 180 && !warned.contains($0.id) }.map { ($0, $0.end.addingTimeInterval(-60)) }
    }

    private func giveNotice() {
        let now = Date()
        let due = notices(at: now).filter { $0.time <= now && $0.timer.remaining(at: now) > 45 }
        guard !due.isEmpty else { return }
        warned.formUnion(due.map(\.timer.id))
        if sounds { onCue?(.soon) }
        if buzz != .off { wrist([.double]) }
    }

    /// Starts already called for, so each is said once.
    private var called: Set<String> = []

    /// The moment to start this step's time so it lands with what is already going.
    private func startMoment(at now: Date) -> (key: String, time: Date, label: String, with: String)? {
        guard let session, let landing = session.landing(at: now) else { return nil }
        let key = "\(session.step).\(session.slot).\(landing.with.id)"
        guard !called.contains(key) else { return nil }
        return (key, now.addingTimeInterval(Double(landing.wait)), session.durations[session.slot].label ?? "Step \(session.step + 1)", landing.with.label)
    }

    /// Says when it is time to start something so it finishes with what is already cooking.
    private func callStart() {
        let now = Date()
        guard let session, session.landing(at: now) == nil, session.durations.indices.contains(session.slot),
              session.timer(step: session.step, slot: session.slot)?.isLive != true, let due = pendingStart, due.time <= now.addingTimeInterval(1) else { return }
        pendingStart = nil
        called.insert(due.key)
        if sounds { onCue?(.soon) }
        if buzz != .off { wrist([.double, .tap]) }
        if spoken { assistant.read("Start the \(due.label.lowercased()) now, to finish with the \(due.with.lowercased()).") }
    }
    private var pendingStart: (key: String, time: Date, label: String, with: String)?

    /// Wakes at the next timer's end, so the screen and the Lock Screen turn to ringing,
    /// a minute before a long one ends, and when it is time to start something so it lands
    /// with the rest.
    private func arm() {
        wake?.invalidate(); wake = nil
        let now = Date()
        pendingStart = previewOnly ? nil : startMoment(at: now)
        guard !previewOnly, let end = ([session?.nextEnd(after: now), pendingStart?.time] + notices(at: now).map(\.time).filter { $0 > now }).compactMap({ $0 }).min() else { return }
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.rang() }
        }
        RunLoop.main.add(timer, forMode: .common)
        wake = timer
    }

    private func rang() {
        objectWillChange.send()
        giveNotice()
        callStart()
        arm(); show()
        ring()
        liveChanged()
    }

    /// Coming back to the app: timers may have ended while it was suspended.
    private func woke() {
        guard session != nil else { return }
        objectWillChange.send()
        arm(); show()
        ring()
        liveChanged()
    }

    /// Rings a finished timer until it is stopped, for up to a minute: the bell, and three
    /// buzzes on the wrist. Runes is kept awake while a timer counts, so this also happens
    /// behind a locked phone; the timer's notification is there in case it could not be.
    private func ring() {
        guard ringTask == nil, !previewOnly, sounds || buzz != .off else { return }
        // An alarm that only rings leaves the cook guessing which pan it means. This one
        // says its name, and what to look for.
        if spoken, let rung = session?.ringing(at: Date()).first, let session {
            let times = session.recipe.durations(step: rung.step)
            let cue = times.indices.contains(rung.slot) ? StepDetails.cue(for: times[rung.slot], in: session.recipe.steps[rung.step]) : nil
            assistant.read("\(rung.label). Time’s up." + (cue.map { " Check: \($0)." } ?? ""))
        }
        // The first buzz also counts out where the pan is: taps for a burner, a long one for the oven.
        let place = session.flatMap { session in session.ringing(at: Date()).first.map { StationPlan(steps: session.recipe.steps).spot(step: $0.step).place } }
        ringTask = Task { [weak self] in
            for round in 0..<30 {
                guard let self, !Task.isCancelled, let session = self.session, !session.ringing(at: Date()).isEmpty else { break }
                if self.sounds { self.onCue?(.ring) }
                if self.buzz != .off { self.wrist([.triple] + (round == 0 ? place.map(RecipeBrief.wrist) ?? [] : [])) }
                try? await Task.sleep(for: .seconds(2))
            }
            self?.ringTask = nil
            self?.liveChanged()
        }
    }

    /// One pending notification per running timer; anything else of ours is withdrawn.
    private func syncNotifications() {
        guard !previewOnly else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Array(scheduled))
        scheduled = []
        guard let session else { return }
        let now = Date()
        for timer in session.running(at: now) {
            let content = UNMutableNotificationContent()
            content.title = "Time’s up"
            content.body = "\(timer.label) · step \(timer.step + 1) of \(session.recipe.title)"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, timer.end.timeIntervalSince(now)), repeats: false)
            let id = Self.notificationPrefix + timer.id
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            scheduled.insert(id)
        }
    }

    /// True for one of Cook's timer notifications.
    nonisolated static func isTimer(_ identifier: String) -> Bool { identifier.hasPrefix(notificationPrefix) }

    private func askToNotify() {
        guard !askedToNotify, !previewOnly else { return }
        askedToNotify = true
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    // MARK: Lock Screen

    private func show(alert: LiveAlert? = nil) {
        guard !previewOnly, let session else { return }
        onActivity?(activityState(session), alert)
    }

    func activityState(_ session: CookSession, now: Date = Date()) -> CookActivityState {
        let timers = session.live(at: now).prefix(5).map {
            CookActivityTimer(id: $0.id, end: $0.end, total: $0.total, ringing: $0.isRinging(at: now), remaining: $0.paused, label: $0.label)
        }
        return CookActivityState(position: session.position, step: session.step, count: session.count,
                                 timers: Array(timers), finished: session.finished)
    }

    private func persist() {
        guard !previewOnly else { return }
        let saved = Saved(recipes: recipes, controls: controls, sounds: sounds, session: session, buzz: buzz.rawValue, dial: dial, spoken: spoken, reads: reads,
                          listLook: listLook.rawValue, cookingLook: cookingLook.rawValue)
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

enum CookError: LocalizedError {
    case unreachable, noRecipe
    var errorDescription: String? {
        switch self {
        case .unreachable: "That page couldn’t be reached. Check the link and your connection."
        case .noRecipe: "No recipe was found on that page. Paste its text instead."
        }
    }
}
