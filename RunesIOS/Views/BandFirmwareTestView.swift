import SwiftUI

/// What the firmware tests have found so far, kept while the app runs. The Meta sign-in and
/// the band's serial number stay in memory here and are never written anywhere.
@MainActor
final class BandFirmwareTest: ObservableObject {
    static let shared = BandFirmwareTest()

    @Published private(set) var lines: [String] = []
    @Published private(set) var checking = false
    /// The sign-in page to show, while a check waits for it.
    @Published var login: MetaLoginRequest?
    /// The packages Meta offered, lowest build first.
    @Published private(set) var offers: [FirmwareOffer] = []
    /// The package that was fetched and checked against its own list.
    @Published private(set) var package: FirmwarePackage?
    /// What to call that package on the page: Meta's build number when it gave one.
    @Published private(set) var packageName = ""
    @Published private(set) var fetching = false
    /// Whether something is being sent to the band, and how far the current item is.
    @Published private(set) var running = false
    @Published private(set) var progress: FirmwareUpdate.Progress?
    /// The version an install was asked for, until the band is seen running it.
    @Published private(set) var awaiting: UInt64?
    @Published private(set) var verifying = false
    /// The whole update from one tap is under way.
    @Published private(set) var updating = false
    private var ended: CheckedContinuation<FirmwareUpdate.Ending, Never>?
    /// The build the one tap update installs, and the one it goes on to if the band will not
    /// take the first one's models: the band reports holding that one's since a trial.
    static let firstChoice = "1003366292", secondChoice = "1075365371"
    /// The key Meta wrapped for this band. It stays in memory.
    @Published private(set) var hasKey = false
    private var wrappedKey: Data? { didSet { hasKey = wrappedKey != nil } }
    /// Packages already on this phone, each with the checksum Meta gave when it was fetched.
    struct Kept: Equatable { let target: String; let build: String?; let checksum: String }
    @Published private(set) var kept: [Kept] = []
    /// Nothing is sent to a band whose battery is below this.
    static let batteryFloor = 50
    private var band: (serial: String, software: String)?
    /// The Meta sign-in, kept in the Keychain so a restart does not ask again.
    private var session: MetaSession? = FirmwareSignIn.load() { didSet { signedInNow = session != nil } }
    @Published private(set) var signedInNow = FirmwareSignIn.load() != nil
    private var signIn: CheckedContinuation<URL, Error>?
    private var task: Task<Void, Never>?

    var knowsBand: Bool { band != nil }

    /// The band's device information, as it arrives on connecting.
    func deviceReply(_ reply: Data) {
        guard let identity = BandInfo.identity(reply) else { return }
        band = identity
        guard let awaiting else { return }
        if identity.software == String(awaiting) {
            self.awaiting = nil
            say("The band is back and says it runs \(identity.software), the new version.")
        } else { say("The band is back and says it runs \(identity.software), not \(awaiting) yet.") }
    }

    private func say(_ line: String) {
        lines.append(line)
        SessionController.shared.noteFirmware(line)
    }

    /// Asks Meta what it offers this band: once as the version the band runs, and once as
    /// version 1, which the public projects use to be offered a whole build. The sign-in is the
    /// one Meta's page finishes for this app today, unless the older one is asked for.
    func check(olderSignIn: Bool = false) {
        guard !busy, band != nil else { return }
        lines = []
        task = Task { [weak self] in await self?.askMeta(older: olderSignIn) }
    }

    private var busy: Bool { checking || fetching || running || verifying || updating }

    private func askMeta(older olderSignIn: Bool) async {
        let otherSignIn = !olderSignIn
        guard !checking, let band else { return }
        checking = true
        do {
            let meta = MetaService(), service = FirmwareService()
            defer { meta.close(); service.close(); self.checking = false }
            do {
                if self.session == nil {
                    let request = try await otherSignIn ? meta.prepareWebLogin() : meta.prepareLogin()
                    SessionController.shared.noteFirmware("sign-in: started, \(otherSignIn ? "newer way" : "older way")")
                    let callback: URL = try await withCheckedThrowingContinuation { continuation in
                        self.signIn = continuation; self.login = request
                    }
                    self.session = try await otherSignIn ? meta.finishWebLogin(callback, request: request) : meta.finishLogin(callback, request: request)
                    if let session = self.session { FirmwareSignIn.save(session) }
                    SessionController.shared.noteFirmware("sign-in: done, and kept on this phone")
                }
                guard let token = self.session?.accessToken else { return }
                self.say("Band runs \(band.software).")
                var offers: [FirmwareOffer] = []
                for version in [band.software, "1"] {
                    for host in FirmwareService.hosts {
                        for question in FirmwareOffer.Question.allCases {
                            try Task.checkCancellation()
                            let asked = "\(host.prefix(while: { $0 != "." })) \(question.name) as \(version)"
                            var answer = try await service.ask(question, host: host, serial: band.serial, version: version, token: token, asMetaApp: false)
                            var note = ""
                            if answer.status != 200 {
                                answer = try await service.ask(question, host: host, serial: band.serial, version: version, token: token, asMetaApp: true)
                                note = answer.status == 200 ? " (answered only when asked as the Meta app)" : ""
                            }
                            // A sign-in Meta no longer accepts is asked for again on the next check.
                            // Meta's code 190 is how it says a sign-in has ended.
                            var ended = answer.status == 401 || answer.status == 403
                            if case .refused(let codes) = answer.reply, codes.contains("code 190") { ended = true }
                            if ended, self.session != nil { self.forgetSignIn(); self.say("Meta no longer accepts the kept sign-in. Check again to sign in.") }
                            switch answer.reply {
                            case .offer(let offer):
                                if !offers.contains(offer) { offers.append(offer) }
                                self.say("\(asked): \(offer.summary)\(note)")
                            case .nothing: self.say("\(asked): nothing offered (HTTP \(answer.status))\(note)")
                            case .refused(let codes): self.say("\(asked): refused (HTTP \(answer.status)\(codes.isEmpty ? "" : ", \(codes)"))")
                            case .unreadable: self.say("\(asked): no readable answer (HTTP \(answer.status))")
                            }
                        }
                    }
                }
                var distinct: [FirmwareOffer] = []
                for offer in offers where !distinct.contains(where: { $0.target == offer.target }) { distinct.append(offer) }
                self.offers = distinct.sorted { (UInt64($0.target) ?? 0) < (UInt64($1.target) ?? 0) }
                self.say(self.offers.isEmpty ? "Meta offered this band nothing." : "Offered: \(self.offers.map { $0.build.map { "build \($0)" } ?? $0.target }.joined(separator: ", ")).")
            } catch {
                self.login = nil
                if !Task.isCancelled, (error as? BandError)?.errorDescription != BandError.cancelled.errorDescription {
                    self.say("Could not check: \((error as? BandError)?.localizedDescription ?? "Meta could not be reached").")
                }
            }
        }
    }

    private func reason(_ error: Error) -> String { (error as? BandError)?.localizedDescription ?? "Meta could not be reached" }

    private func folder() throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Firmware", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Finds the packages kept on this phone, so a trial after a restart needs no sign-in.
    func findKept() {
        guard let folder = try? folder(), let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        kept = files.filter { $0.pathExtension == "json" }.compactMap { file -> Kept? in
            let target = file.deletingPathExtension().lastPathComponent
            guard target.allSatisfy(\.isNumber), let note = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: String],
                  let checksum = note["checksum"], FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(target).zip").path) else { return nil }
            return Kept(target: target, build: note["build"], checksum: checksum)
        }.sorted { (UInt64($0.target) ?? 0) < (UInt64($1.target) ?? 0) }
    }

    /// Loads a package kept on this phone and checks it again. Nothing is asked of Meta, so
    /// the band's key is not in memory afterwards, and a band that lacks it is told nothing.
    func use(_ kept: Kept) {
        guard !busy else { return }
        task = Task { [weak self] in _ = await self?.loadKept(kept) }
    }

    @discardableResult
    private func loadKept(_ kept: Kept) async -> Bool {
        guard !fetching else { return false }
        fetching = true
        do {
            defer { self.fetching = false }
            do {
                let file = try self.folder().appendingPathComponent("\(kept.target).zip")
                let package = try await Task.detached { () throws -> FirmwarePackage in
                    let zip = try Data(contentsOf: file)
                    guard FirmwarePackage.sha256(zip) == kept.checksum else { throw BandError.storage("The kept package no longer matches its checksum") }
                    return try FirmwarePackage.read(zip)
                }.value
                guard String(package.version) == kept.target else { throw BandError.storage("The kept package holds another version") }
                self.package = package; self.wrappedKey = nil
                self.packageName = kept.build.map { "build \($0)" } ?? "version \(package.version)"
                self.say("Package checked from this phone: \(self.packageName), \(package.summary).")
                self.say("The band's key is not in memory. That is fine if the band already has key \(package.keyNumber).")
                return true
            } catch { self.say("Could not use the kept package: \(self.reason(error))."); return false }
        }
    }

    /// The package's bytes: the copy kept on this phone if its checksum still matches, or a download.
    private func bytes(of offer: FirmwareOffer, _ service: FirmwareService) async throws -> Data {
        guard let checksum = offer.checksum?.lowercased(), checksum.count == 64, offer.target.allSatisfy(\.isNumber) else {
            throw BandError.storage("Meta gave no checksum for this package")
        }
        let folder = try folder()
        let kept = folder.appendingPathComponent("\(offer.target).zip")
        // The checksum is kept beside the package, so it can be checked again without asking Meta.
        func note() {
            var fields = ["checksum": checksum]
            if let build = offer.build { fields["build"] = build }
            try? JSONSerialization.data(withJSONObject: fields).write(to: folder.appendingPathComponent("\(offer.target).json"), options: .atomic)
            findKept()
        }
        if let data = try? Data(contentsOf: kept), FirmwarePackage.sha256(data) == checksum {
            say("Package \(offer.target): already on this phone, and its checksum matches Meta's.")
            note()
            return data
        }
        guard let link = offer.link else { throw BandError.storage("Meta gave no link for this package") }
        say("Package \(offer.target): downloading.")
        let fetched = try await service.download(link)
        guard fetched.status == 200 else { throw BandError.transport("The download did not arrive (HTTP \(fetched.status))") }
        guard FirmwarePackage.sha256(fetched.data) == checksum else { throw BandError.storage("The download's checksum does not match Meta's (\(fetched.data.count) bytes)") }
        try fetched.data.write(to: kept, options: .atomic)
        note()
        say("Package \(offer.target): downloaded, \(fetched.data.count) bytes, and its checksum matches Meta's.")
        return fetched.data
    }

    /// Gets one offered package onto this phone, checks every item in it, and asks Meta for
    /// the key the band needs to read it. Nothing is sent to the band.
    func fetch(_ offer: FirmwareOffer) {
        guard !busy, band != nil else { return }
        task = Task { [weak self] in _ = await self?.loadOffer(offer) }
    }

    @discardableResult
    private func loadOffer(_ offer: FirmwareOffer) async -> Bool {
        guard !fetching, let band else { return false }
        fetching = true
        do {
            let service = FirmwareService()
            defer { service.close(); self.fetching = false }
            do {
                let zip = try await self.bytes(of: offer, service)
                let package = try await Task.detached { try FirmwarePackage.read(zip) }.value
                guard String(package.version) == offer.target else { throw BandError.storage("The package holds version \(package.version), not the \(offer.target) Meta offered") }
                self.package = package; self.wrappedKey = nil
                self.packageName = offer.build.map { "build \($0)" } ?? "version \(package.version)"
                self.say("Package checked: \(self.packageName), \(package.summary).")
                guard let token = self.session?.accessToken else {
                    self.say("Not signed in, so the band's key was not asked for. Check with Meta, then get the package again.")
                    return true
                }
                for host in FirmwareService.hosts {
                    for asMetaApp in [false, true] {
                        let answer = try await service.key(Int(package.keyNumber), host: host, serial: band.serial, token: token, asMetaApp: asMetaApp)
                        if let key = answer.key {
                            self.wrappedKey = key
                            self.say("Key \(package.keyNumber) for this band: received, \(key.count) bytes, still wrapped.")
                            return true
                        }
                        if answer.status == 401 || answer.status == 403 { self.forgetSignIn() }
                        self.say("Key \(package.keyNumber) from \(host.prefix(while: { $0 != "." }))\(asMetaApp ? ", asked as the Meta app" : ""): not given (HTTP \(answer.status)).")
                    }
                }
                return true
            } catch {
                if !Task.isCancelled { self.say("Could not get the package: \(self.reason(error)).") }
                return false
            }
        }
    }

    /// Sends a key install, a trial transfer, a discard or an install to the band. The band
    /// must be connected and charged past the floor, and the page asks the person first.
    func start(_ mode: FirmwareUpdate.Mode) {
        guard !busy else { return }
        let plan: FirmwareUpdate.Plan
        if mode == .cancel { plan = FirmwareUpdate.Plan(version: 0, items: [], keyNumber: 0, wrappedKey: nil, mode: .cancel) }
        else if let package { plan = package.plan(mode, wrappedKey: wrappedKey) }
        else { return }
        task = Task { [weak self] in _ = await self?.send(plan) }
    }

    /// Runs one plan on the band and waits for it to end.
    private func send(_ plan: FirmwareUpdate.Plan) async -> FirmwareUpdate.Ending {
        let controller = SessionController.shared
        guard !running else { return .failed }
        guard controller.snapshot.state == .streaming else { say("Not started: the band is not connected."); return .failed }
        guard let level = controller.snapshot.battery else { say("Not started: the band's battery level is not known yet."); return .failed }
        guard level >= Self.batteryFloor else { say("Not started: the band's battery is at \(level)%. Charge it past \(Self.batteryFloor)%."); return .failed }
        running = true; progress = nil
        // The phone must not lock part way: iOS would stop the app between the band's pulses.
        UIApplication.shared.isIdleTimerDisabled = true
        say(plan.mode == .cancel ? "Band battery \(level)%." : "Band battery \(level)%. Using \(packageName).")
        return await withCheckedContinuation { continuation in
            ended = continuation
            controller.startUpdate(plan)
        }
    }

    /// Makes one build ready on this phone: the kept copy if there is one, or Meta's.
    private func ready(_ target: String) async -> (package: FirmwarePackage, name: String, key: Data?)? {
        findKept()
        if let kept = kept.first(where: { $0.target == target }), await loadKept(kept), let package { return (package, packageName, wrappedKey) }
        if !offers.contains(where: { $0.target == target }) { await askMeta(older: false) }
        guard let offer = offers.first(where: { $0.target == target }), await loadOffer(offer), let package else { return nil }
        return (package, packageName, wrappedKey)
    }

    /// The whole update from one tap, after the page has asked once: both builds made ready,
    /// the first installed, the second if the band will not take the first one's models, the
    /// wait for the band to restart, and the checklist. It stops at the first thing that is
    /// not as expected, and before the install is asked for that always leaves the band as it was.
    func updateBand() {
        guard !busy, band != nil else { return }
        updating = true; lines = []
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.updating = false }
            await self.update()
        }
    }

    private func update() async {
        let controller = SessionController.shared
        say("Update: build 64 first. If the band will not take its models, build 72 as the Meta app would install it.")
        guard let first = await ready(Self.firstChoice) else {
            return say("Update: stopped. Build 64 could not be made ready, and nothing was sent to the band.")
        }
        // The second build is made ready before anything is sent, so a refusal can be followed at once.
        let second = await ready(Self.secondChoice)
        if second == nil { say("Update: build 72 could not be made ready, so there is nothing to go on to if build 64 is refused.") }
        package = first.package; packageName = first.name; wrappedKey = first.key
        var ending = await send(first.package.plan(.install, wrappedKey: first.key))
        if ending == .modelRefused, let second {
            say("Update: the band will not take \(first.name)'s models. Going on with \(second.name), whose models it reports holding.")
            try? await Task.sleep(for: .seconds(3))
            package = second.package; packageName = second.name; wrappedKey = second.key
            var plan = second.package.plan(.install, wrappedKey: second.key)
            plan.trustsHeldModel = true
            ending = await send(plan)
        }
        guard ending == .installing else {
            return say("Update: stopped before the install was asked for. Nothing was installed, and the band runs what it ran before.")
        }
        let back = await wait(900) { self.awaiting == nil && controller.snapshot.state == .streaming ? true : nil }
        if back == nil {
            say(controller.snapshot.state == .streaming
                ? "Update: the band is connected and says it runs \(band?.software ?? "an unknown version"), not the new one."
                : "Update: the band has not connected again in 15 minutes. The journal's connection and protocol lines say how far it gets.")
        }
        guard controller.snapshot.state == .streaming else { return }
        try? await Task.sleep(for: .seconds(3))
        await checklist()
        say("Update: finished. The lines above are the band's answers on the firmware it runs now.")
    }

    /// Removes the kept Meta sign-in from this phone.
    func forgetSignIn() { session = nil; FirmwareSignIn.clear() }

    func stop() { if running { SessionController.shared.stopUpdate() } }

    /// What the update wrote, already in the journal, and whether it has ended.
    func updateHeard(_ new: [String], _ progress: FirmwareUpdate.Progress?, _ ending: FirmwareUpdate.Ending?) {
        lines += new; self.progress = progress
        guard let ending else { return }
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        if ending == .installing, let package {
            awaiting = package.version
            say("Waiting for the band to restart and connect again. Keep the app open. This can take a few minutes.")
        }
        ended?.resume(returning: ending); ended = nil
    }

    /// Asks the band the things the app relies on and writes down each answer: its version,
    /// its update status, the wrist setting, a vibration, the named settings and a gesture.
    /// It is the same before an update and after one, so the two can be compared.
    func runChecklist() {
        guard !busy else { return }
        task = Task { [weak self] in await self?.checklist() }
    }

    private func checklist() async {
        guard !verifying else { return }
        verifying = true
        do {
            defer { self.verifying = false }
            let controller = SessionController.shared
            @MainActor func note(_ line: String) { self.say("Checklist: \(line)") }
            guard controller.snapshot.state == .streaming else {
                return note("the band is not connected. The journal's connection and protocol lines say how far it got.")
            }
            note("connected and receiving.")
            note(self.band.map { "the band says it runs \($0.software)." } ?? "no device information was read.")
            let heard = BandTests.shared.trials.count
            controller.readFirmwareStatus()
            let status = await self.wait(6) { BandTests.shared.trials.dropFirst(heard).last { $0.hasPrefix("firmware: ") } }
            note(status.map { "update status, \($0.dropFirst(10))." } ?? "no answer to the update status.")
            note(controller.snapshot.hand.map { "the wrist setting reads \($0.rawValue)." } ?? "the wrist setting has not been read.")
            let answered = VibrationLab.shared.answers.count
            controller.vibrate([BandPulse(duration: 150, amplitude: 230)])
            let pulse = await self.wait(6) { VibrationLab.shared.answers.count > answered ? VibrationLab.shared.answers.last : nil }
            note(pulse.map { "a vibration was \($0.result.rawValue) in \(Int($0.latency * 1000)) ms." } ?? "no answer to a vibration.")
            BandTests.shared.startReading(); controller.readNamedSettings()
            let read = await self.wait(40) { BandTests.shared.busy ? nil : BandTests.shared.named.count }
            if read == nil { BandTests.shared.interrupted() }
            note(read.map { "named settings read, \($0) of them." } ?? "the named settings did not finish reading.")
            let total = controller.snapshot.gestureTotal
            note("tap a finger and thumb together now.")
            let gesture = await self.wait(20) { controller.snapshot.gestureTotal > total ? true : nil }
            note(gesture == nil ? "no gesture arrived in 20 seconds." : "a gesture arrived.")
        }
    }

    private func wait<T>(_ seconds: Double, for value: () -> T?) async -> T? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !Task.isCancelled {
            if let found = value() { return found }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return value()
    }

    func signedIn(_ url: URL) { login = nil; signIn?.resume(returning: url); signIn = nil }
    func signInFailed() { login = nil; signIn?.resume(throwing: BandError.authentication("Meta sign-in did not finish.")); signIn = nil }
    func cancelSignIn() { login = nil; signIn?.resume(throwing: BandError.cancelled); signIn = nil }
}

/// The firmware tests on the band tests page. Asking Meta and getting a package send nothing
/// to the band. The rows that do send something each ask first.
struct BandFirmwarePanel: View {
    @ObservedObject private var test = BandFirmwareTest.shared
    @ObservedObject private var controller = SessionController.shared
    @State private var asking: FirmwareUpdate.Mode?
    @State private var confirmUpdate = false

    private var busy: Bool { test.checking || test.fetching || test.running || test.verifying || test.updating }
    private var connected: Bool { controller.snapshot.state == .streaming }

    var body: some View {
        PanelGroup("Firmware update", caption: "Asks Meta which firmware it offers this band, on Meta's own sign-in page, and gets a package onto this phone. The key, trial and install rows send to the band and ask first. A trial ends with the band discarding everything. An install cannot be undone.") {
            ActionRow(test.updating ? "Updating the band…" : "Update the band") { confirmUpdate = true }
                .disabled(busy || !connected || !test.knowsBand)
            Rule()
            ActionRow(test.checking ? "Asking Meta…" : "Check with Meta") { test.check() }
                .disabled(busy || !test.knowsBand)
            Rule()
            ActionRow("Check with Meta, signing in the older way") { test.check(olderSignIn: true) }
                .disabled(busy || !test.knowsBand)
            ForEach(test.offers, id: \.target) { offer in
                Rule()
                ActionRow(test.fetching ? "Getting the package…" : "Get \(offer.build.map { "build \($0)" } ?? "version \(offer.target)")") { test.fetch(offer) }
                    .disabled(busy)
            }
            // A kept package that Meta also offers just now is fetched from its own row, which gets the key too.
            ForEach(test.kept.filter { kept in !test.offers.contains { $0.target == kept.target } && test.package.map { String($0.version) != kept.target } ?? true }, id: \.target) { kept in
                Rule()
                ActionRow("Use \(kept.build.map { "build \($0)" } ?? "version \(kept.target)") kept on this phone") { test.use(kept) }
                    .disabled(busy)
            }
            if let package = test.package {
                Rule()
                ActionRow("Install key \(package.keyNumber) on the band, for \(test.packageName)") { asking = .key }
                    .disabled(busy || !connected || !test.hasKey)
                Rule()
                ActionRow("Trial transfer of \(test.packageName)") { asking = .trial }
                    .disabled(busy || !connected)
                Rule()
                ActionRow("Install \(test.packageName) on the band") { asking = .install }
                    .disabled(busy || !connected)
            }
            Rule()
            ActionRow(test.verifying ? "Running the checklist…" : "Run the band checklist") { test.runChecklist() }
                .disabled(busy || !connected)
            Rule()
            if test.running {
                ActionRow("Stop") { test.stop() }
                if let progress = test.progress {
                    Rule()
                    lines("\(progress.name): \(progress.stage), \(progress.sent * 100 / max(progress.size, 1))% of \(progress.size / 1024) KB")
                }
            } else {
                ActionRow("Have the band discard an update it holds") { asking = .cancel }
                    .disabled(busy || !connected)
            }
            if test.signedInNow {
                Rule()
                ActionRow("Forget the Meta sign-in kept on this phone") { test.forgetSignIn() }
                    .disabled(busy)
            }
            if !test.knowsBand {
                Rule()
                lines("Connect the band first, so it can say which band it is.")
            }
            if !test.lines.isEmpty {
                Rule()
                lines(test.lines.joined(separator: "\n"))
            }
        }
        .onAppear(perform: test.findKept)
        .sheet(item: $test.login, onDismiss: test.cancelSignIn) { request in
            NavigationStack {
                MetaLoginView(request: request, completed: test.signedIn, failed: test.signInFailed, trace: { SessionController.shared.noteFirmware($0) })
                    .navigationTitle("Meta sign-in").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: test.cancelSignIn) } }
            }
        }
        .confirmationDialog("Update the band? This cannot be undone.", isPresented: $confirmUpdate, titleVisibility: .visible) {
            Button("Update, this cannot be undone", role: .destructive) { test.updateBand() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runes installs build 64. If the band will not take that build's models, it installs build 72 with the models the band already holds, as the Meta app would, and only if the band confirms them. The band restarts into the new firmware and can never go back to the old one. Other apps that talk to the band directly may stop working with it. Its battery must be at \(BandFirmwareTest.batteryFloor)% or more. Keep this screen open. It takes 10 to 20 minutes, then Runes checks the band by itself.")
        }
        .confirmationDialog(question, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), titleVisibility: .visible, presenting: asking) { mode in
            Button(button(mode), role: mode == .key || mode == .install ? .destructive : nil) { test.start(mode) }
            Button("Cancel", role: .cancel) {}
        } message: { mode in
            Text(detail(mode))
        }
    }

    private var question: String {
        switch asking {
        case .key: return "Install key \(test.package?.keyNumber ?? 0) on the band?"
        case .trial: return "Send \(test.packageName) to the band as a trial?"
        case .install: return "Install \(test.packageName) on the band? This cannot be undone."
        default: return "Have the band discard an update it holds?"
        }
    }

    private func button(_ mode: FirmwareUpdate.Mode) -> String {
        switch mode {
        case .key: return "Install the key"
        case .trial: return "Start the trial"
        case .cancel: return "Discard"
        case .install: return "Install, this cannot be undone"
        }
    }

    private func detail(_ mode: FirmwareUpdate.Mode) -> String {
        let floor = BandFirmwareTest.batteryFloor
        switch mode {
        case .key: return "This cannot be undone. The band keeps the key, and nothing else on it changes. Put the band on its charger first. Its battery must be at \(floor)% or more."
        case .trial: return "The band receives the firmware and checks it, then discards it. Nothing is installed. If the band lacks the key it is installed first, and that cannot be undone. Put the band on its charger and keep this screen open. It takes about 10 minutes."
        case .cancel: return "This clears a transfer that was cut off. The firmware the band runs is not touched."
        case .install: return "The band restarts into the new firmware and can never go back to the old one. Other apps that talk to the band directly may stop working with it. If the band refuses the model bundle as older than the one it holds, it is sent with the version check skipped, which nobody has tried. Put the band on its charger first, with \(floor)% or more, and keep this screen open. It takes about 10 minutes, then the band restarts."
        }
    }

    private func lines(_ text: String) -> some View {
        Text(text).font(.code).foregroundStyle(Color.muted).textSelection(.enabled)
            .padding(.horizontal, Metric.inset).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
