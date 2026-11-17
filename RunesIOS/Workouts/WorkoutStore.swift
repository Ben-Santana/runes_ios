import Foundation
import UIKit

/// The split (each day a `WorkoutPlan`), the global control gestures, the journal, and the running workout.
/// While a workout runs, its control gestures are taken here instead of running mappings,
/// and reps come from `feed`, which the session fills from the band's motion streams.
/// Everything works with the phone locked: the Live Activity carries the state.
@MainActor
final class WorkoutStore: ObservableObject {
    static let shared = WorkoutStore()
    /// Counted on the transport queue; see `SessionController`.
    nonisolated static let feed = RepFeed()
    private static let key = "runes.workouts.v1"
    private static let historyLimit = 1000

    struct Saved: Codable {
        var plans: [WorkoutPlan]
        var controls: WorkoutControls
        var sensitivity: RepSensitivity
        var history: [WorkoutRecord]
        var unit: WeightUnit = .kg
        var sounds = WorkoutSounds()
        var endsAtTarget = false
        var health = HealthSettings()
        var wearable: Wearable?

        init(plans: [WorkoutPlan], controls: WorkoutControls, sensitivity: RepSensitivity, history: [WorkoutRecord], unit: WeightUnit, sounds: WorkoutSounds,
             endsAtTarget: Bool, health: HealthSettings, wearable: Wearable?) {
            self.plans = plans; self.controls = controls; self.sensitivity = sensitivity; self.history = history; self.unit = unit
            self.sounds = sounds; self.endsAtTarget = endsAtTarget; self.health = health; self.wearable = wearable
        }
        /// Data saved before the split and units existed still loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            plans = try c.decodeIfPresent([WorkoutPlan].self, forKey: .plans) ?? WorkoutPlan.starterSplit
            controls = try c.decodeIfPresent(WorkoutControls.self, forKey: .controls) ?? .standard
            sensitivity = try c.decodeIfPresent(RepSensitivity.self, forKey: .sensitivity) ?? .normal
            history = try c.decodeIfPresent([WorkoutRecord].self, forKey: .history) ?? []
            unit = try c.decodeIfPresent(WeightUnit.self, forKey: .unit) ?? .kg
            sounds = (try? c.decodeIfPresent(WorkoutSounds.self, forKey: .sounds)) ?? WorkoutSounds()
            endsAtTarget = try c.decodeIfPresent(Bool.self, forKey: .endsAtTarget) ?? false
            health = (try? c.decodeIfPresent(HealthSettings.self, forKey: .health)) ?? HealthSettings()
            wearable = try? c.decodeIfPresent(Wearable.self, forKey: .wearable)
        }
    }

    @Published private(set) var plans: [WorkoutPlan]
    @Published private(set) var controls: WorkoutControls { didSet { controlsChanged() } }
    @Published private(set) var sensitivity: RepSensitivity
    @Published private(set) var history: [WorkoutRecord]
    @Published private(set) var unit: WeightUnit
    @Published private(set) var sounds: WorkoutSounds { didSet { soundsLiveChanged() } }
    /// Logs a set by itself once the band has counted its target reps, or a timed set has
    /// been held for its time, instead of waiting for Stop.
    @Published private(set) var endsAtTarget = false
    /// Whether finished workouts are added to Apple Health. Off until the person turns it on.
    @Published private(set) var health = HealthSettings()
    /// What Health allows. Read only while the feature is on, so nothing is asked at launch.
    @Published private(set) var healthAccess: HealthAccess = .notAsked
    private lazy var healthLink = HealthLink()
    private var savingToHealth = false
    /// The watch, band or strap the person linked to wear along with the Meta band. nil until they do.
    @Published private(set) var wearable: Wearable?
    @Published private(set) var heartState: HeartLinkState = .idle
    /// Wearables found while the person is choosing one.
    @Published private(set) var heartSensors: [HeartSensor] = []
    /// The wearable's latest reading, while it is being read.
    @Published private(set) var heartRate: Int?
    private lazy var heartLink = makeHeartLink()
    /// The running workout's readings, and those of finished ones still to go to Health.
    private var heartLog = HeartLog()
    private var heartToSave: [String: [HeartSample]] = [:]
    /// True while the wearable's screen shows its live reading outside a workout.
    private var showingHeart = false
    @Published private(set) var run: WorkoutRun? {
        didSet {
            guard (oldValue == nil) != (run == nil), !previewOnly else { return }
            onReserve?(reservedNow)
            soundsLiveChanged()
        }
    }

    /// Plays a sound at a volume. Set by the session.
    var onSound: ((SoundVoice, Double) -> Void)?
    /// Told whether a workout with sounds on is running, so the audio is kept ready to
    /// play each cue the moment it happens, with the phone locked too. Set by the session.
    var onSoundsLive: ((Bool) -> Void)? { didSet { soundsLive = nil; soundsLiveChanged() } }
    private var soundsLive: Bool?
    /// Plays the target cue when a timed set has been held for its target.
    private var holdTimer: Task<Void, Never>?

    /// Told which gestures a running workout holds (none when nothing runs), so mappings
    /// that use them turn off for as long as it does.
    var onReserve: ((Set<GestureKind>) -> Void)? { didSet { onReserve?(reservedNow) } }
    private var reservedNow: Set<GestureKind> {
        run == nil || yielded ? [] : controls.reserved.union(SwitchControls.reserved(switchMapping))
    }
    /// The switch-controls combo, while this is the app the band switches to and from and
    /// its controls are selected. Set by `ControlSwitch`.
    var switchMapping: Mapping? { didSet { if switchMapping != oldValue { controlsChanged() } } }
    /// True while the regular mappings have the band though a workout runs. Reps still count.
    var yielded = false { didSet { if yielded != oldValue, !previewOnly { onReserve?(reservedNow) } } }
    /// Decides which command a band gesture completes, combos included.
    private let decider = TriggerDecider()
    /// Told whether a workout needs the band's motion streams. Set by the session.
    var onMotionDemand: ((Bool) -> Void)? { didSet { onMotionDemand?(run != nil) } }
    /// Shows the workout on the Live Activity (nil restores band status); the string is an alert.
    var onActivity: ((WorkoutActivityState?, String?) -> Void)?
    /// Told when a workout starts and ends and what happens in it, for the raw data recording.
    var onTrace: ((WorkoutTrace) -> Void)?

    private var previewOnly = false

    private init() {
        var saved = Saved(plans: WorkoutPlan.starterSplit, controls: .standard, sensitivity: .normal, history: [], unit: .kg, sounds: WorkoutSounds(),
                          endsAtTarget: false, health: HealthSettings(), wearable: nil)
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Saved.self, from: data) { saved = decoded }
        plans = saved.plans.map { $0.normalized() }
        controls = saved.controls; sensitivity = saved.sensitivity; history = saved.history; unit = saved.unit
        sounds = saved.sounds; endsAtTarget = saved.endsAtTarget; health = saved.health; wearable = saved.wearable
        if !HealthLink.isAvailable { healthAccess = .unavailable }
        decider.onFire = { [weak self] id in
            guard let self, self.run != nil else { return }
            if id == SwitchControls.mappingID { ControlSwitch.shared.toggle(); return }
            guard let command = self.controls.command(forMapping: id) else { return }
            self.perform(command)
        }
        decider.configure(controls.mappings)
        // A workout that finished just before the app closed is sent now.
        refreshHealth()
    }

    private func controlsChanged() {
        guard !previewOnly else { return }
        decider.configure(SwitchControls.adding(switchMapping, to: controls.mappings))
        onReserve?(reservedNow)
    }

    #if DEBUG
    /// Fixed state for screenshots and previews; never saved.
    init(preview plans: [WorkoutPlan], run: WorkoutRun? = nil, history: [WorkoutRecord] = [],
         health: HealthSettings = HealthSettings(), healthAccess: HealthAccess = .notAsked,
         wearable: Wearable? = nil, heartState: HeartLinkState = .idle, heartSensors: [HeartSensor] = [], heartRate: Int? = nil,
         bandHand: Handedness? = .right) {
        self.plans = plans; controls = .standard; sensitivity = .normal; self.history = history; self.run = run; unit = .kg
        sounds = WorkoutSounds()
        self.health = health; self.healthAccess = healthAccess
        self.wearable = wearable; self.heartState = heartState; self.heartSensors = heartSensors; self.heartRate = heartRate
        previewHand = bandHand
        previewOnly = true
    }
    private var previewHand: Handedness?
    #endif

    // MARK: Editing

    func save(_ plan: WorkoutPlan) {
        let plan = plan.normalized()
        if let i = plans.firstIndex(where: { $0.id == plan.id }) { plans[i] = plan } else { plans.append(plan) }
        persist()
    }
    func delete(planID: String) { plans.removeAll { $0.id == planID }; persist() }
    func delete(at offsets: IndexSet) { plans.remove(atOffsets: offsets); persist() }
    func duplicate(planID: String) {
        guard let source = plans.first(where: { $0.id == planID }) else { return }
        var copy = source
        copy.id = UUID().uuidString.lowercased(); copy.name = "\(source.name) copy"
        copy.items = copy.items.map { var item = $0; item.id = UUID().uuidString.lowercased(); return item }
        save(copy)
    }
    func setTrigger(_ trigger: CommandTrigger?, for command: WorkoutCommand) { controls.setTrigger(trigger, for: command); persist() }
    func setSensitivity(_ value: RepSensitivity) { sensitivity = value; persist() }
    func setUnit(_ value: WeightUnit) { unit = value; persist() }
    func setSounds(_ change: (inout WorkoutSounds) -> Void) { change(&sounds); persist() }
    func setEndsAtTarget(_ on: Bool) { endsAtTarget = on; persist() }
    func clearHistory() { removeFromHealth(history); history = []; persist() }
    func deleteRecord(_ id: String) { removeFromHealth(history.filter { $0.id == id }); history.removeAll { $0.id == id }; persist() }
    func move(planFrom source: IndexSet, to destination: Int) { plans.move(fromOffsets: source, toOffset: destination); persist() }

    // MARK: Reading

    /// The split day after the one done most recently, or the first.
    var upNext: WorkoutPlan? {
        guard let last = history.first, let i = plans.firstIndex(where: { $0.id == last.planID || $0.name == last.name }) else { return plans.first }
        return plans[(i + 1) % plans.count]
    }

    /// Every logged set, newest first, including the running workout's.
    var allSets: [SetLog] { (run?.logs.reversed() ?? []) + history.flatMap { $0.sets.reversed() } }

    /// 1 for a muscle trained today, fading by a seventh each day after, 0 after a week.
    /// Muscles a set only works second-hand count half.
    func freshness(now: Date = Date()) -> [Muscle: Double] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var result: [Muscle: Double] = [:]
        for log in allSets {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: log.at), to: today).day ?? 0
            guard days < 7 else { continue }
            let value = max(0, 1 - Double(days) / 7)
            for m in log.exercise.primary { result[m] = max(result[m] ?? 0, value) }
            for m in log.exercise.secondary { result[m] = max(result[m] ?? 0, value * 0.5) }
        }
        return result
    }

    /// Sets that trained a muscle in each calendar week, oldest first, ending with this week.
    /// Sets that only work it second-hand count half.
    func weeklySets(_ muscle: Muscle, weeks: Int = 12, now: Date = Date()) -> [Double] {
        weeklySets(of: [muscle], weeks: weeks, now: now)
    }

    /// The same for a group: a set counts once if it trains any of the muscles first-hand.
    func weeklySets(of muscles: Set<Muscle>, weeks: Int = 12, now: Date = Date()) -> [Double] {
        let calendar = Calendar.current
        guard weeks > 0, let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var result = Array(repeating: 0.0, count: weeks)
        for log in allSets {
            let weight = log.exercise.primary.contains(where: muscles.contains) ? 1
                : log.exercise.secondary.contains(where: muscles.contains) ? 0.5 : 0
            guard weight > 0, let start = calendar.dateInterval(of: .weekOfYear, for: log.at)?.start,
                  let ago = calendar.dateComponents([.weekOfYear], from: start, to: thisWeek).weekOfYear,
                  (0..<weeks).contains(ago) else { continue }
            result[weeks - 1 - ago] += weight
        }
        return result
    }

    /// Days since a muscle was last trained first-hand, nil if never.
    func daysSince(_ muscle: Muscle, now: Date = Date()) -> Int? { daysSince(of: [muscle], now: now) }

    /// Days since any of the muscles was last trained first-hand, nil if never.
    func daysSince(of muscles: Set<Muscle>, now: Date = Date()) -> Int? {
        guard let log = allSets.first(where: { $0.exercise.primary.contains(where: muscles.contains) }) else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: log.at), to: calendar.startOfDay(for: now)).day
    }

    func weightText(_ weight: Double?) -> String? {
        guard let weight, weight > 0 else { return nil }
        let number = weight.rounded() == weight ? String(Int(weight)) : String(format: "%.1f", weight)
        return "\(number) \(unit.title)"
    }

    private func persist() {
        guard !previewOnly else { return }
        let saved = Saved(plans: plans, controls: controls, sensitivity: sensitivity, history: history, unit: unit, sounds: sounds,
                          endsAtTarget: endsAtTarget, health: health, wearable: wearable)
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    // MARK: Running

    func start(_ plan: WorkoutPlan) {
        if run != nil { end() }
        let next = WorkoutRun(plan: plan.normalized())
        guard next.phase != .finished else { return }
        run = next
        heartLog = HeartLog()
        followWearable()
        onMotionDemand?(true)
        if !previewOnly { onTrace?(.began(next)) }
        changed()
    }

    /// Ends the workout, keeping any logged sets in history.
    func end() {
        guard let finished = run else { return }
        if !previewOnly { onTrace?(.ended(finished)) }
        run = nil
        holdTimer?.cancel(); holdTimer = nil
        Self.feed.count(nil, sensitivity: sensitivity)
        onMotionDemand?(false)
        record(finished)
        keepHeart(of: finished)
        followWearable()
        onActivity?(nil, nil)
        saveToHealth()
    }

    func perform(_ command: WorkoutCommand) { perform(command, settling: true) }

    /// `settling` off logs the live count as it stands, for a set ended on reaching its target.
    private func perform(_ command: WorkoutCommand, settling: Bool) {
        guard var current = run else { return }
        // The set logs the counter's settled count, which drops a lone movement at either end.
        if settling, command == .stop, current.phase == .counting, let settled = Self.feed.settled, settled != current.reps {
            if !previewOnly { onTrace?(.event("settled", "live=\(current.reps) settled=\(settled)")) }
            current.settle(settled)
        }
        let before = current
        let logged = current.apply(command)
        run = current
        trace(command, from: before, logged: logged, to: current)
        if let cue = WorkoutCue.after(command, from: before, to: current, logged: logged) { play(cue) }
        changed(alert: logged.map { "\($0.slot.exercise.name), \($0.slot.label.lowercased()): \(Self.value($0))" })
    }

    /// Deletes a set logged in the running workout.
    func deleteLog(_ id: String) {
        guard var current = run, let removed = current.removeLog(id) else { return }
        run = current
        guard !previewOnly else { return }
        onTrace?(.event("set_deleted", "exercise=\(removed.exercise.id) \(removed.slot.label) logged=\(removed.reps)"))
        if current.phase == .finished { record(current) }
        onActivity?(activityState(current), nil)
    }

    /// Takes a band gesture that is one of the workout controls while a workout runs.
    /// Returns false to let mappings handle it.
    func consume(_ gesture: BandGesture) -> Bool {
        guard run != nil, let kind = GestureKind(gesture), reservedNow.contains(kind) else { return false }
        decider.receive(kind)
        return true
    }

    /// Takes a rotation or movement from the band's motion while a workout runs and one
    /// of its combos uses it. Returns false to let mappings have it.
    func consume(_ step: ComboStep) -> Bool {
        guard run != nil, reservedNow.contains(step.gesture) else { return false }
        decider.receive(step)
        return true
    }

    /// The band's orientation, for air steps in a workout's combos.
    func orientation(_ q: [Double]) {
        if run != nil, controls.usesMotion { decider.orientation(q) }
    }

    /// A rep counted from the band's motion.
    func rep() {
        guard var current = run, current.phase == .counting else { return }
        current.rep()
        run = current
        if !previewOnly { onTrace?(.event("rep", "\(current.reps)")) }
        if endsAtTarget, let slot = current.current, slot.exercise.measure == .reps, !slot.assumed, current.reps >= slot.target {
            // The set-done cue stands in for the target's.
            if !previewOnly { onTrace?(.event("auto_stop", "reps=\(current.reps) target=\(slot.target)")) }
            perform(.stop, settling: false)
            return
        }
        if let cue = WorkoutCue.afterRep(current) { play(cue) }
        changed()
    }

    /// Labels the raw recording with what the command did.
    private func trace(_ command: WorkoutCommand, from before: WorkoutRun, logged: SetLog?, to run: WorkoutRun) {
        guard let onTrace, !previewOnly else { return }
        onTrace(.event("command", "\(command.rawValue) \(before.phase.rawValue)->\(run.phase.rawValue) reps=\(before.reps)"))
        if let logged {
            onTrace(.event("set_logged", "exercise=\(logged.exercise.id) \(logged.slot.label) logged=\(logged.reps) assumed=\(logged.slot.assumed)"))
        }
        // A set starts on Start, or restarts on Repeat while counting.
        if run.phase == .counting, before.phase != .counting || command == .repeatLast, let slot = run.current {
            let weight = slot.weight.map { "\($0)\(unit.rawValue)" } ?? "none"
            onTrace(.event("set_start", "exercise=\(slot.exercise.id) \(slot.label) target=\(slot.target) weight=\(weight)"))
        }
    }

    private func changed(alert: String? = nil) {
        guard let run else { return }
        // Entering a set, or restarting one, starts a fresh count; anything else stops it.
        if run.phase == .counting {
            if run.reps == 0 { Self.feed.count(run.current?.exercise, sensitivity: sensitivity) }
        } else {
            Self.feed.count(nil, sensitivity: sensitivity)
        }
        if run.phase == .finished { record(run) }
        guard !previewOnly else { return }
        scheduleHoldTarget(run)
        onActivity?(activityState(run), alert)
    }

    // MARK: Sounds

    private func play(_ cue: WorkoutCue) {
        guard !previewOnly, sounds.on, let voice = sounds[cue] else { return }
        onSound?(voice, sounds.volume)
    }

    private func soundsLiveChanged() {
        guard !previewOnly else { return }
        let live = run != nil && sounds.on
        guard live != soundsLive else { return }
        soundsLive = live
        onSoundsLive?(live)
    }

    /// A timed set has no reps to count, so its target is reached by the clock.
    private func scheduleHoldTarget(_ run: WorkoutRun) {
        holdTimer?.cancel(); holdTimer = nil
        guard run.phase == .counting, let slot = run.current, slot.exercise.measure == .seconds,
              let started = run.setStarted else { return }
        let wait = started.addingTimeInterval(Double(slot.target)).timeIntervalSinceNow
        guard wait > 0 else { return }
        holdTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, let now = self.run, now.phase == .counting, now.setStarted == started else { return }
            if self.endsAtTarget { self.perform(.stop) } else { self.play(.target) }
        }
    }

    /// Saves a run's sets to history when it finishes or is ended. A run that carries on
    /// after finishing (repeat last set) updates its own entry.
    private func record(_ run: WorkoutRun) {
        guard !run.logs.isEmpty else {
            // Every set was deleted after it finished.
            history.removeAll { $0.started == run.started && $0.name == run.name }
            return persist()
        }
        let entry = WorkoutRecord(name: run.name, planID: run.planID, started: run.started, ended: Date(), sets: run.logs)
        if let i = history.firstIndex(where: { $0.started == run.started && $0.name == run.name }) {
            history[i].sets = entry.sets; history[i].ended = entry.ended
        } else {
            history.insert(entry, at: 0)
            history = Array(history.prefix(Self.historyLimit))
        }
        persist()
    }

    // MARK: Apple Health

    /// The newest session that is over, and where it stands with Health.
    var healthStatus: HealthStatus {
        HealthStatus(last: history.first { !isRunning($0) }, settings: health, unit: unit)
    }

    /// Turning it on is the only moment Health's permission sheet is shown.
    func setHealth(_ on: Bool) {
        guard on != health.on, !on || healthAccess != .unavailable else { return }
        // Only workouts finished from now on are sent.
        health.on = on; health.since = on ? Date() : nil
        persist()
        guard on, !previewOnly else { return }
        askHealth()
    }

    /// Asks for what is in use: workouts, and heart rate once a wearable is linked.
    private func askHealth() {
        Task {
            healthAccess = await healthLink.requestAccess(heart: wearable != nil)
            saveToHealth()
        }
    }

    /// Reads what Health allows again, for when the person comes back from changing it.
    func refreshHealth() {
        guard health.on, !previewOnly, healthAccess != .unavailable else { return }
        healthAccess = healthLink.access
        saveToHealth()
    }

    private func isRunning(_ record: WorkoutRecord) -> Bool {
        run.map { $0.started == record.started && $0.name == record.name } ?? false
    }

    /// Sends every finished session Health does not have yet, oldest first. A failure is
    /// marked on the session and tried again the next time this runs. Nothing here can
    /// hold up or undo a workout.
    private func saveToHealth() {
        guard health.on, !previewOnly, !savingToHealth, healthAccess == .allowed else { return }
        let pending = history.filter { $0.needsHealth(health, unit: unit) && !isRunning($0) }
            .compactMap { HealthWorkout($0, unit: unit, heart: heartToSave[$0.id] ?? [], heartSource: wearable?.name) }
        guard !pending.isEmpty else { return }
        savingToHealth = true
        Task {
            for workout in pending.reversed() {
                let mark: HealthMark
                do { mark = .saved(try await healthLink.save(workout)) } catch { mark = .failed }
                if case .saved = mark { heartToSave[workout.id] = nil }
                if let i = history.firstIndex(where: { $0.id == workout.id }) { history[i].health = mark }
                // Deleted from the journal while it was being sent.
                else if case .saved(let identifier) = mark { await healthLink.remove([identifier]) }
            }
            savingToHealth = false
            persist()
            // One that ended while these were being sent has not been tried yet.
            if history.contains(where: { $0.health == nil && $0.needsHealth(health, unit: unit) && !isRunning($0) }) { saveToHealth() }
        }
    }

    /// A session deleted in Runes leaves Health too, while saving to Health is on.
    private func removeFromHealth(_ records: [WorkoutRecord]) {
        let identifiers = records.compactMap { record -> String? in
            if case .saved(let identifier) = record.health { return identifier }
            return nil
        }
        guard health.on, !previewOnly, !identifiers.isEmpty else { return }
        Task { await healthLink.remove(identifiers) }
    }

    // MARK: Wearable

    /// The wrist the band is set for, as the session last confirmed it. Read only here:
    /// it is changed in Settings, where the band is told.
    var bandHand: Handedness? {
        #if DEBUG
        if previewOnly { return previewHand }
        #endif
        return UserDefaults.standard.string(forKey: "bandHand").flatMap(Handedness.init)
    }

    private func makeHeartLink() -> HeartRateLink {
        let link = HeartRateLink()
        link.onState = { [weak self] state in
            guard let self else { return }
            self.heartState = state
            if state != .live { self.heartRate = nil }
        }
        link.onSensors = { [weak self] in self?.heartSensors = $0 }
        link.onBeats = { [weak self] beats in
            guard let self else { return }
            self.heartRate = beats
            if self.run != nil { self.heartLog.add(beats, at: Date()) }
        }
        return link
    }

    /// Looks for wearables sharing heart rate. Called only once the person has said they
    /// want to link one, so Bluetooth is not searched before that.
    func findWearables() {
        guard !previewOnly else { return }
        heartLink.search()
    }

    func stopFindingWearables() {
        guard !previewOnly else { return }
        heartLink.stopSearch()
    }

    /// Links the chosen wearable, worn at first on the wrist the band is not on.
    func link(_ sensor: HeartSensor) {
        wearable = Wearable(id: sensor.id, name: sensor.name, wrist: bandHand.map { $0 == .left ? .right : .left })
        persist()
        guard !previewOnly else { return }
        heartLink.stopSearch()
        followWearable()
        if health.on { askHealth() }
    }

    func setWearableWrist(_ wrist: Handedness?) {
        guard wearable != nil, wearable?.wrist != wrist else { return }
        wearable?.wrist = wrist
        persist()
    }

    func unlinkWearable() {
        wearable = nil; heartRate = nil
        persist()
        followWearable()
    }

    /// Shows the live reading on the wearable's own screen, so the link can be seen working.
    func showHeart(_ on: Bool) {
        showingHeart = on
        followWearable()
    }

    /// Reads the wearable while a workout runs or its screen is open, and lets it go otherwise.
    private func followWearable() {
        guard !previewOnly else { return }
        if let wearable, run != nil || showingHeart { heartLink.follow(wearable.id) }
        else if wearable != nil || heartState != .idle { heartLink.stop() }
    }

    /// Keeps what the wearable read during a workout: a summary in the journal, and the
    /// readings until Health has them. They are not kept across a restart.
    private func keepHeart(of finished: WorkoutRun) {
        guard let i = history.firstIndex(where: { $0.started == finished.started && $0.name == finished.name }),
              let last = history[i].sets.map(\.at).max() else { return }
        let readings = heartLog.within(finished.started, last)
        heartLog = HeartLog()
        guard let summary = HeartSummary(readings) else { return }
        history[i].heart = summary
        heartToSave[history[i].id] = readings
        persist()
    }

    // MARK: Text

    static func reps(_ n: Int) -> String { n == 1 ? "1 rep" : "\(n) reps" }
    static func target(_ slot: WorkoutSlot) -> String { slot.exercise.measure == .seconds ? "\(slot.target) s" : reps(slot.target) }
    static func value(_ log: SetLog) -> String { log.exercise.measure == .seconds ? "\(log.reps) s" : reps(log.reps) }

    func activityState(_ run: WorkoutRun) -> WorkoutActivityState {
        let last = run.last.map { "Last: \($0.slot.exercise.name), set \($0.slot.set): \(Self.value($0))" }
        guard let slot = run.current else {
            let total = run.logs.filter { $0.exercise.measure == .reps }.reduce(0) { $0 + $1.reps }
            return WorkoutActivityState(title: "Workout done", detail: "\(run.logs.count) sets · \(Self.reps(total))",
                                        status: "Saved to history", isCounting: false, reps: 0, last: last, next: nil, finished: true)
        }
        let status: String
        switch run.phase {
        case .counting:
            let doing = slot.assumed ? "In progress" : "Counting"
            status = controls.trigger(for: .stop).map { "\(doing) · \($0.name.lowercased()) to stop" } ?? doing
        default:
            status = controls.trigger(for: .start).map { "\($0.name) to start" } ?? "Waiting to start"
        }
        let next = run.next.map { "Next: \($0.exercise.name), \($0.label.lowercased())" } ?? "Last set"
        return WorkoutActivityState(title: slot.exercise.name, detail: "\(slot.label) · \(Self.target(slot))",
                                    status: status, isCounting: run.phase == .counting, reps: run.reps,
                                    last: last, next: next, finished: false, group: slot.exercise.group)
    }
}
