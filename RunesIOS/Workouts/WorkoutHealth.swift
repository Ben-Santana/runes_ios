import Foundation

// What Workouts sends to Apple Health: one workout for each finished session, as plain values
// so the mapping is checked without HealthKit. HealthLink.swift turns them into Health's types.
// Only what Runes measured is carried: the times, the exercises, and each set's reps, hold and
// weight. Energy and heart rate are never estimated.

/// The Health workout types Runes uses.
enum HealthActivity: String, Sendable, CaseIterable {
    case traditionalStrength, functionalStrength, core, mixedCardio

    /// The type most of the sets belong to. A tie goes to the earlier case.
    init(sets: [SetLog]) {
        var counts: [HealthActivity: Int] = [:]
        for log in sets { counts[Self.kind(log.exercise), default: 0] += 1 }
        self = Self.allCases.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? .traditionalStrength
    }

    private static func kind(_ exercise: Exercise) -> HealthActivity {
        if exercise.group == .cardio { return .mixedCardio }
        if exercise.group == .core { return .core }
        return exercise.equipment == .bodyweight ? .functionalStrength : .traditionalStrength
    }
}

/// One logged set, as Health carries it.
struct HealthSet: Hashable, Sendable {
    var exercise: String
    var set: Int
    /// Reps, or nil for a timed set.
    var reps: Int?
    /// Seconds held, or nil for a set of reps.
    var seconds: Int?
    /// In the workout's unit; nil without a weight.
    var weight: Double?
    /// False when the band could not count the reps and the set logged its target.
    var counted: Bool
    var start: Date
    var end: Date
}

struct HealthWorkout: Hashable, Sendable {
    /// Shorter sessions are not workouts: a set started by mistake, or a test of the gestures.
    static let minimumDuration: TimeInterval = 60

    /// The journal record's id, so the same session is never added twice.
    var id: String
    var name: String
    var activity: HealthActivity
    var start: Date
    /// When the last set was logged. Time spent on the finished screen is not exercise.
    var end: Date
    var unit: WeightUnit
    var sets: [HealthSet]

    var totalReps: Int { sets.reduce(0) { $0 + ($1.reps ?? 0) } }
    /// Weight times reps over every weighted set, in the workout's unit.
    var volume: Double { sets.reduce(0) { $0 + ($1.weight ?? 0) * Double($1.reps ?? 0) } }

    /// nil for a session with no logged set, or one too short to be a workout.
    init?(_ record: WorkoutRecord, unit: WeightUnit) {
        guard let last = record.sets.map(\.at).max(), last.timeIntervalSince(record.started) >= Self.minimumDuration else { return nil }
        id = record.id; name = record.name; start = record.started; end = last; self.unit = unit
        activity = HealthActivity(sets: record.sets)
        sets = record.sets.map { log in
            let timed = log.exercise.measure == .seconds
            // A set saved before its start was kept: a hold began its length ago, reps mark a moment.
            let began = log.started ?? (timed ? log.at.addingTimeInterval(-Double(log.reps)) : log.at)
            return HealthSet(exercise: log.exercise.name, set: log.slot.set,
                             reps: timed ? nil : log.reps, seconds: timed ? log.reps : nil,
                             weight: log.weight.flatMap { $0 > 0 ? $0 : nil }, counted: timed || !log.slot.assumed,
                             start: max(record.started, min(began, log.at)), end: log.at)
        }
    }
}

/// Where a journal record stands with Health.
enum HealthMark: Codable, Hashable, Sendable {
    /// Added to Health under this identifier.
    case saved(String)
    /// The last try failed; the next finished workout tries again.
    case failed
}

/// Whether Runes may add workouts to Health.
enum HealthAccess: Sendable, Hashable {
    /// This device has no Health.
    case unavailable
    case notAsked, allowed, denied
}

/// The person's choice, kept with the other workout settings.
struct HealthSettings: Codable, Hashable, Sendable {
    var on = false
    /// When it was switched on. Earlier workouts stay in Runes only.
    var since: Date?
}

extension WorkoutRecord {
    /// True when this session should be in Health and is not yet.
    func needsHealth(_ settings: HealthSettings, unit: WeightUnit) -> Bool {
        guard settings.on, let since = settings.since, ended >= since else { return false }
        if case .saved = health { return false }
        return HealthWorkout(self, unit: unit) != nil
    }
}

/// The one line Workouts shows about the last session and Health.
enum HealthStatus: Hashable, Sendable {
    case none, saving, saved, failed, tooShort

    init(last record: WorkoutRecord?, settings: HealthSettings, unit: WeightUnit) {
        guard settings.on, let since = settings.since, let record, record.ended >= since else { self = .none; return }
        switch record.health {
        case .saved: self = .saved
        case .failed: self = .failed
        case nil: self = HealthWorkout(record, unit: unit) == nil ? .tooShort : .saving
        }
    }

    var text: String {
        switch self {
        case .none: "None yet"
        case .saving: "Saving"
        case .saved: "Saved"
        case .failed: "Not saved yet"
        case .tooShort: "Too short to save"
        }
    }
}

extension WorkoutRecord {
    /// The session as plain text, one exercise to a line, for apps that take a typed routine.
    /// Health has no fields for sets and reps, so this is how they reach an app such as Bevel.
    func routineText(unit: WeightUnit) -> String {
        var lines: [(name: String, sets: [String])] = []
        for log in sets {
            var text = log.exercise.measure == .seconds ? "\(log.reps) seconds" : log.reps == 1 ? "1 rep" : "\(log.reps) reps"
            if let weight = log.weight, weight > 0 {
                let number = weight.rounded() == weight ? String(Int(weight)) : String(format: "%.1f", weight)
                text += " at \(number) \(unit.title)"
            }
            if lines.last?.name == log.exercise.name { lines[lines.count - 1].sets.append(text) }
            else { lines.append((log.exercise.name, [text])) }
        }
        return lines.map { "\($0.name): \($0.sets.joined(separator: ", "))" }.joined(separator: "\n")
    }
}
