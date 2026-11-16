import Foundation

struct SessionSnapshot: Sendable {
    var state: SessionState = .disconnected
    /// Journal wording. The interface shows `issue` and the state instead.
    var message = "Select your band to connect."
    var issue: SessionIssue?
    var devices: [BandDevice] = []
    var selected: UUID?
    var events: [GestureEvent] = []
    var eventCount = 0
    var startedAt: Date?
    var journalError: String?
    var connectionAttempt = ConnectionAttempt()
    var wantsConnection = false
    var identityChoices: [IdentityChoice] = []
    var identityAccount: UUID?
    var identityFingerprint: String?
    var battery: Int?
    /// Whether the band is set to stay quiet on gestures, which leaves the buzz to Runes. Nil until the band has said.
    var bandQuietOnGestures: Bool?
    var handSetting = HandSetting()
    var hand: Handedness? {
        get { handSetting.confirmed }
        set { handSetting.confirmed = newValue }
    }
    var bluetoothReady = false
    /// The latest physical gesture, one per tap, double tap, hold or swipe.
    var lastGesture: BandGesture?
    /// Physical gestures this session. A double tap upgrades the tap before it, so it is not counted twice.
    var gestureTotal = 0
    /// True once a usable identity exists for the selected band.
    var isSetUp: Bool { selected != nil && identityChoices.contains { $0.eligible && !$0.pending } }
}

struct BandDevice: Identifiable, Sendable {
    let id: UUID
    var name: String
    var rssi: Int?
}

enum SessionState: String, Sendable {
    case disconnected, disconnecting, scanning, connecting, enrollmentRequired, enrolling, authenticating, subscribing, streaming, reconnecting, failed
    var title: String {
        switch self {
        case .enrollmentRequired: return "Choose an identity"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

struct ReceiptContext: Codable, Sendable {
    let wallTime: Date
    let uptime: TimeInterval
    let applicationState: String
}

enum ConnectionStep: String, CaseIterable, Sendable {
    case connecting = "Connecting to band"
    case channelOpen = "Bluetooth channel open"
    case encryption = "Starting encryption"
    case encrypted = "Encryption established"
    case enrollment = "Ownership setup"
    case trust = "Verifying identity"
    case trusted = "Phone identity accepted"
    case subscribing = "Starting gestures"
    case ready = "Ready for gestures"
}

struct ConnectionFailure: Equatable, Sendable {
    enum Kind: Sendable { case identityMismatch, signatureRejected, unknownRejection, invalidBandProof, setupRejected, timeout, authentication, bluetooth, pairing, protocolResponse, storage, cancelled }
    let kind: Kind
    let result: UInt32?
    let channel: UInt16?

    init(_ error: BandError) {
        var result: UInt32?, channel: UInt16?
        switch error {
        case .trust(.rejected(let value, let source)):
            result = value; channel = source
            switch value {
            case 0x03001043: kind = .identityMismatch
            case 0x03001044: kind = .signatureRejected
            default: kind = .unknownRejection
            }
        case .trust(.invalidBandProof): kind = .invalidBandProof
        case .setupRejected(let value, let source): kind = .setupRejected; result = value; channel = source
        case .timeout: kind = .timeout
        case .authentication: kind = .authentication
        case .transport: kind = .bluetooth
        case .pairing: kind = .pairing
        case .wire: kind = .protocolResponse
        case .storage: kind = .storage
        case .cancelled: kind = .cancelled
        }
        self.result = result; self.channel = channel
    }

    var title: String {
        switch kind {
        case .identityMismatch: "Saved identity rejected"
        case .signatureRejected: "Phone signature rejected"
        case .unknownRejection: "Unknown authentication rejection"
        case .invalidBandProof: "Band identity verification failed"
        case .setupRejected: "Band setup rejected"
        case .timeout: "Response timed out"
        case .authentication: "Authentication failed"
        case .bluetooth: "Bluetooth connection failed"
        case .pairing: "Bluetooth pairing changed"
        case .protocolResponse: "Unexpected protocol response"
        case .storage: "Saved setup unavailable"
        case .cancelled: "Cancelled"
        }
    }

    var detail: String {
        switch kind {
        case .identityMismatch: "The band does not accept this phone’s saved identity. Import a setup that still works, or deliberately set up ownership again."
        case .signatureRejected: "The band rejected this phone’s authentication signature. This does not establish that ownership changed."
        case .unknownRejection: "The meaning of this result is not known. Saved setup was retained."
        case .invalidBandProof: "The band’s proof did not match its saved key. Check the selected setup before changing ownership."
        case .setupRejected: "The band refused setup. This result does not establish an owner identity mismatch."
        case .timeout: "The band did not complete this step in time. A timeout does not establish an identity mismatch."
        default: "See the existing journal for more detail."
        }
    }
}

struct ConnectionAttempt: Sendable {
    enum Outcome: Sendable { case connecting, ready, failed, stopped }
    private(set) var startedAt: Date?
    private(set) var steps: [ConnectionStep] = []
    private(set) var failure: ConnectionFailure?
    private(set) var outcome = Outcome.connecting

    mutating func begin(at date: Date = Date()) {
        startedAt = date; steps = [.connecting]; failure = nil; outcome = .connecting
    }
    mutating func reach(_ step: ConnectionStep) {
        guard startedAt != nil, outcome != .failed, outcome != .stopped else { return }
        if !steps.contains(step) { steps.append(step) }
        if step == .ready { outcome = .ready; failure = nil }
    }
    mutating func observeProtocolStage(_ stage: String?) {
        switch stage {
        case "ceremony": reach(.encrypted); reach(.enrollment)
        case "trust", "device_info", "ready":
            reach(.encrypted); reach(.trust)
            if stage != "trust" { reach(.trusted) }
        default: break
        }
    }
    mutating func fail(_ error: BandError) {
        guard startedAt != nil else { return }
        failure = ConnectionFailure(error); outcome = .failed
    }
    mutating func stop() {
        if startedAt != nil, outcome != .failed { outcome = .stopped }
    }
}

struct GestureEvent: Identifiable, Codable, Sendable {
    let id: UUID
    let sessionID: UUID
    let fingerCode: UInt64
    let actionCode: UInt64
    let derivedActionCode: UInt64
    let synthetic: Bool
    let sequence: UInt64
    let deviceTimestamp: UInt64
    let received: ReceiptContext
    var sourceClock: String { "gesture-device-clock" }
    var finger: String { Self.label(fingerCode, ["unknown", "thumb", "index", "middle", "not applicable"]) }
    var action: String { Self.label(actionCode, Self.actions) }
    var derivedAction: String { Self.label(derivedActionCode, Self.derived) }
    var title: String { "\(finger.capitalized) · \(actionCode == 0 && derivedActionCode != 0 ? derivedAction : action)" }
    var layer: String { actionCode != 0 && derivedActionCode != 0 ? "Both layers" : (derivedActionCode != 0 ? "Derived interaction" : "Raw gesture") }
    static let actions = ["unknown", "press", "release", "tap", "doubletap", "click", "up", "down", "left", "right", "wake", "swipeIn", "swipeOut", "ia", "partialPress", "partialRelease", "partialClick", "partialUp", "partialDown", "partialLeft", "partialRight"]
    static let derived = ["unknown", "singleTap", "doubleTap", "buttonHold", "buttonRelease", "buttonUp", "buttonDown", "buttonLeft", "buttonRight", "buttonPress", "buttonHoldRelease"]
    static func label(_ code: UInt64, _ labels: [String]) -> String { code < labels.count ? labels[Int(code)] : "unknown:\(code)" }
}

struct BandIdentity: Codable {
    let privateKey: Data
    var bandPoint: Data?
    var stage: String
    var allowMissingBandKey: Bool? = nil
    var canAuthenticate: Bool { bandPoint != nil || allowMissingBandKey == true }
}

/// The band numbers raw gestures (press, release, tap…) and derived interactions
/// (single tap, hold…) with two independent counters. Comparing one counter
/// against the other made every interleaved packet look like a gap.
enum GestureStream: String, Sendable { case raw, derived }

extension GestureEvent {
    var stream: GestureStream { actionCode != 0 ? .raw : .derived }
    var isIndexFinger: Bool { fingerCode == 2 }
    /// Plain words for the interface, e.g. "Index tap".
    var plainTitle: String {
        let finger = fingerCode < 4 && fingerCode > 0 ? ["", "Thumb", "Index", "Middle"][Int(fingerCode)] : "Band"
        let words: [UInt64: String] = derivedActionCode != 0
            ? [1: "tap", 2: "double tap", 3: "hold", 4: "release", 5: "up", 6: "down", 7: "left", 8: "right", 9: "press", 10: "release"]
            : [1: "press", 2: "release", 3: "tap", 4: "double tap", 5: "click", 6: "up", 7: "down", 8: "left", 9: "right", 10: "wake", 11: "swipe in", 12: "swipe out"]
        let code = derivedActionCode != 0 ? derivedActionCode : actionCode
        return "\(finger) \(words[code] ?? "gesture")"
    }
}

struct SequenceTracker: Sendable {
    private var last: [GestureStream: UInt64] = [:]
    mutating func reset() { last = [:] }
    /// Returns the previous sequence number when `sequence` does not directly follow it on its own stream.
    mutating func gap(_ sequence: UInt64, stream: GestureStream) -> UInt64? {
        defer { last[stream] = sequence }
        guard let previous = last[stream] else { return nil }
        return sequence == (previous &+ 1) & 0xffffffff ? nil : previous
    }
}

enum Handedness: String, Sendable {
    case left, right
    var configuration: Data { PB.field(10, self == .left ? 1 : 0) }
    static func read(_ payload: Data) -> Self? {
        guard let config = try? Fields(Fields(payload).bytes(6)), let value = try? config.integer(10), value <= 1 else { return nil }
        return value == 1 ? .left : .right
    }
}

struct HandSetting: Equatable, Sendable {
    enum Request: Equatable, Sendable { case read, write(Handedness), verify(Handedness) }
    var confirmed: Handedness?
    private(set) var pending: Request?
    private(set) var error: String?
    private(set) var changeID: UUID?
    var busy: Bool { pending != nil }
    var confirmedChangeID: UUID? { !busy && confirmed != nil && error == nil ? changeID : nil }
    init(confirmed: Handedness? = nil) { self.confirmed = confirmed }

    mutating func read() -> Bool {
        guard !busy else { return false }
        pending = .read; confirmed = nil; error = nil; changeID = nil; return true
    }
    mutating func change(to hand: Handedness) -> Bool {
        guard !busy else { return false }
        pending = .write(hand); confirmed = nil; error = nil; changeID = UUID(); return true
    }
    mutating func wrote() -> Bool {
        guard case .write(let hand) = pending else { return false }
        pending = .verify(hand); return true
    }
    mutating func received(_ hand: Handedness?) -> Bool {
        switch pending { case .read, .verify: break; default: return false }
        guard let hand else { fail("The band did not report a valid wrist setting."); return false }
        if case .verify(let requested) = pending, requested != hand {
            error = "The band kept its \(hand.rawValue) wrist setting. Try again."
        } else { error = nil }
        confirmed = hand; pending = nil; return true
    }
    mutating func fail(_ message: String) { confirmed = nil; pending = nil; error = message; changeID = nil }
    mutating func cancel() {
        if busy { confirmed = nil; error = "The wrist setting was not confirmed. Reconnect to check it." }
        pending = nil; changeID = nil
    }
}

enum WristFeedbackPhase: String, CaseIterable, Sendable {
    case wrap, settle
    var duration: UInt64 { self == .wrap ? 70 : 100 }
    var amplitude: UInt64 { self == .wrap ? 200 : 230 }
    var payload: Data { PB.field(1, PB.field(1, duration) + PB.field(3, amplitude)) }
}

/// One motor pulse on the band: the same `wrist_feedback` request the wrist setup uses.
/// The band runs one pulse per request and answers before taking the next, so a pattern
/// is a list of pulses, each started `gap` ms after the previous one ends (or once the
/// band answers, if that is later).
struct BandPulse: Hashable, Sendable {
    /// Milliseconds the motor runs.
    var duration: UInt64
    /// Motor strength, up to 255.
    var amplitude: UInt64
    /// Milliseconds of stillness before the next pulse.
    var gap: UInt64 = 0
    var payload: Data { PB.field(1, PB.field(1, duration) + PB.field(3, min(amplitude, 255))) }
}

extension BandPulse {
    /// Milliseconds from this pulse starting to the next one starting.
    var span: UInt64 { duration + gap }
    /// Motor strength as 0…1.
    var strength: Double { Double(min(amplitude, 255)) / 255 }
}

extension Array where Element == BandPulse {
    /// Planned length of a pattern in milliseconds.
    var milliseconds: UInt64 { reduce(0) { $0 + $1.span } }
}

extension BandPulse {
    /// The Vibration lab's drawing pad spans `sketchSlots` slots of `sketchSlot` ms.
    static let sketchSlot = 100.0
    static let sketchSlots = 20
    /// Drawn quieter than this, a slot is a pause rather than a pulse.
    static let sketchFloor: UInt64 = 25

    /// A drawing (x 0…1 across the pad, y 0…1 strength) as pulses: each slot plays for most
    /// of its time at the average height drawn in it; quiet or empty slots lengthen the pause.
    static func sketch(_ points: [(x: Double, y: Double)]) -> [BandPulse] {
        var pulses: [BandPulse] = []
        for slot in 0..<sketchSlots {
            let heights = points.filter { min(sketchSlots - 1, max(0, Int($0.x * Double(sketchSlots)))) == slot }
                .map { min(1, max(0, $0.y)) }
            let amplitude = heights.isEmpty ? 0 : UInt64((heights.reduce(0, +) / Double(heights.count) * 255).rounded())
            if amplitude < sketchFloor {
                if !pulses.isEmpty { pulses[pulses.count - 1].gap += UInt64(sketchSlot) }
            } else {
                pulses.append(BandPulse(duration: UInt64(sketchSlot * 0.8), amplitude: amplitude, gap: UInt64(sketchSlot * 0.2)))
            }
        }
        return pulses
    }

    /// The Vibration lab's ring as pulses: each lit step plays for most of `stepLength` ms at
    /// its strength, and unlit steps lengthen the pause. Each pulse keeps the step it came from.
    static func loop(steps: [UInt64], stepLength: UInt64, laps: Int) -> [(pulse: BandPulse, step: Int)] {
        var played: [(pulse: BandPulse, step: Int)] = []
        for _ in 0..<max(1, laps) {
            for (step, strength) in steps.enumerated() {
                if strength == 0 {
                    if !played.isEmpty { played[played.count - 1].pulse.gap += stepLength }
                } else {
                    let on = stepLength * 6 / 10
                    played.append((BandPulse(duration: on, amplitude: min(strength, 255), gap: stepLength - on), step))
                }
            }
        }
        return played
    }
}

/// The vibration patterns the band can play, offered beside the sounds in the library.
enum BandBuzz: String, Codable, CaseIterable, Sendable {
    case buzz, tap, double, triple, long, heartbeat, rise, fade, flutter

    var label: String {
        switch self {
        case .buzz: "Buzz"
        case .tap: "Light tap"
        case .double: "Double buzz"
        case .triple: "Triple buzz"
        case .long: "Long buzz"
        case .heartbeat: "Heartbeat"
        case .rise: "Rising"
        case .fade: "Fading"
        case .flutter: "Flutter"
        }
    }

    var pulses: [BandPulse] {
        switch self {
        case .buzz: [BandPulse(duration: 120, amplitude: 230)]
        case .tap: [BandPulse(duration: 50, amplitude: 170)]
        case .double: [BandPulse(duration: 90, amplitude: 230, gap: 120), BandPulse(duration: 90, amplitude: 230)]
        case .triple: Array(repeating: BandPulse(duration: 70, amplitude: 230, gap: 110), count: 3)
        case .long: [BandPulse(duration: 450, amplitude: 240)]
        case .heartbeat: [BandPulse(duration: 60, amplitude: 190, gap: 90), BandPulse(duration: 110, amplitude: 245)]
        case .rise: [120, 180, 245].map { BandPulse(duration: 80, amplitude: $0, gap: 100) }
        case .fade: [245, 180, 120].map { BandPulse(duration: 80, amplitude: $0, gap: 100) }
        case .flutter: Array(repeating: BandPulse(duration: 40, amplitude: 210, gap: 60), count: 5)
        }
    }
}

/// What the band reports of its own settings, written out to find ones the app does not
/// know yet. Numbers only: each field with its value, a nested message as its own fields,
/// and any other bytes as a length, so no name or identifier is written down.
enum BandSettings {
    static func describe(_ payload: Data) -> String? {
        guard let config = try? Fields(Fields(payload).bytes(6)) else { return nil }
        return describe(config, depth: 0)
    }

    /// The band's haptics setting from the settings it reports on connecting: 3 when it buzzes
    /// by itself on gestures, 2 when it stays quiet on them, 1 when its motor is off.
    static func haptics(_ payload: Data) -> UInt64? {
        guard let config = try? Fields(Fields(payload).bytes(6)) else { return nil }
        return try? config.integer(11)
    }

    /// A text field cut to 80 plain characters, or nil when it is absent or empty.
    static func text(_ fields: Fields, _ number: Int) -> String? {
        guard let raw = try? fields.bytes(number) else { return nil }
        let text = plain(raw)
        return text.isEmpty ? nil : text
    }
    static func plain(_ raw: Data) -> String {
        String(decoding: raw.prefix(80), as: UTF8.self).filter { $0.isLetter || $0.isNumber || "-_.,:/()% ".contains($0) }
    }

    static func describe(_ fields: Fields, depth: Int) -> String {
        fields.values.keys.sorted().flatMap { number in
            (fields.values[number] ?? []).map { value in
                switch value {
                case .integer(let integer): return "\(number)=\(integer)"
                case .bytes(let wire, let data):
                    guard wire == 2 else { return "\(number)=fixed(\(data.count))" }
                    if depth < 2, !data.isEmpty, let inner = try? Fields(data) { return "\(number)={\(describe(inner, depth: depth + 1))}" }
                    return "\(number)=bytes(\(data.count))"
                }
            }
        }.joined(separator: " ")
    }
}

/// What the band says about itself when it connects, kept to what describes its software:
/// revisions, release branch, protocol, models and whether it offers handwriting. Its serial
/// number and anything else that names one band are left out.
enum BandInfo {
    static func describe(_ reply: Data) -> String? {
        guard let info = try? Fields(Fields(reply).bytes(4)) else { return nil }
        var parts: [String] = []
        for (number, label) in [(2, "firmware"), (3, "software"), (4, "hardware"), (13, "branch"), (9, "model")] {
            if let text = BandSettings.text(info, number) { parts.append("\(label) \(text)") }
        }
        if let version = try? info.integer(15) { parts.append("protocol \(version)") }
        if (try? info.integer(11)) == 1 { parts.append("restart wanted: \(BandSettings.text(info, 12) ?? "no reason given")") }
        for (number, label) in [(10, "models"), (18, "trial models")] {
            let names = (info.values[number] ?? []).compactMap { value -> String? in
                if case .bytes(2, let data) = value { return BandSettings.plain(data) } else { return nil }
            }
            if !names.isEmpty { parts.append("\(label) \(names.joined(separator: ", "))") }
        }
        if let writing = try? Fields(Fields(info.bytes(19)).bytes(1)) {
            parts.append("handwriting {\(BandSettings.describe(writing, depth: 0))}")
        } else {
            parts.append("handwriting not listed")
        }
        return parts.joined(separator: "; ")
    }
}

/// The band's own list of settings, which it can name. Each is asked for by its place in the
/// list, described, and then read. Whole numbers can also be written, and are read back after.
enum NamedSettings {
    static let channel: UInt16 = 1, field = 14
    /// The list the band is asked for. Every number tried returned the same list; 2 is the one the Mac app uses.
    private static let list: UInt64 = 2

    /// One setting as the band describes and reports it.
    struct Setting: Equatable, Sendable {
        let id: UInt64
        let name: String
        /// The lowest and highest value the band says it takes, when it says.
        var range: ClosedRange<UInt64>?
        /// The field of the answer its value came in, which tells its kind: 4 a whole number, 8 a yes or no.
        var kind: Int?
        var value: UInt64?
        /// What else the band says about it: its title, what it is for, the names of its
        /// choices and of anything it takes when it is an action.
        var detail = ""
        /// Whether a new value can be written: only whole numbers, and only once one has been read.
        var writable: Bool { kind == 4 && value != nil }
    }

    static func count() -> Data { PB.field(1, PB.field(1, list)) }
    /// Places run from 1. The Mac app notes that asking for place 0 can close the band's connection.
    static func describe(index: UInt64) -> Data { PB.field(2, PB.field(1, list) + PB.field(2, max(1, index))) }
    static func read(id: UInt64) -> Data { PB.field(3, PB.field(1, id) + PB.field(2, 0)) }
    /// Writes a whole number. A value read in field 4 is written in field 3.
    static func write(id: UInt64, value: UInt64) -> Data { PB.field(3, PB.field(1, id) + PB.field(2, 1) + PB.field(3, PB.field(1, value))) }

    /// How many settings the band holds, from the answer to `count`. Nil for no answer, a refusal or a count that cannot be right.
    static func count(from reply: Data) -> UInt64? {
        guard let inner = part(1, of: reply), let count = try? inner.integer(1), count > 0, count < 256 else { return nil }
        return count
    }
    /// A setting's number, name and range, from the answer to `describe`. The name is cut to 48 plain characters.
    static func setting(from reply: Data) -> Setting? {
        guard let info = part(2, of: reply), let id = try? info.integer(4), let raw = try? info.bytes(3) else { return nil }
        let name = String(decoding: raw.prefix(48), as: UTF8.self).filter { $0.isLetter || $0.isNumber || "-_. ".contains($0) }
        var range: ClosedRange<UInt64>?
        if let bounds = try? Fields(info.bytes(7)) {
            let low = (try? bounds.integer(2)) ?? 0
            if let high = try? bounds.integer(3), high >= low { range = low...high }
        }
        var detail: [String] = []
        if let title = BandSettings.text(info, 1), title != name { detail.append(title) }
        if let purpose = BandSettings.text(info, 2) { detail.append(purpose) }
        if let choices = try? Fields(info.bytes(15)) {
            let names = (choices.values[1] ?? []).compactMap { value -> String? in
                guard case .bytes(2, let data) = value, let choice = try? Fields(data) else { return nil }
                return "\((try? choice.integer(2, default: 0)) ?? 0) \(BandSettings.text(choice, 1) ?? "unnamed")"
            }
            detail.append("choices: " + names.joined(separator: ", "))
        }
        let takes = (info.values[13] ?? []).compactMap { value -> String? in
            guard case .bytes(2, let data) = value, let argument = try? Fields(data) else { return nil }
            let kind = [2: "whole number", 3: "decimal", 4: "yes or no", 5: "large number"].first { argument.values[$0.key] != nil }?.value ?? "unknown kind"
            return "\(BandSettings.text(argument, 1) ?? "unnamed") (\(kind))"
        }
        if !takes.isEmpty { detail.append("takes: " + takes.joined(separator: ", ")) }
        if info.values[17] != nil { detail.append("takes nothing") }
        return Setting(id: id, name: name, range: range, detail: detail.joined(separator: "; "))
    }
    /// A setting's value, from the answer to `read` or to a `write`: its kind and number when it is a
    /// single value, and all of it written as numbers (`BandSettings`). Nil when the band refused.
    static func value(of id: UInt64, from reply: Data) -> (kind: Int?, value: UInt64?, text: String)? {
        guard let result = part(3, of: reply), (try? result.integer(1)) == id, result.values[3] == nil else { return nil }
        let kinds = (4...11).filter { result.values[$0] != nil }
        var value: UInt64?
        if kinds.count == 1, let wrapper = try? Fields(result.bytes(kinds[0])) {
            value = wrapper.values[1] == nil ? 0 : try? wrapper.integer(1)
        }
        return (kinds.count == 1 ? kinds[0] : nil, value, BandSettings.describe(result, depth: 0))
    }

    private static func part(_ number: Int, of reply: Data) -> Fields? {
        guard let fields = try? Fields(reply), (try? fields.integer(2)) == 1 else { return nil }
        return try? Fields(Fields(fields.bytes(field)).bytes(number))
    }
}

/// Requests the band is known to understand from its published message definitions, which
/// the app does not rely on yet. Each is tried from the Band tests page.
enum BandTrial {
    /// The channel the named settings use, which the band is known to answer on.
    static let channel: UInt16 = 1
    /// Tells the band a gesture arrived, as the Meta app does for each one: the gesture's
    /// sequence number, the kind of app (2, a phone app) and the link (0, direct).
    static func acknowledge(gesture sequence: UInt64) -> Data { PB.field(1, sequence) + PB.field(2, 2) + PB.field(3, 0) }
    /// A vibration the band stores under `name` and plays itself: each pulse is a segment of
    /// duration and strength, and a gap is a segment of no strength. Sent as a haptics request.
    static func pattern(named name: String, _ pulses: [BandPulse], play: Bool = true) -> Data {
        let segments = pulses.flatMap { pulse -> [Data] in
            let on = PB.field(2, PB.field(1, pulse.duration) + PB.field(2, min(pulse.amplitude, 255)))
            return pulse.gap > 0 ? [on, PB.field(2, PB.field(1, pulse.gap) + PB.field(2, 0))] : [on]
        }
        let pattern = segments.reduce(PB.field(1, Data(name.utf8)), +)
        return PB.field(4, PB.field(1, pattern) + PB.field(2, play ? 1 : 0))
    }
    /// Stops whatever the band's motor is playing. Sent as a haptics request.
    static let stop = PB.field(3, Data())
    /// Asks which firmware is running and whether an update is waiting. Sent as an update request; it changes nothing.
    static let firmwareStatus = PB.field(1, Data())
}

extension BandGesture.Kind {
    /// What Runes plays on the band in answer to this gesture, in place of the buzz the band
    /// gives by itself. All but the end of a hold are at full strength and differ in length:
    /// a tap, which a double tap repeats, a longer one as a hold begins, one in between for
    /// a swipe, and a softer, shorter one as a hold ends.
    var answer: [BandPulse] {
        switch self {
        case .tap, .doubleTap: [BandPulse(duration: 70, amplitude: 255)]
        case .holdBegan: [BandPulse(duration: 130, amplitude: 255)]
        case .holdEnded: [BandPulse(duration: 50, amplitude: 220)]
        case .swipe: [BandPulse(duration: 95, amplitude: 255)]
        }
    }
}

enum WristFeedbackResult: String, Sendable {
    case accepted, rejected, unconfirmed
    init(_ payload: Data) {
        guard let fields = try? Fields(payload), let status = try? fields.integer(2) else { self = .unconfirmed; return }
        guard status == 1 else { self = .rejected; return }
        guard let response = try? Fields(fields.bytes(18)), (try? response.bytes(2)) != nil,
              let result = try? response.integer(1) else { self = .unconfirmed; return }
        self = result == 0 ? .accepted : .rejected
    }

    /// The answer to one of the band's own patterns. Its reply is not known as well as a
    /// vibration's, so this asks only that the request was taken and that no result says it failed.
    static func pattern(_ payload: Data) -> Self {
        guard let fields = try? Fields(payload), let status = try? fields.integer(2) else { return .unconfirmed }
        guard status == 1 else { return .rejected }
        guard let response = try? Fields(fields.bytes(18)) else { return .unconfirmed }
        guard response.values[1] != nil else { return .accepted }
        return (try? response.integer(1)) == 0 ? .accepted : .rejected
    }

    /// Which fields a reply carried and its status numbers, for the journal. No payload bytes.
    static func shape(_ payload: Data) -> String {
        guard let fields = try? Fields(payload) else { return "reply unreadable" }
        var note = "reply fields=\(fields.values.keys.sorted())"
        if let status = try? fields.integer(2) { note += " status=\(status)" }
        if let inner = try? Fields(fields.bytes(18)) {
            note += " inner=\(inner.values.keys.sorted())"
            if let result = try? inner.integer(1) { note += " result=\(result)" }
        }
        return note
    }
}

struct WristFeedbackGate: Sendable {
    private var change: UUID?
    private var phases: Set<WristFeedbackPhase> = []
    private var lastSent = -TimeInterval.infinity

    mutating func begin(_ change: UUID) { self.change = change; phases = [] }
    mutating func take(_ phase: WristFeedbackPhase, change: UUID, now: TimeInterval) -> Bool {
        guard self.change == change, now - lastSent >= 0.25 else { return false }
        guard phases.insert(phase).inserted else { return false }
        lastSent = now; return true
    }
    mutating func cancel(_ change: UUID? = nil) {
        if change == nil || self.change == change { self.change = nil }
    }
}

/// Everything the interface may say about a problem: one plain sentence and one action.
/// Protocol detail never appears here; it goes to the journal.
enum SessionIssue: String, Sendable, CaseIterable {
    case bluetoothOff, bluetoothDenied, bandNotNearby, pairingChanged, notRecognised,
         bandNotResponding, stillReleasing, pulseMissing, phoneLocked, signInFailed

    enum Action: Sendable { case reconnect, openSettings, setUpAgain, retryRelease, retrySignIn }

    var sentence: String {
        switch self {
        case .bluetoothOff: return "Bluetooth is off. Turn it on to reconnect."
        case .bluetoothDenied: return "Runes can’t use Bluetooth. Allow it in Settings."
        case .bandNotNearby: return "Band not nearby. Bring it close to your phone."
        case .pairingChanged: return "Your phone and band need to pair again."
        case .notRecognised: return "Your band didn’t recognise this phone."
        case .bandNotResponding: return "Your band stopped responding."
        case .stillReleasing: return "Your band is still disconnecting."
        case .pulseMissing: return "Gestures may pause while your phone is locked."
        case .phoneLocked: return "Unlock your phone to finish connecting."
        case .signInFailed: return "Meta sign-in didn’t finish."
        }
    }
    var action: Action {
        switch self {
        case .bluetoothOff, .bluetoothDenied: return .openSettings
        case .pairingChanged: return .setUpAgain
        case .stillReleasing: return .retryRelease
        case .signInFailed: return .retrySignIn
        case .notRecognised, .bandNotNearby, .bandNotResponding, .pulseMissing, .phoneLocked: return .reconnect
        }
    }
    var actionTitle: String {
        switch action {
        case .reconnect: return self == .pulseMissing ? "Reconnect" : "Try again"
        case .openSettings: return "Open Settings"
        case .setUpAgain: return "Set up again"
        case .retryRelease: return "Try again"
        case .retrySignIn: return "Sign in again"
        }
    }
    /// Gentle issues keep the band connected; the ring stays in its current state.
    var isGentle: Bool { self == .pulseMissing }

    static func from(_ error: BandError) -> SessionIssue {
        switch error {
        case .pairing: return .pairingChanged
        case .authentication, .trust, .setupRejected: return .notRecognised
        case .timeout: return .bandNotResponding
        case .storage: return .phoneLocked
        case .wire: return .bandNotResponding
        case .transport, .cancelled: return .bandNotNearby
        }
    }
}

extension ConnectionRetryPolicy {
    /// Only an identity or ownership failure stops automatic connection. Ordinary
    /// connection, protocol and storage errors keep retrying for as long as the user wants
    /// the band connected; the user's Disconnect is the other way to stop.
    static func stopsAutoConnect(_ error: BandError) -> Bool {
        switch error {
        case .authentication, .trust, .setupRejected, .pairing: return true
        case .timeout(let stage): return stage == "trust" || stage == "ceremony"
        default: return false
        }
    }
    /// Delay before reconnecting after a failure while the link was up. It never runs out:
    /// after the fast steps (1, 2, 4, 8, 16 s) it stays at the ceiling. A lost link is not
    /// delayed at all, because a pending connect costs nothing while the band is away.
    static let ceiling: TimeInterval = 20
    static func backoff(failures: Int) -> TimeInterval {
        delay(for: .transport("retry"), retries: max(0, failures - 1)).map { min($0, ceiling) } ?? ceiling
    }
}


// MARK: Physical gestures

enum SwipeDirection: String, Sendable, CaseIterable { case up, down, left, right }

/// One thing the person did with their hand. The band describes each of these with
/// several packets (a tap is press, button press, release, button release and single tap);
/// the interface reacts to this instead, exactly once.
struct BandGesture: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable { case tap, doubleTap, holdBegan, holdEnded, swipe(SwipeDirection) }
    /// Increases with every reaction, so views can tell two identical gestures apart.
    let id: Int
    let kind: Kind
    let finger: UInt64
    let at: Date
    /// A double tap upgrades the single tap the interface already showed.
    var upgradesPrevious: Bool { kind == .doubleTap }
    /// The end of a hold finishes a gesture that already reacted.
    var isNewGesture: Bool { kind != .holdEnded && kind != .doubleTap }

    var fingerName: String {
        switch finger { case 1: return "Thumb"; case 2: return "Index"; case 3: return "Middle"; default: return "Band" }
    }
    var title: String {
        switch kind {
        case .tap: return "\(fingerName) tap"
        case .doubleTap: return "\(fingerName) double tap"
        case .holdBegan, .holdEnded: return "\(fingerName) hold"
        case .swipe(let direction): return "Swipe \(direction.rawValue)"
        }
    }
}

/// Turns the band's packet stream into physical gestures.
///
/// From the 2026-11-08 journal (971 bursts): the derived layer carries the meaning
/// (singleTap, doubleTap, buttonHold, buttonHoldRelease, buttonUp/Down/Left/Right); raw
/// press/release and derived buttonPress/buttonRelease are parts of those and never react.
/// The second tap of a double tap sends singleTap and then doubleTap within ~11 ms, so a
/// single tap waits `settle` before it counts, and a doubleTap inside that wait replaces it.
struct GestureInterpreter: Sendable {
    static let settle: TimeInterval = 0.04
    private var pendingTap: (finger: UInt64, at: Date, uptime: TimeInterval)?
    /// A raw-layer gesture waiting to see whether the derived layer describes it instead.
    private var pendingRaw: (kind: BandGesture.Kind, finger: UInt64, at: Date, uptime: TimeInterval)?
    private var lastDerivedSequence: UInt64?
    private var derivedSeen = false
    private var holding: UInt64?
    private var serial = 0

    var hasPending: Bool { pendingTap != nil || pendingRaw != nil }

    mutating func reset() { pendingTap = nil; pendingRaw = nil; lastDerivedSequence = nil; holding = nil }

    mutating func feed(_ event: GestureEvent) -> [BandGesture] {
        let now = event.received.uptime, at = event.received.wallTime
        if event.stream == .derived {
            derivedSeen = true; pendingRaw = nil
            if event.sequence == lastDerivedSequence { return [] }   // repeated delivery
            lastDerivedSequence = event.sequence
            let code = event.derivedActionCode, finger = event.fingerCode
            if code == 2 {
                // Double tap: drop the second tap's single tap if it is still waiting.
                pendingTap = nil
                return [make(.doubleTap, finger, at)]
            }
            var out = flush(now: .infinity)
            switch code {
            case 1: pendingTap = (finger, at, now)
            case 3: holding = finger; out.append(make(.holdBegan, finger, at))
            case 10: holding = nil; out.append(make(.holdEnded, finger, at))
            case 5: out.append(make(.swipe(.up), finger, at))
            case 6: out.append(make(.swipe(.down), finger, at))
            case 7: out.append(make(.swipe(.left), finger, at))
            case 8: out.append(make(.swipe(.right), finger, at))
            default: break   // buttonPress, buttonRelease: parts of a gesture
            }
            return out
        }
        // Raw packets only stand in when the band sends no derived layer. They wait `settle`
        // first, because the derived packet for the same gesture follows within microseconds.
        guard !derivedSeen else { return [] }
        let kind: BandGesture.Kind
        switch event.actionCode {
        case 3, 5: kind = .tap
        case 4: kind = .doubleTap
        case 6: kind = .swipe(.up)
        case 7: kind = .swipe(.down)
        case 8, 11: kind = .swipe(.left)
        case 9, 12: kind = .swipe(.right)
        default: return []
        }
        let out = flush(now: .infinity)
        pendingRaw = (kind, event.fingerCode, at, now)
        return out
    }

    /// The gesture a packet means for an answer on the wrist, known the moment it arrives:
    /// each tap as it lands, without the wait that tells a double tap from two taps (the
    /// second tap of a double is a tap here too), a hold beginning or ending, and a swipe.
    /// Nil for the raw layer and for packets that are parts of a gesture.
    ///
    /// The band reports a tap only once the finger has lifted, about a tenth of a second after
    /// it touched. With `onTouch` the finger touching down is answered in its place, before the
    /// band knows whether a tap or a hold is coming, so a hold starts with the same tick.
    static func immediate(_ event: GestureEvent, onTouch: Bool = false) -> BandGesture.Kind? {
        guard event.stream == .derived, !event.synthetic else { return nil }
        switch event.derivedActionCode {
        case 1: return onTouch ? nil : .tap
        case 9: return onTouch ? .tap : nil
        case 3: return .holdBegan
        case 10: return .holdEnded
        case 5: return .swipe(.up)
        case 6: return .swipe(.down)
        case 7: return .swipe(.left)
        case 8: return .swipe(.right)
        default: return nil
        }
    }

    /// Releases a waiting single tap once `settle` has passed.
    mutating func flush(now: TimeInterval) -> [BandGesture] {
        var out: [BandGesture] = []
        if let raw = pendingRaw, now - raw.uptime >= Self.settle {
            pendingRaw = nil
            if !derivedSeen { out.append(make(raw.kind, raw.finger, raw.at)) }
        }
        if let tap = pendingTap, now - tap.uptime >= Self.settle {
            pendingTap = nil
            out.append(make(.tap, tap.finger, tap.at))
        }
        return out
    }

    private mutating func make(_ kind: BandGesture.Kind, _ finger: UInt64, _ at: Date) -> BandGesture {
        serial += 1
        return BandGesture(id: serial, kind: kind, finger: finger, at: at)
    }
}
