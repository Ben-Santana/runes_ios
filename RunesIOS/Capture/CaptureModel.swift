import Foundation

// Capture: make a gesture (by default, hold a finger), say the thought, and it is written
// down as an inscription, which can be kept in a scroll. Each one keeps its sound and, once it has been transcribed on the phone, its words. These are the values; the microphone is
// CaptureRecorder, the words CaptureTranscriber, and CaptureStore ties them to the band.
// Foundation only, so it is tested without the app (Tests/CaptureTests.swift).

struct CaptureNote: Codable, Identifiable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        /// Being put into words now.
        case transcribing
        /// Has its words (possibly none, when nothing was said).
        case done
        /// Couldn't be transcribed where it was recorded; tried again when Runes is opened.
        case pending
        /// This phone can't transcribe the language it is set to.
        case unavailable
    }

    var id = UUID().uuidString.lowercased()
    var at: Date
    /// Seconds of sound.
    var duration: Double
    var text = ""
    var state = State.transcribing
    /// The sound file's name in Capture's folder.
    var file: String
    /// The loudest moment of each slice of the recording, 0...1, for the waveform.
    var peaks: [Float] = []
    /// A few words naming it, written by the on-device model or by hand.
    var title: String?
    /// The scroll it is kept in; nil while it is loose.
    var scroll: String?
    /// Who put it in its scroll, or left it loose. The model never moves one placed by hand.
    var filed: Filing?

    enum Filing: String, Codable, Sendable {
        case scribe, hand
    }

    /// What a row shows: the words, or what is happening to them.
    var summary: String {
        if !text.isEmpty { return text }
        switch state {
        case .transcribing: return "Inscribing…"
        case .pending: return "Its words arrive when you open Runes."
        case .unavailable: return "Voice inscription"
        case .done: return "Nothing was said"
        }
    }
    var hasWords: Bool { !text.isEmpty }
    /// Its title, or until it has one, its first words.
    var heading: String {
        if let title, !title.isEmpty { return title }
        return hasWords ? CaptureRules.fallbackTitle(text) : "Untitled"
    }
    /// The model may still choose a scroll for it.
    var isLoose: Bool { scroll == nil && filed != .hand }
}

/// A rune from the Elder Futhark. Each scroll is marked with one.
enum Rune: String, Codable, CaseIterable, Identifiable, Sendable {
    case fehu, uruz, thurisaz, ansuz, raidho, kenaz, gebo, wunjo
    case hagalaz, naudiz, isa, jera, eihwaz, perthro, algiz, sowilo
    case tiwaz, berkano, ehwaz, mannaz, laguz, ingwaz, dagaz, othala

    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    /// What it has stood for, in a few words.
    var meaning: String {
        switch self {
        case .fehu: "wealth, money, earnings"
        case .uruz: "strength, health, the body"
        case .thurisaz: "obstacles, defence, problems to solve"
        case .ansuz: "speech, messages, wisdom"
        case .raidho: "journeys, travel, plans in motion"
        case .kenaz: "the torch: ideas, craft, making"
        case .gebo: "gifts, partnership, generosity"
        case .wunjo: "joy, friends, comfort"
        case .hagalaz: "disruption, storms, upheaval"
        case .naudiz: "need, necessities, errands"
        case .isa: "stillness, pause, waiting"
        case .jera: "the year, harvest, seasons, routines"
        case .eihwaz: "endurance, the yew, the long view"
        case .perthro: "chance, mystery, games"
        case .algiz: "protection, care, safety"
        case .sowilo: "the sun, success, goals"
        case .tiwaz: "duty, justice, work"
        case .berkano: "growth, family, beginnings"
        case .ehwaz: "the horse, movement, teamwork"
        case .mannaz: "people, the self, others"
        case .laguz: "water, flow, dreams, feelings"
        case .ingwaz: "seeds, potential, home life"
        case .dagaz: "daybreak, change, breakthroughs"
        case .othala: "home, heritage, belongings"
        }
    }

    /// The rune's strokes in a 24 × 24 box, as polylines.
    var strokes: [[(Double, Double)]] {
        let stave = [(12.0, 3.0), (12.0, 21.0)]
        let left = [(9.0, 3.0), (9.0, 21.0)]
        switch self {
        case .fehu: return [left, [(9, 10), (16, 4)], [(9, 15), (16, 9)]]
        case .uruz: return [[(8, 21), (8, 3), (16, 9), (16, 21)]]
        case .thurisaz: return [left, [(9, 7.5), (15.5, 12), (9, 16.5)]]
        case .ansuz: return [left, [(9, 3), (16, 8)], [(9, 9), (16, 14)]]
        case .raidho: return [[(8, 21), (8, 3), (15.5, 7.5), (8, 12), (15.5, 21)]]
        case .kenaz: return [[(15.5, 5), (8.5, 12), (15.5, 19)]]
        case .gebo: return [[(7, 4), (17, 20)], [(17, 4), (7, 20)]]
        case .wunjo: return [left, [(9, 3), (15.5, 7.5), (9, 12)]]
        case .hagalaz: return [[(8, 3), (8, 21)], [(16, 3), (16, 21)], [(8, 9), (16, 15)]]
        case .naudiz: return [stave, [(8, 9), (16, 14)]]
        case .isa: return [stave]
        case .jera: return [[(11, 4), (6.5, 9), (11, 14)], [(13, 10), (17.5, 15), (13, 20)]]
        case .eihwaz: return [stave, [(12, 3), (16.5, 7)], [(12, 21), (7.5, 17)]]
        case .perthro: return [[(8, 3), (8, 21)], [(8, 3), (12.5, 8), (17, 4)], [(8, 21), (12.5, 16), (17, 20)]]
        case .algiz: return [stave, [(12, 11), (7, 4.5)], [(12, 11), (17, 4.5)]]
        case .sowilo: return [[(15, 3), (8.5, 10.5), (15.5, 13.5), (9, 21)]]
        case .tiwaz: return [stave, [(7, 8.5), (12, 3), (17, 8.5)]]
        case .berkano: return [[(8, 3), (8, 21)], [(8, 3), (15.5, 7.5), (8, 12), (15.5, 16.5), (8, 21)]]
        case .ehwaz: return [[(7, 21), (7, 3), (12, 9), (17, 3), (17, 21)]]
        case .mannaz: return [[(7, 3), (7, 21)], [(17, 3), (17, 21)], [(7, 3), (17, 11)], [(17, 3), (7, 11)]]
        case .laguz: return [left, [(9, 3), (15.5, 9.5)]]
        case .ingwaz: return [[(12, 5.5), (17.5, 12), (12, 18.5), (6.5, 12), (12, 5.5)]]
        case .dagaz: return [[(6, 4), (18, 20), (18, 4), (6, 20), (6, 4)]]
        case .othala: return [[(7, 20), (16.5, 10), (12, 3.5), (7.5, 10), (17, 20)]]
        }
    }

    /// A rune for a name nobody chose one for: always the same one for the same name.
    static func fallback(for name: String) -> Rune {
        let sum = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return allCases[sum % allCases.count]
    }
}

/// A scroll: inscriptions kept together under a name and a rune.
struct CaptureScroll: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString.lowercased()
    var name: String
    var rune: Rune
    /// What belongs in it, in the owner's words; it tells the model where inscriptions go.
    var purpose = ""
    var created = Date()
}

/// What starts a recording from the band: one gesture, or a combo of two to eight finger
/// and swipe steps. Making it again saves the recording. When it ends with a finger held
/// (a hold on its own, or a combo whose last step is one), the recording lasts as long as
/// the hold and saves when the finger lets go.
struct CaptureTrigger: Codable, Hashable, Sendable {
    var steps: [ComboStep]
    var intervalMs = ComboRules.defaultTime

    static func gesture(_ kind: GestureKind) -> CaptureTrigger { CaptureTrigger(steps: [ComboStep(kind)]) }
    /// Hold your index finger, speak, let go.
    static let standard = gesture(.holdIndex)

    var isCombo: Bool { steps.count > 1 }
    /// The gesture when this is a single one.
    var gesture: GestureKind? { isCombo ? nil : steps.first?.gesture }
    /// "Double tap index", "Swipe up, then tap and hold index".
    var name: String {
        steps.enumerated().map { $0.offset == 0 ? $0.element.name : $0.element.name.lowercased() }.joined(separator: ", then ")
    }

    /// Gestures a trigger may use on its own. Releases only make sense inside a combo.
    static let singleChoices = GestureKind.motions
    /// Steps a combo may use: finger gestures and swipes. Motion and air gestures would
    /// keep the band's motion streams on for as long as Capture waits.
    static func comboChoices(after steps: [ComboStep]) -> [GestureKind] {
        ComboRules.allowedNext(after: steps).filter { !$0.isMotion && !$0.isAir }
    }

    var isValid: Bool {
        if let gesture { return Self.singleChoices.contains(gesture) }
        return ComboRules.valid(steps) && ComboRules.times.contains(intervalMs)
            && steps.allSatisfy { !$0.gesture.isMotion && !$0.gesture.isAir }
    }

    /// The finger letting go, when the trigger ends with that finger held. That release
    /// saves the recording; without one, making the trigger again does.
    var release: GestureKind? { steps.last?.gesture.release }
    var holds: Bool { release != nil }

    /// The gestures Capture takes while it waits for the trigger; mappings that use one
    /// are off meanwhile. A double tap arrives after the tap that began it and a hold
    /// ends with a release, so those are taken with them.
    var reserved: Set<GestureKind> {
        var gestures = Set(steps.map(\.gesture))
        if gestures.contains(.doubleTapIndex) { gestures.insert(.tapIndex) }
        if gestures.contains(.doubleTapMiddle) { gestures.insert(.tapMiddle) }
        if gestures.contains(.holdIndex) { gestures.insert(.releaseIndex) }
        if gestures.contains(.holdMiddle) { gestures.insert(.releaseMiddle) }
        return gestures
    }

    static let comboID = "capture:record"
    /// The trigger as a mapping, for a `MappingEngine` that only decides when it was made.
    /// A single gesture's mapping must be named after it; the placeholder action never runs.
    var mapping: Mapping {
        if let gesture { return Mapping(id: gesture.rawValue, enabled: true, actions: [.haptic(.light)]) }
        return Mapping(id: Self.comboID, enabled: true, actions: [.haptic(.light)], steps: steps, intervalMs: intervalMs)
    }

    /// How to start, as the beginning of a sentence: "Hold your index finger", "Double tap index".
    var start: String {
        switch gesture {
        case .holdIndex: "Hold your index finger"
        case .holdMiddle: "Hold your middle finger"
        default: name
        }
    }
    /// How to save, as the end of one: "let go", "do it again".
    var stop: String { holds ? "let go" : "do it again" }
}

/// How Capture says it started or saved a note, so it can be used without looking.
enum CaptureFeedback: String, Codable, CaseIterable, Sendable {
    /// A tick when recording starts and a note when it is saved.
    case sounds
    /// The phone vibrates instead (once to start, twice when saved), and the Lock Screen
    /// shows a notification for each.
    case buzz
    case off
}

/// How Capture records: what starts it from the band, how it signals and its microphone.
struct CaptureControls: Codable, Hashable, Sendable {
    var trigger = CaptureTrigger.standard
    var feedback = CaptureFeedback.sounds
    /// Record with the headphones' microphone instead of the phone's.
    var headset = false
    /// Apple Intelligence names each inscription and files loose ones into scrolls.
    var scribe = true

    /// The gestures Capture takes while it can record; mappings that use them are off.
    var reserved: Set<GestureKind> { trigger.reserved }

    private enum Keys: String, CodingKey { case trigger, hold, sounds, feedback, headset, scribe }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let saved = try? c.decode(CaptureTrigger.self, forKey: .trigger), saved.isValid {
            trigger = saved
        } else if let hold = try? c.decode(GestureKind.self, forKey: .hold), hold.isHold {
            // Settings saved when only a hold could record.
            trigger = .gesture(hold)
        }
        if let saved = try? c.decode(CaptureFeedback.self, forKey: .feedback) {
            feedback = saved
        } else if let sounds = try? c.decode(Bool.self, forKey: .sounds) {
            // Settings saved when the cues were only sounds or nothing.
            feedback = sounds ? .sounds : .off
        }
        headset = (try? c.decode(Bool.self, forKey: .headset)) ?? false
        scribe = (try? c.decode(Bool.self, forKey: .scribe)) ?? true
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(feedback, forKey: .feedback)
        try c.encode(headset, forKey: .headset)
        try c.encode(scribe, forKey: .scribe)
    }
}

enum CaptureRules {
    /// A hold shorter than this was a slip, not a note.
    static let minimum = 0.6
    /// A hold whose release never arrives (the band went out of range) stops here.
    static let maximum = 300.0
    /// Sound kept from just before the hold was recognised, so the first word isn't cut.
    static let preroll = 0.8
    /// Bars in a note's waveform.
    static let bars = 56

    /// "0:07", "12:30".
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The first words of a note, for the Lock Screen.
    static func snippet(_ text: String, limit: Int = 90) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > limit ? line.prefix(limit).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// A title from the words alone, for phones without the on-device model: the first
    /// clause, cut to six words, without its closing punctuation.
    static func fallbackTitle(_ text: String, words limit: Int = 6) -> String {
        let clause = text.split(whereSeparator: { ".!?\n;:".contains($0) }).first.map(String.init) ?? text
        let words = clause.split(whereSeparator: \.isWhitespace)
        var title = words.prefix(limit).joined(separator: " ").trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        if words.count > limit { title += "…" }
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    /// A title as the model wrote it, tidied: one line, no quotes, no closing full stop, at most 60 characters.
    static func cleanTitle(_ raw: String) -> String? {
        var title = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’*#").union(.whitespaces))
        while title.hasSuffix(".") { title.removeLast() }
        if title.count > 60 { title = String(title.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" }
        return title.isEmpty ? nil : title.prefix(1).uppercased() + title.dropFirst()
    }

    /// Any number of peaks as `bars` bars, each the loudest of its share, scaled so the
    /// loudest bar is full height and silence still shows as a dot.
    static func waveform(_ peaks: [Float], bars: Int = bars) -> [Float] {
        guard bars > 0 else { return [] }
        guard !peaks.isEmpty else { return Array(repeating: 0.04, count: bars) }
        var result: [Float] = []
        for bar in 0..<bars {
            let from = bar * peaks.count / bars, to = max(from + 1, (bar + 1) * peaks.count / bars)
            result.append(peaks[min(from, peaks.count - 1)..<min(to, peaks.count)].max() ?? 0)
        }
        let top = max(result.max() ?? 0, 0.02)
        return result.map { max(0.04, min(1, $0 / top)) }
    }

    /// A microphone level (0...1 linear) as something to draw: quiet speech still moves it.
    static func meter(_ level: Float) -> Double {
        guard level > 0.0005 else { return 0 }
        let decibels = 20 * log10(Double(level))
        return min(1, max(0, (decibels + 50) / 50))
    }
}

/// Notes grouped by the day they were taken, newest first.
struct CaptureDay: Identifiable, Hashable, Sendable {
    var id: String { title }
    var title: String
    var notes: [CaptureNote]

    static func group(_ notes: [CaptureNote], now: Date = Date(), calendar: Calendar = .current) -> [CaptureDay] {
        let today = calendar.startOfDay(for: now)
        var days: [CaptureDay] = []
        var starts: [Date] = []
        for note in notes.sorted(by: { $0.at > $1.at }) {
            let start = calendar.startOfDay(for: note.at)
            if let index = starts.firstIndex(of: start) { days[index].notes.append(note); continue }
            let ago = calendar.dateComponents([.day], from: start, to: today).day ?? 0
            let title: String
            switch ago {
            case ..<1: title = "Today"
            case 1: title = "Yesterday"
            case 2..<7: title = start.formatted(.dateTime.weekday(.wide))
            default: title = start.formatted(.dateTime.day().month(.wide))
            }
            starts.append(start); days.append(CaptureDay(title: title, notes: [note]))
        }
        return days
    }

    /// Notes taken on the same day as `now`.
    static func today(_ notes: [CaptureNote], now: Date = Date(), calendar: Calendar = .current) -> Int {
        notes.filter { calendar.isDate($0.at, inSameDayAs: now) }.count
    }
}
