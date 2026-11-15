import Foundation

/// How an alarm vibrates the band, ordered from the softest to the most insistent.
enum AlarmStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case tide, heartbeat, metronome, restless, staccato, siren

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tide: "Tide"
        case .heartbeat: "Heartbeat"
        case .metronome: "Metronome"
        case .restless: "Restless"
        case .staccato: "Staccato"
        case .siren: "Siren"
        }
    }

    var detail: String {
        switch self {
        case .tide: "Slow swells with long quiet between them."
        case .heartbeat: "A steady lub-dub, every couple of seconds."
        case .metronome: "Even beats, like a clock you can feel."
        case .restless: "Uneven taps and buzzes that never settle into a rhythm."
        case .staccato: "Quick, sharp bursts close together."
        case .siren: "Long, nearly continuous buzzing."
        }
    }

    /// 1 is gentle, 5 is hardest to sleep through.
    var aggression: Int {
        switch self {
        case .tide: 1
        case .heartbeat: 2
        case .metronome: 3
        case .restless: 3
        case .staccato: 4
        case .siren: 5
        }
    }

    /// Stillness after each round, in milliseconds.
    var rest: UInt64 {
        switch self {
        case .tide: 3500
        case .heartbeat: 1400
        case .metronome: 900
        case .restless: 400
        case .staccato: 700
        case .siren: 300
        }
    }

    /// One round of the pattern at full strength (`level` 0...1 scales the motor).
    /// `round` seeds the irregular style, so each round differs but stays reproducible.
    func pulses(level: Double, round: Int) -> [BandPulse] {
        func p(_ duration: UInt64, _ relative: Double, gap: UInt64 = 0) -> BandPulse {
            BandPulse(duration: duration, amplitude: AlarmStyle.amplitude(relative * level), gap: gap)
        }
        switch self {
        case .tide:
            return [p(160, 0.45, gap: 60), p(200, 0.7, gap: 60), p(280, 1, gap: 80), p(200, 0.6)]
        case .heartbeat:
            return [p(70, 0.75, gap: 110), p(140, 1)]
        case .metronome:
            return Array(repeating: p(150, 1, gap: 350), count: 3) + [p(150, 1)]
        case .restless:
            var rng = SeededRandom(seed: UInt64(round) &* 0x9E37_79B9_7F4A_7C15 &+ 1)
            let count = Int.random(in: 4...8, using: &rng)
            return (0..<count).map { _ in
                p(UInt64.random(in: 40...320, using: &rng), Double.random(in: 0.55...1, using: &rng),
                  gap: UInt64.random(in: 70...900, using: &rng))
            }
        case .staccato:
            return Array(repeating: p(55, 1, gap: 65), count: 8)
        case .siren:
            return Array(repeating: p(480, 1, gap: 70), count: 4)
        }
    }

    /// Milliseconds one round takes, pulses, gaps and the rest after it.
    func roundLength(level: Double, round: Int) -> UInt64 {
        pulses(level: level, round: round).reduce(rest) { $0 + $1.duration + $1.gap }
    }

    /// The band barely registers below ~70, so the scale starts there.
    static func amplitude(_ relative: Double) -> UInt64 {
        UInt64((70 + 185 * min(max(relative, 0), 1)).rounded())
    }
}

/// Strength chosen on a five-step scale.
enum AlarmStrength {
    static let range = 1...5
    static func level(_ step: Int) -> Double { 0.2 + 0.2 * Double(min(max(step, 1), 5) - 1) }
    static func title(_ step: Int) -> String {
        ["Whisper", "Soft", "Medium", "Strong", "Maximum"][min(max(step, 1), 5) - 1]
    }

    /// With ramping on, strength starts two steps lower (never below 1) and climbs one step
    /// a minute to the chosen strength.
    static func level(step: Int, ramp: Bool, elapsed: TimeInterval) -> Double {
        guard ramp else { return level(step) }
        let start = max(step - 2, 1)
        return level(min(step, start + Int(elapsed / 60)))
    }
}

struct Alarm: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var hour = 7
    var minute = 0
    /// Calendar weekdays (1 = Sunday). Empty rings once, at the next matching time.
    var days: Set<Int> = []
    var enabled = true
    var label = ""
    var style: AlarmStyle = .heartbeat
    var strength = 3
    var ramp = true
    /// 0 turns snoozing off: then the snooze gesture, or opening the Live Activity, stops it.
    var snoozeMinutes = 9
    var canSnooze: Bool { snoozeMinutes > 0 }
    /// A phone notification with sound a minute later, in case the band didn't wake you.
    var phoneBackup = false

    var timeText: String { String(format: "%d:%02d", hour, minute) }

    var repeatText: String {
        if days.isEmpty { return "Once" }
        if days.count == 7 { return "Every day" }
        if days == [2, 3, 4, 5, 6] { return "Weekdays" }
        if days == [1, 7] { return "Weekends" }
        let names = Calendar.current.shortWeekdaySymbols
        return days.sorted().map { names[$0 - 1] }.joined(separator: " ")
    }

    /// The next moment this alarm rings, strictly after `date`.
    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        var parts = DateComponents(); parts.hour = hour; parts.minute = minute; parts.second = 0
        if days.isEmpty { return calendar.nextDate(after: date, matching: parts, matchingPolicy: .nextTime) }
        return days.compactMap { day -> Date? in
            var p = parts; p.weekday = day
            return calendar.nextDate(after: date, matching: p, matchingPolicy: .nextTime)
        }.min()
    }
}

/// SplitMix64, so the irregular rhythm is the same on every run of the same round.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// What the band can do to a ringing alarm.
enum AlarmCommand: String, Codable, CaseIterable, Identifiable, Sendable {
    case snooze, stop
    var id: String { rawValue }
    var title: String { self == .snooze ? "Snooze" : "Stop" }
    var detail: String {
        self == .snooze ? "Snoozes a ringing alarm; stops one with snooze off." : "Stops a ringing or snoozed alarm."
    }
}

/// Which gesture or combo snoozes or stops an alarm. Both start unset.
struct AlarmControls: Codable, Hashable, Sendable {
    var triggers: [AlarmCommand: CommandTrigger] = [:]
    private static let mappingPrefix = "alarm:"

    /// Finger gestures, swipes and combos of them; motion steps would need the band's
    /// motion streams running all night.
    static var rules: TriggerRules {
        .gestureOrCombo(GestureKind.motions, next: { ComboRules.allowedNext(after: $0).filter { !$0.isMotion && !$0.isAir } }, allowsNone: true)
    }

    func trigger(for command: AlarmCommand) -> CommandTrigger? { triggers[command] }
    func gesture(for command: AlarmCommand) -> GestureKind? { triggers[command]?.gesture }
    mutating func setTrigger(_ trigger: CommandTrigger?, for command: AlarmCommand) { triggers.assign(trigger, to: command) }
    var reserved: Set<GestureKind> { triggers.reserved }
    var mappings: [Mapping] { triggers.mappings(prefix: Self.mappingPrefix) }
    func command(forMapping id: String) -> AlarmCommand? { triggers.command(forMapping: id, prefix: Self.mappingPrefix) }
    var isEmpty: Bool { !triggers.values.contains(where: \.isValid) }

    init() {}
    private enum Keys: String, CodingKey { case triggers }
    init(from decoder: Decoder) throws {
        triggers = Dictionary(saved: try decoder.container(keyedBy: Keys.self).decode([String: CommandTrigger].self, forKey: .triggers))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(triggers.saved, forKey: .triggers)
    }
}
