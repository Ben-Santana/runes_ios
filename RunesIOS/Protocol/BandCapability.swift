import Foundation

/// How the band describes one of its named settings: the kind of value it holds, the limits
/// it gives and the actions it lists. This is read from the same answer as
/// `NamedSettings.setting`, by the field numbers of the band's published message definitions.
struct BandCapability: Equatable, Sendable {
    /// The kind of value. Each kind has a field of its own in the description.
    enum Kind: Int, CaseIterable, Sendable {
        case whole = 7, wholeList = 8, decimal = 9, decimalList = 10, yesNo = 11, yesNoList = 12
        case resource = 14, choice = 15, choiceList = 16, nothing = 17, long = 19

        var word: String {
            switch self {
            case .whole: "whole number"
            case .wholeList: "whole numbers"
            case .decimal: "decimal"
            case .decimalList: "decimals"
            case .yesNo: "yes or no"
            case .yesNoList: "yes or no list"
            case .resource: "resource"
            case .choice: "choice"
            case .choiceList: "choices"
            case .nothing: "no value"
            case .long: "long whole number"
            }
        }
    }

    /// Nil when the band filled in no kind, or more than one.
    var kind: Kind?
    /// The value in the description: a number, 0 or 1 for a yes or no, or the place of a choice.
    var current: Int64?
    var low: Int64?, high: Int64?
    /// The places a choice can take.
    var choices: [Int64] = []
    /// The numbers of the actions the band lists. A read is 0 and a write is 1.
    var actions: [UInt64] = []
    var tags: [UInt64] = []
    var level: UInt64?
    /// How many named arguments the band lists.
    var arguments = 0
    /// The band's own sentence about the setting, cut to 96 plain characters.
    var note = ""

    /// Nil for no answer, a refusal or an answer that is not a description.
    init?(describing reply: Data) {
        guard let fields = try? Fields(reply), (try? fields.integer(2)) == 1,
              let info = try? Fields(Fields(fields.bytes(NamedSettings.field)).bytes(2)) else { return nil }
        let kinds = Kind.allCases.filter { info.values[$0.rawValue] != nil }
        if kinds.count == 1 { kind = kinds[0] }
        // A value of zero is left off the wire, so a missing number reads as zero.
        if let kind, let body = try? Fields(info.bytes(kind.rawValue)) {
            func number(_ field: Int) -> Int64? { (try? body.integer(field, default: 0)).map { Int64(bitPattern: $0) } }
            switch kind {
            case .whole, .long: current = number(1); low = number(2); high = number(3)
            case .yesNo: current = number(1)
            case .choice:
                current = number(3)
                choices = (body.values[1] ?? []).compactMap { entry in
                    guard case .bytes(2, let data) = entry, let choice = try? Fields(data) else { return nil }
                    return (try? choice.integer(2, default: 0)).map { Int64(bitPattern: $0) }
                }
            default: break
            }
        }
        actions = Self.numbers(info.values[6])
        tags = Self.numbers(info.values[5])
        level = try? info.integer(18)
        arguments = info.values[13]?.count ?? 0
        if let text = try? info.bytes(2) {
            note = String(decoding: text.prefix(96), as: UTF8.self).filter { $0.isLetter || $0.isNumber || " -_.,:/()".contains($0) }
        }
    }

    /// The description on one line: the kind in words and the rest as numbers.
    var summary: String {
        var first = kind?.word ?? "no kind given"
        switch kind {
        case .whole, .long: first += " \(low ?? 0) to \(high ?? 0), now \(current ?? 0)"
        case .yesNo: first += ", now \(current ?? 0)"
        case .choice: first += " of \(Self.list(choices)), now \(current ?? 0)"
        default: break
        }
        var parts = [first, "actions \(Self.list(actions))"]
        if !tags.isEmpty { parts.append("tags \(Self.list(tags))") }
        if let level { parts.append("level \(level)") }
        if arguments > 0 { parts.append("\(arguments) arguments") }
        if !note.isEmpty { parts.append("“\(note)”") }
        return parts.joined(separator: "; ")
    }

    /// The result number of the answer to a read or a write, when the band gave one. Zero is success and is left off the wire.
    static func code(from reply: Data) -> UInt64? {
        guard let fields = try? Fields(reply), let answer = try? Fields(Fields(fields.bytes(NamedSettings.field)).bytes(3)) else { return nil }
        return try? answer.integer(3)
    }

    /// The numbers in a repeated field, whether the band packed them into one block or sent each alone. At most 64 are read.
    static func numbers(_ values: [Fields.Value]?) -> [UInt64] {
        var result: [UInt64] = []
        for value in values ?? [] {
            switch value {
            case .integer(let number): result.append(number)
            case .bytes(2, let packed):
                var number: UInt64 = 0, shift: UInt64 = 0
                for byte in packed {
                    number |= UInt64(byte & 127) << shift
                    if byte < 128 { result.append(number); number = 0; shift = 0 } else { shift = min(shift + 7, 63) }
                }
            default: break
            }
        }
        return Array(result.prefix(64))
    }

    private static func list<Number: BinaryInteger>(_ numbers: [Number]) -> String {
        numbers.isEmpty ? "none" : numbers.map { "\($0)" }.joined(separator: " ")
    }
}

/// The band's own tightness check. The band lists a setting named `trigger-band-tightness`
/// that it will not let be read. The check is asked for with the action and the kind of value
/// that setting's description gives. Nothing here writes a setting the band keeps.
enum BandTightness {
    static let trigger = "trigger-band-tightness"
    /// How long the band's messages are collected after the check is asked for, in seconds.
    static let listen: TimeInterval = 30
    /// The kind of frame the band uses for a message it sends without being asked.
    static let update: UInt32 = 0x02000316
    private static let answerKind: UInt32 = 0x02000315
    /// Where the writing out of a message as numbers starts, so that it follows four levels of nesting and not two.
    private static let depth = -2

    /// The actions the check can be asked with: those the band lists, apart from a read. When
    /// the band lists none this is a write, the one other action this band is known to take.
    static func actions(_ capability: BandCapability) -> [UInt64] {
        let listed = capability.actions.filter { $0 != 0 }
        return capability.actions.isEmpty ? [1] : Array(Set(listed)).sorted()
    }

    /// The values the check can be asked with. Nil when it takes none, and empty when it takes
    /// a kind of value this app does not send.
    static func values(_ capability: BandCapability) -> [Int64]? {
        switch capability.kind {
        case nil, .nothing: return nil
        case .yesNo: return [0, 1]
        case .choice: return Array(capability.choices.prefix(8))
        case .whole:
            guard let low = capability.low, let high = capability.high, low <= high else { return [] }
            if high - low < 8 { return Array(low...high) }
            return Array(Set([low, min(max(capability.current ?? low, low), high), high])).sorted()
        default: return []
        }
    }

    /// The request that asks for the check. Nil for any other setting, for an action the band
    /// does not list, and for a value outside what its description allows.
    static func start(id: UInt64, name: String, capability: BandCapability, action: UInt64, value: Int64?) -> Data? {
        guard name == trigger, actions(capability).contains(action) else { return nil }
        var body = PB.field(1, id) + PB.field(2, action)
        switch (values(capability), value) {
        case (nil, nil): break
        case (let allowed?, let value?) where allowed.contains(value):
            let field = capability.kind == .yesNo ? 7 : capability.kind == .choice ? 10 : 3
            body += PB.field(field, PB.field(1, UInt64(bitPattern: value)))
        default: return nil
        }
        return PB.field(3, body)
    }

    /// What the band says about a named setting, as the answer to a request or without being asked.
    struct Answer: Equatable, Sendable {
        var id: UInt64, action: UInt64
        /// Zero is success.
        var code: UInt64
        /// The field the value came in, which tells its kind, and the value or values.
        var kind: Int?
        var values: [Double] = []

        var line: String {
            var text = "setting \(id) action \(action) result \(code)"
            if let kind { text += " kind \(kind) value \(values.map(BandTightness.plain).joined(separator: " "))" }
            return text
        }
    }

    static func answer(_ message: Fields) -> Answer {
        var answer = Answer(id: (try? message.integer(1, default: 0)) ?? 0, action: (try? message.integer(2, default: 0)) ?? 0,
                            code: (try? message.integer(3, default: 0)) ?? 0)
        // Field 10 is a time and is not a value.
        let kinds = [4, 5, 6, 7, 8, 9, 11, 12, 13].filter { message.values[$0] != nil }
        guard kinds.count == 1, let body = try? Fields(message.bytes(kinds[0])) else { return answer }
        answer.kind = kinds[0]
        switch kinds[0] {
        case 6, 7: answer.values = decimals(body.values[1])
        case 5, 9, 12: answer.values = BandCapability.numbers(body.values[1]).map { Double(Int64(bitPattern: $0)) }
        default: answer.values = [Double(Int64(bitPattern: (try? body.integer(1, default: 0)) ?? 0))]
        }
        return answer
    }

    /// One line for the band's answer to the request that asks for the check.
    static func reply(_ payload: Data) -> String {
        guard !payload.isEmpty else { return "No answer: the band stayed silent or closed the request." }
        guard let fields = try? Fields(payload) else { return "Answer unreadable." }
        let status = (try? fields.integer(2)).map { "status \($0)" } ?? "no status"
        guard let message = try? Fields(Fields(fields.bytes(NamedSettings.field)).bytes(3)) else {
            return "Answer \(status), fields \(fields.values.keys.sorted())."
        }
        return "Answer \(status): \(answer(message).line) [\(BandSettings.describe(message, depth: depth))]"
    }

    /// The band's tightness reading from a message it sent without being asked, when the message carries one.
    static func reading(fromUpdate payload: Data) -> UInt64? {
        guard let detector = try? Fields(Fields(payload).bytes(21)) else { return nil }
        return try? detector.integer(3)
    }

    /// One line for a frame that is not part of a stream the app asked for. What is known of it
    /// comes first, then all of it as numbers, with any other bytes as a length.
    static func describe(kind: UInt32, channel: UInt16, payload: Data) -> String {
        let head = "Frame \(String(kind, radix: 16)) channel \(channel & 0x7fff), \(payload.count) bytes"
        guard let fields = try? Fields(payload) else { return head + ": not a message." }
        var parts: [String] = []
        if kind == answerKind { parts.append("late answer") }
        if kind == update {
            if let detector = try? Fields(fields.bytes(21)) {
                var text = "detector update \((try? detector.integer(2, default: 0)) ?? 0)"
                for (field, name) in [(3, "tightness"), (4, "orientation"), (7, "off wrist")] {
                    if let value = try? detector.integer(field) { text += " \(name) \(value)" }
                }
                if let body = try? Fields(detector.bytes(5)) {
                    let numbers = (1...4).map { (try? body.integer($0, default: 0)) ?? 0 }
                    text += " on wrist status \(numbers[0]) now \(numbers[1]) before \(numbers[2]) motion \(numbers[3])"
                }
                if let body = try? Fields(detector.bytes(6)) {
                    text += " interference status \((try? body.integer(1, default: 0)) ?? 0) ratio \(decimals(body.values[2]).map(plain).joined())"
                }
                parts.append(text)
            }
            if let message = try? Fields(Fields(fields.bytes(15)).bytes(1)) { parts.append("setting update: \(answer(message).line)") }
            if let quality = try? Fields(fields.bytes(9)) { parts.append("quality check, dead channels \((try? quality.integer(2, default: 0)) ?? 0)") }
            if let state = try? Fields(fields.bytes(1)) {
                let numbers = [1, 5, 6].map { (try? state.integer($0, default: 0)) ?? 0 }
                parts.append("device state \(numbers[0]) on wrist \(numbers[1]) reason \(numbers[2])")
            }
        }
        return head + (parts.isEmpty ? "" : ": " + parts.joined(separator: "; ")) + " [\(BandSettings.describe(fields, depth: depth))]"
    }

    /// Decimals from a field of four byte numbers, alone or packed into one block.
    private static func decimals(_ values: [Fields.Value]?) -> [Double] {
        var result: [Double] = []
        for value in values ?? [] {
            guard case .bytes(let wire, let data) = value, wire == 5 || wire == 2, data.count % 4 == 0 else { continue }
            for offset in stride(from: 0, to: min(data.count, 256), by: 4) { result.append(Double(Float(bitPattern: data.be32(offset).byteSwapped))) }
        }
        return result
    }

    private static func plain(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(format: "%.4g", value)
    }
}
