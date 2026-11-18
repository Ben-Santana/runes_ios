// Offline checks that the app speaks the band's link on both firmware generations: public test
// vectors, the frame reader, and whole sessions against a pretend band. No Bluetooth, Keychain or network.
// swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Session/BandStatus.swift RunesIOS/Protocol/Wire.swift RunesIOS/Protocol/BandCrypto.swift RunesIOS/Protocol/BandLink.swift RunesIOS/Protocol/BandStreams.swift RunesIOS/Protocol/BandWriting.swift RunesIOS/Protocol/BandProtocol.swift RunesIOS/Protocol/EMG.swift RunesIOS/Authentication/OwnershipCeremony.swift RunesIOS/Persistence/IdentityStore.swift RunesIOS/Relay/RelayWire.swift RunesIOS/Firmware/FirmwareUpdate.swift Tests/BandLinkTests.swift -o /private/tmp/runes-band-link-tests && /private/tmp/runes-band-link-tests
// The vectors, the padding cases and the recorded gestures come from the public band-core project. See THIRD_PARTY_NOTICES.md.
import Foundation
import CryptoKit
import CommonCrypto

private func hex(_ text: String) -> Data {
    var data = Data(), text = Substring(text)
    while text.count >= 2 { data.append(UInt8(text.prefix(2), radix: 16)!); text = text.dropFirst(2) }
    return data
}
private func bytes(_ range: Range<UInt8>) -> Data { Data(range) }
private func hkdf(_ input: Data, salt: Data) -> Data {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: input), salt: salt, info: Data("AirShield".utf8), outputByteCount: 32)
        .withUnsafeBytes { Data($0) }
}
private func sha(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
/// A precondition whose test may throw.
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) throws {
    let held = try condition()
    precondition(held, message(), line: line)
}

/// The record cipher written again from the published description, so the app's own cipher is
/// checked against something other than itself.
private final class PretendCipher {
    let key: Data, late: Bool
    /// The key for the check, when it is not the record key.
    let checkKey: Data?
    var iv: Data, counter: UInt32
    init(key: Data, iv: Data, counter: UInt32, late: Bool, checkKey: Data? = nil) { self.key = key; self.iv = iv; self.counter = counter; self.late = late; self.checkKey = checkKey }

    private func aes(_ input: Data, _ operation: Int) -> Data {
        var output = [UInt8](repeating: 0, count: input.count), written = 0
        let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in input.withUnsafeBytes { p in
            CCCrypt(CCOperation(operation), CCAlgorithm(kCCAlgorithmAES), 0, k.baseAddress, 32, v.baseAddress, p.baseAddress, input.count, &output, output.count, &written)
        } } }
        precondition(status == kCCSuccess && written == input.count)
        return Data(output)
    }
    private func tag(_ body: Data) -> Data {
        var count = counter.littleEndian
        let message = (late ? Data([2, 2, 0, 0]) : Data()) + Swift.withUnsafeBytes(of: &count) { Data($0) } + body
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: checkKey ?? key)).prefix(8))
    }
    /// One record from plain bytes. Late firmware pads every record; early firmware only an uneven one.
    func seal(_ plain: Data) -> Data {
        var padded = plain
        let count = late ? 16 - plain.count % 16 : (16 - plain.count % 16) % 16
        padded.append(contentsOf: repeatElement(UInt8(0xc0 + count), count: count))
        let ciphertext = aes(padded, kCCEncrypt), body = Data([UInt8(ciphertext.count / 16 - 1)]) + ciphertext
        let record = Data([0x40]) + tag(body) + body
        iv = Data(ciphertext.suffix(16)); counter &+= 1
        return record
    }
    /// The plain bytes of one record, padding included.
    func open(_ record: Data) -> Data {
        precondition(record.octet(0) == 0x40 && tag(record.portion(9..<record.count)) == record.portion(1..<9), "The phone's record does not authenticate")
        let ciphertext = record.portion(10..<record.count), plain = aes(ciphertext, kCCDecrypt)
        iv = Data(ciphertext.suffix(16)); counter &+= 1
        return plain
    }
}

/// A band that follows the published rules of one firmware generation.
private final class PretendBand {
    let late: Bool
    /// Late firmware names a scheme here; a test can make it name another.
    var named: UInt64
    var offered: UInt64
    /// Derives its keys by the early rules whatever it names, to see the phone refuse it.
    var wrongKeys = false
    /// Checks its records with a key of its own, as the glasses' scheme does.
    var ownCheckKey = false
    /// Late firmware sets these bits on the flagged channels it sends on.
    var tag: UInt16
    let agreement = P256.KeyAgreement.PrivateKey(), signing = P256.Signing.PrivateKey()
    let challenge = bytes(0..<16), seed = bytes(0..<32), iv = bytes(16..<32)
    var hostPoint = Data(), hostChallenge = Data(), hostSeed = Data()
    private var toHost: PretendCipher!, fromHost: PretendCipher!
    private var inbox = Data(), plain = Data()
    /// How many bytes of padding each of the phone's records carried.
    private(set) var paddings: [Int] = []
    var point: Data { Data(agreement.publicKey.x963Representation.dropFirst()) }

    init(late: Bool) {
        self.late = late; named = late ? 26 : 3; offered = late ? 27 : 3; tag = late ? 0x1c00 : 0
    }

    private func key(_ secret: Data, _ challenge: Data, _ seed: Data) -> Data {
        if late && !wrongKeys { return hkdf(secret, salt: sha(challenge + seed)) }
        let hashed = sha(secret)
        return hkdf(hashed, salt: sha(hashed + challenge + seed))
    }

    /// The band's two clear messages, in answer to the phone's encryption request.
    func hello(_ request: Data) throws -> Data {
        let frame = try DataXReceiver().feed(request, padded: false)[0], fields = try Fields(frame.payload)
        precondition(frame.channel == 0x8001 && frame.words == [0x81000005, 0x02000001])
        try expect(try fields.integer(4) == 31, "The phone offers every scheme, as the Meta app does")
        hostPoint = try fields.bytes(1, count: 64); hostChallenge = try fields.bytes(2, count: 16)
        let ask = try Frame(channel: 0x8001 | tag, words: [0x81000005, 0x02000001], payload:
            PB.field(1, point) + PB.field(2, challenge) + PB.field(3, 0) + PB.field(4, offered) + PB.field(7, late ? 17 : 16)).encoded()
        let enable = try Frame(channel: 1, words: [0x02000002], payload:
            PB.field(1, point) + PB.field(2, seed) + PB.field(3, iv) + PB.field(4, 42) + PB.field(5, named)).encoded()
        return ask + enable
    }

    /// Takes the phone's encryption answer and derives both directions.
    func keys(_ enable: Frame) throws {
        let fields = try Fields(enable.payload)
        precondition(enable.channel == 1 && enable.words == [0x02000002])
        try expect(try fields.bytes(1) == hostPoint)
        try expect(try (late ? [26, offered] : [3]).contains(fields.integer(5)), "The phone names a scheme this firmware knows")
        hostSeed = try fields.bytes(2, count: 32)
        let secret = try agreement.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: Data([4]) + hostPoint))
            .withUnsafeBytes { Data($0) }
        func check(_ challenge: Data, _ seed: Data) -> Data? { ownCheckKey ? hkdf(secret, salt: sha(seed + challenge + Data("hmac_derive".utf8))) : nil }
        toHost = PretendCipher(key: key(secret, hostChallenge, seed), iv: iv, counter: 42, late: late, checkKey: check(hostChallenge, seed))
        fromHost = PretendCipher(key: key(secret, challenge, hostSeed), iv: try fields.bytes(3, count: 16), counter: UInt32(try fields.integer(4)), late: late, checkKey: check(challenge, hostSeed))
    }

    /// Frames as encrypted records. Late firmware can cut a frame across records, each one padded.
    func send(_ frames: [Frame], pieces: Int = 1) throws -> Data {
        var plain = Data()
        for var frame in frames {
            if frame.channel & 0x8000 != 0 { frame.channel |= tag }
            plain.append(try frame.encoded())
        }
        guard late, pieces > 1, plain.count > pieces * 3 else { return toHost.seal(plain) }
        var records = Data(), offset = 0
        for piece in 0..<pieces {
            // Uneven cuts, so that frame headers and payloads are both split.
            let end = piece == pieces - 1 ? plain.count : min(plain.count, offset + plain.count / pieces + piece * 3 + 1)
            if end > offset { records.append(toHost.seal(plain.portion(offset..<end))) }
            offset = end
        }
        return records
    }

    /// The frames in the phone's bytes, checking that each record is padded as this firmware expects.
    func read(_ bytes: Data) throws -> [Frame] {
        inbox.append(bytes)
        var frames: [Frame] = []
        while inbox.count >= 10 {
            let length = 10 + (Int(inbox.octet(9)) + 1) * 16
            if inbox.count < length { break }
            var record = fromHost.open(inbox.portion(0..<length)); inbox = Data(inbox.dropFirst(length))
            if late {
                let count = Int(record.octet(record.count - 1)) - 0xc0
                precondition((1...16).contains(count) && record.suffix(count).allSatisfy { $0 == UInt8(0xc0 + count) }, "Late firmware needs every record padded")
                record.removeLast(count); paddings.append(count)
            }
            plain.append(record)
            while plain.count >= 4 {
                let size = Int(plain.be16(0) & 0x7fff) + 4
                if plain.count < size { break }
                frames.append(try DataXReceiver().feed(plain.portion(0..<size), padded: false)[0])
                plain = Data(plain.dropFirst(size))
            }
            // What early firmware finds after whole frames is padding, and never a whole block of it.
            if !late {
                let padding = plain.count < 16 && plain.allSatisfy { $0 == UInt8(0xc0 + plain.count) } ? plain.count : 0
                paddings.append(padding)
                if padding > 0 { plain = Data() }
            }
        }
        return frames
    }
}

/// A phone and a pretend band joined together, with what the phone reported along the way.
private final class Pair {
    let host: BandProtocol, band: PretendBand
    let hostKey = P256.Signing.PrivateKey()
    var now: TimeInterval = 1
    /// Feed the phone one byte at a time, as a slow link might.
    var bytewise = false
    /// Cut the band's records into this many pieces on late firmware.
    var pieces = 1
    private(set) var log: [String] = []

    init(late: Bool, ceremony: OwnershipCeremony? = nil, verifyBand: Bool = true, way: Int = 0) throws {
        band = PretendBand(late: late)
        if let ceremony { host = try BandProtocol(identity: nil, ceremony: ceremony) }
        else {
            host = try BandProtocol(identity: BandIdentity(privateKey: hostKey.rawRepresentation, bandPoint: verifyBand ? BandCrypto.point(band.signing) : nil,
                                                          stage: "verified", allowMissingBandKey: verifyBand ? nil : true), way: way)
        }
    }

    func feed(_ data: Data) throws -> (Data, [BandProtocol.Signal]) {
        now += 0.01
        guard bytewise else { return try host.feed(data, now: now) }
        var output = Data(), signals: [BandProtocol.Signal] = []
        for byte in data { let (out, emitted) = try host.feed(Data([byte]), now: now); output.append(out); signals.append(contentsOf: emitted) }
        return (output, signals)
    }

    /// The clear exchange. Returns the first frames the phone sends once encryption is up.
    func handshake() throws -> [Frame] {
        let output = try feed(band.hello(host.start(now: 0))).0
        let size = Int(output.be16(0) & 0x7fff) + 4
        try band.keys(DataXReceiver().feed(output.portion(0..<size), padded: false)[0])
        return try band.read(output.portion(size..<output.count))
    }

    /// Band to phone. Returns what the phone wrote back.
    @discardableResult
    func deliver(_ frames: Frame...) throws -> [Frame] {
        let (output, signals) = try feed(band.send(frames, pieces: pieces))
        log.append(contentsOf: signals.map(Self.describe))
        return try band.read(output)
    }

    /// Mutual trust and the device information read, up to the point the app starts its requests.
    func authenticate(after first: [Frame], version: UInt64? = nil) throws {
        precondition(first.count == 1 && first[0].channel == 0x8002)
        precondition(first[0].words == (first[0].words.count == 1 ? [0x02001000] : [0x81000024, 0x02001000]))
        try expect(try deliver(Frame(channel: 2, words: [0x03001000], payload: Data())).isEmpty)
        let signature = try BandCrypto.sign(BandCrypto.transcript(band.hostChallenge, band.hostPoint, band.seed, band.point), privateKey: band.signing.rawRepresentation)
        let end = try deliver(Frame(channel: 0x8002, words: [0x02001001], payload: PB.field(2, signature)))
        precondition(end.count == 2 && end[0].words == [0x03001000] && end[0].channel == 2 | band.tag, "The acknowledgement keeps the band's channel bits")
        precondition(end[1].channel == 0x8001 && end[1].words == [0x02001000])
        let info = try deliver(Frame(channel: 0x8001, words: [0x02001000], payload: PB.field(1, 1) + PB.field(2, Data(repeating: 4, count: 16))))
        precondition(info.count == 1 && info[0].channel == 0x8003 && info[0].words == [0x8100ce56, 0x02000314])
        let about = PB.field(2, Data("fw".utf8)) + PB.field(3, Data("sw".utf8)) + PB.field(6, Data("SERIAL".utf8)) + (version.map { PB.field(15, $0) } ?? Data())
        try deliver(Frame(channel: 3, words: [0x02000315], payload: PB.field(1, Fields(info[0].payload).integer(1)) + PB.field(2, 1) + PB.field(4, about)))
        precondition(host.stage == "ready")
    }

    /// One request from the app and the band's answer to it.
    @discardableResult
    func ask(_ operation: String, _ channel: UInt16, _ field: Int, _ payload: Data = Data(), answer: Data) throws -> Frame {
        now += 0.01
        let sent = try band.read(host.request(operation, channel: channel, field: field, payload: payload, now: now))
        precondition(sent.count == 1 && sent[0].channel == channel | 0x8000)
        let fields = try Fields(sent[0].payload)
        try expect(try fields.bytes(field) == payload)
        try deliver(Frame(channel: channel, words: [0x02000315], payload: PB.field(1, fields.integer(1)) + answer))
        return sent[0]
    }

    static func describe(_ signal: BandProtocol.Signal) -> String {
        switch signal {
        case .ready: return "ready"
        case .reply(let operation, let payload): return "reply \(operation)\(payload.isEmpty ? " unanswered" : "")"
        case .ownership(let step):
            switch step {
            case .claim(let certificate, let serial, let secondary, let nonce, _): return "claim \(certificate.count) \(serial) \(secondary.count) \(nonce.count)"
            case .pair(let receipt, let signature): return "pair \(receipt) \(signature.count)"
            default: return "ownership"
            }
        case .enrolled: return "enrolled"
        case .motion(let kind, let values, let sequence, let timestamp): return "motion \(kind) \(values) \(sequence) \(timestamp)"
        case .gesture(let finger, let action, let derived, let synthetic, let sequence, let timestamp): return "gesture \(finger) \(action) \(derived) \(synthetic) \(sequence) \(timestamp)"
        case .emg(let values, let sequence, let timestamp): return "emg \(values.count) \(values[0]) \(sequence) \(timestamp)"
        case .emgUnavailable(let reason): return "emg unavailable \(reason)"
        case .handUnavailable(let reason): return "hand unavailable \(reason)"
        case .wristFeedback(let result): return "feedback \(result.rawValue)"
        case .inference(let scores, let pipeline): return "inference \(scores.count) \(pipeline)"
        case .other(let kind, let channel, _): return "other \(String(kind, radix: 16)) \(channel)"
        }
    }
}

@main
struct BandLinkTests {
    static func caught(_ work: () throws -> Void) -> BandError {
        do { try work(); preconditionFailure("Expected failure") }
        catch let error as BandError { return error }
        catch { preconditionFailure("Unexpected error type") }
    }

    static func main() throws {
        try vectors()
        try records()
        try frames()
        precondition(BandLink.psm(Data([0xff, 0x00])) == 255 && BandLink.psm(Data([0x80, 0x00])) == 128)
        for odd in [nil, Data(), Data([0x00]), Data([0xff]), Data([0x7f, 0x00]), Data([0xff, 0x01]), Data([0xff, 0x00, 0x00])] { precondition(BandLink.psm(odd) == nil) }
        print("Link rules passed: public key and record vectors, scheme choice, padding on both generations, split frames, and the channel number.")

        // The same script on both generations must report the same things to the app.
        let early = try session(late: false), late = try session(late: true)
        precondition(early == late && early.count == 25, "A session on late firmware reports what one on early firmware does")
        let slow = try session(late: true, bytewise: true), cut = try session(late: true, pieces: 3), shredded = try session(late: true, pieces: 7, bytewise: true)
        precondition(slow == early && cut == early && shredded == early)
        try expect(try session(late: false, bytewise: true) == early)
        print("Sessions passed: trust, device information, streams, gestures, motion, EMG, wrist setting, vibration, named settings and update status on early and late firmware, whole, bytewise and with frames cut across records.")

        try update(late: false); try update(late: true); try update(late: true, pieces: 3)
        print("Update passed: a trial transfer over the link on early and late firmware, eight chunks in flight, numbered after the app's own requests.")
        try recording()
        try streams()
        try enrollment()
        try refusals()
        try ways()
        try writing()
        print("Band link checks passed.")
    }

    /// Published vectors. Scheme 3 comes from the reference Python package, and the raw secret
    /// derivation and the prefixed check from the glasses' scheme 31, which scheme 26 shares.
    static func vectors() throws {
        precondition(BandLink.original.key(secret: bytes(0..<32), challenge: bytes(0..<16), seed: bytes(32..<64))
            == hex("5080496832e72e0a4de90f22e7797a3c6277197b4bd29f296bd7142850db1998"))
        let secret = hex("f2f6f1f1a56fb52122ec338ed887338b42b976290253dbd6f48f3cc0b15b2ba8")
        precondition(BandLink.revised.key(secret: secret, challenge: hex("c75051fb3e50142ba10c15a023777c6b"), seed: Data(repeating: 0x41, count: 32))
            == hex("d70b81653601bbc46f13c6749324fa2b680af0064592a2c663a0891d7a43875d"))
        let challenge = Data("0123456789abcdef".utf8), seed = hex("c58e0f4bf291a0b2f50a40955b0bd53c9c7fd5a9f5fdbf7b14272efed585ca14")
        precondition(BandLink.revised.key(secret: secret, challenge: challenge, seed: seed)
            == hex("2f72596312c1120bf869dd69b0c6b4aa6cc05981723a45a4bb294343a11793cc"))
        // A published scheme 31 record. Its check uses a separate key, derived here, and the same
        // prefix and counter layout as scheme 26.
        let packet = hex("40f4d00bc5a22d9ecd0055ff7a63ea6ac9f1723721ffa9d7f4a7")
        let checkKey = hkdf(secret, salt: sha(seed + challenge + Data("hmac_derive".utf8)))
        precondition(BandLink.revised.tag(packet.portion(9..<packet.count), counter: 0xba8d8b80, key: checkKey) == packet.portion(1..<9))
        precondition(BandLink.original.tag(packet.portion(9..<packet.count), counter: 0xba8d8b80, key: checkKey) != packet.portion(1..<9))

        // The same published record gives the key of its own that scheme 31 checks with.
        let own = BandLink(scheme: 31, hashesSecret: false, macPrefix: Data([2, 2, 0, 0]), padsEveryRecord: true, checkKey: .derived)
        precondition(own.checkKey(secret: secret, challenge: challenge, seed: seed, recordKey: Data(count: 32)) == checkKey)
        precondition(BandLink.revised.checkKey(secret: secret, challenge: challenge, seed: seed, recordKey: bytes(0..<32)) == bytes(0..<32))
        // Early firmware has one way. Newer firmware has the known one first, named 26 and then
        // named as the band offered, and after it the other ways the public project lists.
        precondition(BandLink.ways(offered: 3) == [.original] && BandLink.ways(offered: 4).isEmpty)
        let ways = BandLink.ways(offered: 27)
        precondition(ways.count == 16 && ways[0] == .revised && ways[1].scheme == 27 && ways[1].macPrefix == BandLink.revised.macPrefix && !ways[1].hashesSecret)
        precondition(ways[2].checkKey == .derived && ways[2].scheme == 26 && ways.allSatisfy(\.padsEveryRecord) && BandLink.ways(offered: 26).count == 8)
        precondition(BandLink.offered(3) == .original && BandLink.offered(27) == .revised && BandLink.offered(31) == .revised)
        for mask: UInt64 in [0, 1, 2, 4, 7] { precondition(BandLink.offered(mask) == nil) }
        precondition(BandLink.route(0x9c01) == 0x8001 && BandLink.route(0x9801) == 0x8001 && BandLink.route(0x9502) == 0x8002)
        precondition(BandLink.route(0x8005) == 0x8005 && BandLink.route(6) == 6 && BandLink.route(0x1c06) == 6)
    }

    /// The record cipher against the reference vectors and against the pretend band's own cipher.
    static func records() throws {
        let first = hex("40c9f748fb0f0ae8e0018675352ee743a1e58ccd288d25d27f6e72551887e4aad6fc68175e7287a1eee1")
        let second = hex("4038cb0decaa0692b900d5962230f8734c8a3de4d262936261f1")
        let receiver = try AirShieldReceiver(AirShieldCipher(key: bytes(0..<32), iv: bytes(0..<16), counter: UInt64(UInt32.max)))
        var decoded: [Data] = []
        for byte in first + Data([0x81, 0, 1, 2, 42, 43, 44]) + second { decoded.append(contentsOf: try receiver.feed(Data([byte]))) }
        precondition(decoded == [Data("first block.....second block....".utf8), Data("last block......".utf8)])
        let sender = try AirShieldCipher(key: bytes(0..<32), iv: bytes(0..<16), counter: UInt64(UInt32.max))
        try expect(try sender.encrypt(decoded[0]) == first && sender.encrypt(decoded[1]) == second, "Early records are byte for byte what they were")

        for (link, late) in [(BandLink.original, false), (BandLink.revised, true)] {
            let key = bytes(7..<39), iv = bytes(3..<19)
            let app = try AirShieldCipher(key: key, iv: iv, counter: 9, link: link), band = PretendCipher(key: key, iv: iv, counter: 9, late: late)
            let back = try AirShieldCipher(key: key, iv: iv, counter: 9, link: link), bandOut = PretendCipher(key: key, iv: iv, counter: 9, late: late)
            for length in [1, 15, 16, 17, 31, 32, 48, 950, 4080] {
                let plain = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7) })
                let padding = late ? 16 - length % 16 : (16 - length % 16) % 16
                let opened = band.open(try app.encrypt(plain))
                precondition(opened.count == length + padding && opened.prefix(length) == plain)
                precondition(opened.suffix(padding).allSatisfy { $0 == UInt8(0xc0 + padding) })
                try expect(try back.decrypt(bandOut.seal(plain)) == opened)
            }
        }
        // A whole block of padding leaves room for 4080 bytes of data, which is where the app cuts.
        let limit = try AirShieldCipher(key: bytes(0..<32), iv: bytes(0..<16), counter: 0, link: .revised)
        precondition(BandLink.revised.recordLimit == 4080 && BandLink.original.recordLimit == 4096)
        _ = try limit.encrypt(Data(count: 4080))
        _ = caught { _ = try limit.encrypt(Data(count: 4096)) }
        // A record changed on the way is refused, on either generation.
        for link in [BandLink.original, .revised] {
            var record = try AirShieldCipher(key: bytes(0..<32), iv: bytes(0..<16), counter: 1, link: link).encrypt(Data(count: 20))
            record[12] ^= 1
            let error = caught { _ = try AirShieldCipher(key: bytes(0..<32), iv: bytes(0..<16), counter: 1, link: link).decrypt(record) }
            guard case .authentication = error else { preconditionFailure("A changed record must fail its check") }
        }
        // The two generations do not read each other's records.
        let crossed = try AirShieldCipher(key: bytes(0..<32), iv: bytes(0..<16), counter: 1, link: .revised).encrypt(Data(count: 20))
        _ = caught { _ = try AirShieldCipher(key: bytes(0..<32), iv: bytes(0..<16), counter: 1).decrypt(crossed) }
    }

    /// The frame reader. The cases are band-core's, which came from what its authors saw on bands.
    static func frames() throws {
        func frame(_ channel: UInt16, _ word: UInt32, _ payload: Data) throws -> Data { try Frame(channel: channel, words: [word], payload: payload).encoded() }
        func padded(_ data: Data, whole: Bool) -> Data {
            let count = whole ? 16 - data.count % 16 : (16 - data.count % 16) % 16
            return data + Data(repeating: UInt8(0xc0 + count), count: count)
        }
        // Early firmware: an aligned frame that happens to end in padding bytes keeps them.
        for tail in [Data([0xc1]), Data([0xc2, 0xc2])] {
            var payload = bytes(0..<24); payload.replaceSubrange((24 - tail.count)..<24, with: tail)
            let record = try frame(5, 0x0200020d, payload)
            precondition(record.count == 32)
            let read = try DataXReceiver().feed(record)
            precondition(read.count == 1 && read[0].channel == 5 && read[0].words == [0x0200020d] && read[0].payload == payload)
        }
        for length in 1...16 {
            let payload = Data((0..<length).map { UInt8($0) ^ 0xc1 })
            for late in [false, true] {
                let reader = DataXReceiver(); reader.everyRecordPadded = late
                let read = try reader.feed(padded(try frame(5, 0x0200020d, payload), whole: late))
                precondition(read.count == 1 && read[0].payload == payload && reader.pending.isEmpty, "payload length \(length)")
            }
        }
        let early = DataXReceiver()
        var first = bytes(0..<24); first[23] = 0xc1
        try expect(try early.feed(frame(5, 0x0200020d, first)).first?.payload == first)
        let next = try early.feed(padded(frame(0x8010, 0x02000315, bytes(100..<110)), whole: false))
        precondition(next.count == 1 && next[0].channel == 0x8010 && next[0].payload == bytes(100..<110))

        // Late firmware: an aligned frame is followed by a whole block of 0xd0, which must go.
        // Seen on a band as a 1888 byte identity reply in a 1904 byte record.
        let late = DataXReceiver(); late.everyRecordPadded = true
        let aligned = try frame(2, 0x02003001, bytes(0..<24))
        precondition(aligned.count == 32)
        try expect(try late.feed(aligned + Data(repeating: 0xd0, count: 16)).first?.payload == bytes(0..<24) && late.pending.isEmpty)
        let after = try late.feed(frame(2, 0x02002001, bytes(0..<18)) + Data(repeating: 0xc6, count: 6))
        precondition(after.count == 1 && after[0].words == [0x02002001] && after[0].payload == bytes(0..<18))
        // The early reader would have kept that block and read the next frame out of it.
        let stuck = DataXReceiver()
        try expect(try stuck.feed(aligned + Data(repeating: 0xd0, count: 16)).count == 1 && stuck.pending.count == 16)

        // Late firmware cuts frames across records. A record that ends four bytes short of its
        // frame, padded with four bytes, must not be read as the whole frame. Seen during an update.
        let gyro = try frame(5, 0x0200020f, bytes(0..<40)), small = try frame(5, 0x0200020f, Data(repeating: 7, count: 8))
        precondition(gyro.count == 48)
        try expect(try late.feed(gyro.prefix(44) + Data(repeating: 0xc4, count: 4)).isEmpty)
        let rest = try late.feed(padded(gyro.suffix(4) + small, whole: true))
        precondition(rest.count == 2 && rest[0].payload == bytes(0..<40) && rest[1].payload == Data(repeating: 7, count: 8))
        // A frame cut into single blocks, with its header split too.
        let long = try frame(0x9c05, 0x0200020a, Data((0..<300).map { UInt8(truncatingIfNeeded: $0) }))
        var got: [Frame] = [], offset = 0
        for size in [2, 15, 16, 1, 31, 100, 143] { got += try late.feed(padded(long.portion(offset..<(offset + size)), whole: true)); offset += size }
        precondition(offset == long.count && got.count == 1 && got[0].channel == 0x9c05 && got[0].payload.count == 300)
    }

    /// A whole connection as the app drives it, with the band's side played by the pretend band.
    static func session(late: Bool, pieces: Int = 1, bytewise: Bool = false) throws -> [String] {
        let pair = try Pair(late: late)
        pair.bytewise = bytewise; pair.pieces = pieces
        let first = try pair.handshake()
        // The phone proves itself with the hash of its owner key and a signature the band can check.
        let proof = try Fields(first[0].payload)
        try expect(try proof.bytes(1) == sha(BandCrypto.point(pair.hostKey)))
        try BandCrypto.verify(BandCrypto.transcript(pair.band.challenge, pair.band.point, pair.band.hostSeed, pair.band.hostPoint),
                              signature: proof.bytes(2, count: 64), point: BandCrypto.point(pair.hostKey))
        precondition(pair.host.linkNote == (late ? "offered 27, using 26 (way 1 of 16), band named 26" : "offered 3, using 3, band named 3"))
        precondition(pair.host.linkIsGuess == late)
        try pair.authenticate(after: first)

        // What the app asks for as soon as the band is ready.
        let active = try pair.ask("request_active", 6, 5, PB.field(6, 2), answer: PB.field(2, 1))
        precondition(active.words == [0x8100ce56, 0x02000314])
        try pair.ask("input_subscription", 5, 4, answer: PB.field(2, 1) + PB.field(5, Data()))
        try pair.ask("emg_configuration", 7, 5, answer: PB.field(2, 1) + PB.field(6, Data()))
        let flags = BandProtocol.streamFlags(gyro: true, orientation: true, emg: true)
        // Late firmware reports the flags that are on, with others the app never asked about.
        let accepted = late ? PB.field(2, 1) + PB.field(3, 1) + PB.field(4, 0) + PB.field(6, 1) + PB.field(8, 1) + PB.field(29, 1) : flags
        let start = try pair.ask("start_streams", 5, 4, flags, answer: PB.field(2, 1) + PB.field(5, accepted))
        precondition(start.words.isEmpty, "The stream service is opened once")

        // Streams. The type word comes with the first frame on a channel and not again.
        func gesture(_ sequence: UInt64, finger: UInt64, action: UInt64, derived: UInt64) -> Data {
            PB.field(1, sequence) + PB.field(2, 1000 + sequence) + PB.field(3, finger) + PB.field(4, action) + PB.field(5, derived)
        }
        try pair.deliver(Frame(channel: 0x8005, words: [0x0200020d], payload: gesture(1, finger: 2, action: 1, derived: 0)))
        try pair.deliver(Frame(channel: 0x8005, words: [], payload: gesture(2, finger: 2, action: 0, derived: 9)),
                         Frame(channel: 0x8005, words: [], payload: gesture(3, finger: 2, action: 2, derived: 0)))
        let turn = Data([0x10, 0x00, 0xf0, 0xff, 0x05, 0x00])
        try pair.deliver(Frame(channel: 0x8010, words: [0x0200020f], payload: PB.field(1, 7) + PB.field(2, 77) + PB.field(3, turn)))
        var quaternion = Data()
        for value: Float in [0.5, 0.5, 0.5, 0.5] { withUnsafeBytes(of: value.bitPattern.littleEndian) { quaternion.append(contentsOf: $0) } }
        try pair.deliver(Frame(channel: 0x8011, words: [0x02000212], payload: PB.field(1, 8) + PB.field(2, 88) + PB.field(3, quaternion)))
        let samples = Data((0..<256).map { UInt8(truncatingIfNeeded: $0 &* 3) })
        try pair.deliver(Frame(channel: 5, words: [0x0200020a], payload: PB.field(1, 9) + PB.field(2, 99) + PB.field(3, samples)),
                         Frame(channel: 0x8005, words: [], payload: gesture(4, finger: 3, action: 3, derived: 0)))

        // Requests the app makes while streaming, each on the channel it uses on the real band.
        try pair.ask("read_hand", 6, 5, answer: PB.field(2, 1) + PB.field(6, Handedness.left.configuration + PB.field(6, 2)))
        try pair.ask("set_hand", 6, 5, Handedness.right.configuration, answer: PB.field(2, 1))
        try pair.ask("wrist_feedback", 6, 17, WristFeedbackPhase.wrap.payload, answer: PB.field(2, 1) + PB.field(18, Data()))
        try pair.ask("band_pattern", 6, 17, PB.field(2, PB.field(1, 1)), answer: PB.field(2, 1) + PB.field(18, PB.field(1, 0) + PB.field(3, Data())))
        let count = try pair.ask("named_count", NamedSettings.channel, NamedSettings.field, NamedSettings.count(), answer: PB.field(2, 1) + PB.field(14, PB.field(1, PB.field(1, 27))))
        precondition(count.words == [0x8100ce56, 0x02000314])
        try pair.ask("named_read", NamedSettings.channel, NamedSettings.field, NamedSettings.read(id: 22), answer: PB.field(2, 1) + PB.field(14, PB.field(3, PB.field(1, 22) + PB.field(4, PB.field(1, 3)))))
        // The update status, as the band tests page asks it: idle, stable, three items and a key.
        let item = { (kind: UInt64, version: UInt64) in PB.field(5, PB.field(1, kind) + PB.field(2, version)) }
        let status = PB.field(2, PB.field(2, 1) + PB.field(3, 0) + PB.field(4, 1) + item(0, 770435744) + item(1, 770435744) + item(2, 770435744) + PB.field(6, 12))
        try pair.ask("try_firmware", BandTrial.channel, 7, BandTrial.firmwareStatus, answer: PB.field(2, 1) + PB.field(8, status))
        // A frame the size of a firmware chunk, and one that fills its blocks exactly.
        try pair.ask("try_chunk", BandTrial.channel, 9, Data(count: 960), answer: PB.field(2, 1) + PB.field(10, PB.field(2, PB.field(1, 1) + PB.field(2, 950))))
        let before = pair.band.paddings.count
        try pair.ask("try_aligned", BandTrial.channel, 9, Data(count: 8), answer: PB.field(2, 1))
        precondition(pair.band.paddings[before] == (late ? 16 : 0), "A frame of whole blocks is padded only on late firmware")
        // A service the band closes, and a request it never answers, are reported and not fatal.
        now(pair) { try $0.band.read($0.host.request("try_closed", channel: 9, field: 7, payload: Data(), now: $0.now)) }
        try pair.deliver(Frame(channel: 9, words: [0x0300c001], payload: Data()))
        now(pair) { try $0.band.read($0.host.request("try_silent", channel: 9, field: 7, payload: Data(), now: $0.now)) }
        let expired = try pair.host.tick(now: pair.now + 9)
        try expect(expired.count == 1 && Pair.describe(expired[0]) == "reply try_silent unanswered")
        pair.now += 10
        try pair.deliver(Frame(channel: 0x8005, words: [], payload: gesture(5, finger: 1, action: 6, derived: 0)))
        try pair.ask("stop_streams", 5, 4, BandProtocol.stopFlags, answer: PB.field(2, 1) + PB.field(5, late ? Data() : BandProtocol.stopFlags))
        precondition(pair.host.stage == "ready")
        return pair.log
    }

    /// A whole trial transfer carried over the encrypted link. The update numbers its requests
    /// after the app's own and has several in flight, and the band's answers come back as
    /// frames no request of the app was waiting for.
    static func update(late: Bool, pieces: Int = 1) throws {
        let pair = try Pair(late: late)
        pair.pieces = pieces
        try pair.authenticate(after: pair.handshake())
        try pair.ask("request_active", 6, 5, PB.field(6, 2), answer: PB.field(2, 1))
        pair.host.watchesOther = true
        let firmware = Data((0..<30_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ $0 >> 7) })
        let item = FirmwareUpdate.Item(kind: 0, name: "firmware", data: firmware, md5: Data(Insecure.MD5.hash(data: firmware)))
        let job = FirmwareUpdate(FirmwareUpdate.Plan(version: 1003366292, items: [item], keyNumber: 20, wrappedKey: nil, mode: .trial))
        var held = Data(), received = Data(), state: UInt64 = 1, opened = false, most = 0, numbers: [UInt64] = []
        func general(_ code: UInt64) -> Data { PB.field(1, PB.field(1, PB.field(1, code))) }
        var queue = job.begin(ids: &pair.host.requestNumber, now: pair.now)
        while !job.done {
            precondition(!queue.isEmpty, "the update stalled")
            most = max(most, queue.count)
            // Everything waiting goes out in one write, as it does when chunks fill the band's room.
            var wire = Data()
            for body in queue { wire.append(try pair.host.post(channel: BandTrial.channel, body: body)) }
            queue = []
            var answers: [Frame] = []
            for frame in try pair.band.read(wire) {
                precondition(frame.channel == BandTrial.channel | 0x8000 && frame.words == (opened ? [] : [0x8100ce56, 0x02000314]))
                opened = true
                let fields = try Fields(frame.payload), number = try fields.integer(1)
                numbers.append(number)
                var answer = Data()
                if let raw = try? fields.bytes(7) {
                    let request = try Fields(raw)
                    if request.values[1] != nil {
                        let info = PB.field(2, 1) + PB.field(4, state) + PB.field(5, PB.field(2, 770435744)) + PB.field(5, PB.field(1, 1) + PB.field(2, 770435744)) + PB.field(5, PB.field(1, 2)) + PB.field(6, 20)
                        answer = PB.field(8, PB.field(2, info))
                    } else if request.values[2] != nil { state = 2; held = Data(); answer = PB.field(8, general(0)) }
                    else if request.values[3] != nil {
                        let good = Data(Insecure.MD5.hash(data: held)) == item.md5
                        if good { state = 3; received = held }
                        answer = PB.field(8, PB.field(3, PB.field(1, PB.field(1, good ? 0 : 300))))
                    } else if request.values[5] != nil { state = 1; held = Data(); answer = PB.field(8, general(0)) }
                    else { preconditionFailure("a request the trial must never send") }
                } else {
                    let request = try Fields(fields.bytes(9))
                    if let raw = try? request.bytes(1) {
                        try expect(try Fields(raw).bytes(1) == item.md5)
                        answer = PB.field(10, PB.field(1, PB.field(1, 1) + PB.field(2, 16_000) + PB.field(3, UInt64(held.count)) + PB.field(5, 1)))
                    } else {
                        let chunk = try Fields(request.bytes(2)), offset = try chunk.integer(2, default: 0)
                        precondition(offset == UInt64(held.count), "chunks arrive in order")
                        held.append(try chunk.bytes(3))
                        answer = PB.field(10, PB.field(2, PB.field(1, 1) + PB.field(2, offset)))
                    }
                }
                answers.append(Frame(channel: BandTrial.channel | pair.band.tag, words: [0x02000315], payload: PB.field(1, number) + PB.field(2, 1) + answer))
            }
            let (output, signals) = try pair.feed(pair.band.send(answers, pieces: pieces))
            precondition(output.isEmpty && signals.count == answers.count)
            for signal in signals {
                guard case .other(let kind, let channel, let payload) = signal else { preconditionFailure("an update answer was taken for something else") }
                precondition(kind == 0x02000315 && BandLink.route(channel) == BandTrial.channel)
                queue += job.receive(payload, ids: &pair.host.requestNumber, now: pair.now)
            }
        }
        precondition(job.succeeded && received == firmware && state == 1 && most == FirmwareUpdate.windowLimit)
        // Device information was request 1 and the active state request 2, so the update starts at 3 and never repeats a number.
        precondition(numbers.first == 3 && numbers == Array(3..<(3 + UInt64(numbers.count))))
        // The app's own requests carry on after the update's numbers, and its answers are its own again.
        pair.host.watchesOther = false
        let next = try pair.ask("named_count", NamedSettings.channel, NamedSettings.field, NamedSettings.count(), answer: PB.field(2, 1) + PB.field(14, PB.field(1, PB.field(1, 27))))
        let after = try Fields(next.payload).integer(1)
        precondition(after == 3 + UInt64(numbers.count) && next.words.isEmpty)
    }

    private static func now(_ pair: Pair, _ work: (Pair) throws -> [Frame]) {
        pair.now += 0.01
        let sent = try! work(pair)
        precondition(sent.count == 1)
    }

    /// Gestures recorded from a band on late firmware by the band-core authors (2026-10-25), sent
    /// through the late link. The app must read the same fingers, actions, counters and band times.
    static func recording() throws {
        let fingers = ["unknown", "thumb", "index", "middle", "notApplicable"]
        let actions = ["unknown", "press", "release", "tap", "doubletap", "click", "up", "down", "left", "right", "wake", "swipeIn", "swipeOut"]
        let derived = ["unknown", "singleTap", "doubleTap", "buttonHold", "buttonRelease", "buttonUp", "buttonDown", "buttonLeft", "buttonRight", "buttonPress", "buttonHoldRelease"]
        let lines = """
        16.320 G index press unknown seq=1200 band_us=28211308441 syn=false
        16.320 G index unknown buttonPress seq=1946 band_us=28211308441 syn=false
        16.454 G index release unknown seq=1201 band_us=28211447571 syn=false
        16.454 G index unknown buttonRelease seq=1947 band_us=28211447601 syn=false
        16.454 G index unknown singleTap seq=1948 band_us=28211447601 syn=false
        20.038 G index press unknown seq=1202 band_us=28215025970 syn=false
        20.038 G index unknown buttonPress seq=1949 band_us=28215026001 syn=false
        20.157 G index release unknown seq=1203 band_us=28215151611 syn=false
        20.157 G index unknown buttonRelease seq=1950 band_us=28215151611 syn=false
        20.157 G index unknown singleTap seq=1951 band_us=28215151611 syn=false
        23.039 G index press unknown seq=1204 band_us=28218026062 syn=false
        23.039 G index unknown buttonPress seq=1952 band_us=28218026093 syn=false
        """.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        let pair = try Pair(late: true)
        pair.pieces = 2
        try pair.authenticate(after: pair.handshake())
        let flags = BandProtocol.streamFlags(gyro: false, orientation: false)
        try pair.ask("start_streams", 5, 4, flags, answer: PB.field(2, 1) + PB.field(5, PB.field(3, 1)))
        var expected: [String] = [], tracker = SequenceTracker()
        for (index, parts) in lines.enumerated() {
            let finger = UInt64(fingers.firstIndex(of: parts[2])!), action = UInt64(actions.firstIndex(of: parts[3])!), kind = UInt64(derived.firstIndex(of: parts[4])!)
            let sequence = UInt64(parts[5].dropFirst(4))!, time = UInt64(parts[6].dropFirst(8))!
            // Zero is left off the wire, as the band does.
            var payload = PB.field(1, sequence) + PB.field(2, time) + PB.field(3, finger)
            if action != 0 { payload += PB.field(4, action) }
            if kind != 0 { payload += PB.field(5, kind) }
            try pair.deliver(Frame(channel: 0x8005, words: index == 0 ? [0x0200020d] : [], payload: payload))
            expected.append("gesture \(finger) \(action) \(kind) false \(sequence) \(time)")
            precondition(tracker.gap(sequence, stream: action != 0 ? .raw : .derived) == nil, "The recorded counters run without gaps")
        }
        precondition(Array(pair.log.suffix(expected.count)) == expected)
        print("Recording passed: \(expected.count) gestures recorded on late firmware read back through the late link.")
    }

    /// How streams are asked for, by the protocol version the band reports about itself.
    static func streams() throws {
        let flags = BandProtocol.streamFlags(gyro: true, orientation: false)
        for version: UInt64 in [0, 1] { precondition(BandStreams.request(flags, version: version) == flags, "Earlier bands get the request they always got") }
        precondition(BandStreams.version(from: PB.field(4, PB.field(2, Data("fw".utf8)))) == 1 && BandStreams.version(from: Data()) == 1)
        precondition(BandStreams.version(from: PB.field(4, PB.field(15, 2))) == 2)
        let listed = try Fields(BandStreams.request(flags, version: 2))
        try expect(try listed.integer(3) == 1 && listed.integer(6) == 1 && listed.integer(8) == 0 && listed.integer(35) == 90)
        precondition(listed.values[37].map { if case .bytes(2, let name) = $0[0] { return name == Data("GenericC50".utf8) } else { return false } } == true)
        var entries: [UInt64: UInt64] = [:]
        for case .bytes(2, let entry) in listed.values[36] ?? [] { let pair = try Fields(entry); entries[try pair.integer(1)] = try pair.integer(2) }
        precondition(entries.count == 31 && entries[60] == 1 && entries[109] == 1 && entries[156] == 1 && entries[200] == 1 && entries[15] == 1 && entries[18] == 0 && entries[13] == nil)
        precondition(BandStreams.isGesture(0x0200020d, version: 1) && BandStreams.isGesture(0x0200020d, version: 2))
        for kind: UInt32 in [0x0200023c, 0x02000264, 0x020002c8] { precondition(BandStreams.isGesture(kind, version: 2) && !BandStreams.isGesture(kind, version: 1)) }
        for kind: UInt32 in [0x0200020f, 0x02000212, 0x0200020a, 0x0200023b, 0x020002c9, 0x0200033c, 0x02000315] { precondition(!BandStreams.isGesture(kind, version: 2)) }

        // A band on late firmware that reports version 2: the list goes out, the answer carries
        // stream states where the switches were, and gestures come under their own kinds.
        for version: UInt64 in [1, 2] {
            let pair = try Pair(late: true)
            try pair.authenticate(after: pair.handshake(), version: version)
            let states = PB.field(35, PB.field(1, 60) + PB.field(2, 2)) + PB.field(35, PB.field(1, 200) + PB.field(2, 2))
            let request = try pair.band.read(pair.host.request("start_streams", channel: 5, field: 4, payload: flags, now: pair.now))
            let sent = try Fields(Fields(request[0].payload).bytes(4))
            precondition((sent.values[36]?.count ?? 0) == (version == 2 ? 31 : 0))
            try pair.deliver(Frame(channel: 5, words: [0x02000315], payload: PB.field(1, Fields(request[0].payload).integer(1)) + PB.field(2, 1) + PB.field(5, version == 2 ? states : flags)))
            precondition(pair.log.last == "reply start_streams")
            let tap = PB.field(1, 5) + PB.field(2, 500) + PB.field(3, 2) + PB.field(4, 3)
            try pair.deliver(Frame(channel: 0x8005, words: [0x0200023c], payload: tap), Frame(channel: 0x8006, words: [0x020002c8], payload: tap), Frame(channel: 0x8007, words: [0x0200020d], payload: tap))
            precondition(pair.log.filter { $0 == "gesture 2 3 0 false 5 500" }.count == (version == 2 ? 3 : 1))
            let stop = try pair.band.read(pair.host.request("stop_streams", channel: 5, field: 4, payload: BandProtocol.stopFlags, now: pair.now + 1))
            let stopped = try Fields(Fields(stop[0].payload).bytes(4))
            precondition((stopped.values[36]?.count ?? 0) == (version == 2 ? 31 : 0))
        }
        print("Streams passed: the request by protocol version, the listed kinds, and gestures under their own kinds on version 2 only.")
    }

    /// Taking ownership of a band, which is the way back if a band ever refuses its saved owner.
    static func enrollment() throws {
        for late in [false, true] {
            let ceremony = try OwnershipCeremony(previous: nil, allowMissingBandKey: true) { _ in }
            let pair = try Pair(late: late, ceremony: ceremony)
            pair.pieces = late ? 4 : 1
            let first = try pair.handshake()
            precondition(first.count == 1 && first[0].channel == 0x8002 && first[0].words == [0x81000024, 0x02003000] && pair.host.stage == "ceremony")
            // A reply of exactly 1888 bytes, the size seen on a band, which late firmware sends in 1904.
            let identity = PB.field(1, Data(repeating: 1, count: 900)) + PB.field(2, Data("TESTBAND01".utf8)) + PB.field(5, Data(repeating: 2, count: 962))
            precondition(identity.count == 1880)
            let challenge = try pair.deliver(Frame(channel: 0x8002, words: [0x02003001], payload: identity))
            precondition(challenge.count == 1 && challenge[0].words == [0x02002000])
            try pair.deliver(Frame(channel: 2, words: [0x02002001], payload: PB.field(1, Data(repeating: 3, count: 16))))
            precondition(pair.log.last == "claim 900 TESTBAND01 962 16")
            // A long receipt, so the phone's own frame is cut across records.
            let receipt = String(repeating: "r", count: 9000)
            pair.now += 0.01
            let claim = try pair.band.read(pair.host.resume(PairCompletion(signature: Data([4, 4]), receipt: receipt)))
            try expect(claim.count == 1 && claim[0].words == [0x02002002] && (try Fields(claim[0].payload).bytes(2)) == Data(receipt.utf8))
            try pair.deliver(Frame(channel: 2, words: [0x02002003], payload: PB.field(1, Data([5])) + PB.field(2, Data("band-receipt".utf8))))
            precondition(pair.log.last == "pair band-receipt 1")
            let finish = try pair.band.read(pair.host.resume(PairCompletion(signature: Data([6]), receipt: "final")))
            precondition(finish.count == 1 && finish[0].words == [0x02002004])
            let trust = try pair.deliver(Frame(channel: 2, words: [0x02002005], payload: Data()))
            precondition(pair.log.last == "enrolled" && pair.host.stage == "trust" && trust[0].words == [0x02001000])
            try pair.authenticate(after: trust)
        }
        print("Enrollment passed: the ownership steps and the trust that follows, on early and late firmware.")
    }

    /// What must fail, and how it is reported.
    static func refusals() throws {
        // A band that offers schemes this app has no rules for.
        let unknown = try Pair(late: true); unknown.band.offered = 4
        let unsupported = caught { _ = try unknown.handshake() }
        precondition(unsupported.localizedDescription.contains("schemes 4") && unknown.host.linkNote == "offered 4")
        // Early firmware must name the one scheme it has.
        let mixed = try Pair(late: false); mixed.band.named = 26
        try expect(caught { _ = try mixed.handshake() }.localizedDescription.contains("scheme 26"))
        // A band whose keys follow other rules than its scheme: the first record fails its check,
        // and nothing from it is read.
        let silent = try Pair(late: true); silent.band.wrongKeys = true
        let output = try silent.feed(silent.band.hello(silent.host.start(now: 0))).0
        let size = Int(output.be16(0) & 0x7fff) + 4
        try silent.band.keys(DataXReceiver().feed(output.portion(0..<size), padded: false)[0])
        let failed = caught { _ = try silent.feed(silent.band.send([Frame(channel: 2, words: [0x03001000], payload: Data())])) }
        guard case .authentication = failed else { preconditionFailure("Records under the wrong keys must fail their check") }
        // The exact offer of early firmware is still required for the early rules.
        let seven = try Pair(late: false); seven.band.offered = 7
        try expect(caught { _ = try seven.handshake() }.localizedDescription.contains("schemes 7"))
        // A trust refusal on late firmware is still read as one, whatever bits the channel carries.
        for channel: UInt16 in [2, 0x1c02] {
            let refused = try Pair(late: true)
            _ = try refused.handshake()
            let error = caught { _ = try refused.deliver(Frame(channel: channel, words: [0x03001043], payload: Data())) }
            guard case .trust(.rejected(0x03001043, channel)) = error else { preconditionFailure("A refused owner key must be reported as one") }
        }
        // The band's proof is still checked on late firmware.
        let forged = try Pair(late: true)
        _ = try forged.handshake()
        try forged.deliver(Frame(channel: 2, words: [0x03001000], payload: Data()))
        let bad = try BandCrypto.sign(Data(repeating: 0, count: 32), privateKey: P256.Signing.PrivateKey().rawRepresentation)
        let proof = caught { _ = try forged.deliver(Frame(channel: 0x8002, words: [0x02001001], payload: PB.field(2, bad))) }
        guard case .trust(.invalidBandProof) = proof else { preconditionFailure("A forged band proof must be refused") }
        print("Refusals passed: unknown schemes, a renamed scheme, wrong keys, a refused owner key and a forged band proof.")
    }

    /// The scores of the band's own model, asked for with the streams and read as they come.
    static func writing() throws {
        for late in [false, true] {
            let pair = try Pair(late: late)
            try pair.authenticate(after: pair.handshake())
            try pair.ask("request_active", 6, 5, PB.field(6, 2), answer: PB.field(2, 1))
            var row = Data()
            for index in 0..<200 { withUnsafeBytes(of: Float(index % 100 == 7 ? 5 : 0).bitPattern.littleEndian) { row.append(contentsOf: $0) } }
            let message = Frame(channel: 0x8005, words: [0x0200020c], payload: PB.field(1, 1) + PB.field(2, 2) + PB.field(3, row) + PB.field(10, 3))
            // Without the scores asked for, the request is what it always was, and scores are not read.
            let usual = BandProtocol.streamFlags(gyro: false, orientation: false)
            precondition(usual == PB.field(2, 0) + PB.field(3, 1) + PB.field(6, 0) + PB.field(8, 0))
            try pair.ask("start_streams", 5, 4, usual, answer: PB.field(2, 1) + PB.field(5, late ? PB.field(3, 1) : usual))
            let before = pair.log.count
            try pair.deliver(message)
            precondition(pair.log.count == before)
            // Asked for: field 4 is on, and two rows of a hundred arrive as two hundred scores.
            let asked = BandProtocol.streamFlags(gyro: false, orientation: false, inference: true)
            precondition(asked == PB.field(2, 0) + PB.field(3, 1) + PB.field(4, 1) + PB.field(6, 0) + PB.field(8, 0))
            try pair.ask("start_streams", 5, 4, asked, answer: PB.field(2, 1) + PB.field(5, late ? PB.field(3, 1) + PB.field(4, 1) : asked))
            try pair.deliver(message)
            precondition(pair.log.last == "inference 200 3")
            // A message that will not parse is skipped and the connection stays up.
            try pair.deliver(Frame(channel: 0x8005, words: [], payload: Data([0xff, 0xff, 0xff])))
            precondition(pair.host.stage == "ready" && pair.log.last == "inference 200 3")
            // Stopped again: field 4 is off, and scores are no longer read.
            try pair.ask("start_streams", 5, 4, BandProtocol.streamFlags(gyro: false, orientation: false, inference: false), answer: PB.field(2, 1) + PB.field(5, late ? PB.field(3, 1) : usual))
            let after = pair.log.count
            try pair.deliver(message)
            precondition(pair.log.count == after)
            // The handwriting state goes out as a setting, like the wrist.
            try pair.ask("try_writing", 6, 5, BandWriting.state(on: true, standby: nil), answer: PB.field(2, 1))
        }
        // A version 2 band is asked for the scores by kind as well.
        let listed = try Fields(BandStreams.request(BandProtocol.streamFlags(gyro: false, orientation: false, inference: true), version: 2))
        let kinds = (listed.values[36] ?? []).compactMap { value -> UInt64? in
            guard case .bytes(2, let raw) = value, let entry = try? Fields(raw), (try? entry.integer(2)) == 1 else { return nil }
            return try? entry.integer(1)
        }
        precondition(kinds.contains(12) && !kinds.contains(15))
        print("Writing passed: the model's scores asked for, read, skipped when malformed and stopped, on early and late firmware.")
    }

    /// Newer firmware that does not follow the one known set of rules. A band on build 72 named
    /// scheme 27 on 2026-11-17, where other bands name 26.
    static func ways() throws {
        // It names 27 and keeps the known rules: the first way connects, whatever the phone names back.
        for way in [0, 1] {
            let pair = try Pair(late: true, way: way); pair.band.named = 27
            let first = try pair.handshake()
            precondition(!pair.host.linkProven, "nothing from the band has been checked yet")
            try pair.authenticate(after: first)
            precondition(pair.host.linkProven && pair.host.betterWay == nil)
            precondition(pair.host.linkNote == "offered 27, using \(way == 0 ? 26 : 27) (way \(way + 1) of 16), band named 27")
        }
        // It checks its records with a key of its own, or hashes the secret first. The first way
        // fails on the band's first record, and that record is enough to find the way that reads it.
        for (own, found) in [(true, 2), (false, 8)] {
            let pair = try Pair(late: true); pair.band.named = 27; pair.band.ownCheckKey = own; pair.band.wrongKeys = !own
            let output = try pair.feed(pair.band.hello(pair.host.start(now: 0))).0
            let size = Int(output.be16(0) & 0x7fff) + 4
            try pair.band.keys(DataXReceiver().feed(output.portion(0..<size), padded: false)[0])
            let failed = caught { _ = try pair.feed(pair.band.send([Frame(channel: 2, words: [0x03001043], payload: Data())])) }
            guard case .authentication = failed else { preconditionFailure("A record under other rules must fail its check") }
            precondition(pair.host.betterWay == found && !pair.host.linkProven, "\(String(describing: pair.host.betterWay))")
            // Connecting again that way works from the first record.
            let again = try Pair(late: true, way: found); again.band.named = 27; again.band.ownCheckKey = own; again.band.wrongKeys = !own
            try again.authenticate(after: again.handshake())
            precondition(again.host.linkProven && again.host.stage == "ready")
        }
        // Rules nobody has listed: no way reads the record, and none is suggested.
        do {
            let pair = try Pair(late: true); pair.band.named = 27
            let output = try pair.feed(pair.band.hello(pair.host.start(now: 0))).0
            let size = Int(output.be16(0) & 0x7fff) + 4
            try pair.band.keys(DataXReceiver().feed(output.portion(0..<size), padded: false)[0])
            var record = try pair.band.send([Frame(channel: 2, words: [0x03001000], payload: Data())])
            record[3] ^= 0x55
            guard case .authentication = caught({ _ = try pair.feed(record) }) else { preconditionFailure() }
            precondition(pair.host.betterWay == nil)
        }
        // Early firmware is never a guess, and a way number means nothing to it.
        let early = try Pair(late: false, way: 5)
        try early.authenticate(after: early.handshake())
        precondition(!early.host.linkIsGuess && early.host.linkNote == "offered 3, using 3, band named 3")
        print("Ways passed: a band that names 27, a band with its own check key, a band that hashes the secret, unknown rules, and early firmware untouched.")
    }
}
