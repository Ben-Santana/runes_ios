// Offline checks of the firmware update engine against a pretend band. No Bluetooth, no network.
// swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift RunesIOS/Persistence/IdentityStore.swift RunesIOS/Firmware/FirmwareUpdate.swift Tests/FirmwareUpdateTests.swift -o /private/tmp/runes-firmware-update-tests && /private/tmp/runes-firmware-update-tests
// The pretend band follows the update messages as the public band-core project wrote them down.
import Foundation
import CryptoKit

/// The band's side of an update: what it holds, and an answer to each request.
final class PretendBand {
    var state: UInt64 = 1, key: UInt64 = 1
    var running: UInt64 = 770435744
    var received: UInt64?, model: UInt64?
    var memory = 16_000
    var goodKey = Data(repeating: 9, count: 32)
    /// Refusals to give instead of the usual answer.
    var refuseKey: UInt64?, refuseStart: UInt64?, refuseVerify: UInt64?, refuseInstall: UInt64?
    /// Only a check of an install lets the band be asked to install. Any other check fails on it.
    var allowsInstall = false
    /// How it answers an install: with its own answer, with a general one, with no result, or not at all.
    var installAnswer = "own"
    /// Counts connections. The band installs only what it verified in the connection that asks.
    var connection = 0
    private var verifiedIn: [UInt64: Int] = [:]
    private(set) var installed = false
    var unavailable: UInt64?
    /// Chunks at these offsets are lost on the way this many times.
    var lose: [Int: Int] = [:]
    var nackAt: Int?
    var silent = false
    /// Leaves the result out of an accepted answer, as a band that drops empty parts would.
    var bareAnswers = false

    private var item: (kind: UInt64, version: UInt64, size: Int)?
    private var md5 = Data()
    private var parts: [Int: Data] = [:]
    private(set) var verified: [UInt64: Data] = [:]
    private(set) var seen: [String] = []
    private(set) var chunks = 0, bytes = 0

    private var contiguous: Int {
        var offset = 0
        while let part = parts[offset] { offset += part.count }
        return offset
    }
    /// A yes is a result that is there and empty, as the real band sent on 2026-11-17.
    private func result(_ code: UInt64) -> Data { PB.field(1, code == 0 ? Data() : PB.field(1, code)) }
    private func general(_ code: UInt64) -> Data {
        if bareAnswers, code == 0 { return PB.field(1, Data()) }
        return PB.field(1, result(code))
    }
    private func reply(_ id: UInt64, _ field: Int, _ body: Data) -> Data { PB.field(1, id) + PB.field(2, 1) + PB.field(field, body) }

    /// Drops what it holds, as it does when told to or when it loses its place.
    func forget() { state = 1; item = nil; parts = [:]; received = nil; verified = [:]; verifiedIn = [:] }

    func answer(_ body: Data) -> Data? {
        let fields = try! Fields(body), id = try! fields.integer(1)
        if silent || installed { seen.append("unanswered"); return nil }
        if let raw = try? fields.bytes(7) {
            let request = try! Fields(raw)
            if let raw = try? request.bytes(4) {
                precondition(allowsInstall, "only an install may ask the band to install")
                precondition(try! Fields(raw).integer(1) == 0, "the restart is not put off")
                seen.append("install")
                if let refuseInstall { return reply(id, 8, PB.field(4, result(refuseInstall))) }
                // What was verified in an earlier connection does not count.
                guard state == 3, !verified.isEmpty, verifiedIn.values.allSatisfy({ $0 == connection }) else { return reply(id, 8, PB.field(4, result(205))) }
                running = received ?? running; installed = true
                switch installAnswer {
                case "general": return reply(id, 8, general(0))
                case "bare": return reply(id, 8, PB.field(4, Data()))
                case "none": return nil
                default: return reply(id, 8, PB.field(4, result(0) + PB.field(2, 1)))
                }
            }
            if request.values[1] != nil {
                seen.append("status")
                var info = PB.field(2, 1) + PB.field(4, unavailable == nil ? state : 0)
                info += PB.field(5, PB.field(2, running)) + PB.field(5, PB.field(1, 1) + PB.field(2, received ?? running))
                info += PB.field(5, PB.field(1, 2) + (model.map { PB.field(2, $0) } ?? Data())) + PB.field(6, key)
                if let unavailable { info += PB.field(7, unavailable) }
                return reply(id, 8, PB.field(2, info))
            }
            if request.values[5] != nil {
                seen.append("discard")
                guard state != 1 else { return reply(id, 8, general(204)) }
                forget()
                return reply(id, 8, general(0))
            }
            if let raw = try? request.bytes(6) {
                let install = try! Fields(raw)
                seen.append("key \(try! install.integer(1))")
                precondition(try! install.integer(2) == 0)
                if let refuseKey { return reply(id, 8, general(refuseKey)) }
                guard try! install.bytes(3) == goodKey else { return reply(id, 8, general(208)) }
                key = try! install.integer(1)
                return reply(id, 8, general(0))
            }
            if let raw = try? request.bytes(2) {
                let start = try! Fields(raw), about = try! Fields(start.bytes(1))
                let kind = try! about.integer(1, default: 0), version = try! about.integer(2)
                seen.append("start \(kind)")
                precondition(try! start.integer(3) == 0 && start.integer(4) == 0)
                if let refuseStart { return reply(id, 8, general(refuseStart)) }
                guard version > running else { return reply(id, 8, general(202)) }
                item = (kind, version, Int(try! start.integer(2))); parts = [:]; state = 2
                return reply(id, 8, general(0))
            }
            if let raw = try? request.bytes(3) {
                let about = try! Fields(Fields(raw).bytes(1)), kind = try! about.integer(1, default: 0)
                seen.append("verify \(kind)")
                var whole = Data()
                while let part = parts[whole.count] { whole.append(part) }
                let good = item?.kind == kind && whole.count == item?.size && Data(Insecure.MD5.hash(data: whole)) == md5
                let code = refuseVerify ?? (good ? 0 : 300)
                if code == 0 {
                    verified[kind] = whole; verifiedIn[kind] = connection; state = 3
                    if kind == 0 { received = item?.version } else { model = item?.version }
                }
                return reply(id, 8, PB.field(3, result(code)))
            }
            preconditionFailure("unknown update request")
        }
        let request = try! Fields(fields.bytes(9))
        if let raw = try? request.bytes(1) {
            let setup = try! Fields(raw)
            seen.append("setup \(try! setup.integer(4))")
            precondition(try! setup.integer(3) == 1)
            guard let item, Int(try! setup.integer(2)) == item.size else { return reply(id, 10, PB.field(3, PB.field(1, try! setup.integer(4)) + PB.field(2, Data("no item".utf8)))) }
            md5 = try! setup.bytes(1, count: 16)
            let have = contiguous
            return reply(id, 10, PB.field(1, PB.field(1, have == item.size ? 3 : 1) + PB.field(2, UInt64(memory)) + PB.field(3, UInt64(have)) + PB.field(5, try! setup.integer(4))))
        }
        let chunk = try! Fields(request.bytes(2)), offset = Int(try! chunk.integer(2, default: 0)), data = try! chunk.bytes(3)
        chunks += 1
        precondition(data.count <= 950 && !data.isEmpty)
        if let left = lose[offset], left > 0 { lose[offset] = left - 1; return nil }
        if nackAt == offset { return reply(id, 10, PB.field(3, PB.field(1, try! chunk.integer(1)) + PB.field(2, Data("bad offset".utf8)))) }
        if parts[offset] == nil { bytes += data.count }
        parts[offset] = data
        return reply(id, 10, PB.field(2, PB.field(1, try! chunk.integer(1)) + PB.field(2, UInt64(offset))))
    }
}

@main
struct FirmwareUpdateTests {
    static let firmware = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 8) })
    static let model = Data((0..<12_345).map { UInt8(truncatingIfNeeded: $0 &* 3) })

    static func plan(_ mode: FirmwareUpdate.Mode, key: Data? = Data(repeating: 9, count: 32), model: Data? = model) -> FirmwareUpdate.Plan {
        func item(_ kind: UInt64, _ name: String, _ data: Data) -> FirmwareUpdate.Item {
            FirmwareUpdate.Item(kind: kind, name: name, data: data, md5: Data(Insecure.MD5.hash(data: data)))
        }
        return FirmwareUpdate.Plan(version: 1003366292, items: [item(0, "firmware", firmware)] + (model.map { [item(2, "model bundle", $0)] } ?? []),
                                   keyNumber: 20, wrappedKey: key, mode: mode)
    }

    /// Carries requests to the band and answers back until the update ends, the clock moving on
    /// when nothing is in flight. Returns every line the update wrote.
    @discardableResult
    static func run(_ job: FirmwareUpdate, _ band: PretendBand, ids: inout UInt64, clock: inout Double, queue first: [Data], until stop: (() -> Bool)? = nil) -> [String] {
        var queue = first, lines: [String] = [], turns = 0
        while !job.done, stop?() != true {
            turns += 1
            precondition(turns < 200_000, "the update never ended")
            if queue.isEmpty {
                clock += 1
                queue += job.tick(ids: &ids, now: clock)
            } else {
                precondition(queue.count <= FirmwareUpdate.windowLimit, "more in flight than the band was promised")
                clock += 0.01
                if let reply = band.answer(queue.removeFirst()) { queue += job.receive(reply, ids: &ids, now: clock) }
            }
            lines += job.takeLines()
        }
        return lines + job.takeLines()
    }

    static func begin(_ mode: FirmwareUpdate.Mode, _ band: PretendBand, key: Data? = Data(repeating: 9, count: 32), model: Data? = model) -> (job: FirmwareUpdate, lines: [String]) {
        let job = FirmwareUpdate(plan(mode, key: key, model: model))
        var ids: UInt64 = 10, clock = 0.0
        let first = job.begin(ids: &ids, now: clock)
        return (job, run(job, band, ids: &ids, clock: &clock, queue: first))
    }

    static func main() throws {
        // The requests, byte for byte, as the band-core project sends them.
        do {
            let job = FirmwareUpdate(plan(.trial))
            var ids: UInt64 = 10
            let status = job.begin(ids: &ids, now: 0)
            precondition(status == [Data([0x08, 0x0b, 0x3a, 0x02, 0x0a, 0x00])])
            let band = PretendBand(); band.key = 20
            let start = job.receive(band.answer(status[0])!, ids: &ids, now: 0)
            // Request 12 is an update request holding a start: kind 0, version 1003366292, 20000 bytes, no skipping, key 0.
            let version: [UInt8] = [0x94, 0xcf, 0xb8, 0xde, 0x03]
            let about: [UInt8] = [0x08, 0x00, 0x10] + version
            let inner: [UInt8] = [0x0a, UInt8(about.count)] + about + [0x10, 0xa0, 0x9c, 0x01, 0x18, 0x00, 0x20, 0x00]
            precondition(start == [Data([0x08, 0x0c, 0x3a, UInt8(inner.count + 2), 0x12, UInt8(inner.count)] + inner)])
            let setup = job.receive(band.answer(start[0])!, ids: &ids, now: 0)
            let md5 = [UInt8](Insecure.MD5.hash(data: firmware))
            let described: [UInt8] = [0x0a, 0x10] + md5 + [0x10, 0xa0, 0x9c, 0x01, 0x18, 0x01, 0x20, 0x01]
            precondition(setup == [Data([0x08, 0x0d, 0x4a, UInt8(described.count + 2), 0x0a, UInt8(described.count)] + described)])
            let chunks = job.receive(band.answer(setup[0])!, ids: &ids, now: 0)
            precondition(chunks.count == 8, "eight chunks go out at once and no more")
            let first = try Fields(Fields(chunks[0]).bytes(9)), part = try Fields(first.bytes(2))
            let number = try part.integer(1), offset = try part.integer(2, default: 0), data = try part.bytes(3)
            precondition(number == 1 && offset == 0 && data == firmware.prefix(950))
            let second = try Fields(Fields(Fields(chunks[1]).bytes(9)).bytes(2))
            let next = try second.integer(2), request = try Fields(chunks[1]).integer(1)
            precondition(next == 950 && request == 15)
        }

        // The status the user's band gave on 2026-11-17, read back.
        do {
            let band = PretendBand()
            let reply = band.answer(PB.field(1, 6) + PB.field(7, PB.field(1, Data())))!
            let status = BandUpdateStatus(try Fields(Fields(reply).bytes(8)))!
            precondition(status.state == 1 && status.device == 0 && status.key == 1 && status.running == 770435744 && status.received == 770435744 && status.model == 0)
            precondition(status.summary == "idle, stable firmware, running 770435744, received 770435744, model 0, key 1")
        }

        // The key alone: asked for, installed, and confirmed by the band's own status.
        do {
            let band = PretendBand()
            let (job, lines) = begin(.key, band)
            precondition(job.succeeded && band.key == 20 && band.seen == ["status", "key 20", "status"], "\(band.seen)")
            precondition(lines.last == "The band now has key 20.")
            let again = begin(.key, band)
            precondition(again.job.succeeded && band.seen.suffix(1) == ["status"] && again.lines.last == "The band already has key 20.")
        }
        // A band that leaves the result out of its key answer is still judged by its status.
        do {
            let band = PretendBand(); band.bareAnswers = true
            precondition(begin(.key, band).job.succeeded && band.key == 20)
        }
        // A refused key, and a key the band says it took without taking it.
        do {
            let band = PretendBand(); band.refuseKey = 208
            let (job, lines) = begin(.key, band)
            precondition(job.done && !job.succeeded && band.key == 1 && band.seen == ["status", "key 20"])
            precondition(lines.contains("Failed: the band refused the key: invalid key (208)."))
            let wrong = PretendBand(); wrong.goodKey = Data(repeating: 1, count: 32)
            precondition(!begin(.key, wrong).job.succeeded)
        }
        // A band that lacks the key and no key fetched: nothing is sent past the status.
        do {
            let band = PretendBand()
            let (job, _) = begin(.trial, band, key: nil)
            precondition(job.done && !job.succeeded && band.seen == ["status"])
        }

        // The whole trial: key, both items in chunks, each verified, then all of it discarded.
        do {
            let band = PretendBand()
            let (job, lines) = begin(.trial, band)
            precondition(job.succeeded, lines.joined(separator: "\n"))
            precondition(band.seen == ["status", "key 20", "status", "start 0", "setup 1", "verify 0", "start 2", "setup 2", "verify 2", "discard", "status"], "\(band.seen)")
            precondition(band.chunks == 22 + 13 && band.key == 20 && band.state == 1 && band.received == nil && band.verified.isEmpty)
            precondition(lines.last == "Trial passed: every item was sent and verified, then discarded. Nothing was installed.")
            precondition(lines.filter { $0.hasPrefix("The firmware: ") && $0.hasSuffix("KiB/s).") }.count >= 10 && job.progress == nil, lines.joined(separator: "\n"))
        }
        // A band that already has the key is not sent one, even when none was fetched.
        do {
            let band = PretendBand(); band.key = 20
            let (job, _) = begin(.trial, band, key: nil)
            precondition(job.succeeded && !band.seen.contains("key 20"))
        }
        // A small model bundle is a placeholder and is not sent. The band names a model bundle
        // it threw away after an earlier trial, so the version it reports decides nothing.
        do {
            let band = PretendBand(); band.key = 20
            precondition(begin(.trial, band, model: Data(repeating: 1, count: 10_240)).job.succeeded && !band.seen.contains("start 2"))
            let current = PretendBand(); current.key = 20; current.model = 1075365371
            precondition(begin(.trial, current).job.succeeded && current.seen.contains("start 2"))
        }
        // An earlier update the band still holds is discarded before anything is sent.
        do {
            let band = PretendBand(); band.key = 20; band.state = 3; band.received = 5
            let (job, _) = begin(.trial, band)
            precondition(job.succeeded && band.seen.prefix(4) == ["status", "discard", "status", "start 0"])
        }
        // The band already runs this version.
        do {
            let band = PretendBand(); band.running = 1003366292
            let (job, _) = begin(.trial, band)
            precondition(job.done && !job.succeeded && band.seen == ["status"])
        }
        // Updates unavailable: said, and nothing more is asked.
        do {
            let band = PretendBand(); band.unavailable = 3
            let (job, lines) = begin(.trial, band)
            precondition(job.done && !job.succeeded && band.seen == ["status"])
            precondition(lines.contains { $0.contains("because: power") })
        }

        // Lost chunks are sent again after five seconds, and the item still verifies.
        do {
            let band = PretendBand(); band.key = 20; band.lose = [1900: 1, 9500: 3]
            let (job, lines) = begin(.trial, band)
            precondition(job.succeeded && band.chunks == 22 + 13 + 4, "\(band.chunks)")
            precondition(lines.contains("Sent 1 late chunk again."))
        }
        // A chunk the band never answers ends the trial, and the band is told to discard.
        do {
            let band = PretendBand(); band.key = 20; band.lose = [2850: 99]
            let (job, lines) = begin(.trial, band)
            precondition(job.done && !job.succeeded && band.state == 1 && band.seen.suffix(1) == ["discard"])
            precondition(lines.contains("Failed: no answer for the chunk at 2850 after 5 tries."))
        }
        // A refused chunk, a refused start and a failed verify each end it the same way.
        do {
            let band = PretendBand(); band.key = 20; band.nackAt = 4750
            precondition(!begin(.trial, band).job.succeeded && band.state == 1 && band.seen.suffix(1) == ["discard"])
            let power = PretendBand(); power.key = 20; power.refuseStart = 201
            let (job, lines) = begin(.trial, power)
            precondition(!job.succeeded && power.seen == ["status", "start 0", "discard"])
            precondition(lines.contains("Failed: the band refused to start the firmware: power state (201)."))
            let checksum = PretendBand(); checksum.key = 20; checksum.refuseVerify = 300
            precondition(!begin(.trial, checksum).job.succeeded && checksum.seen.suffix(2) == ["verify 0", "discard"])
            let bare = PretendBand(); bare.key = 20; bare.bareAnswers = true
            precondition(!begin(.trial, bare).job.succeeded && bare.seen == ["status", "start 0", "discard"], "an answer with no result is not taken as a yes")
        }
        // A band that stops answering: the trial gives up, and so does its discard.
        do {
            let band = PretendBand(); band.silent = true
            let (job, lines) = begin(.trial, band)
            precondition(job.done && !job.succeeded && lines.contains { $0.hasPrefix("Failed: no answer from the band") })
        }

        // A dropped link part way through an item: the band kept it, and sending picks up where it says.
        for kept in [true, false] {
            let band = PretendBand(); band.key = 20
            let job = FirmwareUpdate(plan(.trial))
            var ids: UInt64 = 10, clock = 0.0
            var lines = run(job, band, ids: &ids, clock: &clock, queue: job.begin(ids: &ids, now: clock)) { band.bytes >= 9_500 }
            precondition(!job.done && job.progress?.stage == "sending")
            job.linkLost()
            precondition(job.tick(ids: &ids, now: clock + 100).isEmpty, "nothing is sent or timed out while the band is away")
            if !kept { band.forget() }
            let before = band.chunks
            // A new connection numbers its requests from the start.
            ids = 3; clock += 100
            lines += run(job, band, ids: &ids, clock: &clock, queue: job.resume(ids: &ids, now: clock))
            precondition(job.succeeded, lines.joined(separator: "\n"))
            precondition(band.seen.filter { $0 == "start 0" }.count == (kept ? 1 : 2))
            precondition(kept ? band.chunks - before < 22 + 13 : band.chunks - before == 22 + 13)
            precondition(lines.contains(kept ? "The band kept what it had. Asking where the firmware stopped." : "The band dropped what it had. Starting again."))
        }
        // A dropped link while the band was verifying: on return it already has the whole item.
        do {
            let band = PretendBand(); band.key = 20
            let job = FirmwareUpdate(plan(.trial, model: nil))
            var ids: UInt64 = 10, clock = 0.0
            run(job, band, ids: &ids, clock: &clock, queue: job.begin(ids: &ids, now: clock)) { job.progress?.stage == "checking" }
            job.linkLost()
            let lines = run(job, band, ids: &ids, clock: &clock, queue: job.resume(ids: &ids, now: clock))
            precondition(job.succeeded && lines.contains("The band already has all of the firmware. Verifying."))
        }
        // A link that keeps dropping ends the trial.
        do {
            let band = PretendBand(); band.key = 20
            let job = FirmwareUpdate(plan(.trial))
            var ids: UInt64 = 10, clock = 0.0
            run(job, band, ids: &ids, clock: &clock, queue: job.begin(ids: &ids, now: clock)) { band.bytes >= 950 }
            for _ in 0..<FirmwareUpdate.lossLimit { job.linkLost(); _ = job.resume(ids: &ids, now: clock) }
            job.linkLost()
            run(job, band, ids: &ids, clock: &clock, queue: job.resume(ids: &ids, now: clock))
            precondition(job.done && !job.succeeded && band.state == 1)
        }

        // Stopping part way: the band discards, and its status is read to be sure.
        do {
            let band = PretendBand(); band.key = 20
            let job = FirmwareUpdate(plan(.trial))
            var ids: UInt64 = 10, clock = 0.0
            run(job, band, ids: &ids, clock: &clock, queue: job.begin(ids: &ids, now: clock)) { band.bytes >= 4_750 }
            let lines = run(job, band, ids: &ids, clock: &clock, queue: job.stop(ids: &ids, now: clock))
            precondition(job.done && !job.succeeded && band.state == 1 && band.seen.suffix(2) == ["discard", "status"])
            precondition(lines.last == "Stopped. The band holds nothing new.")
        }
        // Stopping before anything was sent asks nothing of the band.
        do {
            let job = FirmwareUpdate(plan(.trial))
            var ids: UInt64 = 10
            _ = job.begin(ids: &ids, now: 0)
            precondition(job.stop(ids: &ids, now: 0).isEmpty && job.done)
        }
        // Discarding on request, with something held and with nothing.
        do {
            let band = PretendBand(); band.state = 2
            let (job, lines) = begin(.cancel, band)
            precondition(job.succeeded && band.seen == ["discard", "status"] && lines.last == "Discarded. The band holds nothing new.")
            precondition(begin(.cancel, PretendBand()).job.succeeded)
        }

        // The install: everything in one connection, then the band is told to keep it.
        for answer in ["own", "general"] {
            let band = PretendBand(); band.allowsInstall = true; band.installAnswer = answer
            let (job, lines) = begin(.install, band)
            precondition(job.succeeded && job.committed && band.installed && band.running == 1003366292, lines.joined(separator: "\n"))
            precondition(band.seen == ["status", "key 20", "status", "start 0", "setup 1", "verify 0", "start 2", "setup 2", "verify 2", "install"], "\(band.seen)")
            precondition(lines.last == "The band accepted the install. It now restarts into version 1003366292.")
        }
        // The install request itself, byte for byte: request 11 asks to install now.
        do {
            let band = PretendBand(); band.allowsInstall = true; band.key = 20
            let job = FirmwareUpdate(plan(.install, model: nil))
            var ids: UInt64 = 10, clock = 0.0, last = Data()
            var queue = job.begin(ids: &ids, now: clock)
            while !job.done, !queue.isEmpty {
                last = queue.removeFirst()
                if let reply = band.answer(last) { queue += job.receive(reply, ids: &ids, now: clock) }
            }
            precondition(last.suffix(6) == Data([0x3a, 0x04, 0x22, 0x02, 0x08, 0x00]) && job.committed)
        }
        // An install sends the model bundle whatever the band reports, as a trial does.
        do {
            let band = PretendBand(); band.allowsInstall = true; band.key = 20; band.model = 1075365371
            precondition(begin(.install, band).job.succeeded && band.seen.contains("start 2"))
        }
        // An earlier update the band holds is discarded first, and nothing verified before counts.
        do {
            let band = PretendBand(); band.allowsInstall = true; band.key = 20; band.state = 3; band.received = 5
            let (job, _) = begin(.install, band)
            precondition(job.succeeded && band.seen.prefix(4) == ["status", "discard", "status", "start 0"])
        }
        // An answer with no result, or no answer at all: taken as asked for, never stopped or discarded.
        for answer in ["bare", "none"] {
            let band = PretendBand(); band.allowsInstall = true; band.key = 20; band.installAnswer = answer
            let (job, lines) = begin(.install, band)
            precondition(job.done && job.committed && !job.succeeded && band.seen.last == "install", lines.joined(separator: "\n"))
            var ids: UInt64 = 900
            precondition(job.stop(ids: &ids, now: 0).isEmpty && job.tick(ids: &ids, now: 9999).isEmpty)
        }
        // A refused install: the band keeps running what it had and is told to discard.
        do {
            let band = PretendBand(); band.allowsInstall = true; band.key = 20; band.refuseInstall = 201
            let (job, lines) = begin(.install, band)
            precondition(job.done && !job.committed && !job.succeeded && !band.installed && band.state == 1 && band.seen.suffix(2) == ["install", "discard"])
            precondition(lines.contains("Failed: the band refused to install: power state (201)."))
        }
        // A failed verify during an install never reaches the install request.
        do {
            let band = PretendBand(); band.allowsInstall = true; band.key = 20; band.refuseVerify = 300
            let (job, _) = begin(.install, band)
            precondition(!job.committed && !band.seen.contains("install") && band.seen.last == "discard")
        }
        // A dropped link during an install: it starts again from the first item, so that the
        // install is asked for in the connection that verified everything.
        for drop in [9_500, 20_000 + 4_750] {
            let band = PretendBand(); band.allowsInstall = true; band.key = 20
            let job = FirmwareUpdate(plan(.install))
            var ids: UInt64 = 10, clock = 0.0
            var lines = run(job, band, ids: &ids, clock: &clock, queue: job.begin(ids: &ids, now: clock)) { band.bytes >= drop }
            job.linkLost(); band.connection += 1
            ids = 3
            lines += run(job, band, ids: &ids, clock: &clock, queue: job.resume(ids: &ids, now: clock))
            precondition(job.succeeded && band.installed, lines.joined(separator: "\n"))
            precondition(band.seen.filter { $0 == "start 0" }.count == 2 && band.seen.filter { $0 == "discard" }.count == 1 && band.seen.filter { $0 == "install" }.count == 1)
        }
        // A link that drops just after the install was asked for: the update ends there and asks nothing more.
        do {
            let band = PretendBand(); band.allowsInstall = true; band.key = 20; band.installAnswer = "none"
            let job = FirmwareUpdate(plan(.install))
            var ids: UInt64 = 10, clock = 0.0
            run(job, band, ids: &ids, clock: &clock, queue: job.begin(ids: &ids, now: clock)) { band.installed }
            // Once the install is asked for, stopping sends nothing: a discard now could meet a band part way through.
            precondition(!job.done && job.stop(ids: &ids, now: clock).isEmpty && !job.done)
            job.linkLost()
            precondition(job.done && job.committed && job.resume(ids: &ids, now: clock).isEmpty)
            job.abandon()
            precondition(job.committed)
        }
        // Stopping an install part way discards, and the band keeps what it ran.
        do {
            let band = PretendBand(); band.allowsInstall = true; band.key = 20
            let job = FirmwareUpdate(plan(.install))
            var ids: UInt64 = 10, clock = 0.0
            run(job, band, ids: &ids, clock: &clock, queue: job.begin(ids: &ids, now: clock)) { band.bytes >= 4_750 }
            run(job, band, ids: &ids, clock: &clock, queue: job.stop(ids: &ids, now: clock))
            precondition(job.done && !job.committed && !band.installed && band.state == 1 && band.running == 770435744)
        }
        print("FirmwareUpdateTests passed")
    }
}
