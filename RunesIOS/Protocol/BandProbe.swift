import Foundation

/// Finds out what the band sends and answers beyond what the app uses. The band's published
/// message definitions name every stream it can be asked for and every kind of request it
/// takes. This tries them one at a time: a stream is turned on for a moment and what arrives
/// is counted, and a request is sent empty to see whether the band knows it. A stream switch
/// lasts only as long as the connection, and nothing here writes a setting the band keeps.
final class BandProbe {
    enum Trial: Equatable {
        /// These stream switches turned on together, and how long to listen once the band takes them.
        case streams([Int], listen: TimeInterval)
        /// A request of this kind with nothing in it.
        case request(Int)
    }
    enum Ask: Equatable {
        case send(channel: UInt16, field: Int, payload: Data)
        case listen(TimeInterval)
        /// An answer or the end of a listen is still awaited.
        case wait
        case done
    }

    /// Requests go out under this name, which the protocol treats as optional: no answer, a
    /// refusal or a closed request is reported and the connection stays up.
    static let operation = "try_probe"
    /// The kind of frame the band uses for a message it sends without being asked.
    static let update: UInt32 = 0x02000316

    /// The stream switches, by their numbers in the stream request. The ones the app already
    /// runs are left out: 2 EMG, 3 gestures, 4 model scores, 6 gyro and 8 orientation.
    static let streams: [Int: String] = [
        1: "raw motion", 5: "accelerometer", 7: "magnetometer", 9: "wake status", 10: "band log", 11: "telemetry",
        12: "battery updates", 13: "device telemetry", 14: "raw BTI", 15: "raw PPG", 16: "device state",
        17: "EMG and motion batches", 18: "raw CSA", 19: "setting changes", 20: "AC leads off", 22: "named setting updates",
        23: "model events", 24: "touch events", 25: "DC leads off", 26: "model input", 27: "detector updates",
        28: "Kwaltz telemetry", 29: "band orientation result", 30: "band orientation state", 31: "raw CMSJ", 32: "VCM events",
        33: "health data batches", 34: "bioimpedance", 38: "on wrist events", 39: "wrist tilt", 40: "wrist down",
        41: "temperature", 42: "detector scores", 43: "written text", 44: "health events", 45: "trackpad touch",
        46: "health state", 47: "heart rate", 48: "Metalift capture", 49: "grip strength", 50: "passive context scores",
        51: "health heart rate", 52: "health steps", 53: "health calories", 54: "health exercise points",
        55: "activity detection", 56: "Jamba scores", 58: "handwriting samples"
    ]
    /// The switches whose messages come only when something happens, so they are listened to together and for longer.
    static let events = [9, 10, 11, 12, 13, 16, 19, 22, 23, 27, 29, 30, 38, 39, 40, 41]
    /// The kinds of request that choose one thing to do, so an empty one asks for nothing.
    /// Left out are the ones the app already sends, the ones where empty could itself be an
    /// instruction (6 time, 13 custom model, 16 radio test mode, 19 and 20 events, 23 and 24
    /// calibration) and the ones about identity and stored data (18, 26, 27).
    static let requests: [Int: String] = [2: "battery", 8: "opaque", 10: "link test", 12: "bug report", 15: "system settings", 21: "detector", 22: "health"]
    /// Battery is asked on the channel the public projects use for it. The rest share the named settings' channel.
    private static func channel(_ request: Int) -> UInt16 { request == 2 ? 8 : 1 }
    /// What the band can send without being asked, by its field in that message.
    static let updates: [Int: String] = [
        1: "device state", 2: "battery", 3: "log line", 4: "sensor telemetry", 5: "wake telemetry", 6: "gesture telemetry",
        7: "opaque", 8: "setting change", 9: "quality check", 10: "device telemetry", 11: "derived gesture telemetry",
        12: "heartbeat", 13: "crash log", 14: "custom model", 15: "named setting", 16: "stream state", 17: "system settings",
        18: "haptics", 19: "study event", 20: "model event", 21: "detector", 22: "Kwaltz telemetry", 23: "health event", 24: "EMG sign in"
    ]
    private static let frames: [UInt32: String] = [0x0200020a: "EMG", 0x0200020c: "model scores", 0x0200020d: "gesture", 0x0200020f: "gyro", 0x02000212: "orientation"]

    /// Every switch alone for two seconds, the likely ones first.
    static var sweep: [Trial] {
        let later = [14, 15, 18, 20, 25, 28, 31, 32, 33, 34, 44, 46, 47, 48, 51, 52, 53, 54, 55]
        return (streams.keys.sorted().filter { !later.contains($0) } + later).map { .streams([$0], listen: 2) }
    }
    static var census: [Trial] { requests.keys.sorted().map { .request($0) } }

    private enum Phase { case idle, on, taken, listening, off, request(Int) }
    private struct Heard { var count = 0, least = Int.max, most = 0, shape = "" }

    private var queue: [Trial]
    private let usual: Data
    private var phase = Phase.idle
    private var current: [Int] = [], seconds: TimeInterval = 0
    private var heard: [String: Heard] = [:], order: [String] = []
    private var lines: [String] = []
    private let total: Int
    /// Every switch asked for so far, to be named as off when the usual streams are put back.
    private(set) var tried: Set<Int> = []
    /// What the band took, for the last line.
    private var took: [Int] = [], known: [Int] = []

    init(_ trials: [Trial], usual: Data) {
        queue = trials; self.usual = usual; total = trials.count
    }

    var progress: String { "\(total - queue.count) of \(total)" }
    /// The switches that are on right now, in words, for when the link drops under them.
    var on: String? {
        switch phase {
        case .on, .taken, .listening: return Self.names(current)
        default: return nil
        }
    }
    /// The stream flags that say every switch tried is off.
    var off: Data { tried.sorted().reduce(Data()) { $0 + PB.field($1, 0) } }

    func takeLines() -> [String] { defer { lines = [] }; return lines }
    /// Drops what has not been tried yet. A switch that is on is still turned off.
    func stop() { if !queue.isEmpty { queue = []; lines.append("Stopped.") } }

    private static func names(_ numbers: [Int]) -> String {
        numbers.map { "\($0) \(streams[$0] ?? "unnamed")" }.joined(separator: ", ")
    }
    private func flags(_ value: UInt64) -> Data { current.reduce(usual) { $0 + PB.field($1, value) } }

    /// What to do now. Called at the start, after each answer and when a listen ends.
    func next() -> Ask {
        switch phase {
        case .on, .off, .request: return .wait
        case .taken:
            phase = .listening
            return .listen(seconds)
        case .listening:
            summarise()
            phase = .off
            return .send(channel: 5, field: 4, payload: flags(0))
        case .idle:
            guard !queue.isEmpty else {
                if total > 0, !took.isEmpty || !known.isEmpty {
                    if !took.isEmpty { lines.append("Streams the band took: \(Self.names(took.sorted())).") }
                    if !known.isEmpty { lines.append("Requests the band answered: \(known.sorted().map { "\($0) \(Self.requests[$0] ?? "unnamed")" }.joined(separator: ", ")).") }
                }
                return .done
            }
            switch queue.removeFirst() {
            case .streams(let numbers, let listen):
                // The switches the app runs itself are never touched.
                current = numbers.filter { ![2, 3, 4, 6, 8].contains($0) && (1...63).contains($0) }
                guard !current.isEmpty else { return next() }
                seconds = listen; heard = [:]; order = []; tried.formUnion(current)
                phase = .on
                return .send(channel: 5, field: 4, payload: flags(1))
            case .request(let number):
                guard Self.requests[number] != nil else { return next() }
                phase = .request(number)
                return .send(channel: Self.channel(number), field: number, payload: Data())
            }
        }
    }

    /// The band's answer to the last request sent. Empty for no answer, a refusal or a closed request.
    func answered(_ payload: Data) {
        let fields = try? Fields(payload)
        let status = fields.flatMap { try? $0.integer(2, default: 0) }
        switch phase {
        case .on:
            let accepted = (fields.flatMap { try? Fields($0.bytes(5)) }).map { echo in current.filter { (try? echo.integer($0, default: 0)) == 1 } } ?? []
            if payload.isEmpty { lines.append("\(Self.names(current)): no answer.") }
            else if status != 1 { lines.append("\(Self.names(current)): refused, status \(status.map(String.init) ?? "unreadable").") }
            else if accepted.isEmpty { lines.append("\(Self.names(current)): not taken.") }
            else if accepted.count < current.count { lines.append("Taken: \(Self.names(accepted)). Not taken: \(Self.names(current.filter { !accepted.contains($0) })).") }
            took += accepted
            // A switch is named as off again even when the band did not take it.
            phase = accepted.isEmpty ? .listening : .taken
        case .off:
            if payload.isEmpty || status != 1 { lines.append("The band did not confirm turning off \(Self.names(current)).") }
            phase = .idle
        case .request(let number):
            let name = "Request \(number) \(Self.requests[number] ?? "unnamed")"
            if !payload.isEmpty, let fields, let status {
                let rest = fields.values.keys.filter { $0 > 2 }.sorted()
                if status == 1 { known.append(number) }
                lines.append("\(name): status \(status)" + (rest.isEmpty ? "." : ", answer \(Self.shape(fields, depth: 0, from: 3))."))
            } else {
                lines.append("\(name): no answer.")
            }
            phase = .idle
        default: break
        }
    }

    /// A frame that no stream or request of the app's accounts for.
    func heard(kind: UInt32, payload: Data) {
        switch phase {
        case .on, .taken, .listening: break
        default: return
        }
        let fields = try? Fields(payload)
        var key = Self.frames[kind].map { "\($0) frames" } ?? "frames of kind \(String(kind, radix: 16))"
        if kind == Self.update, let fields {
            key = fields.values.keys.sorted().map { "\(Self.updates[$0] ?? "unnamed") update (\($0))" }.joined(separator: " and ")
        }
        var entry = heard[key] ?? Heard(shape: fields.map { Self.shape($0, depth: 0, from: 1) } ?? "not a message")
        if entry.count == 0 {
            guard order.count < 12 else { return }
            order.append(key)
        }
        entry.count += 1; entry.least = min(entry.least, payload.count); entry.most = max(entry.most, payload.count)
        heard[key] = entry
    }

    private func summarise() {
        let taken = current.filter(took.contains)
        guard !order.isEmpty || !taken.isEmpty else { return }
        let found = order.isEmpty ? "nothing arrived in \(Int(seconds)) s." : "\(order.count) kind\(order.count == 1 ? "" : "s") of message arrived."
        lines.append(taken.isEmpty ? "\(Self.names(current)): not taken, yet \(found)" : "\(Self.names(taken)): taken, \(found)")
        for key in order {
            guard let entry = heard[key] else { continue }
            let size = entry.least == entry.most ? "\(entry.most)" : "\(entry.least) to \(entry.most)"
            let rate = !taken.isEmpty && Double(entry.count) > seconds * 2 ? ", about \(Int((Double(entry.count) / seconds).rounded())) a second" : ""
            lines.append("  \(entry.count) \(key)\(rate), \(size) bytes. First: \(entry.shape)")
        }
    }

    /// One message written out for reading: numbers as they are, text as text, and other bytes
    /// as a length and their first sixteen. Blocks that read as messages are opened two deep.
    static func shape(_ fields: Fields, depth: Int, from first: Int) -> String {
        fields.values.keys.filter { $0 >= first }.sorted().flatMap { number in
            (fields.values[number] ?? []).prefix(4).map { value -> String in
                switch value {
                case .integer(let integer): return "\(number)=\(integer)"
                case .bytes(let wire, let data):
                    let hex = data.prefix(16).map { String(format: "%02x", $0) }.joined() + (data.count > 16 ? "…" : "")
                    guard wire == 2 else { return "\(number)=fixed \(hex)" }
                    if data.isEmpty { return "\(number)=empty" }
                    if data.count >= 3, data.allSatisfy({ (0x20..<0x7f).contains($0) || $0 == 0x0a }) { return "\(number)=“\(BandSettings.plain(data))”" }
                    if depth < 2, let inner = try? Fields(data), inner.values.keys.allSatisfy({ $0 < 64 }) { return "\(number)={\(shape(inner, depth: depth + 1, from: 1))}" }
                    return "\(number)=\(data.count) bytes \(hex)"
                }
            }
        }.joined(separator: " ")
    }
}
