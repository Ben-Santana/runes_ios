// Offline protocol fixtures with ephemeral keys; no Bluetooth, Keychain access or saved credentials.
import Foundation
import CryptoKit

private struct TrustFixture {
    let host: BandProtocol
    let bandTx: AirShieldCipher
    let bandRx: AirShieldReceiver
    let signingKey: P256.Signing.PrivateKey
    let proof: Data

    init() throws {
        let hostKey = P256.Signing.PrivateKey(), bandKey = P256.Signing.PrivateKey()
        signingKey = bandKey
        host = try BandProtocol(identity: BandIdentity(privateKey: hostKey.rawRepresentation,
                                                      bandPoint: BandCrypto.point(bandKey), stage: "verified"))
        let request = try DataXReceiver().feed(host.start(now: 0), padded: false)[0]
        let fields = try Fields(request.payload)
        let hostPoint = try fields.bytes(1), hostChallenge = try fields.bytes(2)
        let peer = P256.KeyAgreement.PrivateKey()
        let peerPoint = Data(peer.publicKey.x963Representation.dropFirst())
        let peerChallenge = Data(repeating: 1, count: 16), peerSeed = Data(repeating: 2, count: 32)
        let peerIV = Data(repeating: 3, count: 16)
        let hello = try Frame(channel: 0x8001, words: [0x02000001], payload:
            PB.field(1, peerPoint) + PB.field(2, peerChallenge) + PB.field(3, 0) + PB.field(4, 3)).encoded()
        let answer = try host.feed(hello, now: 1).0
        let response = try Fields(DataXReceiver().feed(answer, padded: false)[0].payload)
        let secret = try peer.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: Data([4]) + hostPoint))
            .withUnsafeBytes { Data($0) }
        bandTx = try AirShieldCipher(key: BandCrypto.key(secret: secret, challenge: hostChallenge, seed: peerSeed), iv: peerIV, counter: 7)
        bandRx = try AirShieldReceiver(AirShieldCipher(key: BandCrypto.key(secret: secret, challenge: peerChallenge, seed: response.bytes(2)),
                                                      iv: response.bytes(3), counter: response.integer(4)))
        let finish = try Frame(channel: 1, words: [0x02000002], payload:
            PB.field(1, peerPoint) + PB.field(2, peerSeed) + PB.field(3, peerIV) + PB.field(4, 7) + PB.field(5, 3)).encoded()
        let trust = try host.feed(finish, now: 2).0
        _ = try bandRx.feed(trust)
        proof = BandCrypto.transcript(hostChallenge, hostPoint, peerSeed, peerPoint)
        precondition(host.stage == "trust")
    }

    func send(_ frame: Frame, now: TimeInterval = 3) throws -> (Data, [BandProtocol.Signal]) {
        try host.feed(bandTx.encrypt(frame.encoded()), now: now)
    }

    func authenticate() throws {
        _ = try send(Frame(channel: 2, words: [0x03001000], payload: Data()))
        let signature = try BandCrypto.sign(proof, privateKey: signingKey.rawRepresentation)
        let end = try send(Frame(channel: 0x8002, words: [0x02001001], payload: PB.field(2, signature))).0
        _ = try bandRx.feed(end)
        let deviceInfo = try send(Frame(channel: 0x8001, words: [0x02001000], payload: PB.field(1, 1) + PB.field(2, Data(repeating: 4, count: 16)))).0
        let plain = try bandRx.feed(deviceInfo)[0]
        let request = try DataXReceiver().feed(plain)[0]
        let id = try Fields(request.payload).integer(1)
        let ready = try send(Frame(channel: 3, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 1) + PB.field(4, Data())))
        precondition(ready.1.contains { if case .ready = $0 { return true }; return false })
    }

    func requestHand(_ operation: String, payload: Data = Data(), now: TimeInterval = 4) throws -> Frame {
        let output = try host.request(operation, channel: 6, field: 5, payload: payload, now: now)
        return try DataXReceiver().feed(bandRx.feed(output)[0])[0]
    }

    func requestFeedback(_ phase: WristFeedbackPhase, now: TimeInterval = 4) throws -> Frame {
        let output = try host.request("wrist_feedback", channel: 6, field: 17, payload: phase.payload, now: now)
        return try DataXReceiver().feed(bandRx.feed(output)[0])[0]
    }

    func enableGestures() throws {
        let flags = BandProtocol.streamFlags(gyro: false, orientation: false)
        let start = try host.request("start_streams", channel: 5, field: 4, payload: flags, now: 4)
        let request = try DataXReceiver().feed(bandRx.feed(start)[0])[0]
        let id = try Fields(request.payload).integer(1)
        _ = try send(Frame(channel: 5, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 1) + PB.field(5, flags)), now: 5)
    }
}

@main
struct ConnectionDiagnosticsTests {
    static func caught(_ work: () throws -> Void) -> BandError {
        do { try work(); preconditionFailure("Expected failure") }
        catch let error as BandError { return error }
        catch { preconditionFailure("Unexpected error type") }
    }

    static func main() throws {
        try wristFeedback()
        try handSettings()
        try bandTightness()
        for (code, expected): (UInt32, ConnectionFailure.Kind) in [
            (0x03001043, .identityMismatch), (0x03001044, .signatureRejected), (0x0300ABCD, .unknownRejection)
        ] {
            let fixture = try TrustFixture()
            let error = caught { _ = try fixture.send(Frame(channel: 2, words: [code], payload: Data())) }
            let failure = ConnectionFailure(error)
            precondition(failure.kind == expected && failure.result == code && failure.channel == 2)
            precondition(error.localizedDescription.contains(String(format: "0x%08X", code)))
            precondition(ConnectionRetryPolicy.stopsAutoConnect(error))
        }
        let timeout = try TrustFixture()
        let expired = caught { try timeout.host.tick(now: 20) }
        precondition(ConnectionFailure(expired).kind == .timeout)
        precondition(ConnectionFailure(expired).result == nil)
        precondition(SessionIssue.from(expired) == .bandNotResponding)
        precondition(ConnectionRetryPolicy.stopsAutoConnect(expired))

        let starting = try BandProtocol(identity: BandIdentity(privateKey: P256.Signing.PrivateKey().rawRepresentation,
                                                              bandPoint: nil, stage: "host_verified", allowMissingBandKey: true))
        _ = try starting.start(now: 0)
        let startupTimeout = caught { try starting.tick(now: 16) }
        precondition(ConnectionFailure(startupTimeout).kind == .timeout)
        precondition(!ConnectionRetryPolicy.stopsAutoConnect(startupTimeout))

        let invalidProof = try TrustFixture()
        let wrongSignature = try BandCrypto.sign(Data(repeating: 0, count: 32), privateKey: P256.Signing.PrivateKey().rawRepresentation)
        let proofError = caught { _ = try invalidProof.send(Frame(channel: 0x8002, words: [0x02001001], payload: PB.field(2, wrongSignature))) }
        precondition(ConnectionFailure(proofError).kind == .invalidBandProof)
        precondition(ConnectionFailure(proofError).result == nil)

        var attempt = ConnectionAttempt()
        attempt.fail(.transport("unrelated event"))
        precondition(attempt.startedAt == nil && attempt.failure == nil)
        let old = Date(timeIntervalSince1970: 1), new = Date(timeIntervalSince1970: 2)
        attempt.begin(at: old); attempt.reach(.channelOpen); attempt.reach(.encryption)
        let success = try TrustFixture()
        attempt.observeProtocolStage(success.host.stage)
        precondition(attempt.steps.contains(.encrypted) && !attempt.steps.contains(.trusted) && attempt.outcome == .connecting)
        attempt.fail(.trust(.rejected(result: 0x03001043, channel: 2)))
        attempt.stop(); attempt.reach(.ready)
        precondition(attempt.failure?.kind == .identityMismatch && attempt.outcome == .failed)
        attempt.begin(at: new)
        precondition(attempt.startedAt == new && attempt.failure == nil && attempt.steps == [.connecting])
        try success.authenticate()
        attempt.observeProtocolStage(success.host.stage)
        precondition(attempt.steps.contains(.trusted) && !attempt.steps.contains(.ready) && attempt.outcome == .connecting)
        attempt.reach(.subscribing); attempt.reach(.ready)
        precondition(attempt.failure == nil && attempt.outcome == .ready)
        for _ in 0..<100 { attempt.observeProtocolStage("ready") }
        precondition(attempt.steps.count <= ConnectionStep.allCases.count)
        attempt.stop(); precondition(attempt.outcome == .stopped)
        attempt = ConnectionAttempt()
        precondition(attempt.startedAt == nil && attempt.failure == nil && attempt.steps.isEmpty)

        let privateFixture = "fixture-private-not-real-credentials"
        let generic = ConnectionFailure(.authentication(privateFixture))
        precondition(!generic.title.contains(privateFixture) && !generic.detail.contains(privateFixture))
        let unknown = ConnectionFailure(.trust(.rejected(result: 0x0300ABCD, channel: 0x8002)))
        precondition(unknown.result == 0x0300ABCD && unknown.channel == 0x8002 && unknown.kind == .unknownRejection)
        let setup = ConnectionFailure(.setupRejected(result: 0x03001043, channel: 3))
        precondition(setup.kind == .setupRejected && setup.result == 0x03001043)
        print("Connection diagnostics passed: encrypted trust refusal, signature rejection, unknown results, timeouts, proof verification, and attempt lifecycle.")
    }

    static func wristFeedback() throws {
        precondition(WristFeedbackPhase.wrap.payload == Data([0x0a, 0x05, 0x08, 0x46, 0x18, 0xc8, 0x01]))
        precondition(WristFeedbackPhase.settle.payload == Data([0x0a, 0x05, 0x08, 0x64, 0x18, 0xe6, 0x01]))
        let nestedSuccess = PB.field(18, PB.field(1, 0) + PB.field(2, Data()))
        // One of the band's own patterns: taken unless the request or its result says otherwise.
        precondition(WristFeedbackResult.pattern(PB.field(2, 1) + PB.field(18, PB.field(1, 0) + PB.field(3, Data()))) == .accepted)
        precondition(WristFeedbackResult.pattern(PB.field(2, 1) + PB.field(18, Data())) == .accepted)
        precondition(WristFeedbackResult.pattern(PB.field(2, 1) + PB.field(18, PB.field(1, 2))) == .rejected)
        precondition(WristFeedbackResult.pattern(PB.field(2, 0) + nestedSuccess) == .rejected)
        precondition(WristFeedbackResult.pattern(PB.field(2, 1)) == .unconfirmed)
        // The band's settings are written out as numbers, and bytes that are not a message as a length.
        let settings = PB.field(6, PB.field(6, 2) + PB.field(10, 1) + PB.field(46, PB.field(3, 1)) + PB.field(9, Data([0xff, 0xff])))
        precondition(BandSettings.describe(settings) == "6=2 9=bytes(2) 10=1 46={3=1}")
        precondition(BandSettings.describe(PB.field(2, 1)) == nil)
        // Band tests: a gesture's acknowledgement, a stored pattern with its gap as a still segment, and stop.
        precondition(BandTrial.acknowledge(gesture: 7) == Data([0x08, 0x07, 0x10, 0x02, 0x18, 0x00]))
        let stored = BandTrial.pattern(named: "ab", [BandPulse(duration: 60, amplitude: 190, gap: 90), BandPulse(duration: 110, amplitude: 245)])
        let twoBeats = Data([0x0a, 0x02, 0x61, 0x62, 0x12, 0x05, 0x08, 0x3c, 0x10, 0xbe, 0x01, 0x12, 0x04, 0x08, 0x5a, 0x10, 0x00, 0x12, 0x05, 0x08, 0x6e, 0x10, 0xf5, 0x01])
        precondition(stored == PB.field(4, PB.field(1, twoBeats) + PB.field(2, 1)))
        precondition(BandTrial.stop == Data([0x1a, 0x00]))
        // The band's named settings: the requests, and what is read from their answers.
        precondition(NamedSettings.count() == Data([0x0a, 0x02, 0x08, 0x02]))
        precondition(NamedSettings.describe(index: 5) == Data([0x12, 0x04, 0x08, 0x02, 0x10, 0x05]))
        precondition(NamedSettings.describe(index: 0) == NamedSettings.describe(index: 1))
        precondition(NamedSettings.read(id: 27) == Data([0x1a, 0x04, 0x08, 0x1b, 0x10, 0x00]))
        precondition(NamedSettings.write(id: 22, value: 0) == Data([0x1a, 0x08, 0x08, 0x16, 0x10, 0x01, 0x1a, 0x02, 0x08, 0x00]))
        func named(_ part: Int, _ body: Data, status: UInt64 = 1) -> Data { PB.field(2, status) + PB.field(14, PB.field(part, body)) }
        precondition(NamedSettings.count(from: named(1, PB.field(1, 27))) == 27)
        precondition(NamedSettings.count(from: named(1, PB.field(1, 0))) == nil)
        precondition(NamedSettings.count(from: named(1, PB.field(1, 27), status: 0)) == nil)
        precondition(NamedSettings.count(from: Data()) == nil)
        let described = NamedSettings.setting(from: named(2, PB.field(3, Data("haptics".utf8)) + PB.field(4, 22) + PB.field(7, PB.field(1, 3) + PB.field(3, 3))))
        precondition(described == NamedSettings.Setting(id: 22, name: "haptics", range: 0...3))
        // A description also carries a title, a purpose, the names of choices and what an action takes.
        let chosen = PB.field(15, PB.field(1, PB.field(1, Data("off".utf8)) + PB.field(2, 1)) + PB.field(1, PB.field(1, Data("on".utf8)) + PB.field(2, 2)))
        let rich = NamedSettings.setting(from: named(2, PB.field(1, Data("Haptics".utf8)) + PB.field(2, Data("Motor level".utf8)) + PB.field(3, Data("haptics".utf8)) + PB.field(4, 22) + chosen))
        precondition(rich?.detail == "Haptics; Motor level; choices: 1 off, 2 on")
        let action = NamedSettings.setting(from: named(2, PB.field(3, Data("trigger-haptics".utf8)) + PB.field(4, 23) + PB.field(13, PB.field(1, Data("duration".utf8)) + PB.field(2, Data()))))
        precondition(action?.detail == "takes: duration (whole number)")
        // What the band says about its software leaves out its serial number (field 6).
        let about = PB.field(4, PB.field(2, Data("1.2.3".utf8)) + PB.field(6, Data("SERIAL".utf8)) + PB.field(15, 2) + PB.field(19, PB.field(1, PB.field(1, 1) + PB.field(3, 100))))
        precondition(BandInfo.describe(about) == "firmware 1.2.3; protocol 2; handwriting {1=1 3=100}")
        precondition(BandInfo.describe(PB.field(4, PB.field(2, Data("1.2.3".utf8)))) == "firmware 1.2.3; handwriting not listed")
        precondition(described?.writable == false)
        precondition(NamedSettings.setting(from: named(2, PB.field(4, 22))) == nil)
        // A whole number comes in field 4, and zero is an empty one. A yes or no comes in field 8.
        let three = NamedSettings.value(of: 22, from: named(3, PB.field(1, 22) + PB.field(4, PB.field(1, 3))))
        precondition(three?.kind == 4 && three?.value == 3 && three?.text == "1=22 4={1=3}")
        let zero = NamedSettings.value(of: 21, from: named(3, PB.field(1, 21) + PB.field(4, Data())))
        precondition(zero?.kind == 4 && zero?.value == 0)
        precondition(NamedSettings.value(of: 11, from: named(3, PB.field(1, 11) + PB.field(8, PB.field(1, 1))))?.kind == 8)
        // A refusal carries a status in field 3; an answer about another setting is not this one's.
        precondition(NamedSettings.value(of: 23, from: named(3, PB.field(1, 23) + PB.field(3, 1))) == nil)
        precondition(NamedSettings.value(of: 22, from: named(3, PB.field(1, 21) + PB.field(4, PB.field(1, 3)))) == nil)
        precondition(NamedSettings.value(of: 22, from: Data()) == nil)
        let responses: [(Data, WristFeedbackResult)] = [
            // The band's real reply: status 1 and an empty result block, zero being left off the wire.
            (PB.field(2, 1) + PB.field(18, Data()), .accepted),
            (PB.field(2, 1) + nestedSuccess, .accepted),
            (PB.field(2, 0) + nestedSuccess, .rejected),
            (nestedSuccess, .unconfirmed),
            (PB.field(2, 1), .unconfirmed),
            (PB.field(2, 1) + PB.field(2, 1) + nestedSuccess, .unconfirmed),
            (PB.field(2, 1) + PB.field(18, PB.field(1, 1) + PB.field(2, Data())), .rejected),
            (PB.field(2, 1) + PB.field(18, PB.field(2, Data())), .accepted),
            (PB.field(2, 1) + PB.field(18, PB.field(1, 0) + PB.field(3, Data())), .accepted),
            (PB.field(2, 1) + PB.field(18, PB.field(1, 7)), .rejected),
            (PB.field(2, 1) + PB.field(18, PB.field(1, 0) + PB.field(1, 7)), .unconfirmed),
            (PB.field(2, 1) + PB.field(18, PB.field(1, Data([1]))), .unconfirmed)
        ]
        for (response, expected) in responses {
            let fixture = try TrustFixture(); try fixture.authenticate()
            let request = try fixture.requestFeedback(.wrap)
            let fields = try Fields(request.payload), id = try fields.integer(1)
            let payload = try fields.bytes(17)
            precondition(payload == WristFeedbackPhase.wrap.payload)
            precondition(fixture.host.wristFeedbackPending && !fixture.host.canSendWristFeedback)
            _ = caught { _ = try fixture.requestHand("set_hand", payload: Handedness.left.configuration, now: 5) }
            for (channel, wrongID): (UInt16, UInt64) in [(5, id), (6, id + 1)] {
                let wrong = try fixture.send(Frame(channel: channel, words: [0x02000315], payload: PB.field(1, wrongID) + response), now: 5)
                precondition(wrong.1.isEmpty && fixture.host.wristFeedbackPending)
            }
            let reply = try fixture.send(Frame(channel: 6, words: [0x02000315], payload: PB.field(1, id) + response), now: 6)
            precondition(reply.1.contains { if case .wristFeedback(let result) = $0 { return result == expected }; return false })
            precondition(!fixture.host.wristFeedbackPending && fixture.host.canSendWristFeedback)
            _ = try fixture.requestHand("set_hand", payload: Handedness.left.configuration, now: 7)
            precondition(!fixture.host.canSendWristFeedback)
        }
        for timeout in [false, true] {
            let fixture = try TrustFixture(); try fixture.authenticate(); try fixture.enableGestures()
            let request = try fixture.requestFeedback(.settle, now: 6)
            let id = try Fields(request.payload).integer(1)
            if timeout {
                let waiting = try fixture.host.tick(now: 10.9)
                precondition(waiting.isEmpty)
                let expired = try fixture.host.tick(now: 11)
                precondition(expired.contains { if case .wristFeedback(.unconfirmed) = $0 { return true }; return false })
            } else {
                _ = try fixture.send(Frame(channel: 6, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 0)), now: 7)
            }
            let gesture = try fixture.send(Frame(channel: 0x8005, words: [0x0200020d], payload:
                PB.field(1, 1) + PB.field(2, 100) + PB.field(3, 2) + PB.field(4, 1)), now: 12)
            precondition(gesture.1.contains { if case .gesture(2, 1, _, _, _, _) = $0 { return true }; return false })
            _ = try fixture.requestHand("set_hand", payload: Handedness.right.configuration, now: 13)
            let stale = try fixture.send(Frame(channel: 6, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 1) + nestedSuccess), now: 14)
            precondition(stale.1.isEmpty && !fixture.host.canSendWristFeedback)
        }
        let closed = try TrustFixture(); try closed.authenticate()
        _ = try closed.requestFeedback(.wrap)
        let rejection = try closed.send(Frame(channel: 6, words: [0x03000001], payload: Data()), now: 5)
        precondition(rejection.1.contains { if case .wristFeedback(.unconfirmed) = $0 { return true }; return false })
        precondition(closed.host.canSendWristFeedback)

        var gate = WristFeedbackGate()
        let first = UUID(), next = UUID()
        precondition(!gate.take(.wrap, change: first, now: 1))
        gate.begin(first)
        precondition(gate.take(.wrap, change: first, now: 1))
        precondition(!gate.take(.wrap, change: first, now: 2))
        precondition(!gate.take(.settle, change: first, now: 1.1))
        precondition(gate.take(.settle, change: first, now: 1.7))
        precondition(!gate.take(.settle, change: first, now: 3))
        gate.begin(next); gate.cancel(first)
        precondition(!gate.take(.wrap, change: first, now: 4))
        precondition(gate.take(.wrap, change: next, now: 4))
        gate.cancel(next)
        precondition(!gate.take(.settle, change: next, now: 5))
        gate.begin(first); gate.cancel()
        precondition(!gate.take(.settle, change: first, now: 6))

        var hand = HandSetting()
        precondition(hand.read() && hand.received(.right) && hand.confirmedChangeID == nil)
        precondition(hand.change(to: .left) && hand.confirmedChangeID == nil)
        let change = hand.changeID
        precondition(hand.wrote() && hand.received(.left) && hand.confirmedChangeID == change)
        hand.cancel(); precondition(hand.confirmedChangeID == nil)
        precondition(hand.change(to: .right) && hand.changeID != change && hand.wrote())
        precondition(hand.received(.left) && hand.confirmedChangeID == nil)
        print("Wrist feedback checks passed: fixed bounded payloads, nested acknowledgement, serialized control, gesture continuation, cancellation and fresh-change gating.")
    }

    static func handSettings() throws {
        precondition(Handedness.right.configuration == Data([0x50, 0x00]))
        precondition(Handedness.left.configuration == Data([0x50, 0x01]))
        for hand in [Handedness.left, .right] {
            let fixture = try TrustFixture(); try fixture.authenticate()
            let write = try fixture.requestHand("set_hand", payload: hand.configuration)
            let fields = try Fields(write.payload), id = try fields.integer(1)
            let writtenConfig = try fields.bytes(5)
            precondition(writtenConfig == hand.configuration, "Only field10 may be written")
            _ = caught { _ = try fixture.requestHand("read_hand") }
            for (channel, replyID): (UInt16, UInt64) in [(5, id), (6, id + 100)] {
                let stale = try fixture.send(Frame(channel: channel, words: [0x02000315], payload: PB.field(1, replyID) + PB.field(2, 1)), now: 5)
                precondition(stale.1.isEmpty)
            }
            let written = try fixture.send(Frame(channel: 6, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 1)), now: 5)
            precondition(written.1.contains { if case .reply("set_hand", _) = $0 { return true }; return false })
            let read = try fixture.requestHand("read_hand", now: 6)
            let readFields = try Fields(read.payload), readID = try readFields.integer(1)
            let readConfig = try readFields.bytes(5)
            precondition(readConfig.isEmpty)
            let payload = PB.field(1, readID) + PB.field(2, 1) + PB.field(6, hand.configuration + PB.field(6, 2))
            let readBack = try fixture.send(Frame(channel: 6, words: [0x02000315], payload: payload), now: 7)
            precondition(readBack.1.contains { if case .reply("read_hand", let value) = $0 { return Handedness.read(value) == hand }; return false })
        }
        for config in [Data(), PB.field(10, 2), PB.field(10, 0) + PB.field(10, 1), PB.field(10, Data())] {
            precondition(Handedness.read(PB.field(6, config)) == nil)
        }

        for operation in ["read_hand", "set_hand"] {
            let refused = try TrustFixture(); try refused.authenticate()
            let request = try refused.requestHand(operation, payload: operation == "set_hand" ? Handedness.left.configuration : Data())
            let id = try Fields(request.payload).integer(1)
            let signals = try refused.send(Frame(channel: 6, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 0)), now: 5).1
            precondition(signals.contains { if case .handUnavailable = $0 { return true }; return false })
            precondition(refused.host.stage == "ready")
            _ = try refused.requestHand("read_hand", now: 6)

            let timeout = try TrustFixture(); try timeout.authenticate()
            let pending = try timeout.requestHand(operation)
            let staleID = try Fields(pending.payload).integer(1)
            let expired = try timeout.host.tick(now: 13)
            precondition(expired.contains { if case .handUnavailable = $0 { return true }; return false })
            precondition(timeout.host.stage == "ready")
            let lateClose = try timeout.send(Frame(channel: 6, words: [0x03000001], payload: Data()), now: 13)
            precondition(lateClose.1.isEmpty && timeout.host.stage == "ready")
            _ = try timeout.requestHand("read_hand", now: 14)
            let stale = try timeout.send(Frame(channel: 6, words: [0x02000315], payload: PB.field(1, staleID) + PB.field(2, 1) + PB.field(6, Handedness.left.configuration)), now: 15)
            precondition(stale.1.isEmpty)

            let closed = try TrustFixture(); try closed.authenticate()
            _ = try closed.requestHand(operation)
            let close = try closed.send(Frame(channel: 6, words: [0x03000001], payload: Data()), now: 5)
            precondition(close.1.contains { if case .handUnavailable = $0 { return true }; return false })
            let reopened = try closed.requestHand("read_hand", now: 6)
            precondition(reopened.words == [0x8100ce56, 0x02000314])

            for status in [Data(), PB.field(2, 1) + PB.field(2, 1), PB.field(2, Data()), PB.field(2, 2)] {
                let malformed = try TrustFixture(); try malformed.authenticate()
                let request = try malformed.requestHand(operation)
                let id = try Fields(request.payload).integer(1)
                let reply = try malformed.send(Frame(channel: 6, words: [0x02000315], payload: PB.field(1, id) + status), now: 5)
                precondition(reply.1.contains { if case .handUnavailable = $0 { return true }; return false })
                precondition(malformed.host.stage == "ready")
            }
        }
        let required = try TrustFixture(); try required.authenticate()
        let request = try required.requestHand("request_active", payload: PB.field(6, 2))
        let id = try Fields(request.payload).integer(1)
        _ = caught { _ = try required.send(Frame(channel: 6, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 0)), now: 5) }
        _ = try required.requestHand("request_active", payload: PB.field(6, 2), now: 6)
        _ = caught { _ = try required.send(Frame(channel: 6, words: [0x03000001], payload: Data()), now: 7) }

        let live = try TrustFixture(); try live.authenticate()
        let flags = BandProtocol.streamFlags(gyro: false, orientation: false)
        let start = try live.host.request("start_streams", channel: 5, field: 4, payload: flags, now: 4)
        let startFrame = try DataXReceiver().feed(live.bandRx.feed(start)[0])[0]
        let startID = try Fields(startFrame.payload).integer(1)
        _ = try live.send(Frame(channel: 5, words: [0x02000315], payload: PB.field(1, startID) + PB.field(2, 1) + PB.field(5, flags)), now: 5)
        for timedOut in [false, true] {
            let request = try live.requestHand("set_hand", payload: Handedness.left.configuration, now: timedOut ? 10 : 6)
            let id = try Fields(request.payload).integer(1)
            if timedOut { _ = try live.host.tick(now: 19) }
            else { _ = try live.send(Frame(channel: 6, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 0)), now: 7) }
            let gesture = try live.send(Frame(channel: 0x8005, words: [0x0200020d], payload:
                PB.field(1, timedOut ? 2 : 1) + PB.field(2, 100) + PB.field(3, 2) + PB.field(4, 1)), now: timedOut ? 20 : 8)
            precondition(gesture.1.contains { if case .gesture(2, 1, _, _, _, _) = $0 { return true }; return false })
        }

        var setting = HandSetting(confirmed: .right)
        precondition(setting.read() && !setting.change(to: .left))
        precondition(setting.received(.right))
        precondition(setting.change(to: .left) && !setting.change(to: .right) && !setting.read())
        precondition(setting.confirmed == nil && !setting.received(.left))
        precondition(setting.wrote() && !setting.wrote() && setting.confirmed == nil)
        precondition(setting.received(.left) && setting.confirmed == .left && !setting.busy && setting.error == nil)
        precondition(setting.change(to: .right) && setting.wrote())
        precondition(setting.received(.left) && setting.confirmed == .left && setting.error != nil)
        precondition(setting.change(to: .right) && setting.wrote())
        precondition(!setting.received(nil) && setting.confirmed == nil && setting.error != nil)
        precondition(setting.change(to: .right)); setting.fail("Timed out")
        precondition(setting.confirmed == nil && !setting.busy)
        precondition(setting.change(to: .left), "A cached value must remain selectable after an uncertain write")
        setting.cancel()
        precondition(setting.change(to: .right)); setting.cancel()
        precondition(!setting.wrote() && !setting.received(.right) && setting.confirmed == nil)
        setting = HandSetting()
        precondition(!setting.received(.right) && setting.confirmed == nil)
        print("Wrist setting checks passed: explicit0/1 partial writes, serialized readback, rejection, timeout, stale replies and confirmed state.")
    }
    static func bandTightness() throws {
        func named(_ part: Int, _ body: Data, status: UInt64 = 1) -> Data { PB.field(2, status) + PB.field(14, PB.field(part, body)) }
        func described(_ body: Data) -> BandCapability? { BandCapability(describing: named(2, body)) }
        let minusFive = UInt64(bitPattern: -5)

        // A description gives the kind by which field is filled in, with limits, actions, tags and level.
        let haptics = described(PB.field(2, Data("Haptic level (0-3)!".utf8)) + PB.field(3, Data("haptics".utf8)) + PB.field(4, 22)
            + PB.field(5, Data([2])) + PB.field(6, Data([0, 1])) + PB.field(7, PB.field(1, 3) + PB.field(3, 3)) + PB.field(18, 1))
        precondition(haptics?.kind == .whole && haptics?.current == 3 && haptics?.low == 0 && haptics?.high == 3)
        precondition(haptics?.actions == [0, 1] && haptics?.tags == [2] && haptics?.level == 1 && haptics?.arguments == 0)
        precondition(haptics?.summary == "whole number 0 to 3, now 3; actions 0 1; tags 2; level 1; “Haptic level (0-3)”")
        // Actions sent one by one read the same as a packed block, and an empty block is still a kind.
        let trigger = described(PB.field(3, Data(BandTightness.trigger.utf8)) + PB.field(4, 3) + PB.field(6, 1) + PB.field(17, Data()))
        precondition(trigger?.kind == .nothing && trigger?.actions == [1] && trigger?.current == nil)
        precondition(trigger?.summary == "no value; actions 1")
        let signed = described(PB.field(4, 9) + PB.field(7, PB.field(1, minusFive) + PB.field(2, minusFive) + PB.field(3, 200)) + PB.field(13, Data()) + PB.field(13, Data()))
        precondition(signed?.low == -5 && signed?.high == 200 && signed?.current == -5 && signed?.arguments == 2 && signed?.actions == [])
        let choice = described(PB.field(15, PB.field(1, PB.field(1, Data("off".utf8))) + PB.field(1, PB.field(1, Data("on".utf8)) + PB.field(2, 2)) + PB.field(3, 2)))
        precondition(choice?.kind == .choice && choice?.choices == [0, 2] && choice?.current == 2)
        precondition(choice?.summary == "choice of 0 2, now 2; actions none")
        precondition(described(PB.field(11, PB.field(1, 1)))?.kind == .yesNo && described(PB.field(11, Data()))?.current == 0)
        precondition(described(PB.field(9, Data()))?.kind == .decimal && described(PB.field(19, PB.field(3, 9)))?.high == 9)
        // Two kinds filled in, or none, is no kind. A refusal or silence is no description.
        precondition(described(PB.field(7, Data()) + PB.field(17, Data()))?.kind == nil && described(Data())?.summary == "no kind given; actions none")
        precondition(BandCapability(describing: named(2, PB.field(17, Data()), status: 0)) == nil)
        precondition(BandCapability(describing: named(3, PB.field(1, 3))) == nil && BandCapability(describing: Data()) == nil)
        precondition(BandCapability.numbers([.integer(4), .bytes(2, Data([1, 0x96, 0x01])), .bytes(5, Data([1, 2, 3, 4]))]) == [4, 1, 150])
        // The result number of an answer, which is missing when the band took the request.
        precondition(BandCapability.code(from: named(3, PB.field(1, 3) + PB.field(3, 2))) == 2)
        precondition(BandCapability.code(from: named(3, PB.field(1, 3))) == nil && BandCapability.code(from: Data()) == nil)

        // The band's real description of the check: a whole number 0 to 100 and actions 2, 3 and 4.
        let name = BandTightness.trigger
        let real = described(PB.field(3, Data(name.utf8)) + PB.field(4, 3) + PB.field(6, Data([2, 3, 4])) + PB.field(7, PB.field(3, 100)))!
        precondition(real.summary == "whole number 0 to 100, now 0; actions 2 3 4")
        // The ways are tried least first, and each needs the action the band lists for it.
        precondition(BandTightness.plan(real)! == [
            .worn, .run(value: nil, way: "run alone"), .listen(5),
            .act(3), .listen(3), .run(value: nil, way: "after action 3"), .listen(8),
            .run(value: 0, way: "after action 3, with value 0"), .listen(8),
            .streams(22), .run(value: nil, way: "with setting updates on"), .listen(8),
            .streams(27), .run(value: nil, way: "with detector updates on"), .listen(8)])
        var plain = trigger!; plain.actions = [2]
        precondition(BandTightness.plan(plain)! == [
            .worn, .run(value: nil, way: "run alone"), .listen(5),
            .streams(22), .run(value: nil, way: "with setting updates on"), .listen(8),
            .streams(27), .run(value: nil, way: "with detector updates on"), .listen(8)])
        precondition(BandTightness.plan(trigger!) == nil && BandTightness.plan(haptics!) == nil)

        // The requests. Only the check's own setting is asked, never with a read or a write, and only as the band lists.
        precondition(BandTightness.request(id: 3, name: name, capability: real, action: 2, value: nil) == Data([0x1a, 0x04, 0x08, 0x03, 0x10, 0x02]))
        precondition(BandTightness.request(id: 3, name: name, capability: real, action: 3, value: nil) == Data([0x1a, 0x04, 0x08, 0x03, 0x10, 0x03]))
        precondition(BandTightness.request(id: 3, name: name, capability: real, action: 4, value: nil) == Data([0x1a, 0x04, 0x08, 0x03, 0x10, 0x04]))
        precondition(BandTightness.request(id: 3, name: name, capability: real, action: 2, value: 0) == Data([0x1a, 0x08, 0x08, 0x03, 0x10, 0x02, 0x1a, 0x02, 0x08, 0x00]))
        precondition(BandTightness.request(id: 3, name: name, capability: real, action: 2, value: 100) != nil)
        precondition(BandTightness.request(id: 3, name: name, capability: real, action: 2, value: 101) == nil)
        precondition(BandTightness.request(id: 3, name: name, capability: real, action: 2, value: -1) == nil)
        precondition(BandTightness.request(id: 3, name: name, capability: real, action: 3, value: 0) == nil)
        var everything = real; everything.actions = [0, 1, 2, 3, 4, 5]
        for action: UInt64 in [0, 1, 5] { precondition(BandTightness.request(id: 3, name: name, capability: everything, action: action, value: nil) == nil) }
        precondition(BandTightness.request(id: 3, name: name, capability: plain, action: 3, value: nil) == nil)
        precondition(BandTightness.request(id: 3, name: name, capability: plain, action: 2, value: 0) == nil)
        precondition(BandTightness.request(id: 2, name: "band-tightness-threshold", capability: everything, action: 2, value: nil) == nil)
        precondition(BandTightness.request(id: 22, name: "haptics", capability: everything, action: 2, value: 2) == nil)

        // Stream requests keep the usual flags and add to them, and the band has to say each extra one back.
        let usual = BandProtocol.streamFlags(gyro: true, orientation: false)
        precondition(BandTightness.flags(usual, with: []) == usual)
        precondition(BandTightness.flags(usual, with: [27, 22]) == usual + Data([0xb0, 0x01, 0x01, 0xd8, 0x01, 0x01]))
        let both = PB.field(1, 9) + PB.field(2, 1) + PB.field(5, BandTightness.flags(usual, with: [22]))
        precondition(BandTightness.streams(both, extra: [22]).taken && BandTightness.streams(both, extra: []).taken)
        precondition(BandTightness.streams(both, extra: [22]).line == "Stream answer status 1 [2=0 3=1 6=1 8=0 22=1]")
        precondition(!BandTightness.streams(both, extra: [22, 27]).taken)
        precondition(BandTightness.streams(PB.field(2, 1) + PB.field(5, usual), extra: [22]).line == "Stream answer status 1, not taken [2=0 3=1 6=1 8=0]")
        precondition(!BandTightness.streams(PB.field(2, 0) + PB.field(5, BandTightness.flags(usual, with: [22])), extra: [22]).taken)
        precondition(BandTightness.streams(PB.field(2, 0), extra: []) == (false, "Stream answer status 0, no flags."))
        precondition(BandTightness.streams(Data(), extra: []) == (false, "No stream answer: the band stayed silent or closed the request."))
        precondition(BandTightness.streams(Data([0xff]), extra: []).line == "Stream answer unreadable.")

        // A number in an answer counts only for this setting and only when the band did not refuse.
        precondition(BandTightness.number(inAnswer: named(3, PB.field(1, 3) + PB.field(2, 2)), id: 3) == nil)
        precondition(BandTightness.number(inAnswer: named(3, PB.field(1, 3) + PB.field(2, 2) + PB.field(4, PB.field(1, 37))), id: 3) == 37)
        precondition(BandTightness.number(inAnswer: named(3, PB.field(1, 3) + PB.field(4, Data())), id: 3) == 0)
        precondition(BandTightness.number(inAnswer: named(3, PB.field(1, 4) + PB.field(4, PB.field(1, 37))), id: 3) == nil)
        precondition(BandTightness.number(inAnswer: named(3, PB.field(1, 3) + PB.field(3, 1) + PB.field(4, PB.field(1, 37))), id: 3) == nil)
        precondition(BandTightness.number(inAnswer: named(3, PB.field(1, 3) + PB.field(4, PB.field(1, 37)), status: 0), id: 3) == nil)
        precondition(BandTightness.number(inAnswer: Data(), id: 3) == nil)
        // Whether the band says it is on a wrist.
        precondition(BandTightness.worn(named(3, PB.field(1, 17) + PB.field(8, PB.field(1, 1))), id: 17) == "On wrist: yes.")
        precondition(BandTightness.worn(named(3, PB.field(1, 17) + PB.field(8, Data())), id: 17) == "On wrist: no.")
        precondition(BandTightness.worn(named(3, PB.field(1, 17) + PB.field(3, 1)), id: 17) == "On wrist: not readable.")
        precondition(BandTightness.worn(Data(), id: 17) == "On wrist: not readable.")

        // What the band says back: the setting, the action, a result and a value of some kind.
        func said(_ message: Data) -> BandTightness.Answer { BandTightness.answer(try! Fields(message)) }
        let whole = said(PB.field(1, 3) + PB.field(2, 1) + PB.field(4, PB.field(1, 17)) + PB.field(10, 99))
        precondition(whole == BandTightness.Answer(id: 3, action: 1, code: 0, kind: 4, values: [17]))
        precondition(whole.line == "setting 3 action 1 result 0 kind 4 value 17")
        let refused = said(PB.field(1, 3) + PB.field(3, 2))
        precondition(refused.code == 2 && refused.kind == nil && refused.line == "setting 3 action 0 result 2")
        let half = Data([0, 0, 0, 0x3f]), quarter = Data([0, 0, 0x80, 0x3e])
        var fixed = PB.varint(UInt64(1 << 3 | 5)); fixed.append(half)
        precondition(said(PB.field(1, 3) + PB.field(6, fixed)).line == "setting 3 action 0 result 0 kind 6 value 0.5")
        precondition(said(PB.field(7, PB.field(1, half + quarter))).values == [0.5, 0.25])
        precondition(said(PB.field(5, PB.field(1, Data([1, 0x96, 0x01])))).values == [1, 150])
        precondition(said(PB.field(8, Data())).values == [0])
        precondition(said(PB.field(4, PB.field(1, minusFive))).values == [-5])
        precondition(said(PB.field(4, Data()) + PB.field(8, Data())).kind == nil)
        precondition(BandTightness.reply(Data()) == "No answer: the band stayed silent or closed the request.")
        precondition(BandTightness.reply(Data([0xff])) == "Answer unreadable.")
        precondition(BandTightness.reply(PB.field(1, 9) + PB.field(2, 0)) == "Answer status 0, fields [1, 2].")
        precondition(BandTightness.reply(PB.field(1, 9) + named(3, PB.field(1, 3) + PB.field(2, 1) + PB.field(4, PB.field(1, 17))))
            == "Answer status 1: setting 3 action 1 result 0 kind 4 value 17 [1=3 2=1 4={1=17}]")

        // Messages the band sends without being asked, each written as what is known and then as numbers.
        let event = Data(repeating: 0xff, count: 16)
        let detector = PB.field(21, PB.field(1, event) + PB.field(2, 4) + PB.field(3, 2))
        precondition(BandTightness.number(kind: BandTightness.update, payload: detector, id: 3) == 2)
        precondition(BandTightness.number(kind: BandTightness.update, payload: PB.field(21, PB.field(2, 4)), id: 3) == nil)
        precondition(BandTightness.number(kind: 0x0200020d, payload: detector, id: 3) == nil && BandTightness.number(kind: BandTightness.update, payload: Data(), id: 3) == nil)
        precondition(BandTightness.describe(kind: BandTightness.update, channel: 0x8005, payload: detector)
            == "Frame 2000316 channel 5, 25 bytes: detector update 4 tightness 2 [21={1=bytes(16) 2=4 3=2}]")
        var ratio = PB.varint(UInt64(2 << 3 | 5)); ratio.append(half)
        let worn = PB.field(21, PB.field(5, PB.field(1, 1) + PB.field(2, 2) + PB.field(4, 1)) + PB.field(6, PB.field(1, 1) + ratio))
        precondition(BandTightness.describe(kind: BandTightness.update, channel: 5, payload: worn).hasPrefix(
            "Frame 2000316 channel 5, 20 bytes: detector update 0 on wrist status 1 now 2 before 0 motion 1 interference status 1 ratio 0.5 ["))
        let pushed = PB.field(15, PB.field(1, PB.field(1, 3) + PB.field(4, PB.field(1, 17))))
        precondition(BandTightness.describe(kind: BandTightness.update, channel: 1, payload: pushed)
            == "Frame 2000316 channel 1, 10 bytes: setting update: setting 3 action 0 result 0 kind 4 value 17 [15={1={1=3 4={1=17}}}]")
        precondition(BandTightness.number(kind: BandTightness.update, payload: pushed, id: 3) == 17 && BandTightness.number(kind: BandTightness.update, payload: pushed, id: 2) == nil)
        precondition(BandTightness.number(kind: BandTightness.update, payload: PB.field(15, PB.field(1, PB.field(1, 3) + PB.field(2, 3))), id: 3) == nil)
        let other = PB.field(9, PB.field(1, 500) + PB.field(2, 6)) + PB.field(1, PB.field(1, 2) + PB.field(5, 1))
        precondition(BandTightness.describe(kind: BandTightness.update, channel: 5, payload: other)
            == "Frame 2000316 channel 5, 13 bytes: quality check, dead channels 6; device state 2 on wrist 1 reason 0 [1={1=2 5=1} 9={1=500 2=6}]")
        precondition(BandTightness.describe(kind: 0x02000299, channel: 0x8005, payload: PB.field(1, 7)) == "Frame 2000299 channel 5, 2 bytes [1=7]")
        precondition(BandTightness.describe(kind: 0x02000315, channel: 1, payload: PB.field(1, 7)) == "Frame 2000315 channel 1, 2 bytes: late answer [1=7]")
        precondition(BandTightness.describe(kind: 0x02000299, channel: 5, payload: Data([0xff])) == "Frame 2000299 channel 5, 1 bytes: not a message.")

        // On the wire: the request is one the band may refuse or ignore, and other frames are passed on only while listening.
        func isOther(_ signals: [BandProtocol.Signal], _ wanted: UInt32) -> Bool {
            signals.contains { if case .other(let kind, _, _) = $0 { return kind == wanted }; return false }
        }
        func isAnswer(_ signals: [BandProtocol.Signal], empty: Bool) -> Bool {
            signals.contains { if case .reply("named_trigger", let payload) = $0 { return payload.isEmpty == empty }; return false }
        }
        let ask = BandTightness.request(id: 3, name: name, capability: real, action: 2, value: nil)!
        func asked(_ fixture: TrustFixture, now: TimeInterval) throws -> UInt64 {
            let output = try fixture.host.request("named_trigger", channel: NamedSettings.channel, field: NamedSettings.field, payload: ask, now: now)
            let fields = try Fields(DataXReceiver().feed(fixture.bandRx.feed(output)[0])[0].payload)
            let sent = try fields.bytes(14)
            precondition(sent == ask)
            return try fields.integer(1)
        }
        let live = try TrustFixture(); try live.authenticate(); try live.enableGestures()
        let update = Frame(channel: 0x8005, words: [BandTightness.update], payload: detector)
        let unheard = try live.send(update, now: 6)
        precondition(unheard.1.isEmpty)
        live.host.watchesOther = true
        var id = try asked(live, now: 6)
        let heard = try live.send(update, now: 6.5)
        precondition(isOther(heard.1, BandTightness.update))
        let gesture = try live.send(Frame(channel: 0x8005, words: [0x0200020d], payload: PB.field(1, 1) + PB.field(2, 100) + PB.field(3, 2) + PB.field(4, 1)), now: 7)
        precondition(gesture.1.count == 1 && !isOther(gesture.1, 0x0200020d))
        let answered = try live.send(Frame(channel: 1, words: [0x02000315], payload: PB.field(1, id) + named(3, PB.field(1, 3) + PB.field(3, 2), status: 0)), now: 8)
        precondition(isAnswer(answered.1, empty: false) && answered.1.count == 1)
        // Silence ends the wait without ending the connection, and a late answer is still heard while listening.
        id = try asked(live, now: 9)
        let waiting = try live.host.tick(now: 16.9), expired = try live.host.tick(now: 17)
        precondition(waiting.isEmpty && isAnswer(expired, empty: true))
        let late = try live.send(Frame(channel: 1, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 1)), now: 18)
        precondition(isOther(late.1, 0x02000315))
        live.host.watchesOther = false
        let ignored = try live.send(Frame(channel: 1, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 1)), now: 19)
        precondition(ignored.1.isEmpty)
        // The band closing the request is reported the same way, and the next request opens it again.
        _ = try asked(live, now: 20)
        let closed = try live.send(Frame(channel: 1, words: [0x0300c001], payload: Data()), now: 21)
        precondition(isAnswer(closed.1, empty: true))
        _ = try asked(live, now: 22)
        precondition(live.host.stage == "ready")
        // A stream request the test makes is as optional: refused, unanswered or closed, the connection stays up and gestures go on.
        func streamsAsked(_ now: TimeInterval) throws -> UInt64 {
            let wanted = BandTightness.flags(BandProtocol.streamFlags(gyro: false, orientation: false), with: [22])
            let output = try live.host.request("named_streams", channel: 5, field: 4, payload: wanted, now: now)
            let fields = try Fields(DataXReceiver().feed(live.bandRx.feed(output)[0])[0].payload)
            let sent = try fields.bytes(4)
            precondition(sent == wanted)
            return try fields.integer(1)
        }
        func isStreams(_ signals: [BandProtocol.Signal], empty: Bool) -> Bool {
            signals.contains { if case .reply("named_streams", let payload) = $0 { return payload.isEmpty == empty }; return false }
        }
        id = try streamsAsked(23)
        let refusedStreams = try live.send(Frame(channel: 5, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 0)), now: 24)
        precondition(isStreams(refusedStreams.1, empty: false))
        _ = try streamsAsked(25)
        let silentStreams = try live.host.tick(now: 33)
        precondition(isStreams(silentStreams, empty: true))
        _ = try streamsAsked(34)
        let closedStreams = try live.send(Frame(channel: 5, words: [0x0300c001], payload: Data()), now: 35)
        precondition(isStreams(closedStreams.1, empty: true))
        let still = try live.send(Frame(channel: 0x8005, words: [0x0200020d], payload: PB.field(1, 2) + PB.field(2, 200) + PB.field(3, 2) + PB.field(4, 1)), now: 36)
        precondition(still.1.contains { if case .gesture = $0 { return true }; return false } && live.host.stage == "ready")
        print("Band tightness checks passed: descriptions, the plan, requests and their limits, stream flags, answers, unasked messages, refusal, silence and late answers.")
    }
}
