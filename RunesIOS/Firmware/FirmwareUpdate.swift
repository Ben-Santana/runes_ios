import Foundation

/// What the band says about updates when it is asked.
struct BandUpdateStatus: Equatable {
    /// 0 unavailable, 1 idle, 2 receiving, 3 received and verified.
    var state: UInt64 = 0
    /// 0 stable firmware, 1 trial firmware, 2 recovery firmware.
    var device: UInt64 = 0
    /// The version of the key the band holds for reading packages.
    var key: UInt64 = 0
    /// Why updates are unavailable: 1 no Bluetooth, 2 turned off on the band, 3 power, 4 trial firmware.
    var reason: UInt64 = 0
    /// The firmware it runs, the firmware it last received, and its model bundle.
    var running: UInt64?, received: UInt64?, model: UInt64?

    /// Reads the update part of a status answer.
    init?(_ answer: Fields) {
        guard let info = try? Fields(answer.bytes(2)) else { return nil }
        func number(_ field: Int) -> UInt64 { (try? info.integer(field, default: 0)) ?? 0 }
        state = number(4); device = number(3); key = number(6); reason = number(7)
        for case .bytes(2, let raw) in info.values[5] ?? [] {
            guard let item = try? Fields(raw), let kind = try? item.integer(1, default: 0), let version = try? item.integer(2, default: 0) else { continue }
            switch kind {
            case 0: running = version
            case 1: received = version
            case 2: model = version
            default: break
            }
        }
    }

    var summary: String {
        func shown(_ version: UInt64?) -> String { version.map(String.init) ?? "none" }
        let states = ["unavailable", "idle", "receiving", "received and verified"]
        let devices = ["stable firmware", "trial firmware", "recovery firmware"]
        let reasons = ["no reason given", "no Bluetooth", "turned off on the band", "power", "trial firmware running"]
        func name(_ names: [String], _ value: UInt64) -> String { value < UInt64(names.count) ? names[Int(value)] : "unknown \(value)" }
        var text = "\(name(states, state)), \(name(devices, device)), running \(shown(running)), received \(shown(received)), model \(shown(model)), key \(key)"
        if state == 0 { text += ", because: \(name(reasons, reason))" }
        return text
    }
}

/// One update, request by request. It writes the requests and reads the band's answers, and
/// whoever owns the connection sends and receives them. The order and the timings are the ones
/// the public band-core project used on a band. A trial sends and verifies every item and then
/// has the band discard them. Only an install ends with the band told to keep them, and
/// that cannot be undone.
final class FirmwareUpdate {
    enum Mode: Equatable {
        /// Gives the band the key the package needs. The band keeps it.
        case key
        /// The key if needed, every item sent and verified, then all of it discarded.
        case trial
        /// Has the band discard whatever update it holds.
        case cancel
        /// The whole update in one connection: the key if needed, every item sent and verified,
        /// then the band told to install them. It restarts into the new firmware. One way.
        case install
    }
    struct Item {
        /// 0 for firmware and 2 for the model bundle, as the band numbers them.
        let kind: UInt64
        let name: String
        let data: Data
        let md5: Data
    }
    struct Plan {
        let version: UInt64
        /// The firmware first, then the model bundle if the package has one.
        let items: [Item]
        let keyNumber: UInt64
        /// The key as Meta wrapped it for this band. Needed only when the band lacks it.
        let wrappedKey: Data?
        let mode: Mode
        /// Whether a model bundle the band refuses as older is asked for once more with the
        /// version check skipped. The band refused one on 2026-11-17 that a trial had already
        /// sent it. The switch is in the band's own messages and no source has tried it. The
        /// firmware itself is never asked for this way.
        var forcesRefusedModel = false
        /// Whether a model bundle the band already reports at this package's version is left
        /// unsent, as the Meta app leaves it. The band is asked to verify the bundle it holds,
        /// and nothing is installed unless it does.
        var trustsHeldModel = false
    }
    struct Progress: Equatable {
        let name: String
        let sent: Int, size: Int
        /// "waiting", "sending" or "checking".
        let stage: String
    }

    static let chunkSize = 950
    /// The most chunks in flight. The band offers room for more on some firmware, and links dropped with it.
    static let windowLimit = 8
    static let chunkTries = 4
    /// A model bundle this small is a placeholder and is not sent.
    static let modelFloor = 10 * 1024
    static let answerWait: TimeInterval = 15, chunkWait: TimeInterval = 5
    static let lossLimit = 5

    private enum Ask { case first, afterReset, afterKey, resumed, last }
    private enum Step: Equatable { case status(Ask), reset, key, start, setup, verify, abort, rescue, commit }
    private struct Sent { var id: UInt64; var at: TimeInterval; var tries: Int }
    private struct Transfer {
        let number: UInt64
        var next = 0, window = 0
        var pending: [Int: Sent] = [:]
        var started: TimeInterval
        var samples: [(at: TimeInterval, sent: Int)] = []
        var shown = 0
    }

    private let plan: Plan
    private var items: [Item] = []
    private var item = 0
    private var waiting: (id: UInt64, deadline: TimeInterval, step: Step)?
    private var transfer: Transfer?
    /// Whether the band accepted the start of the current item, so a dropped link can pick it up.
    private var started = false
    /// Whether anything was asked of the band that leaves it holding part of an update.
    private var touched = false
    /// The final discard has been asked for.
    private var closing = false
    private var stopped = false, failed = false, away = false
    /// The current item's start is being asked for again with the version check skipped.
    private var forcing = false
    /// The band reports this package's model bundle already, and is asked to verify it unsent.
    private var heldModel = false
    private var modelRefused = false
    private var losses = 0
    private var log: [String] = []
    private(set) var done = false
    /// Whether the run ended the way its mode intends.
    private(set) var succeeded = false
    /// The band was told to install, or may have been. From here nothing is discarded or stopped.
    private(set) var committed = false
    private(set) var status: BandUpdateStatus?

    /// How a run ended. An install that was asked for counts as installing even with no answer,
    /// since the band may already be restarting.
    enum Ending: Equatable {
        case passed, failed, installing
        /// It failed because the band would not take the model bundle, and nothing was installed.
        case modelRefused
    }
    var ending: Ending? { !done ? nil : committed ? .installing : succeeded ? .passed : modelRefused ? .modelRefused : .failed }

    init(_ plan: Plan) { self.plan = plan }

    var mode: Mode { plan.mode }

    /// The lines written since the last call, for the page and the journal.
    func takeLines() -> [String] { defer { log = [] }; return log }

    var progress: Progress? {
        guard !done, item < items.count else { return nil }
        let size = items[item].data.count
        if let transfer { return Progress(name: items[item].name, sent: sent(transfer, size), size: size, stage: "sending") }
        if case .verify = waiting?.step { return Progress(name: items[item].name, sent: size, size: size, stage: "checking") }
        return Progress(name: items[item].name, sent: 0, size: size, stage: "waiting")
    }

    private func say(_ line: String) { log.append(line) }
    private func sent(_ transfer: Transfer, _ size: Int) -> Int { min(size, max(0, transfer.next - transfer.pending.count * Self.chunkSize)) }

    // MARK: Requests

    private func update(_ request: Data, _ ids: inout UInt64) -> (id: UInt64, body: Data) {
        ids += 1
        return (ids, PB.field(1, ids) + PB.field(7, request))
    }
    private func bulk(_ request: Data, _ ids: inout UInt64) -> (id: UInt64, body: Data) {
        ids += 1
        return (ids, PB.field(1, ids) + PB.field(9, request))
    }
    private func info(_ kind: UInt64) -> Data { PB.field(1, kind) + PB.field(2, plan.version) }

    private func ask(_ step: Step, _ ids: inout UInt64, _ now: TimeInterval) -> Data {
        let request: Data
        switch step {
        case .status: request = PB.field(1, Data())
        case .reset, .abort, .rescue: request = PB.field(5, Data())
        case .key: request = PB.field(6, PB.field(1, plan.keyNumber) + PB.field(2, 0) + PB.field(3, plan.wrappedKey ?? Data()))
        case .start:
            touched = true
            request = PB.field(2, PB.field(1, info(items[item].kind)) + PB.field(2, UInt64(items[item].data.count)) + PB.field(3, forcing ? 1 : 0) + PB.field(4, 0))
        case .verify: request = PB.field(3, PB.field(1, info(items[item].kind)))
        // Install now, without putting the restart off.
        case .commit: request = PB.field(4, PB.field(1, 0))
        case .setup: request = Data()
        }
        let (id, body) = update(request, &ids)
        waiting = (id, now + Self.answerWait, step)
        return body
    }

    // MARK: Starting, stopping and a dropped link

    func begin(ids: inout UInt64, now: TimeInterval) -> [Data] {
        switch plan.mode {
        case .cancel:
            say("Asking the band to discard the update it holds.")
            closing = true
            return [ask(.abort, &ids, now)]
        case .key: say("Key \(plan.keyNumber) for version \(plan.version).")
        case .trial: say("Trial of version \(plan.version). It ends with the band discarding everything, and nothing is installed.")
        case .install: say("Update to version \(plan.version). It ends with the band installing it and restarting. This cannot be undone.")
        }
        return [ask(.status(.first), &ids, now)]
    }

    /// The person asked to stop. The band is told to discard what it holds.
    func stop(ids: inout UInt64, now: TimeInterval) -> [Data] {
        guard !done, !stopped else { return [] }
        if committed || waiting?.step == .commit {
            say("The install has been asked for and cannot be stopped.")
            return []
        }
        guard !away, touched else { abandon(); return [] }
        stopped = true; transfer = nil; waiting = nil
        say("Stopping. Asking the band to discard what it has.")
        closing = true
        return [ask(.abort, &ids, now)]
    }

    /// Ends the run with nothing more said to the band, for when it is not there to be told.
    func abandon() {
        guard !done, !committed, waiting?.step != .commit else { return }
        stopped = true; done = true; transfer = nil; waiting = nil
        say(touched ? "Stopped without telling the band. The next run clears what it holds." : "Stopped. Nothing had been sent.")
    }

    /// The connection dropped. Whatever was in flight is forgotten until the band is back.
    func linkLost() {
        guard !done, !away else { return }
        if waiting?.step == .commit {
            committed = true; done = true; waiting = nil
            say("The link dropped just after the install was asked for. The band is most likely restarting into the new firmware.")
            return
        }
        away = true; losses += 1; waiting = nil; transfer = nil
        say("The link dropped. Waiting for the band to come back.")
    }

    /// The band is connected again. Its status decides where to pick up.
    func resume(ids: inout UInt64, now: TimeInterval) -> [Data] {
        guard !done, away else { return [] }
        away = false
        if losses > Self.lossLimit { return fail("the link dropped \(losses) times", &ids, now) }
        say("The band is back. Asking what it holds.")
        if closing { return [ask(.status(.resumed), &ids, now)] }
        if plan.mode == .trial, touched { return [ask(.status(.resumed), &ids, now)] }
        // An install is asked for in the connection that verified every item, so after a
        // dropped link it starts again from the first one.
        item = 0; started = false
        return [ask(.status(.first), &ids, now)]
    }

    private func fail(_ why: String, _ ids: inout UInt64, _ now: TimeInterval) -> [Data] {
        say("Failed: \(why).")
        transfer = nil; failed = true
        guard touched, !closing, !committed else { done = true; return [] }
        say("Asking the band to discard what it has.")
        closing = true
        return [ask(.rescue, &ids, now)]
    }

    // MARK: Answers

    static func resultName(_ code: UInt64?) -> String {
        guard let code else { return "no result in the answer" }
        let names: [UInt64: String] = [0: "accepted", 100: "invalid item", 200: "no space", 201: "power state", 202: "older version", 203: "an update is in progress",
                                       204: "no update in progress", 205: "wrong state", 206: "trial firmware running", 207: "key version mismatch",
                                       208: "invalid key", 209: "key install failed", 300: "wrong checksum"]
        return "\(names[code] ?? "unknown") (\(code))"
    }

    /// The result code inside one part of an update answer. A code left out is 0, and an answer
    /// with no result at all gives nil.
    private func code(_ response: Fields, _ field: Int) -> UInt64? {
        guard let part = try? Fields(response.bytes(field)), let result = try? Fields(part.bytes(1)) else { return nil }
        return try? result.integer(1, default: 0)
    }
    /// An answer as field numbers and values only, for the journal.
    private func shape(_ fields: Fields) -> String { let text = BandSettings.describe(fields, depth: 0); return text.isEmpty ? "empty" : text }

    /// One answer from the band to a request of this update. Others are ignored.
    func receive(_ reply: Data, ids: inout UInt64, now: TimeInterval) -> [Data] {
        guard !done, let fields = try? Fields(reply), let id = try? fields.integer(1) else { return [] }
        if fields.values[10] != nil { return receiveBulk(fields, id, &ids, now) }
        guard let (expected, _, step) = waiting, expected == id else { return [] }
        waiting = nil
        guard let response = try? Fields(fields.bytes(8)) else {
            return fail("the band gave no update answer (\(shape(fields)))", &ids, now)
        }
        switch step {
        case .status(let ask): return status(response, ask, &ids, now)
        case .verify:
            let result = code(response, 3) ?? code(response, 1)
            guard result == 0 else {
                say("Verify answer: \(shape(response)).")
                return fail("the band did not verify the \(items[item].name): \(Self.resultName(result))", &ids, now)
            }
            say("The band verified the \(items[item].name).")
            item += 1; started = false; forcing = false
            return nextItem(&ids, now)
        case .reset:
            say("Discarding the earlier update: \(Self.resultName(code(response, 1))).")
            item = 0; started = false
            return [ask(.status(.afterReset), &ids, now)]
        case .key:
            let result = code(response, 1)
            say("Key answer: \(shape(response)).")
            guard result == nil || result == 0 else { return fail("the band refused the key: \(Self.resultName(result))", &ids, now) }
            // The band's own status is what says whether it took the key.
            return [ask(.status(.afterKey), &ids, now)]
        case .start:
            let result = code(response, 1)
            guard result == 0 else {
                say("Start answer: \(shape(response)).")
                if result == 202, items[item].kind == 2, plan.forcesRefusedModel, !forcing {
                    say("The band refused the \(items[item].name) as older than what it holds. Asking once more with the version check skipped.")
                    forcing = true
                    return [ask(.start, &ids, now)]
                }
                if result == 202, items[item].kind == 2 { modelRefused = true }
                return fail("the band refused to start the \(items[item].name): \(Self.resultName(result))", &ids, now)
            }
            say("The band accepted the start of the \(items[item].name)\(forcing ? ", with the version check skipped" : "").")
            forcing = false
            started = true
            return startTransfer(&ids, now)
        case .abort:
            say("Discard answer: \(Self.resultName(code(response, 1))). Checking that nothing is held.")
            return [ask(.status(.last), &ids, now)]
        case .rescue:
            say("Discard after the failure: \(Self.resultName(code(response, 1))).")
            done = true
            return []
        case .commit:
            let result = code(response, 4) ?? code(response, 1)
            say("Install answer: \(shape(response)).")
            if let result, result != 0 { return fail("the band refused to install: \(Self.resultName(result))", &ids, now) }
            committed = true; done = true
            if result == 0 {
                succeeded = true
                say("The band accepted the install. It now restarts into version \(plan.version).")
            } else {
                say("The band answered the install without a result. It may be restarting. Read its status when it is back.")
            }
            return []
        case .setup: return []
        }
    }

    private func finish(_ status: BandUpdateStatus) {
        done = true
        let clean = status.state == 1 && status.received == status.running
        if !clean { say("The band does not look clean. Read the status above.") }
        else if stopped { say("Stopped. The band holds nothing new.") }
        else if failed { say("The band holds nothing new.") }
        else if plan.mode == .trial { succeeded = true; say("Trial passed: every item was sent and verified, then discarded. Nothing was installed.") }
        else { succeeded = true; say("Discarded. The band holds nothing new.") }
    }

    private func status(_ response: Fields, _ ask: Ask, _ ids: inout UInt64, _ now: TimeInterval) -> [Data] {
        guard let status = BandUpdateStatus(response) else { return fail("the status answer could not be read (\(shape(response)))", &ids, now) }
        self.status = status
        say("Band: \(status.summary).")
        switch ask {
        case .last:
            finish(status)
            return []
        case .afterKey:
            guard status.key == plan.keyNumber else { return fail("the band still reports key \(status.key), not \(plan.keyNumber)", &ids, now) }
            say("The band now has key \(status.key).")
            if plan.mode == .key { done = true; succeeded = true; return [] }
            return afterStatus(status, &ids, now)
        case .resumed:
            if closing {
                if status.state == 2 || status.state == 3 { return [self.ask(failed ? .rescue : .abort, &ids, now)] }
                finish(status)
                return []
            }
            switch status.state {
            case 2 where started:
                say("The band kept what it had. Asking where the \(items[item].name) stopped.")
                return startTransfer(&ids, now)
            case 3:
                say("The band holds a verified update. Discarding it.")
                closing = true
                return [self.ask(.abort, &ids, now)]
            case 1:
                say("The band dropped what it had. Starting again.")
                item = 0; started = false
                return afterStatus(status, &ids, now)
            case 2: return [self.ask(.reset, &ids, now)]
            default: return fail("the band says updates are unavailable now", &ids, now)
            }
        case .first, .afterReset:
            if plan.mode == .key { return afterStatus(status, &ids, now) }
            if status.running == plan.version {
                done = true
                say("The band already runs this version. Nothing to do.")
                return []
            }
            switch status.state {
            case 0: return fail("the band says updates are unavailable now", &ids, now)
            case 1: return afterStatus(status, &ids, now)
            case 2 where ask == .first, 3 where ask == .first:
                say("The band holds an earlier update. Discarding it first.")
                return [self.ask(.reset, &ids, now)]
            default: return fail("the band is still busy with an earlier update", &ids, now)
            }
        }
    }

    /// The band is idle: the key if it lacks it, then the first item.
    private func afterStatus(_ status: BandUpdateStatus, _ ids: inout UInt64, _ now: TimeInterval) -> [Data] {
        if status.key != plan.keyNumber {
            guard let key = plan.wrappedKey, !key.isEmpty else {
                return fail("the band has key \(status.key) and the package needs key \(plan.keyNumber), which was not fetched", &ids, now)
            }
            say("Installing key \(plan.keyNumber). The band has key \(status.key).")
            return [ask(.key, &ids, now)]
        }
        if plan.mode == .key {
            done = true; succeeded = true
            say("The band already has key \(plan.keyNumber).")
            return []
        }
        if items.isEmpty {
            for candidate in plan.items {
                // After a discard the band can still name the model bundle it threw away, so the
                // version it reports does not decide what is sent. A trial sends what an install would.
                if candidate.kind == 2, candidate.data.count <= Self.modelFloor {
                    say("The \(candidate.name) is not sent: the package's is a placeholder.")
                } else { items.append(candidate) }
            }
        }
        heldModel = plan.trustsHeldModel && status.model == plan.version
        return nextItem(&ids, now)
    }

    private func nextItem(_ ids: inout UInt64, _ now: TimeInterval) -> [Data] {
        guard item >= items.count else {
            if heldModel, items[item].kind == 2 {
                say("The band reports this \(items[item].name) already, so it is not sent. Asking the band to verify the one it holds.")
                touched = true
                return [ask(.verify, &ids, now)]
            }
            say("Starting the \(items[item].name), \(items[item].data.count) bytes.")
            return [ask(.start, &ids, now)]
        }
        if plan.mode == .install {
            say("Every item is verified. Asking the band to install them.")
            return [ask(.commit, &ids, now)]
        }
        say("Every item is verified. Asking the band to discard them.")
        closing = true
        return [ask(.abort, &ids, now)]
    }

    // MARK: Sending one item

    private func startTransfer(_ ids: inout UInt64, _ now: TimeInterval) -> [Data] {
        let number = UInt64(item + 1)
        let setup = PB.field(1, items[item].md5) + PB.field(2, UInt64(items[item].data.count)) + PB.field(3, 1) + PB.field(4, number)
        let (id, body) = bulk(PB.field(1, setup), &ids)
        waiting = (id, now + Self.chunkWait, .setup)
        transfer = Transfer(number: number, started: now)
        return [body]
    }

    private func chunk(_ offset: Int, _ ids: inout UInt64) -> (id: UInt64, body: Data) {
        let data = items[item].data, end = min(offset + Self.chunkSize, data.count)
        let part = Data(data[(data.startIndex + offset)..<(data.startIndex + end)])
        return bulk(PB.field(2, PB.field(1, transfer?.number ?? 0) + PB.field(2, UInt64(offset)) + PB.field(3, part)), &ids)
    }

    /// Sends new chunks while the band has room for them.
    private func fill(_ ids: inout UInt64, _ now: TimeInterval) -> [Data] {
        let size = items[item].data.count
        var out: [Data] = []
        while let current = transfer, current.pending.count < current.window, current.next < size {
            let offset = current.next
            let (id, body) = chunk(offset, &ids)
            transfer?.pending[offset] = Sent(id: id, at: now, tries: 0)
            transfer?.next = min(offset + Self.chunkSize, size)
            out.append(body)
        }
        return out
    }

    private func receiveBulk(_ fields: Fields, _ id: UInt64, _ ids: inout UInt64, _ now: TimeInterval) -> [Data] {
        guard let response = try? Fields(fields.bytes(10)) else { return [] }
        let name = item < items.count ? items[item].name : "item"
        if let (expected, _, step) = waiting, step == .setup, expected == id {
            waiting = nil
            guard let info = try? Fields(response.bytes(1)) else { return fail("the transfer setup had no answer (\(shape(response)))", &ids, now) }
            func number(_ field: Int) -> Int { Int(clamping: (try? info.integer(field, default: 0)) ?? 0) }
            let state = number(1), memory = number(2), offset = number(3), size = items[item].data.count
            say("The \(name): transfer state \(state), band memory \(memory), continuing at \(offset).")
            switch state {
            case 3:
                transfer = nil
                say("The band already has all of the \(name). Verifying.")
                return [ask(.verify, &ids, now)]
            case 1, 2:
                guard memory >= Self.chunkSize else { return fail("the band has too little memory for the \(name) (\(memory))", &ids, now) }
                guard offset <= size else { return fail("the band asked for the \(name) from \(offset), past its end", &ids, now) }
                transfer?.window = min(memory / Self.chunkSize, Self.windowLimit)
                transfer?.next = offset
                transfer?.samples = [(now, offset)]
                transfer?.shown = offset * 100 / max(size, 1) / 5 * 5
                transfer?.started = now
                if offset == size { transfer = nil; return [ask(.verify, &ids, now)] }
                return fill(&ids, now)
            default: return fail("unknown transfer state \(state) for the \(name)", &ids, now)
            }
        }
        guard let current = transfer, let offset = current.pending.first(where: { $0.value.id == id })?.key else { return [] }
        if response.values[3] != nil { return fail("the band refused a chunk of the \(name) at \(offset) (\(shape(response)))", &ids, now) }
        guard let ack = try? Fields(response.bytes(2)) else { return fail("an odd answer to the chunk of the \(name) at \(offset) (\(shape(response)))", &ids, now) }
        let acked = Int(clamping: (try? ack.integer(2, default: UInt64(offset))) ?? UInt64(offset))
        transfer?.pending[acked] = nil
        transfer?.pending[offset] = nil
        guard var next = transfer else { return [] }
        let size = items[item].data.count, sentNow = sent(next, size), percent = sentNow * 100 / max(size, 1)
        next.samples.append((now, sentNow))
        while next.samples.count > 2, let first = next.samples.first, now - first.at > 30 { next.samples.removeFirst() }
        if percent >= next.shown + 5, let first = next.samples.first {
            next.shown = percent / 5 * 5
            let rate = Double(sentNow - first.sent) / max(now - first.at, 0.001) / 1024
            say("The \(name): \(percent)% (\(String(format: "%.1f", rate)) KiB/s).")
        }
        transfer = next
        if next.pending.isEmpty, next.next >= size {
            say("The \(name) was sent in \(Int(now - next.started)) s. Verifying.")
            transfer = nil
            return [ask(.verify, &ids, now)]
        }
        return fill(&ids, now)
    }

    /// Sends late chunks again and gives up on a request the band never answered.
    func tick(ids: inout UInt64, now: TimeInterval) -> [Data] {
        guard !done, !away else { return [] }
        if let (_, deadline, step) = waiting, now >= deadline {
            waiting = nil
            if step == .commit {
                committed = true; done = true
                say("No answer to the install request. The band may be restarting. Read its status when it is back.")
                return []
            }
            if step == .rescue || (closing && failed) {
                say("No answer to the discard after the failure. Read the update status.")
                done = true
                return []
            }
            return fail("no answer from the band to a request (\(step))", &ids, now)
        }
        guard let current = transfer else { return [] }
        var out: [Data] = []
        for (offset, sent) in current.pending.sorted(by: { $0.key < $1.key }) where now - sent.at >= Self.chunkWait {
            if sent.tries >= Self.chunkTries { return fail("no answer for the chunk at \(offset) after \(sent.tries + 1) tries", &ids, now) }
            let (id, body) = chunk(offset, &ids)
            transfer?.pending[offset] = Sent(id: id, at: now, tries: sent.tries + 1)
            out.append(body)
        }
        if !out.isEmpty { say("Sent \(out.count) late chunk\(out.count == 1 ? "" : "s") again.") }
        return out
    }
}
