import Foundation
import CryptoKit

// Mutated exclusively on the transport's run-loop thread.
final class BandProtocol {
    enum Signal {
        case ready, reply(operation: String, payload: Data), ownership(OwnershipStep), enrolled(BandIdentity)
        case motion(kind: RelayWire.Event.Kind, values: [Double], sequence: UInt64, timestamp: UInt64)
        case gesture(finger: UInt64, action: UInt64, derived: UInt64, synthetic: Bool, sequence: UInt64, timestamp: UInt64)
        /// One EMG batch: 16 samples × 8 channels, sample-major, raw 16-bit ADC counts.
        case emg(values: [UInt16], sequence: UInt64, timestamp: UInt64)
        /// The band would not provide EMG. The connection stays up; EMG is simply left off.
        case emgUnavailable(String)
        case handUnavailable(String)
        case wristFeedback(WristFeedbackResult)
        /// One message of scores from the band's own model: nine while it reads gestures, and
        /// rows of a hundred in its handwriting state.
        case inference(scores: [Float], pipeline: UInt64)
        /// A frame that no request or stream here accounts for. Passed on only while `watchesOther` is set.
        case other(kind: UInt32, channel: UInt16, payload: Data)
    }
    private struct Pending {
        let operation: String; let id: UInt64; let deadline: TimeInterval; let flags: Data?
        var isHandRequest: Bool { operation == "read_hand" || operation == "set_hand" }
        var isWristFeedback: Bool { operation == "wrist_feedback" || operation == "band_pattern" }
        /// A named setting request or a band test: optional, so no answer or a refusal is reported and never fatal.
        var isOptional: Bool { operation.hasPrefix("named_") || operation.hasPrefix("try_") }
    }
    private var identity: BandIdentity?
    private let ceremony: OwnershipCeremony?
    private let ephemeral = P256.KeyAgreement.PrivateKey()
    private let challenge: Data, seed: Data, iv: Data, counter: UInt64
    private var point: Data { Data(ephemeral.publicKey.x963Representation.dropFirst()) }
    private var peerPoint: Data?, peerChallenge: Data?, peerSeed: Data?
    private var tx: AirShieldCipher?, rx: AirShieldReceiver?
    /// The link rules for the firmware this band runs, taken from its encryption request.
    private var link = BandLink.original
    /// What the band offered and which rules were chosen, for the journal.
    private(set) var linkNote = ""
    /// Which of the possible ways of making keys this connection tries, when newer firmware
    /// leaves more than one open.
    private let way: Int
    /// Whether the rules in use are one way among several, not yet shown to be the band's.
    private(set) var linkIsGuess = false
    /// Set once the band has sent a record whose check passed, which only the right rules allow.
    private(set) var linkProven = false
    /// Another way whose check does pass on what the band sent, found when this one's failed.
    private(set) var betterWay: Int?
    private var ways: [BandLink] = []
    /// What is needed to try the other ways on the band's first records.
    private var material: (secret: Data, iv: Data, counter: UInt64)?
    private var unread = Data()
    /// The protocol version the band reported about itself, which decides how streams are asked for.
    private var version: UInt64 = 1
    private let clear = DataXReceiver(), frames = DataXReceiver()
    private var types: [UInt16: UInt32] = [:], pending: [UInt16: Pending] = [:], opened: Set<UInt16> = []
    private var nextID: UInt64 = 0
    private var hostTrusted = false, bandTrusted = false, endSent = false, gesturesEnabled = false, gyroEnabled = false, orientationEnabled = false, emgEnabled = false, inferenceEnabled = false
    private(set) var stage = "idle"
    private var deadline = TimeInterval.infinity
    var canSendWristFeedback: Bool { stage == "ready" && pending.isEmpty }
    var wristFeedbackPending: Bool { pending[6]?.isWristFeedback == true }
    /// How the band last answered a wrist feedback request, for the journal.
    private(set) var feedbackNote = ""
    /// Set while a test listens for whatever else the band sends.
    var watchesOther = false
    init(identity: BandIdentity?, ceremony: OwnershipCeremony? = nil, way: Int = 0) throws {
        guard (identity == nil) != (ceremony == nil) else { throw BandError.authentication("Provide identity or explicit enrollment.") }
        self.identity = identity; self.ceremony = ceremony; self.way = max(0, way)
        challenge = try BandCrypto.random(16); seed = try BandCrypto.random(32); iv = try BandCrypto.random(16)
        counter = UInt64(try BandCrypto.random(4).be32(0))
    }
    private func frame(_ channel: UInt16, _ words: [UInt32], _ payload: Data = Data()) throws -> Data { try Frame(channel: channel, words: words, payload: payload).encoded() }
    func start(now: TimeInterval) throws -> Data {
        stage = "encryption"; deadline = now + 15
        return try frame(0x8001, [0x81000005, 0x02000001], PB.field(1, point) + PB.field(2, challenge) + PB.field(3, 0) + PB.field(4, 31) + PB.field(7, 16))
    }
    @discardableResult
    func tick(now: TimeInterval) throws -> [Signal] {
        if now >= deadline {
            throw BandError.timeout(stage: stage)
        }
        var signals: [Signal] = []
        for (channel, request) in pending where now >= request.deadline {
            if request.isWristFeedback {
                pending[channel] = nil; feedbackNote = "no reply in time"; signals.append(.wristFeedback(.unconfirmed)); continue
            }
            if request.isOptional {
                pending[channel] = nil; signals.append(.reply(operation: request.operation, payload: Data())); continue
            }
            guard request.isHandRequest else { throw BandError.timeout(stage: request.operation) }
            pending[channel] = nil
            signals.append(.handUnavailable("The wrist setting timed out. Try again."))
        }
        return signals
    }
    func encrypt(_ data: Data) throws -> Data {
        guard let tx else { throw BandError.wire("Encryption is not established.") }
        var output = Data(), offset = 0
        while offset < data.count { let end = min(offset + link.recordLimit, data.count); output.append(try tx.encrypt(data.portion(offset..<end))); offset = end }
        return output
    }
    func resume(_ completion: PairCompletion) throws -> Data {
        guard stage == "ceremony", let ceremony else { throw BandError.authentication("No enrollment is pending.") }
        return try encrypt(ceremony.resume(completion))
    }
    func request(_ operation: String, channel: UInt16, field: Int, payload: Data, now: TimeInterval, setup: Bool = false) throws -> Data {
        guard stage == "ready" || setup, pending[channel] == nil else { throw BandError.wire("Request is invalid for this protocol state.") }
        nextID += 1
        let words: [UInt32] = opened.contains(channel) ? [] : [0x8100ce56, 0x02000314]
        if !words.isEmpty { types[channel] = nil; types[channel | 0x8000] = nil }
        opened.insert(channel)
        pending[channel] = Pending(operation: operation, id: nextID, deadline: now + (["wrist_feedback", "band_pattern"].contains(operation) ? 5 : 8), flags: ["start_streams", "stop_streams"].contains(operation) ? payload : nil)
        let body = pending[channel]?.flags == nil ? payload : BandStreams.request(payload, version: version)
        return try encrypt(frame(channel | 0x8000, words, PB.field(1, nextID) + PB.field(field, body)))
    }
    /// A request sent without waiting for its answer, on a channel already in use: for a buzz
    /// that must go out at once even while another request there is unanswered. The band's
    /// reply matches no waiting request and is dropped.
    func post(channel: UInt16, field: Int, payload: Data) throws -> Data {
        guard stage == "ready", opened.contains(channel) else { throw BandError.wire("Request is invalid for this protocol state.") }
        nextID += 1
        return try encrypt(frame(channel | 0x8000, [], PB.field(1, nextID) + PB.field(field, payload)))
    }
    /// The number of the last request sent, which a firmware update moves on as it numbers its own.
    var requestNumber: UInt64 { get { nextID } set { nextID = max(nextID, newValue) } }
    /// A request the caller numbered and built, sent with nothing waiting for its answer, so a
    /// firmware update can have several in flight on one channel. The answers arrive as
    /// `other` while `watchesOther` is set.
    func post(channel: UInt16, body: Data) throws -> Data {
        guard stage == "ready" else { throw BandError.wire("Request is invalid for this protocol state.") }
        let words: [UInt32] = opened.contains(channel) ? [] : [0x8100ce56, 0x02000314]
        if !words.isEmpty { types[channel] = nil; types[channel | 0x8000] = nil }
        opened.insert(channel)
        return try encrypt(frame(channel | 0x8000, words, body))
    }
    func feed(_ input: Data, now: TimeInterval) throws -> (Data, [Signal]) {
        var signals = try tick(now: now)
        var output = Data(), data = input
        if rx == nil {
            guard clear.pending.count + input.count <= 1 << 20 else { throw BandError.wire("Setup buffer overflow.") }
            clear.pending.append(input); data = Data()
            while rx == nil, clear.pending.count >= 4 {
                let size = Int(clear.pending.be16(0) & 0x7fff) + 4
                guard size >= 8, clear.pending.octet(0) & 0x80 != 0 else { throw BandError.wire("Invalid clear handshake frame.") }
                if clear.pending.count < size { break }
                let packet = clear.pending.portion(0..<size); clear.pending = Data(clear.pending.dropFirst(size))
                guard let frame = try DataXReceiver().feed(packet, padded: false).first else { throw BandError.wire("Empty handshake frame.") }
                output.append(try handshake(frame, now: now))
            }
            if rx != nil { data = clear.pending; clear.pending = Data() }
        }
        if let rx {
            let records: [Data]
            if linkIsGuess, !linkProven {
                // Kept until one record's check passes, so the other ways can be tried on the same bytes.
                if unread.count + data.count <= 1 << 16 { unread.append(data) }
                do { records = try rx.feed(data) } catch { betterWay = wayThatReads(unread); throw error }
                if !records.isEmpty { linkProven = true; unread = Data(); material = nil }
            } else { records = try rx.feed(data) }
            for plain in records {
                for packet in try frames.feed(plain) {
                    let (out, emitted) = try receive(packet, now: now); output.append(out); signals.append(contentsOf: emitted)
                }
            }
        }
        return (output, signals)
    }
    /// The cipher for what the band sends, under one way of making keys.
    private func reader(_ link: BandLink, secret: Data, iv: Data, counter: UInt64) throws -> AirShieldCipher {
        guard let peerSeed else { throw BandError.wire("Encryption is not established.") }
        let key = link.key(secret: secret, challenge: challenge, seed: peerSeed)
        return try AirShieldCipher(key: key, iv: iv, counter: counter, link: link, checkKey: link.checkKey(secret: secret, challenge: challenge, seed: peerSeed, recordKey: key))
    }
    /// Tries every other way on what the band has sent so far, and returns one whose check passes.
    private func wayThatReads(_ bytes: Data) -> Int? {
        guard let material else { return nil }
        return ways.indices.first { index in
            guard index != way % ways.count, let cipher = try? reader(ways[index], secret: material.secret, iv: material.iv, counter: material.counter) else { return false }
            return ((try? AirShieldReceiver(cipher).feed(bytes))?.isEmpty == false)
        }
    }
    private func handshake(_ packet: Frame, now: TimeInterval) throws -> Data {
        guard let kind = packet.words.last else { throw BandError.wire("Untyped encryption response.") }
        let f = try Fields(packet.payload), peer = try f.bytes(1, count: 64)
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: Data([4]) + peer)
        if kind == 0x02000001 {
            let schemes = try f.integer(4)
            linkNote = "offered \(schemes)"
            ways = BandLink.ways(offered: schemes)
            guard BandLink.route(packet.channel) == 0x8001, peerPoint == nil, try f.integer(3) == 0, !ways.isEmpty else { throw BandError.wire("Unsupported encryption request (schemes \(schemes)).") }
            link = ways[way % ways.count]; linkIsGuess = ways.count > 1
            linkNote += ", using \(link.scheme)" + (linkIsGuess ? " (way \(way % ways.count + 1) of \(ways.count))" : "")
            peerPoint = peer; peerChallenge = try f.bytes(2, count: 16)
            return try frame(1, [0x02000002], PB.field(1, point) + PB.field(2, seed) + PB.field(3, iv) + PB.field(4, counter) + PB.field(5, link.scheme))
        }
        let named = try f.integer(5, default: 0)
        linkNote += ", band named \(named)"
        // Older firmware names the one scheme it has. Newer firmware names what it likes, 26 on
        // some bands and 27 on others, whatever the phone named, so there the name is only noted.
        guard kind == 0x02000002, BandLink.route(packet.channel) == 1, peer == peerPoint, let peerChallenge, linkIsGuess || named == link.scheme else { throw BandError.wire("Unexpected encryption response (scheme \(named)).") }
        let peerSeed = try f.bytes(2, count: 32); self.peerSeed = peerSeed
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
        let key = link.key(secret: secret, challenge: peerChallenge, seed: seed)
        tx = try AirShieldCipher(key: key, iv: iv, counter: counter, link: link, checkKey: link.checkKey(secret: secret, challenge: peerChallenge, seed: seed, recordKey: key))
        let peerIV = try f.bytes(3, count: 16), peerCounter = try f.integer(4)
        rx = try AirShieldReceiver(reader(link, secret: secret, iv: peerIV, counter: peerCounter))
        if linkIsGuess { material = (secret, peerIV, peerCounter) }
        frames.everyRecordPadded = link.padsEveryRecord
        if let ceremony { stage = "ceremony"; deadline = now + 180; return try encrypt(ceremony.start()) }
        stage = "trust"; deadline = now + 15; return try enableTrust()
    }
    private func enableTrust(opened: Bool = false) throws -> Data {
        guard let identity, let peerPoint, let peerChallenge else { throw BandError.authentication("Incomplete trust transcript.") }
        let key = try P256.Signing.PrivateKey(rawRepresentation: identity.privateKey)
        let signature = try BandCrypto.sign(BandCrypto.transcript(peerChallenge, peerPoint, seed, point), privateKey: identity.privateKey)
        return try encrypt(frame(0x8002, opened ? [0x02001000] : [0x81000024, 0x02001000], PB.field(1, Data(SHA256.hash(data: BandCrypto.point(key)))) + PB.field(2, signature)))
    }
    private func maybeEnd() throws -> Data {
        if hostTrusted && bandTrusted && !endSent {
            endSent = true
            return try encrypt(frame(0x8001, [0x02001000], PB.field(1, 1) + PB.field(2, BandCrypto.random(16))))
        }
        return Data()
    }
    private func receive(_ packet: Frame, now: TimeInterval) throws -> (Data, [Signal]) {
        let kind: UInt32, channel = BandLink.route(packet.channel)
        if let word = packet.words.last {
            if word & 0xff000000 == 0x03000000 { return try result(packet, kind: word) }
            guard types.count < 1024 || types[channel] != nil else { throw BandError.wire("Too many protocol channels.") }
            types[channel] = word; kind = word
        } else if let word = types[channel] { kind = word } else { return (Data(), []) }
        if kind == 0x02001001 && bandTrusted { throw BandError.authentication("Duplicate band proof.") }
        if stage == "ceremony", let ceremony {
            guard channel & 0x7fff == 2 else { return (Data(), []) }
            let step = try ceremony.receive(kind: kind, payload: packet.payload)
            switch step {
            case .write(let bytes): return (try encrypt(bytes), [])
            case .complete(let identity):
                self.identity = identity; stage = "trust"; deadline = now + 15
                return (try enableTrust(opened: true), [.enrolled(identity)])
            default: return (Data(), [.ownership(step)])
            }
        }
        if stage == "trust" {
            if kind == 0x02001001, packet.channel & 0x8000 != 0 {
                guard let identity, let peerPoint, let peerSeed else { throw BandError.authentication("Verified band identity is missing.") }
                let signature = try Fields(packet.payload).bytes(2, count: 64)
                if let bandPoint = identity.bandPoint {
                    try BandCrypto.verify(BandCrypto.transcript(challenge, point, peerSeed, peerPoint), signature: signature, point: bandPoint)
                } else if identity.allowMissingBandKey != true {
                    throw BandError.authentication("Band proof requires a saved public key.")
                }
                bandTrusted = true
                return (try encrypt(frame(packet.channel & 0x7fff, [0x03001000])) + maybeEnd(), [])
            }
            if kind == 0x02001000, channel == 0x8001, endSent {
                let f = try Fields(packet.payload)
                guard try f.integer(1) == 1 else { throw BandError.wire("Invalid setup acknowledgement.") }
                _ = try f.bytes(2, count: 16); stage = "device_info"; deadline = now + 8
                return (try request("device_info", channel: 3, field: 3, payload: Data(), now: now, setup: true), [])
            }
            return (Data(), [])
        }
        if kind == 0x02000315, channel & 0x8000 == 0 {
            let f = try Fields(packet.payload), id = try f.integer(1)
            guard let p = pending[channel], p.id == id else {
                return (Data(), watchesOther && stage == "ready" ? [.other(kind: kind, channel: packet.channel, payload: packet.payload)] : [])
            }
            pending[channel] = nil
            // EMG is optional: a refused configuration read is reported, never fatal.
            if p.operation == "emg_configuration" || p.isOptional { return (Data(), [.reply(operation: p.operation, payload: packet.payload)]) }
            if p.isWristFeedback {
                feedbackNote = WristFeedbackResult.shape(packet.payload)
                return (Data(), [.wristFeedback(p.operation == "band_pattern" ? .pattern(packet.payload) : WristFeedbackResult(packet.payload))])
            }
            if p.isHandRequest {
                guard let status = try? f.integer(2), status == 1 else {
                    return (Data(), [.handUnavailable("The band did not confirm the wrist setting request. Try again.")])
                }
                return (Data(), [.reply(operation: p.operation, payload: packet.payload)])
            }
            let wantsEMG = try p.flags.map { try Fields($0).integer(2) == 1 } ?? false
            if try f.integer(2) != 1, wantsEMG {
                return (Data(), [.emgUnavailable("Band rejected a stream request that included EMG.")])
            }
            guard try f.integer(2) == 1 else { throw BandError.wire("Band rejected \(p.operation).") }
            if p.operation == "device_info" {
                _ = try Fields(f.bytes(4)); version = BandStreams.version(from: packet.payload); stage = "ready"; deadline = .infinity
                return (Data(), [.reply(operation: p.operation, payload: packet.payload), .ready])
            }
            if let flags = p.flags {
                let wanted = try Fields(flags)
                // A version 2 band answers with the state of each stream, so its switches are not compared.
                if version < 2 {
                    let accepted = try Fields(f.bytes(5))
                    if try wanted.integer(2) == 1, try accepted.integer(2, default: 0) != 1 {
                        return (Data(), [.emgUnavailable("Band acknowledged streams without EMG.")])
                    }
                    // A flag the band leaves out of its answer is off.
                    for n in [2, 3, 6, 8] { guard try accepted.integer(n, default: 0) == wanted.integer(n) else { throw BandError.wire("Band stream acknowledgement differs from request.") } }
                }
                gesturesEnabled = try wanted.integer(3) == 1
                gyroEnabled = try wanted.integer(6) == 1
                orientationEnabled = try wanted.integer(8) == 1
                emgEnabled = try wanted.integer(2) == 1
                inferenceEnabled = try wanted.integer(4, default: 0) == 1
            }
            return (Data(), [.reply(operation: p.operation, payload: packet.payload)])
        }
        if stage == "ready", gesturesEnabled, BandStreams.isGesture(kind, version: version) {
            let f = try Fields(packet.payload), synthetic = try f.integer(12, default: 0)
            guard synthetic <= 1 else { throw BandError.wire("Invalid gesture synthetic flag.") }
            return (Data(), [.gesture(finger: try f.integer(3, default: 0), action: try f.integer(4, default: 0), derived: try f.integer(5, default: 0), synthetic: synthetic == 1, sequence: try f.integer(1), timestamp: try f.integer(2))])
        }
        if stage == "ready", gyroEnabled, kind == 0x0200020f {
            let f = try Fields(packet.payload), bytes = try f.bytes(3, count: 6)
            return (Data(), [.motion(kind: .gyro, values: Self.gyro(bytes), sequence: try f.integer(1), timestamp: try f.integer(2))])
        }
        if stage == "ready", orientationEnabled, kind == 0x02000212 {
            let f = try Fields(packet.payload), bytes = try f.bytes(3, count: 16)
            return (Data(), [.motion(kind: .orientation, values: try Self.orientation(bytes), sequence: try f.integer(1), timestamp: try f.integer(2))])
        }
        if stage == "ready", emgEnabled, kind == 0x0200020a {
            let f = try Fields(packet.payload), bytes = try f.bytes(3, count: 256)
            return (Data(), [.emg(values: EMG.decode(bytes), sequence: try f.integer(1), timestamp: try f.integer(2))])
        }
        if stage == "ready", inferenceEnabled, kind == 0x0200020c {
            // Sensor data that will not parse is skipped, not fatal.
            guard let f = try? Fields(packet.payload), let raw = try? f.bytes(3) else { return (Data(), []) }
            return (Data(), [.inference(scores: BandWriting.scores(raw), pipeline: (try? f.integer(10, default: 0)) ?? 0)])
        }
        if stage == "ready", watchesOther { return (Data(), [.other(kind: kind, channel: packet.channel, payload: packet.payload)]) }
        return (Data(), [])
    }
    private func result(_ packet: Frame, kind: UInt32) throws -> (Data, [Signal]) {
        let channel = BandLink.route(packet.channel) & 0x7fff
        if stage == "trust", channel == 2 {
            guard kind == 0x03001000 else { throw BandError.trust(.rejected(result: kind, channel: packet.channel)) }
            guard !hostTrusted else { throw BandError.wire("Duplicate host authentication acknowledgement (channel \(packet.channel)).") }
            hostTrusted = true; return (try maybeEnd(), [])
        }
        if stage != "ready" { throw BandError.setupRejected(result: kind, channel: packet.channel) }
        if let p = pending[channel], p.operation == "emg_configuration" {
            pending[channel] = nil
            return (Data(), [.emgUnavailable("Band closed the EMG configuration service (\(String(kind, radix: 16))).")])
        }
        if let p = pending[channel], p.isOptional {
            pending[channel] = nil; opened.remove(channel)
            return (Data(), [.reply(operation: p.operation, payload: Data())])
        }
        if let p = pending[channel], p.isHandRequest {
            pending[channel] = nil; opened.remove(channel)
            return (Data(), [.handUnavailable("The band closed the wrist setting request. Try again.")])
        }
        if let p = pending[channel], p.isWristFeedback {
            pending[channel] = nil; opened.remove(channel)
            feedbackNote = "service result 0x\(String(kind, radix: 16))"
            return (Data(), [.wristFeedback(.unconfirmed)])
        }
        if channel == 6, pending[channel] == nil {
            opened.remove(channel)
            return (Data(), [])
        }
        if pending[channel] != nil || [5, 6, 7].contains(channel) { throw BandError.wire("Band service closed (\(String(kind, radix: 16))).") }
        return (Data(), [])
    }
    /// `inference` asks for the scores of the band's own model, or stops them. Left out, the
    /// request says nothing about them, as it always has.
    static func streamFlags(gyro: Bool, orientation: Bool, emg: Bool = false, inference: Bool? = nil) -> Data {
        PB.field(2, emg ? 1 : 0) + PB.field(3, 1) + (inference.map { PB.field(4, $0 ? 1 : 0) } ?? Data()) + PB.field(6, gyro ? 1 : 0) + PB.field(8, orientation ? 1 : 0)
    }
    static func gyro(_ bytes: Data) -> [Double] {
        (0..<3).map { index in
            let offset = index * 2
            let bits = UInt16(bytes.octet(offset)) | UInt16(bytes.octet(offset + 1)) << 8
            return Double(Int16(bitPattern: bits))
        }
    }
    static func orientation(_ bytes: Data) throws -> [Double] {
        let values = (0..<4).map { Double(Float(bitPattern: bytes.be32($0 * 4).byteSwapped)) }
        guard values.allSatisfy(\.isFinite) else { throw BandError.wire("Invalid orientation sample.") }
        return values
    }
    static let stopFlags = PB.field(2, 0) + PB.field(3, 0) + PB.field(6, 0) + PB.field(8, 0)
}
