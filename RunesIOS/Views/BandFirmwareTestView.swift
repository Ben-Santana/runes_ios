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
    @Published private(set) var fetching = false
    /// Whether something is being sent to the band, and how far the current item is.
    @Published private(set) var running = false
    @Published private(set) var progress: FirmwareUpdate.Progress?
    /// The key Meta wrapped for this band. It stays in memory.
    @Published private(set) var hasKey = false
    private var wrappedKey: Data? { didSet { hasKey = wrappedKey != nil } }
    /// Nothing is sent to a band whose battery is below this.
    static let batteryFloor = 50
    private var band: (serial: String, software: String)?
    private var session: MetaSession?
    private var signIn: CheckedContinuation<URL, Error>?
    private var task: Task<Void, Never>?

    var knowsBand: Bool { band != nil }

    /// The band's device information, as it arrives on connecting.
    func deviceReply(_ reply: Data) { if let identity = BandInfo.identity(reply) { band = identity } }

    private func say(_ line: String) {
        lines.append(line)
        SessionController.shared.noteFirmware(line)
    }

    /// Asks Meta what it offers this band: once as the version the band runs, and once as
    /// version 1, which the public projects use to be offered a whole build. The sign-in is the
    /// one Meta's page finishes for this app today, unless the older one is asked for.
    func check(olderSignIn: Bool = false) {
        let otherSignIn = !olderSignIn
        guard !checking, !fetching, !running, let band else { return }
        checking = true; lines = []
        task = Task { [weak self] in
            guard let self else { return }
            let meta = MetaService(), service = FirmwareService()
            defer { meta.close(); service.close(); self.checking = false; self.task = nil }
            do {
                if self.session == nil {
                    let request = try await otherSignIn ? meta.prepareWebLogin() : meta.prepareLogin()
                    SessionController.shared.noteFirmware("sign-in: started, \(otherSignIn ? "newer way" : "older way")")
                    let callback: URL = try await withCheckedThrowingContinuation { continuation in
                        self.signIn = continuation; self.login = request
                    }
                    self.session = try await otherSignIn ? meta.finishWebLogin(callback, request: request) : meta.finishLogin(callback, request: request)
                    SessionController.shared.noteFirmware("sign-in: done")
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
                            if answer.status == 401 || answer.status == 403 { self.session = nil }
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

    /// The package's bytes: the copy kept on this phone if its checksum still matches, or a download.
    private func bytes(of offer: FirmwareOffer, _ service: FirmwareService) async throws -> Data {
        guard let checksum = offer.checksum?.lowercased(), checksum.count == 64, offer.target.allSatisfy(\.isNumber) else {
            throw BandError.storage("Meta gave no checksum for this package")
        }
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Firmware", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = folder.appendingPathComponent("\(offer.target).zip")
        if let data = try? Data(contentsOf: kept), FirmwarePackage.sha256(data) == checksum {
            say("Package \(offer.target): already on this phone, and its checksum matches Meta's.")
            return data
        }
        guard let link = offer.link else { throw BandError.storage("Meta gave no link for this package") }
        say("Package \(offer.target): downloading.")
        let fetched = try await service.download(link)
        guard fetched.status == 200 else { throw BandError.transport("The download did not arrive (HTTP \(fetched.status))") }
        guard FirmwarePackage.sha256(fetched.data) == checksum else { throw BandError.storage("The download's checksum does not match Meta's (\(fetched.data.count) bytes)") }
        try fetched.data.write(to: kept, options: .atomic)
        say("Package \(offer.target): downloaded, \(fetched.data.count) bytes, and its checksum matches Meta's.")
        return fetched.data
    }

    /// Gets one offered package onto this phone, checks every item in it, and asks Meta for
    /// the key the band needs to read it. Nothing is sent to the band.
    func fetch(_ offer: FirmwareOffer) {
        guard !checking, !fetching, !running, let band else { return }
        fetching = true
        task = Task { [weak self] in
            guard let self else { return }
            let service = FirmwareService()
            defer { service.close(); self.fetching = false; self.task = nil }
            do {
                let zip = try await self.bytes(of: offer, service)
                let package = try await Task.detached { try FirmwarePackage.read(zip) }.value
                guard String(package.version) == offer.target else { throw BandError.storage("The package holds version \(package.version), not the \(offer.target) Meta offered") }
                self.package = package; self.wrappedKey = nil
                self.say("Package checked: \(package.summary).")
                guard let token = self.session?.accessToken else {
                    self.say("Not signed in, so the band's key was not asked for. Check with Meta, then get the package again.")
                    return
                }
                for host in FirmwareService.hosts {
                    for asMetaApp in [false, true] {
                        let answer = try await service.key(Int(package.keyNumber), host: host, serial: band.serial, token: token, asMetaApp: asMetaApp)
                        if let key = answer.key {
                            self.wrappedKey = key
                            self.say("Key \(package.keyNumber) for this band: received, \(key.count) bytes, still wrapped.")
                            return
                        }
                        if answer.status == 401 || answer.status == 403 { self.session = nil }
                        self.say("Key \(package.keyNumber) from \(host.prefix(while: { $0 != "." }))\(asMetaApp ? ", asked as the Meta app" : ""): not given (HTTP \(answer.status)).")
                    }
                }
            } catch {
                if !Task.isCancelled { self.say("Could not get the package: \(self.reason(error)).") }
            }
        }
    }

    /// Sends a key install, a trial transfer or a discard to the band. The band must be
    /// connected and charged past the floor, and the page asks the person first.
    func start(_ mode: FirmwareUpdate.Mode) {
        guard !checking, !fetching, !running else { return }
        let controller = SessionController.shared
        guard controller.snapshot.state == .streaming else { return say("Not started: the band is not connected.") }
        guard let level = controller.snapshot.battery else { return say("Not started: the band's battery level is not known yet.") }
        guard level >= Self.batteryFloor else { return say("Not started: the band's battery is at \(level)%. Charge it past \(Self.batteryFloor)%.") }
        let plan: FirmwareUpdate.Plan
        if mode == .cancel { plan = FirmwareUpdate.Plan(version: 0, items: [], keyNumber: 0, wrappedKey: nil, mode: .cancel) }
        else if let package { plan = package.plan(mode, wrappedKey: wrappedKey) }
        else { return }
        running = true; progress = nil
        // The phone must not lock part way: iOS would stop the app between the band's pulses.
        UIApplication.shared.isIdleTimerDisabled = true
        say("Band battery \(level)%.")
        controller.startUpdate(plan)
    }

    func stop() { if running { SessionController.shared.stopUpdate() } }

    /// What the update wrote, already in the journal, and whether it has ended.
    func updateHeard(_ new: [String], _ progress: FirmwareUpdate.Progress?, _ ended: Bool?) {
        lines += new; self.progress = progress
        guard ended != nil else { return }
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
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

    private var busy: Bool { test.checking || test.fetching || test.running }
    private var connected: Bool { controller.snapshot.state == .streaming }

    var body: some View {
        PanelGroup("Firmware update", caption: "Asks Meta which firmware it offers this band, on Meta's own sign-in page, and gets a package onto this phone. The key and trial rows send to the band and ask first. A trial ends with the band discarding everything. Nothing here installs firmware.") {
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
            if let package = test.package {
                Rule()
                ActionRow("Install key \(package.keyNumber) on the band") { asking = .key }
                    .disabled(busy || !connected || !test.hasKey)
                Rule()
                ActionRow("Trial transfer of version \(package.version)") { asking = .trial }
                    .disabled(busy || !connected)
            }
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
            if !test.knowsBand {
                Rule()
                lines("Connect the band first, so it can say which band it is.")
            }
            if !test.lines.isEmpty {
                Rule()
                lines(test.lines.joined(separator: "\n"))
            }
        }
        .sheet(item: $test.login, onDismiss: test.cancelSignIn) { request in
            NavigationStack {
                MetaLoginView(request: request, completed: test.signedIn, failed: test.signInFailed, trace: { SessionController.shared.noteFirmware($0) })
                    .navigationTitle("Meta sign-in").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: test.cancelSignIn) } }
            }
        }
        .confirmationDialog(question, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), titleVisibility: .visible, presenting: asking) { mode in
            Button(mode == .key ? "Install the key" : mode == .trial ? "Start the trial" : "Discard", role: mode == .key ? .destructive : nil) { test.start(mode) }
            Button("Cancel", role: .cancel) {}
        } message: { mode in
            Text(detail(mode))
        }
    }

    private var question: String {
        switch asking {
        case .key: return "Install key \(test.package?.keyNumber ?? 0) on the band?"
        case .trial: return "Send version \(test.package?.version ?? 0) to the band as a trial?"
        default: return "Have the band discard an update it holds?"
        }
    }

    private func detail(_ mode: FirmwareUpdate.Mode) -> String {
        let floor = BandFirmwareTest.batteryFloor
        switch mode {
        case .key: return "This cannot be undone. The band keeps the key, and nothing else on it changes. Put the band on its charger first. Its battery must be at \(floor)% or more."
        case .trial: return "The band receives the firmware and checks it, then discards it. Nothing is installed. If the band lacks the key it is installed first, and that cannot be undone. Put the band on its charger and keep this screen open. It can take 20 minutes."
        case .cancel: return "This clears a transfer that was cut off. The firmware the band runs is not touched."
        }
    }

    private func lines(_ text: String) -> some View {
        Text(text).font(.code).foregroundStyle(Color.muted).textSelection(.enabled)
            .padding(.horizontal, Metric.inset).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
