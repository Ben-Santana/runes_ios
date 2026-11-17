import Foundation

// Workouts: a split of training days (exercises × sets), global control gestures, and the
// state machine for a running workout. Reps come from the band's motion for the exercises it
// can count (ExerciseCatalog.swift); the rest log their target, or their time.
// Everything here is a pure value type so it is tested without a band.

/// Scales every exercise's thresholds.
enum RepSensitivity: String, Codable, CaseIterable, Sendable {
    case low, normal, high
    var title: String { rawValue.capitalized }
    /// Multiplier for thresholds: higher sensitivity needs less movement.
    var scale: Double { switch self { case .low: 1.2; case .normal: 1; case .high: 0.8 } }
}

enum WeightUnit: String, Codable, CaseIterable, Sendable {
    case kg, lb
    var title: String { rawValue }
    var step: Double { self == .kg ? 2.5 : 5 }
}

/// One exercise in a split day, done for `sets` sets of `reps` reps (seconds for a timed one),
/// optionally at `weight` in the store's unit.
struct WorkoutItem: Codable, Hashable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    var exercise: Exercise
    var sets: Int
    var reps: Int
    var weight: Double? = nil

    init(exercise: Exercise, sets: Int, reps: Int, weight: Double? = nil) {
        self.exercise = exercise; self.sets = sets; self.reps = reps; self.weight = weight
    }

    static let setRange = 1...10, repRange = 1...100, secondRange = 5...600, weightRange = 0.0...1000.0
    static func defaultTarget(_ exercise: Exercise) -> Int { exercise.measure == .seconds ? 30 : 10 }
    var targetRange: ClosedRange<Int> { exercise.measure == .seconds ? Self.secondRange : Self.repRange }
}

/// One day of the split: a named list of exercises.
struct WorkoutPlan: Codable, Hashable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    var name: String
    var items: [WorkoutItem]

    var setCount: Int { items.reduce(0) { $0 + $1.sets } }
    var summary: String {
        let exercises = items.count == 1 ? "1 exercise" : "\(items.count) exercises"
        return "\(exercises) · \(setCount == 1 ? "1 set" : "\(setCount) sets")"
    }

    /// Every muscle this day trains first-hand.
    var muscles: Set<Muscle> { Set(items.flatMap(\.exercise.primary)) }

    static func new(_ index: Int) -> WorkoutPlan {
        WorkoutPlan(name: "Day \(index)", items: [])
    }
    static let sample = WorkoutPlan(name: "Arms", items: [
        WorkoutItem(exercise: .bicepCurl, sets: 3, reps: 12),
        WorkoutItem(exercise: .lateralRaise, sets: 3, reps: 10),
        WorkoutItem(exercise: .overheadExtension, sets: 2, reps: 12),
    ])
    private static func day(_ name: String, _ items: [(String, Int, Int)]) -> WorkoutPlan {
        WorkoutPlan(name: name, items: items.compactMap { id, sets, reps in
            Exercise.byID[id].map { WorkoutItem(exercise: $0, sets: sets, reps: reps) }
        })
    }
    /// A push / pull / legs split for a first launch.
    static let starterSplit: [WorkoutPlan] = [
        day("Push", [("benchPress", 4, 8), ("dumbbellShoulderPress", 3, 10), ("inclineDumbbellPress", 3, 10),
                     ("lateralRaise", 3, 12), ("tricepPushdown", 3, 12), ("overheadExtension", 2, 12)]),
        day("Pull", [("pullUp", 4, 8), ("bentOverRow", 3, 10), ("latPulldown", 3, 10),
                     ("facePull", 3, 15), ("bicepCurl", 3, 12), ("hammerCurl", 2, 12)]),
        day("Legs", [("backSquat", 4, 6), ("romanianDeadlift", 3, 8), ("legPress", 3, 12),
                     ("legCurl", 3, 12), ("calfRaise", 4, 15), ("plank", 3, 45)]),
    ]

    /// Trimmed name, sets and reps within range.
    func normalized() -> WorkoutPlan {
        var plan = self
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        plan.name = trimmed.isEmpty ? "Workout" : trimmed
        plan.items = items.map { item in
            var item = item
            item.sets = min(max(item.sets, WorkoutItem.setRange.lowerBound), WorkoutItem.setRange.upperBound)
            item.reps = min(max(item.reps, item.targetRange.lowerBound), item.targetRange.upperBound)
            if let w = item.weight { item.weight = w > 0 ? min(w, WorkoutItem.weightRange.upperBound) : nil }
            return item
        }
        return plan
    }
}

/// What the global workout gestures do.
enum WorkoutCommand: String, Codable, CaseIterable, Sendable {
    case start, stop, repeatLast, skip

    var title: String {
        switch self {
        case .start: "Start set"
        case .stop: "Stop set"
        case .repeatLast: "Repeat last set"
        case .skip: "Skip set"
        }
    }
    var detail: String {
        switch self {
        case .start: "Begins the set. Reps are counted for exercises the band can follow."
        case .stop: "Logs the set and moves to the next one."
        case .repeatLast: "Does the set you just finished again. While counting, restarts the set."
        case .skip: "Moves on without logging."
        }
    }
}

/// A gesture or a combo per command, the same for every workout.
struct WorkoutControls: Codable, Hashable, Sendable {
    var triggers: [WorkoutCommand: CommandTrigger]

    static let standard = WorkoutControls(gestures: [
        .start: .doubleTapIndex, .stop: .doubleTapMiddle, .repeatLast: .swipeLeft, .skip: .swipeRight,
    ])
    /// Gestures a command may use on its own. Releases only exist inside combos.
    static let choices = CommandTrigger.singleChoices
    private static let mappingPrefix = "workout:"

    init(triggers: [WorkoutCommand: CommandTrigger]) { self.triggers = triggers }
    init(gestures: [WorkoutCommand: GestureKind]) { triggers = gestures.mapValues(CommandTrigger.gesture) }

    func trigger(for command: WorkoutCommand) -> CommandTrigger? { triggers[command] }
    /// The command's gesture, when it is a single one.
    func gesture(for command: WorkoutCommand) -> GestureKind? { triggers[command]?.gesture }
    func command(for gesture: GestureKind) -> WorkoutCommand? {
        WorkoutCommand.allCases.first { triggers[$0]?.gesture == gesture }
    }
    /// Assigns a trigger; a command that already had it takes this command's old one.
    mutating func setTrigger(_ trigger: CommandTrigger?, for command: WorkoutCommand) { triggers.assign(trigger, to: command) }
    mutating func set(_ gesture: GestureKind?, for command: WorkoutCommand) { setTrigger(gesture.map(CommandTrigger.gesture), for: command) }

    /// The gestures a running workout takes; mappings that use one are off until it ends.
    var reserved: Set<GestureKind> { triggers.reserved }
    /// The triggers as mappings, for the engine that decides which one was made.
    var mappings: [Mapping] { triggers.mappings(prefix: Self.mappingPrefix) }
    var usesMotion: Bool { triggers.usesMotion }
    func command(forMapping id: String) -> WorkoutCommand? { triggers.command(forMapping: id, prefix: Self.mappingPrefix) }

    private enum Keys: String, CodingKey { case gestures, triggers }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let saved = try c.decodeIfPresent([String: CommandTrigger].self, forKey: .triggers) {
            triggers = Dictionary(saved: saved)
        } else {
            // Saved before a command could take a combo: one gesture each.
            triggers = try c.decode([WorkoutCommand: GestureKind].self, forKey: .gestures).mapValues(CommandTrigger.gesture)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(triggers.saved, forKey: .triggers)
    }
}

/// A set to do, in the order the run goes through them.
struct WorkoutSlot: Codable, Hashable, Sendable {
    var exercise: Exercise
    var set: Int
    var of: Int
    var target: Int
    var weight: Double? = nil
    var isRepeat = false

    /// The value a set logs when the band can't count it.
    var assumed: Bool { !exercise.detectsReps }
    var unit: String { exercise.measure == .seconds ? "s" : (target == 1 ? "rep" : "reps") }

    var label: String { isRepeat ? "Set \(set) of \(of), again" : "Set \(set) of \(of)" }
}

/// A finished set.
struct SetLog: Codable, Hashable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    var slot: WorkoutSlot
    /// Reps, or seconds for a timed exercise.
    var reps: Int
    var at: Date
    /// When the set began; nil for sets saved before this was kept.
    var started: Date? = nil

    var exercise: Exercise { slot.exercise }
    var weight: Double? { slot.weight }
}

/// A workout that was done, for history.
struct WorkoutRecord: Codable, Hashable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    var name: String
    /// The split day it ran; nil for workouts saved before the split.
    var planID: String? = nil
    var started: Date
    var ended: Date
    var sets: [SetLog]
    /// Where the session stands with Apple Health; nil when it was never sent.
    var health: HealthMark? = nil
    /// Heart rate from a linked wearable, when one shared it during the workout.
    var heart: HeartSummary? = nil

    var totalReps: Int { sets.filter { $0.exercise.measure == .reps }.reduce(0) { $0 + $1.reps } }
    /// Weight × reps over every weighted set.
    var volume: Double { sets.reduce(0) { $0 + ($1.weight ?? 0) * Double($1.exercise.measure == .reps ? $1.reps : 0) } }
    var muscles: Set<Muscle> { Set(sets.flatMap(\.exercise.primary)) }
}

/// A running workout: waits for the start gesture, counts a set, logs it on the stop gesture,
/// then waits again for the next set.
struct WorkoutRun: Codable, Hashable, Sendable {
    enum Phase: String, Codable, Sendable { case waiting, counting, finished }

    let planID: String
    let name: String
    let started: Date
    private(set) var slots: [WorkoutSlot]
    private(set) var index = 0
    private(set) var phase: Phase
    private(set) var reps = 0
    private(set) var logs: [SetLog] = []
    /// When the current set began.
    private(set) var setStarted: Date?

    init(plan: WorkoutPlan, at now: Date = Date()) {
        planID = plan.id; name = plan.name; started = now
        slots = plan.items.flatMap { item in
            (1...max(1, item.sets)).map { WorkoutSlot(exercise: item.exercise, set: $0, of: item.sets, target: item.reps, weight: item.weight) }
        }
        phase = slots.isEmpty ? .finished : .waiting
    }

    var current: WorkoutSlot? { slots.indices.contains(index) ? slots[index] : nil }
    var next: WorkoutSlot? { slots.indices.contains(index + 1) ? slots[index + 1] : nil }
    var last: SetLog? { logs.last }
    var remaining: Int { max(0, slots.count - index) }

    /// Applies a command. Returns the set it logged, if any.
    @discardableResult
    mutating func apply(_ command: WorkoutCommand, at now: Date = Date()) -> SetLog? {
        switch (command, phase) {
        case (.start, .waiting):
            phase = .counting; reps = 0; setStarted = now
        case (.stop, .counting):
            guard let slot = current else { return nil }
            // A timed exercise logs how long it was held; one the band can't count logs its target.
            let value: Int
            if slot.exercise.measure == .seconds { value = max(1, Int(now.timeIntervalSince(setStarted ?? now).rounded())) }
            else if slot.assumed { value = slot.target }
            else { value = reps }
            let log = SetLog(slot: slot, reps: value, at: now, started: setStarted)
            logs.append(log)
            advance()
            return log
        case (.repeatLast, .counting):
            reps = 0; setStarted = now
        case (.repeatLast, .waiting), (.repeatLast, .finished):
            guard var again = last?.slot else { return nil }
            again.isRepeat = true
            slots.insert(again, at: index)
            phase = .waiting
        case (.skip, .waiting), (.skip, .counting):
            advance()
        default:
            break
        }
        return nil
    }

    /// A rep from the counter; ignored unless a set is being counted.
    mutating func rep() { if phase == .counting { reps += 1 } }
    /// Replaces the live count with the counter's settled one, just before the set logs.
    mutating func settle(_ count: Int) { if phase == .counting { reps = max(0, count) } }

    /// Drops a logged set. The run's place is unchanged.
    @discardableResult
    mutating func removeLog(_ id: String) -> SetLog? {
        guard let i = logs.firstIndex(where: { $0.id == id }) else { return nil }
        return logs.remove(at: i)
    }

    private mutating func advance() {
        index += 1; reps = 0; setStarted = nil
        phase = index < slots.count ? .waiting : .finished
    }
}

/// Counts reps from orientation (w, x, y, z) and gyroscope (x, y, z) samples.
///
/// Nothing refers to where the set started: the user may tap start from anywhere. The
/// forearm's orientation, taken relative to a slowly moving centre, becomes an angle about the
/// axis it keeps turning on; a rep is that angle going out and back (`Cycle`), each leg at least
/// a fraction of the set's typical rep. Reps are counted live as they complete; `settled` is the
/// count the set logs, which drops the warm-up wobble and a lone movement at either end.
/// Tuned on recorded back, chest and arm sessions (2026-11-13, 2026-11-15).
struct RepCounter: Sendable {
    let exercise: Exercise
    let scale: Double
    private var armed = true
    private var lastRep: TimeInterval = -.infinity
    /// Time and size of every rep counted live.
    private(set) var reps: [(time: TimeInterval, size: Double)] = []

    // Swing filters step once per sample: receipt times arrive in bursts, so they can't drive them.
    private static let rate = 100.0          // orientation samples per second, roughly
    private static let centreTime = 2.5      // s; how fast the start pose is forgotten
    private static let axisTime = 2.0        // s; memory for the swing axis
    private static let smoothing = 1 / (0.25 * rate)
    private var samples = 0.0
    private var centre: [Double]?
    private var spread = [Double](repeating: 0, count: 9)
    private var axis = [1.0, 1.0, 1.0].map { $0 / 3.0.squareRoot() }
    private var along = 0.0
    private var cycle: Cycle?
    private var effort = Effort()

    init(exercise: Exercise, sensitivity: RepSensitivity = .normal) {
        self.exercise = exercise; scale = sensitivity.scale
        if case .swing(let degrees)? = exercise.signal { cycle = Cycle(minimum: degrees * scale) }
    }

    /// The count the set logs: live reps without the ones that don't look like the rest.
    var settled: Int { Self.settle(reps, effort: effort.trace) }

    static func settle(_ reps: [(time: TimeInterval, size: Double)], effort: [(time: TimeInterval, level: Double)] = []) -> Int {
        guard reps.count >= 4 else { return reps.count }
        let sizes = reps.map(\.size).sorted(), typical = sizes[sizes.count / 2]
        // Counted before the threshold knew how big a rep is.
        var kept = reps.filter { $0.size >= 0.3 * typical }
        guard kept.count >= 4 else { return kept.count }
        let gaps = zip(kept.dropFirst(), kept).map { $0.time - $1.time }.sorted()
        let pace = gaps[gaps.count / 2]
        // Reaching for the handle before the first rep, or putting it back after the last.
        if kept[kept.count - 1].time - kept[kept.count - 2].time > 2.5 * pace { kept.removeLast() }
        if kept[1].time - kept[0].time > 2.5 * pace { kept.removeFirst() }
        return Effort.confirm(kept.map(\.time), pace: pace, trace: effort)
    }

    /// Returns true when this sample completes a rep.
    mutating func orientation(_ q: [Double], at now: TimeInterval) -> Bool {
        guard case .swing? = exercise.signal, q.count == 4, q.allSatisfy(\.isFinite) else { return false }
        let norm = sqrt(q.reduce(0) { $0 + $1 * $1 })
        guard norm > 1e-8 else { return false }
        var current = q.map { $0 / norm }
        samples += 1
        guard var c = centre else { centre = current; return false }
        if zip(c, current).reduce(0, { $0 + $1.0 * $1.1 }) < 0 { current = current.map { -$0 } }
        // Plain average until there's enough history, so the start pose fades quickly.
        let kc = max(1 / samples, 1 / (Self.centreTime * Self.rate))
        c = zip(c, current).map { $0 + kc * ($1 - $0) }
        let cn = sqrt(c.reduce(0) { $0 + $1 * $1 })
        c = c.map { $0 / cn }; centre = c
        let r = Self.rotation(from: c, to: current)
        let ka = max(1 / samples, 1 / (Self.axisTime * Self.rate))
        for i in 0..<3 { for j in 0..<3 { spread[3 * i + j] += ka * (r[i] * r[j] - spread[3 * i + j]) } }
        // One power-iteration step; the sign is kept so the projection doesn't flip.
        var a = (0..<3).map { i in (0..<3).reduce(0) { $0 + spread[3 * i + $1] * axis[$1] } }
        var an = sqrt(a.reduce(0) { $0 + $1 * $1 })
        if an < 1e-9 * max(spread[0] + spread[4] + spread[8], 1e-12) {
            let i = [0, 4, 8].map { spread[$0] }.enumerated().max { $0.element < $1.element }!.offset
            a = (0..<3).map { spread[3 * i + $0] }; an = sqrt(a.reduce(0) { $0 + $1 * $1 })
        }
        if an > 1e-12 {
            a = a.map { $0 / an }
            axis = zip(a, axis).reduce(0, { $0 + $1.0 * $1.1 }) < 0 ? a.map { -$0 } : a
        }
        along += Self.smoothing * (zip(r, axis).reduce(0) { $0 + $1.0 * $1.1 } - along)
        return step(along, at: now)
    }

    /// The rotation from `a` to `b` (unit quaternions) as a rotation vector in degrees, in `a`'s frame.
    private static func rotation(from a: [Double], to b: [Double]) -> [Double] {
        let (w1, x1, y1, z1) = (a[0], -a[1], -a[2], -a[3]), (w2, x2, y2, z2) = (b[0], b[1], b[2], b[3])
        var w = w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2
        var v = [w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2, w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2, w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2]
        if w < 0 { w = -w; v = v.map { -$0 } }
        let s = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard s > 1e-12 else { return [0, 0, 0] }
        let degrees = 2 * atan2(s, w) * 180 / .pi
        return v.map { $0 / s * degrees }
    }

    /// One EMG packet (16 samples × 8 channels): how hard the forearm is working, for `settled`.
    mutating func emg(_ values: [UInt16], at now: TimeInterval) {
        if exercise.signal != nil { effort.add(values, at: now) }
    }

    private mutating func step(_ value: Double, at now: TimeInterval) -> Bool {
        guard let size = cycle?.add(value), now - lastRep >= exercise.minimumRepInterval else { return false }
        lastRep = now
        reps.append((now, size))
        return true
    }

    mutating func gyroscope(_ values: [Double], at now: TimeInterval) -> Bool {
        guard case .burst(let on, let off)? = exercise.signal, values.count == 3, values.allSatisfy(\.isFinite) else { return false }
        let magnitude = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return crossed(magnitude, on: on * scale, off: off * scale, at: now)
    }

    private mutating func crossed(_ value: Double, on: Double, off: Double, at now: TimeInterval) -> Bool {
        if value < off { armed = true; return false }
        guard armed, value > on, now - lastRep >= exercise.minimumRepInterval else { return false }
        armed = false; lastRep = now
        reps.append((now, 1))
        return true
    }
}

/// Forearm muscle effort from the band's EMG: each channel's sample-to-sample change (which
/// drops slow drift and movement), rectified, summed over channels, kept 16 times a second.
/// A rep moved without load, such as reaching for the handle or putting it back, shows little
/// effort next to the set's real reps.
struct Effort: Sendable {
    private static let channels = 8, packetsPerPoint = 8, limit = 16 * 600
    static let floor = 0.05    // quantile of the set's effort taken as resting
    static let share = 0.15    // of the typical rep's effort above rest
    static let edges = 1       // reps at each end that may be dropped
    private(set) var trace: [(time: TimeInterval, level: Double)] = []
    private var previous: [Double]?
    private var sum = 0.0, packets = 0

    mutating func add(_ values: [UInt16], at now: TimeInterval) {
        guard values.count == 16 * Self.channels, trace.count < Self.limit else { return }
        var last = previous ?? (0..<Self.channels).map { Double(values[$0]) }
        for sample in 0..<16 {
            for ch in 0..<Self.channels {
                let v = Double(values[sample * Self.channels + ch])
                sum += abs(v - last[ch]); last[ch] = v
            }
        }
        previous = last; packets += 1
        if packets == Self.packetsPerPoint { trace.append((now, sum)); sum = 0; packets = 0 }
    }

    /// The reps at `times` that show effort; all of them when there is too little EMG to judge.
    static func confirm(_ times: [TimeInterval], pace: TimeInterval, trace: [(time: TimeInterval, level: Double)]) -> Int {
        guard times.count >= 4, let start = times.first, let end = times.last,
              trace.filter({ $0.time >= start - pace && $0.time <= end }).count >= Int((end - start + pace) * 8 * 0.8) else { return times.count }
        let levels = trace.map(\.level).sorted()
        let rest = levels[Int(Double(levels.count - 1) * floor)]
        let efforts = times.map { t -> Double in
            let window = trace.filter { $0.time > t - pace && $0.time <= t }.map(\.level)
            return window.isEmpty ? 0 : window.reduce(0, +) / Double(window.count) - rest
        }
        let typical = efforts.sorted()[efforts.count / 2]
        guard typical > 0 else { return times.count }
        let weak = efforts.indices.filter { efforts[$0] < share * typical && ($0 < edges || $0 >= efforts.count - edges) }
        return times.count - weak.count
    }
}

/// Finds turns in a 1-D signal and pairs them into reps. A turn is the signal coming back from
/// its latest extreme by `delta`: the larger of `minimum` and a fraction of the typical rep, so
/// wobble inside a rep isn't a turn. The first leg's direction is "out"; a rep counts once the
/// way back has covered most of the way out, so the last rep needs no movement after it.
struct Cycle: Sendable {
    let minimum: Double
    private static let fraction = 0.5
    private static let back = 0.8
    private static let memory = 5
    private var direction = 0           // 1 rising, -1 falling, 0 not yet known
    private var low = Double.infinity, high = -Double.infinity
    private var turn = 0.0, extreme = 0.0
    private var out = 0
    /// The out leg waiting for its way back.
    private var pending: Double?
    private var legs: [Double] = []
    private var sizes: [Double] = []

    init(minimum: Double) { self.minimum = minimum }

    private var delta: Double {
        let recent = sizes.isEmpty ? legs.suffix(Self.memory) : sizes.suffix(Self.memory)
        guard !recent.isEmpty else { return minimum }
        let sorted = recent.sorted()
        return max(minimum, Self.fraction * sorted[sorted.count / 2])
    }

    /// Returns the rep's size when this value completes one.
    mutating func add(_ x: Double) -> Double? {
        let d = delta
        if direction == 0 {
            low = min(low, x); high = max(high, x)
            if x - low >= d { direction = 1; turn = low; extreme = x }
            else if high - x >= d { direction = -1; turn = high; extreme = x }
            return nil
        }
        if (x - extreme) * Double(direction) > 0 { extreme = x }
        let travelled = abs(extreme - turn)
        if direction != out, let first = pending, travelled >= max(d, Self.back * first) {
            pending = nil
            sizes.append(first); if sizes.count > Self.memory { sizes.removeFirst() }
            return first
        }
        guard (extreme - x) * Double(direction) >= d else { return nil }
        let way = direction
        turn = extreme; extreme = x; direction = -direction
        legs.append(travelled); if legs.count > 2 * Self.memory { legs.removeFirst() }
        if out == 0 { out = way }
        // An out leg replaces one that never came back: that was a change of position.
        if way == out { pending = travelled }
        return nil
    }
}

/// Feeds motion samples to the active set's counter on the transport queue, so only
/// counted reps cross to the main actor.
final class RepFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: RepCounter?

    /// Starts a fresh count, or stops counting with nil.
    func count(_ exercise: Exercise?, sensitivity: RepSensitivity) {
        lock.withLock { counter = exercise.flatMap { $0.detectsReps ? RepCounter(exercise: $0, sensitivity: sensitivity) : nil } }
    }
    var isCounting: Bool { lock.withLock { counter != nil } }

    /// One EMG packet (16 samples × 8 channels).
    func ingest(emg values: [UInt16], at now: TimeInterval) {
        lock.withLock { counter?.emg(values, at: now) }
    }

    /// The count the set should log; nil when nothing is being counted.
    var settled: Int? { lock.withLock { counter?.settled } }

    /// `orientation` true for a quaternion, false for a gyroscope sample. True when a rep completed.
    func ingest(orientation: Bool, _ values: [Double], at now: TimeInterval) -> Bool {
        lock.withLock {
            guard counter != nil else { return false }
            return orientation ? counter!.orientation(values, at: now) : counter!.gyroscope(values, at: now)
        }
    }
}
