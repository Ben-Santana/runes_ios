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
    /// The newest package Meta offered, for the tests that follow.
    private(set) var offer: FirmwareOffer?
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
    /// version 1, which the public projects use to be offered a whole build.
    func check() {
        guard !checking, let band else { return }
        checking = true; lines = []
        task = Task { [weak self] in
            guard let self else { return }
            let meta = MetaService(), service = FirmwareService()
            defer { meta.close(); service.close(); self.checking = false; self.task = nil }
            do {
                if self.session == nil {
                    let request = try await meta.prepareLogin()
                    let callback: URL = try await withCheckedThrowingContinuation { continuation in
                        self.signIn = continuation; self.login = request
                    }
                    self.session = try await meta.finishLogin(callback, request: request)
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
                self.offer = offers.max { (Int($0.target) ?? 0) < (Int($1.target) ?? 0) }
                self.say(self.offer.map { "Newest offered: \($0.summary)." } ?? "Meta offered this band nothing.")
            } catch {
                self.login = nil
                if !Task.isCancelled, (error as? BandError)?.errorDescription != BandError.cancelled.errorDescription {
                    self.say("Could not check: \((error as? BandError)?.localizedDescription ?? "Meta could not be reached").")
                }
            }
        }
    }

    func signedIn(_ url: URL) { login = nil; signIn?.resume(returning: url); signIn = nil }
    func signInFailed() { login = nil; signIn?.resume(throwing: BandError.authentication("Meta sign-in did not finish.")); signIn = nil }
    func cancelSignIn() { login = nil; signIn?.resume(throwing: BandError.cancelled); signIn = nil }
}

/// The firmware tests on the band tests page. This one asks Meta what it offers the band and
/// shows versions. It downloads nothing and sends nothing to the band.
struct BandFirmwarePanel: View {
    @ObservedObject private var test = BandFirmwareTest.shared

    var body: some View {
        PanelGroup("Firmware update", caption: "Asks Meta which firmware it offers this band and shows the versions. You sign in on Meta's own page. Nothing is downloaded and nothing is sent to the band.") {
            ActionRow(test.checking ? "Asking Meta…" : "Check with Meta") { test.check() }
                .disabled(test.checking || !test.knowsBand)
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
                MetaLoginView(request: request, completed: test.signedIn, failed: test.signInFailed)
                    .navigationTitle("Meta sign-in").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: test.cancelSignIn) } }
            }
        }
    }

    private func lines(_ text: String) -> some View {
        Text(text).font(.code).foregroundStyle(Color.muted).textSelection(.enabled)
            .padding(.horizontal, Metric.inset).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
