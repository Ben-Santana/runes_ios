import Foundation
import OSLog
import CryptoKit

/// Owned by the app; every method and callback below runs on transport.perform.
final class SessionCore: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.runes.ios", category: "BandConnection")
    let transport = BandTransport()
    var onSnapshot: ((SessionSnapshot) -> Void)?
    var onRelayEvent: ((RelayWire.Event) -> Void)?
    var onRelayReady: ((RelayWire.Demand?) -> Void)?
    private var relayDemand = RelayWire.Demand.idle
    private var pendingStreams: RelayWire.Demand?
    private var activeStreams: RelayWire.Demand?
    /// Motion streams the phone itself needs (combos with rotation or movement steps).
    private var localMotion = false
    /// EMG is only requested while a workout's raw data is recording.
    private var localEMG = false
    /// Per connection: the EMG layout was read and validated.
    private var emgReady = false
    private var emgReading = false
    private var activeEMG = false
    private var pendingEMG: Bool?
    /// Why EMG is off until the next recording asks again.
    private var emgBlocked: String?
    /// An unexpected EMG failure dropped the link once; never ask again this app run.
    private var emgHardBlocked = false
    /// Every raw band sample (gyro, orientation, EMG, gesture) while streaming, for the Motion Lab.
    var onRaw: ((RawSample) -> Void)?
    var onEMGStatus: ((String) -> Void)?
    /// Each played pulse's answer from the band, with seconds from send to answer.
    var onPulse: ((WristFeedbackResult, TimeInterval) -> Void)?
    /// Every vibration request that went out to the band, as it is sent.
    var onPulseSent: ((BandPulse) -> Void)?
    /// The band's settings as it last reported them (`BandSettings`).
    var onSettings: ((String) -> Void)?
    /// The band's answer to one of its own patterns, with the reply's shape.
    var onPattern: ((UInt64, WristFeedbackResult, String) -> Void)?
    /// What the band said about its software when it connected (`BandInfo`).
    var onInfo: ((String) -> Void)?
    /// The whole device information reply, for the firmware check. It holds the serial number, so it is never logged.
    var onDeviceReply: ((Data) -> Void)?
    /// What a band test heard back, as a line for the tests page.
    var onTrial: ((String) -> Void)?
    /// The band's handwriting as it is read: whether it is on, the text so far, and how many
    /// rows of scores have arrived. The text is what the person wrote, so it is never journalled.
    var onWriting: ((Bool, String, Int) -> Void)?
    private var writingWanted = false, activeWriting = false
    private var pendingWriting: Bool?
    private var writing = BandWriting.Decoder()
    private var writingMessages = 0
    /// The band's standby time as it last reported it, to put back after handwriting turned it off.
    private var standby: UInt64?
    /// How many scores the band's messages carry and from which model, noted when either changes.
    private var writingShape = ""
    /// Counts each time handwriting is turned on, so a late check belongs to one try.
    private var writingTry = 0
    /// The named settings as last read, by name, and writes still to make, one at a time.
    private var settingsByName: [String: NamedSettings.Setting] = [:]
    private var settingQueue: [(name: String, value: UInt64)] = []
    private var afterSettings: ((Bool) -> Void)?
    /// What to do once a read of the named settings that a test asked for is done.
    private var afterSettingsRead: (() -> Void)?
    /// A line about which gesture model the band runs, whether the trial model is asked for,
    /// and how many gesture messages came from the usual model and from the trial one since.
    var onModel: ((String?, Bool, Int, Int) -> Void)?
    private var trialModelWanted = false
    private var modelGestures = (usual: 0, trial: 0)
    /// What a firmware update wrote, how far its current item is, and once it has ended, how it went.
    var onUpdate: (([String], FirmwareUpdate.Progress?, FirmwareUpdate.Ending?) -> Void)?
    private var update: FirmwareUpdate?
    private var updateShown: FirmwareUpdate.Progress?
    /// A clock for the update's timeouts that stands still while the app is suspended, so a
    /// pause in the background is not taken for a silent band.
    private var updateClock: TimeInterval = 0, updateSeen: TimeInterval = 0
    /// Whether each gesture is acknowledged to the band, as the Meta app does. Off unless a test turns it on.
    var acknowledgesGestures = false { didSet { acknowledgementNoted = false } }
    private var acknowledgementNoted = false
    /// Each named setting as it is read or written back, with a line saying so. A line alone is a
    /// note, and an empty one ends a read.
    var onNamedSetting: ((NamedSettings.Setting?, String) -> Void)?
    /// How the band describes each named setting, as the list is read.
    var onCapability: ((NamedSettings.Setting, BandCapability) -> Void)?
    /// Each line of the band tightness test: what was asked, the answer, and every other message
    /// the band sent while the test listened. An empty line ends it.
    var onTightness: ((String) -> Void)?
    /// Orientation and gyroscope samples, whether they were started for the Mac or for this phone.
    var onMotion: ((RelayWire.Event.Kind, [Double]) -> Void)?
    var onGesture: ((GestureEvent) -> Void)?
    /// One call per physical gesture (plus the end of a hold); drives haptics and animation.
    var onBandGesture: ((BandGesture) -> Void)?
    private var interpreter = GestureInterpreter()
    var onOwnership: ((OwnershipStep, MetaSession, UUID) -> Void)?
    /// Asks the app to hold background execution while a timed retry is waiting.
    var onRetryWait: ((Bool) -> Void)?
    private var snapshot = SessionSnapshot()
    private let identities = IdentityStore()
    private var journal: EventJournal?
    private var proto: BandProtocol?
    private var enrollment: OwnershipCeremony?
    private var meta: MetaSession?
    private var enrollmentAttempt: UUID?
    private var candidate: BandIdentity?
    private var candidateAccount: UUID?
    private var candidatePending = false
    private var identityConfirmation = IdentityConfirmation()
    private var sessionID = UUID()
    private var sequences = SequenceTracker()
    private var appState = "launching"
    private var failures = 0
    private var trustRetried = false
    /// Which way of making keys to try on firmware that leaves several open, kept across
    /// launches, and whether the band has answered under it.
    private var linkWay = UserDefaults.standard.integer(forKey: "bandLinkWay")
    private var linkWayProven = UserDefaults.standard.bool(forKey: "bandLinkWayProven")
    private var linkWayTries = 0, linkWaysTried = 0
    private var reconnectAt: TimeInterval? { didSet { if (oldValue == nil) != (reconnectAt == nil) { onRetryWait?(reconnectAt != nil) } } }
    private var waitingSince: TimeInterval?
    private var scanUntil: TimeInterval?
    private var releaseCompletion: ((Bool) -> Void)?
    private var stoppingUntil: TimeInterval?
    private var userRecoveryRequired = false
    private var available = false
    private var started = false
    private var handRequested = false
    private var wristFeedbackGate = WristFeedbackGate()
    private var feedbackInFlight: WristFeedbackPhase?
    /// The rest of the band vibration playing now; `buzzResting` while a pulse and its gap run.
    private var buzzQueue: [BandPulse] = []
    private var buzzResting = false
    private var buzzGeneration = 0
    private var pulseSentAt: TimeInterval?
    private var patternInFlight: UInt64?
    /// When the gesture now being answered reached the phone, and the delays of the answers since the last report.
    private var answerHeardAt: TimeInterval?
    private var answerDelays: [TimeInterval] = []
    private var answersUntimed = 0
    /// The sequence number of the last packet answered, since the band can deliver one twice.
    private var lastAnswered: UInt64?
    /// Whether the pattern playing is one to show on the screen edge.
    private var buzzShown = true
    /// Where the read of the named settings has got to: how many there are, the place in the list, and the setting just described.
    private var settingRead: (count: UInt64, index: UInt64, setting: NamedSettings.Setting?)?
    /// The named setting being written, until its value has been read back.
    private var settingWrite: NamedSettings.Setting?
    /// How the band described each named setting when the list was last read, by the setting's number.
    private var capabilities: [UInt64: BandCapability] = [:]
    /// The band tightness test while it runs: when it began, the settings it asks about and
    /// the steps still to do. Each step waits for its answer or its time before the next.
    private var tightnessSince: TimeInterval?
    private var tightnessTargets: [BandTightness.Subject: (setting: NamedSettings.Setting, capability: BandCapability)] = [:]
    private var tightnessSteps: [BandTightness.Step] = []
    /// A value to run a check with, once the band has refused it without one.
    private var tightnessValues: [BandTightness.Subject: Int64] = [:]
    /// The wrist state each time it was read, and what changed it when it changed.
    private var tightnessStates: [Double] = []
    private var tightnessChange: String?
    /// The step whose answer is awaited, and a count that makes a wait that was cut short do nothing.
    private var tightnessAsked: BandTightness.Step?
    private var tightnessWait = 0
    /// The way being tried, and the number and the way once a number has arrived.
    private var tightnessWay = ""
    private var tightnessFound: String?
    private var tightnessHeard = 0
    /// What the test has changed and must put back: extra stream flags the band took, whether
    /// the streams were asked for at all, and whether updates were started.
    private var tightnessFlags: [Int] = []
    private var tightnessStreams = false
    private var tightnessWatching: [BandTightness.Subject] = []
    private var tightnessClosing = false
    /// The band probe while it runs, and the count that tells one of its waits from the next.
    private var probe: BandProbe?
    private var probeWait = 0
    /// Stream switches the probe tried, named as off the next time the usual streams are asked for.
    private var streamsOff = Data()
    /// Lines from the band probe as it runs, and whether it is still running.
    var onProbe: (([String], Bool) -> Void)?
    private var lastSettings: String?
    private var pendingHandTarget: (band: UUID, attempt: Date)?
    private static let notNearbyAfter: TimeInterval = 30

    init() {
        let defaults = UserDefaults.standard
        snapshot.selected = defaults.string(forKey: "selectedBand").flatMap(UUID.init(uuidString:))
        snapshot.wantsConnection = defaults.bool(forKey: "wantsConnection")
        if let hand = defaults.string(forKey: "bandHand") { snapshot.hand = Handedness(rawValue: hand) }
        transport.onDevice = { [weak self] device in
            guard let self else { return }
            if let i = self.snapshot.devices.firstIndex(where: { $0.id == device.id }) { self.snapshot.devices[i] = device } else { self.snapshot.devices.append(device) }
            self.publish()
        }
        transport.onAvailability = { [weak self] ready, message in self?.availability(ready, message: message) }
        transport.onDiagnostic = { [weak self] message in
            guard let self else { return }
            self.logger.info("\(message, privacy: .public)")
            self.record("bluetooth_diagnostic", message)
        }
        transport.onProgress = { [weak self] message in
            guard let self else { return }
            self.logger.info("Bluetooth: \(message, privacy: .public)")
            self.snapshot.message = message
            self.record("transport", message)
            self.publish()
        }
        transport.onOpen = { [weak self] in self?.opened() }
        transport.onData = { [weak self] data, receipt in self?.received(data, receipt: receipt) }
        transport.onFailure = { [weak self] error in self?.fail(error) }
        transport.onLinkLost = { [weak self] systemReconnecting in self?.linkLost(systemReconnecting) }
        transport.onBattery = { [weak self] level in
            guard let self, self.snapshot.battery != level else { return }
            self.snapshot.battery = level; self.record("battery", "level=\(level)"); self.publish()
        }
        transport.onPulse = { [weak self] healthy in
            guard let self else { return }
            if healthy { if self.snapshot.issue == .pulseMissing { self.snapshot.issue = nil } }
            else if self.snapshot.issue == nil { self.snapshot.issue = .pulseMissing }
            self.publish()
        }
        transport.onClosed = { [weak self] confirmed in
            guard let self, self.snapshot.state == .disconnecting else { return }
            let completion = self.releaseCompletion; self.releaseCompletion = nil
            self.snapshot.issue = confirmed ? nil : .stillReleasing
            self.transition(confirmed ? .disconnected : .failed, confirmed
                ? "Bluetooth release confirmed locally."
                : "Bluetooth release was not confirmed. Automatic connection is paused.")
            completion?(confirmed)
        }
        transport.onTick = { [weak self] in self?.tick() }
        transport.onRestore = { [weak self] id in
            guard let self else { return }
            if self.snapshot.selected != id { self.clearHand() }
            self.proto = nil; self.sequences.reset(); self.interpreter.reset(); self.sessionID = UUID(); self.snapshot.selected = id
            self.pendingStreams = nil; self.activeStreams = nil; self.resetEMG()
            self.handRequested = false
            self.snapshot.connectionAttempt.begin()
            self.record("restoration", "Restored peripheral; a new authenticated channel is required.")
            self.transition(.connecting, "Restoring band connection.")
        }
    }
    /// Loads stored state. Bluetooth starts separately, so first-run onboarding can ask for it.
    func start(bluetooth: Bool) {
        transport.perform { [self] in
            do { journal = try EventJournal() } catch { snapshot.journalError = "Journal unavailable. Unlock the phone and retry journal access." }
            do { try refreshIdentities() } catch { snapshot.message = error.localizedDescription }
            publish()
        }
        if bluetooth { startBluetooth() }
    }
    func startBluetooth() {
        guard !started else { return }
        started = true
        transport.start(selected: snapshot.selected, desired: snapshot.wantsConnection)
    }
    private func context() -> ReceiptContext { ReceiptContext(wallTime: Date(), uptime: ProcessInfo.processInfo.systemUptime, applicationState: appState) }
    private func publish() { onSnapshot?(snapshot) }
    private func transition(_ state: SessionState, _ message: String) {
        logger.info("Session \(state.rawValue, privacy: .public): \(message, privacy: .public)")
        let now = ProcessInfo.processInfo.systemUptime
        switch state {
        case .connecting, .reconnecting, .authenticating, .subscribing, .enrolling: if waitingSince == nil { waitingSince = now }
        default: waitingSince = nil
        }
        if state == .streaming, snapshot.issue != .pulseMissing { snapshot.issue = nil }
        if state == .subscribing { snapshot.connectionAttempt.reach(.subscribing) }
        if state == .streaming { snapshot.connectionAttempt.reach(.ready) }
        snapshot.state = state; snapshot.message = message
        WakeProbe.shared.setBandState(state.rawValue)
        if state != .streaming {
            snapshot.handSetting.cancel(); feedbackInFlight = nil
            wristFeedbackGate.cancel(); pendingHandTarget = nil
            onRelayReady?(nil)
            endTightness(); endProbe()
        }
        record("connection", "\(state.rawValue): \(message)"); publish()
    }
    private func record(_ kind: String, _ message: String? = nil, event: GestureEvent? = nil, receipt: ReceiptContext? = nil) {
        do {
            if journal == nil { journal = try EventJournal() }
            try journal?.append(kind: kind, receipt: receipt ?? context(), session: sessionID, message: message, gesture: event)
            snapshot.journalError = nil
        } catch { snapshot.journalError = "Event journal could not be written. Background evidence may be incomplete." }
    }
    func lifecycle(_ state: String) {
        appState = state; transport.setApplicationState(state)
        if state != "foreground" { wristFeedbackGate.cancel() }
        WakeProbe.shared.setApplicationState(state)
        record("lifecycle", state); publish()
    }
    func scan() {
        guard !snapshot.wantsConnection, stoppingUntil == nil, snapshot.state != .disconnecting else { return }
        guard available else { snapshot.issue = .bluetoothOff; transition(.failed, "Scan requested while Bluetooth is unavailable."); return }
        snapshot.devices = []; snapshot.issue = nil; transport.scan(); scanUntil = ProcessInfo.processInfo.systemUptime + 30
        transition(.scanning, "Looking for nearby Meta bands.")
    }
    func stopScan() {
        guard snapshot.state == .scanning else { return }
        scanUntil = nil; transport.stopScan(); transition(.disconnected, "Scan stopped.")
    }
    func refreshIdentityChoices() {
        do { try refreshIdentities(); publish() } catch { fail(error) }
    }
    private func refreshIdentities() throws {
        snapshot.identityChoices = try identities.choices()
        if let selected = snapshot.selected { snapshot.identityAccount = identities.account(for: selected) }
    }
    func select(_ device: BandDevice) { select(id: device.id) }
    func select(id: UUID) {
        guard !snapshot.wantsConnection, stoppingUntil == nil, snapshot.state != .disconnecting else { return }
        if snapshot.selected != id { clearHand() }
        snapshot.selected = id
        snapshot.connectionAttempt = ConnectionAttempt()
        snapshot.issue = nil
        UserDefaults.standard.set(id.uuidString, forKey: "selectedBand")
        do { try refreshIdentities() } catch { fail(error); return }
        snapshot.identityFingerprint = nil
        publish()
    }
    /// The saved identity to try for a band with a new Bluetooth identifier, if one exists.
    /// It is bound to the new identifier only after it authenticates.
    func reusableAccount() -> UUID? {
        guard let id = snapshot.selected else { return nil }
        let own = identities.account(for: id)
        if snapshot.identityChoices.contains(where: { $0.account == own && $0.eligible }) { return own }
        return snapshot.identityChoices.first(where: { $0.eligible && !$0.pending })?.account
    }
    private func setIntent(_ desired: Bool) {
        snapshot.wantsConnection = desired; UserDefaults.standard.set(desired, forKey: "wantsConnection")
    }
    private func chooseCandidate(account: UUID? = nil, pending: Bool? = nil) throws {
        guard let id = snapshot.selected else { throw BandError.storage("Select a band first.") }
        let account = account ?? identities.account(for: id)
        let saved = try identities.load(account)
        let waiting = try identities.load(account, pending: true)
        let choice = try ConnectionIdentitySelection.choose(saved: saved, pending: waiting, preferPending: pending)
        candidate = choice.identity; candidateAccount = account; candidatePending = choice.pending
        snapshot.identityAccount = account; snapshot.identityFingerprint = try choice.identity.publicFingerprint
    }
    func connect(account: UUID? = nil, pending: Bool? = nil) {
        guard snapshot.selected != nil, stoppingUntil == nil, snapshot.state != .disconnecting else { return }
        transport.stopScan(); scanUntil = nil; userRecoveryRequired = false; failures = 0; trustRetried = false; reconnectAt = nil
        snapshot.connectionAttempt.begin()
        do {
            try chooseCandidate(account: account ?? reusableAccount(), pending: pending)
            enrollment = nil; meta = nil; enrollmentAttempt = nil; identityConfirmation.cancel()
            snapshot.issue = nil
            setIntent(true); beginConnection()
        } catch { fail(error) }
    }
    func importIdentity(_ identity: BandIdentity, for id: UUID) {
        guard appState == "foreground", snapshot.selected == id,
              !snapshot.wantsConnection, stoppingUntil == nil, snapshot.state != .disconnecting else { return }
        // Keep the saved identity intact until the imported candidate authenticates.
        do {
            let account = identities.account(for: id)
            try identities.save(identity, for: account, pending: true)
            try refreshIdentities()
            connect(account: account, pending: true)
        } catch { fail(error) }
    }
    func beginEnrollment(_ session: MetaSession, for id: UUID) {
        guard snapshot.selected == id, appState == "foreground", stoppingUntil == nil, snapshot.state != .disconnecting else { return }
        snapshot.connectionAttempt.begin()
        do {
            transport.disconnect(); proto = nil; reconnectAt = nil; userRecoveryRequired = false; failures = 0; trustRetried = false
            let account = identities.account(for: id)
            candidateAccount = account; candidatePending = true
            let previous = try identities.load(account, pending: true)
            enrollment = try OwnershipCeremony(previous: previous, allowMissingBandKey: true) { [identities] record in try identities.save(record, for: account, pending: true) }
            meta = session; enrollmentAttempt = UUID(); candidate = nil; identityConfirmation.cancel()
            snapshot.issue = nil
            setIntent(true); beginConnection()
        } catch { fail(error) }
    }
    private func beginConnection() {
        guard snapshot.wantsConnection, let id = snapshot.selected else { return }
        proto = nil; sequences.reset(); interpreter.reset(); sessionID = UUID(); handRequested = false
        pendingStreams = nil; activeStreams = nil; resetEMG()
        snapshot.connectionAttempt.begin()
        guard available else { transition(.reconnecting, "Waiting for Bluetooth to become available."); return }
        transition(enrollment == nil ? .connecting : .enrolling, enrollment == nil ? "Connecting to your band." : "Enrolling this phone with the band.")
        transport.connect(id)
    }
    private func opened() {
        guard snapshot.wantsConnection else { transport.disconnect(); return }
        if snapshot.connectionAttempt.startedAt == nil { snapshot.connectionAttempt.begin() }
        snapshot.connectionAttempt.reach(.channelOpen)
        do {
            identityConfirmation.beginConnection()
            if enrollment == nil, candidate == nil { try chooseCandidate(account: reusableAccount()) }
            if let candidate {
                let publicPoint = try P256.Signing.PrivateKey(rawRepresentation: candidate.privateKey).publicKey.x963Representation.dropFirst()
                let fingerprint = SHA256.hash(data: Data(publicPoint)).map { String(format: "%02x", $0) }.joined()
                let summary = "Identity fingerprint=\(fingerprint) stage=\(candidate.stage) hasBandKey=\(candidate.bandPoint != nil) compatibility=\(candidate.allowMissingBandKey == true) privateKeyBytes=\(candidate.privateKey.count)"
                logger.info("\(summary, privacy: .public)")
                record("identity_diagnostic", summary)
            }
            proto = try BandProtocol(identity: enrollment == nil ? candidate : nil, ceremony: enrollment, way: linkWay)
            snapshot.connectionAttempt.reach(.encryption)
            transition(enrollment == nil ? .authenticating : .enrolling, enrollment == nil ? candidate?.bandPoint == nil ? "Authenticating phone in compatibility mode; band identity is unverified." : "Verifying the band and phone identity." : "Completing ownership enrollment; compatibility mode is allowed if Meta omits the band key.")
            try transport.write(proto!.start(now: ProcessInfo.processInfo.systemUptime))
        } catch { fail(error) }
    }
    private func received(_ data: Data, receipt: ReceiptContext) {
        WakeProbe.shared.noteBandData()
        guard let proto else { return }
        do {
            let oldStage = proto.stage
            let oldEnrollmentStage = enrollment?.record.stage
            let (output, signals) = try proto.feed(data, now: receipt.uptime)
            if oldStage != proto.stage || oldEnrollmentStage != enrollment?.record.stage {
                protocolProgress()
            }
            if !output.isEmpty { try transport.write(output) }
            for signal in signals { try handle(signal, receipt: receipt) }
        } catch { fail(error) }
    }
    private func rpc(_ operation: String, _ channel: UInt16, _ field: Int, _ payload: Data = Data()) throws {
        guard let proto else { throw BandError.transport("Band protocol is not active.") }
        try transport.write(proto.request(operation, channel: channel, field: field, payload: payload, now: ProcessInfo.processInfo.systemUptime))
    }
    func recordRelayDiagnostic(_ message: String) {
        record("relay", message)
    }
    /// Detail that belongs in the journal rather than on screen.
    func note(_ kind: String, _ message: String) { record(kind, message) }

    func setRelayDemand(_ demand: RelayWire.Demand) {
        if relayDemand != demand {
            record("relay", "Mac requested active=\(demand.active) gyro=\(demand.gyro) orientation=\(demand.orientation)")
        }
        relayDemand = demand
        guard snapshot.state == .streaming else { return }
        do { try reconcileStreams() } catch { fail(error) }
    }

    func setLocalMotion(_ on: Bool) {
        guard localMotion != on else { return }
        localMotion = on
        record("mappings", on ? "Motion streams requested for combos." : "Combos no longer need motion streams.")
        guard snapshot.state == .streaming else { return }
        do { try reconcileStreams() } catch { fail(error) }
    }

    func setLocalEMG(_ on: Bool) {
        guard localEMG != on else { return }
        localEMG = on
        if on {
            emgBlocked = nil
            if emgHardBlocked { emgStatus("EMG is off for this app run after an earlier failure. Relaunch to retry.") }
        }
        record("motion_lab", on ? "EMG requested for workout data." : "Workout data stopped; EMG no longer requested.")
        guard snapshot.state == .streaming else { return }
        do { try reconcileStreams() } catch { fail(error) }
    }

    private func resetEMG() { emgReady = false; emgReading = false; activeEMG = false; pendingEMG = nil; activeWriting = false; pendingWriting = nil }
    private func emgStatus(_ text: String) { record("emg", text); onEMGStatus?(text) }

    private func reconcileStreams() throws {
        // The band tightness test asks for streams itself while it runs, and this is called again when it ends.
        guard pendingStreams == nil, !emgReading, (tightnessSince == nil && probe == nil) || snapshot.state != .streaming else { return }
        // A firmware update runs with gestures alone. The extra traffic made a band lose its place.
        let quiet = update != nil
        let wantEMG = localEMG && emgBlocked == nil && !emgHardBlocked && !quiet
        if wantEMG && !emgReady {
            // Never enable EMG before its layout has been read and validated.
            emgReading = true
            emgStatus("Reading the band’s EMG configuration.")
            try rpc("emg_configuration", 7, 5)
            return
        }
        // The relay only forwards the streams the Mac asked for (see onRelayReady), so streams
        // started for this phone's combos never reach the Mac.
        let requested = RelayWire.Demand(active: true, gyro: !quiet && ((relayDemand.active && relayDemand.gyro) || localMotion),
                                         orientation: !quiet && ((relayDemand.active && relayDemand.orientation) || localMotion))
        let wantWriting = writingWanted && !quiet
        if activeStreams == requested, activeEMG == wantEMG, activeWriting == wantWriting {
            onRelayReady?(relayDemand)
            return
        }
        onRelayReady?(nil)
        // The model's scores are named only once handwriting has been asked for, on or off.
        try rpc("start_streams", 5, 4, BandProtocol.streamFlags(gyro: requested.gyro, orientation: requested.orientation, emg: wantEMG,
                                                                 inference: wantWriting || activeWriting ? wantWriting : nil) + streamsOff)
        pendingStreams = requested; pendingEMG = wantEMG; pendingWriting = wantWriting; streamsOff = Data()
    }

    /// Limit automatic reads; an explicit wrist change can retry.
    private func requestHand() {
        let defaults = UserDefaults.standard, attempts = defaults.integer(forKey: "handReadAttempts")
        guard !handRequested else { return }
        handRequested = true
        guard attempts < 2 else {
            UserDefaults.standard.removeObject(forKey: "bandHand")
            snapshot.handSetting.fail("The wrist setting could not be read. Choose a wrist to try again."); publish(); return
        }
        guard snapshot.handSetting.read() else { return }
        defaults.removeObject(forKey: "bandHand")
        defaults.set(attempts + 1, forKey: "handReadAttempts")
        do { try rpc("read_hand", 6, 5) }
        catch { snapshot.handSetting.fail("Could not read the wrist setting. Try again.") }
        publish()
    }

    func setHand(_ hand: Handedness, for band: UUID) {
        guard snapshot.selected == band, appState == "foreground", snapshot.state == .streaming, update == nil,
              let attempt = snapshot.connectionAttempt.startedAt,
              snapshot.handSetting.change(to: hand) else { return }
        pendingHandTarget = (band, attempt)
        UserDefaults.standard.removeObject(forKey: "bandHand")
        if let change = snapshot.handSetting.changeID { wristFeedbackGate.begin(change) }
        record("hand", "Requested \(hand.rawValue) wrist."); publish()
        sendPendingHand()
    }

    private func sendPendingHand() {
        guard case .write(let hand) = snapshot.handSetting.pending, proto?.wristFeedbackPending == false else { return }
        guard let target = pendingHandTarget, snapshot.selected == target.band,
              snapshot.connectionAttempt.startedAt == target.attempt,
              appState == "foreground", snapshot.state == .streaming else {
            pendingHandTarget = nil
            snapshot.handSetting.fail("Return to Runes and choose a wrist again."); publish(); return
        }
        pendingHandTarget = nil
        do { try rpc("set_hand", 6, 5, hand.configuration) }
        catch { snapshot.handSetting.fail("Could not change the wrist setting. Reconnect and try again."); fail(error) }
    }

    func wristFeedback(_ phase: WristFeedbackPhase, for hand: Handedness, change: UUID, band: UUID, attempt: Date) {
        let now = ProcessInfo.processInfo.systemUptime
        guard appState == "foreground", snapshot.state == .streaming, snapshot.selected == band,
              snapshot.connectionAttempt.startedAt == attempt, snapshot.handSetting.confirmedChangeID == change,
              snapshot.hand == hand, let proto, proto.canSendWristFeedback, update == nil,
              wristFeedbackGate.take(phase, change: change, now: now) else { return }
        feedbackInFlight = phase
        record("wrist_feedback", "\(phase.rawValue) requested.")
        do { try rpc("wrist_feedback", 6, 17, phase.payload); onPulseSent?(BandPulse(duration: phase.duration, amplitude: phase.amplitude)) }
        catch { record("wrist_feedback", "Send unconfirmed.") }
    }

    func cancelWristFeedback(change: UUID) { wristFeedbackGate.cancel(change) }

    /// Vibrates the band, replacing any pattern still playing. Works with the app in the
    /// background, as long as the band is streaming.
    func buzzBand(_ buzz: BandBuzz) { play(buzz.pulses, name: buzz.rawValue) }

    /// Plays any list of pulses, replacing a pattern still playing. An empty list stops it.
    /// A pattern with no name is an answer to a gesture: there is one for every gesture, so it
    /// is left out of the journal and off the screen edge, where the gesture already shows.
    func play(_ pulses: [BandPulse], name: String?) {
        guard snapshot.state == .streaming, proto != nil, update == nil else { return }
        buzzGeneration += 1
        buzzQueue = pulses; buzzResting = false; buzzShown = name != nil
        guard !pulses.isEmpty else { return }
        if let name { record("band_buzz", "\(name) requested.") }
        sendNextPulse()
    }

    /// Buzzes the band in answer to a gesture, in place of the buzz the band gives by itself.
    /// Sent only while the band is known to stay quiet on gestures, so nothing is felt twice,
    /// and straight from where the packet arrives, so no time is lost on the way. When
    /// nothing else is waiting on the band the answer is timed; otherwise it is sent
    /// without waiting for a reply, so an answer is never skipped.
    private func answer(_ event: GestureEvent) {
        guard snapshot.state == .streaming, snapshot.bandQuietOnGestures == true, let proto,
              event.sequence != lastAnswered, UserDefaults.standard.object(forKey: Preferences.bandAnswers) as? Bool ?? true,
              let gesture = GestureInterpreter.immediate(event, onTouch: UserDefaults.standard.bool(forKey: Preferences.bandAnswersOnTouch)) else { return }
        lastAnswered = event.sequence
        if proto.canSendWristFeedback {
            answerHeardAt = event.received.wallTime.timeIntervalSince1970
            play(gesture.answer, name: nil)
        } else if let pulse = gesture.answer.first, let frame = try? proto.post(channel: 6, field: 17, payload: pulse.payload) {
            try? transport.write(frame)
            answersUntimed += 1
        }
    }

    /// Notes how long one answer took, from the gesture reaching the phone to the band saying it
    /// had the pulse, and reports every twenty. That round trip is about what the answer adds
    /// over the band buzzing by itself: one leg in for the gesture and one leg out for the pulse.
    private func timed(answer delay: TimeInterval) {
        guard delay >= 0, delay < 2 else { return }
        answerDelays.append(delay)
        guard answerDelays.count >= 20 else { return }
        let sorted = answerDelays.sorted(), untimed = answersUntimed
        answerDelays = []; answersUntimed = 0
        func milliseconds(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }
        trial("gesture answers: 20 timed, \(untimed) more sent without waiting; gesture heard to pulse taken was \(milliseconds(sorted[10])) ms in the middle, \(milliseconds(sorted[0])) ms fastest, \(milliseconds(sorted[19])) ms slowest.")
    }

    /// Notes what the band's haptics setting is, as read on connecting or after it was written.
    private func heard(haptics value: UInt64) {
        let quiet = value == 2
        guard quiet != snapshot.bandQuietOnGestures else { return }
        snapshot.bandQuietOnGestures = quiet; publish()
        record("band_buzz", quiet ? "The band stays quiet on gestures; Runes answers them." : "Band haptics setting \(value); Runes does not answer gestures.")
    }

    /// Reads every setting the band can name, one request at a time.
    func readNamedSettings() {
        guard tightnessSince == nil, probe == nil else { onNamedSetting?(nil, "Wait for the band test to end."); onNamedSetting?(nil, ""); return }
        guard snapshot.state == .streaming, settingRead == nil, settingWrite == nil, update == nil else { return }
        record("band_settings", "Named settings: reading.")
        settingRead = (0, 0, nil)
        askSetting("named_count", NamedSettings.count())
    }

    /// Writes a whole number to one named setting, then reads it back. The band keeps it.
    func writeNamedSetting(_ setting: NamedSettings.Setting, value: UInt64) {
        guard snapshot.state == .streaming, settingRead == nil, settingWrite == nil, update == nil, setting.writable, let kind = setting.kind else { return }
        record("band_settings", "Writing \(setting.name) = \(value) (was \(setting.value.map(String.init) ?? "unknown")).")
        settingWrite = setting
        askSetting("named_write", NamedSettings.write(id: setting.id, value: value, kind: kind))
    }

    /// Writes several named settings in order, each read back before the next. `done` hears
    /// whether every one of them now holds its value.
    private func writeSettings(_ writes: [(name: String, value: UInt64)], done: @escaping (Bool) -> Void) {
        settingQueue = writes; afterSettings = done
        writeNextSetting()
    }

    private func writeNextSetting(after last: NamedSettings.Setting? = nil, wanted: UInt64? = nil) {
        guard let done = afterSettings else { return }
        func end(_ held: Bool) { settingQueue = []; afterSettings = nil; done(held) }
        if let last, last.value != wanted { return end(false) }
        guard let next = settingQueue.first else { return end(true) }
        guard let setting = settingsByName[next.name], setting.writable, settingRead == nil, settingWrite == nil, snapshot.state == .streaming, update == nil else { return end(false) }
        writeNamedSetting(setting, value: next.value)
    }

    private func askNext() {
        guard var read = settingRead else { return }
        guard read.index < read.count else {
            settingRead = nil
            record("band_settings", "Named settings: done."); onNamedSetting?(nil, "")
            let next = afterSettingsRead
            afterSettingsRead = nil; next?()
            return
        }
        read.index += 1; read.setting = nil; settingRead = read
        askSetting("named_describe", NamedSettings.describe(index: read.index))
    }

    private func askSetting(_ operation: String, _ payload: Data) {
        do { try rpc(operation, NamedSettings.channel, NamedSettings.field, payload) }
        catch {
            settingRead = nil; settingWrite = nil; afterSettingsRead = nil
            record("band_settings", "Named settings: could not ask."); onNamedSetting?(nil, "Could not ask the band."); onNamedSetting?(nil, "")
            if let done = afterSettings { settingQueue = []; afterSettings = nil; done(false) }
        }
    }

    private func namedSetting(_ operation: String, _ payload: Data) {
        func line(_ setting: NamedSettings.Setting?, _ text: String) {
            if !text.isEmpty { record("band_settings", text) }
            onNamedSetting?(setting, text)
        }
        switch operation {
        case "named_count":
            guard let count = NamedSettings.count(from: payload) else {
                settingRead = nil
                line(nil, "No list (\(WristFeedbackResult.shape(payload))).")
                return line(nil, "")
            }
            settingRead = (count, 0, nil); capabilities = [:]
            line(nil, "\(count) settings.")
            askNext()
        case "named_describe":
            guard var read = settingRead else { return }
            guard let setting = NamedSettings.setting(from: payload) else {
                line(nil, "\(read.index): not described.")
                return askNext()
            }
            read.setting = setting; settingRead = read
            if let capability = BandCapability(describing: payload) { capabilities[setting.id] = capability; onCapability?(setting, capability) }
            askSetting("named_read", NamedSettings.read(id: setting.id))
        case "named_read":
            guard let read = settingRead, var setting = read.setting else { return }
            let answer = NamedSettings.value(of: setting.id, from: payload)
            setting.kind = answer?.kind; setting.value = answer?.value
            settingsByName[setting.name] = setting
            let range = capabilities[setting.id].map { " [\($0.summary)]" } ?? setting.range.map { " [\($0.lowerBound) to \($0.upperBound)]" } ?? ""
            let refusal = BandCapability.code(from: payload).map { "not readable (result \($0))" } ?? "not readable"
            let detail = setting.detail.isEmpty ? "" : " (\(setting.detail))"
            line(setting, "#\(setting.id) \(setting.name)\(range) = \(answer?.text ?? refusal)\(detail)")
            askNext()
        case "named_write":
            guard let setting = settingWrite else { return }
            guard NamedSettings.value(of: setting.id, from: payload) != nil else {
                settingWrite = nil
                line(setting, "\(setting.name): the band refused the write (\(WristFeedbackResult.shape(payload))).")
                return writeNextSetting(after: setting, wanted: nil)
            }
            askSetting("named_verify", NamedSettings.read(id: setting.id))
        default:
            guard var setting = settingWrite else { return }
            settingWrite = nil
            let answer = NamedSettings.value(of: setting.id, from: payload)
            setting.kind = answer?.kind; setting.value = answer?.value
            if setting.name == "haptics", let value = answer?.value { heard(haptics: value) }
            line(setting, "\(setting.name): the band now reports \(answer?.value.map(String.init) ?? "nothing readable").")
            if answer != nil { settingsByName[setting.name] = setting }
            if settingQueue.first?.name == setting.name { writeNextSetting(after: setting, wanted: settingQueue.removeFirst().value) }
        }
    }

    /// Sends one band test request. A request still waiting on the same channel means this one is skipped.
    func tryOnBand(_ operation: String, field: Int, _ payload: Data) {
        guard snapshot.state == .streaming, update == nil else { return }
        do { try rpc("try_" + operation, BandTrial.channel, field, payload) }
        catch { if operation != "acknowledge" { trial("\(operation): the band is busy; try again.") } }
    }

    private func trial(_ line: String) { record("band_test", line); onTrial?(line) }
    /// The shape of a test's answer, or that none came.
    private func answer(_ payload: Data) -> String { payload.isEmpty ? "no answer" : WristFeedbackResult.shape(payload) }

    /// Runs the band tightness test: tries each way of getting the band's tightness in turn,
    /// stops at the first that returns a number, then puts back what it changed. It sends
    /// only requests about the two checks and stream requests. It writes no setting the band keeps.
    func checkTightness(_ settings: [NamedSettings.Setting]) {
        guard tightnessSince == nil else { return }
        var targets: [BandTightness.Subject: (setting: NamedSettings.Setting, capability: BandCapability)] = [:]
        for setting in settings {
            if let subject = BandTightness.Subject(rawValue: setting.name), let capability = capabilities[setting.id] { targets[subject] = (setting, capability) }
        }
        // A probe that is running is another reason not to start. The page is told, so it does not go on waiting.
        guard snapshot.state == .streaming, settingRead == nil, settingWrite == nil, pendingStreams == nil, !emgReading, update == nil, probe == nil, let proto,
              let steps = BandTightness.plan(targets.mapValues(\.capability)) else {
            tightness("Not started: the band is busy, not connected, or does not list running the check.")
            onTightness?(""); return
        }
        tightnessSince = ProcessInfo.processInfo.systemUptime
        tightnessTargets = targets; tightnessSteps = steps; tightnessValues = [:]; tightnessStates = []; tightnessChange = nil
        tightnessAsked = nil; tightnessWay = ""; tightnessFound = nil; tightnessHeard = 0
        tightnessFlags = []; tightnessStreams = false; tightnessWatching = []; tightnessClosing = false
        proto.watchesOther = true
        let asked = BandTightness.Subject.allCases.compactMap { subject in
            targets[subject].map { "\(subject.word) is setting \($0.setting.id), actions \($0.capability.actions.map(String.init).joined(separator: " "))" }
        }
        tightness("Started: \(asked.joined(separator: "; ")).")
        nextTightnessStep()
    }

    /// Writes one line of the band tightness test, with the seconds since it began.
    private func tightness(_ text: String) {
        let line = (tightnessSince.map { String(format: "+%.1fs ", ProcessInfo.processInfo.systemUptime - $0) } ?? "") + text
        record("band_tightness", line); onTightness?(line)
    }

    private func nextTightnessStep() {
        guard tightnessSince != nil, tightnessAsked == nil else { return }
        guard snapshot.state == .streaming else { return endTightness() }
        guard !tightnessSteps.isEmpty else { return tightnessClosing ? endTightness() : closeTightness() }
        let step = tightnessSteps.removeFirst()
        func about(_ subject: BandTightness.Subject, _ action: UInt64, _ value: Int64? = nil) -> (channel: UInt16, field: Int, payload: Data)? {
            guard let target = tightnessTargets[subject] else { return nil }
            return BandTightness.request(subject, id: target.setting.id, name: target.setting.name, capability: target.capability, action: action, value: value)
                .map { (NamedSettings.channel, NamedSettings.field, $0) }
        }
        var request: (channel: UInt16, field: Int, payload: Data)?
        switch step {
        case .listen(let seconds):
            tightnessWait += 1
            let wait = tightnessWait
            transport.perform(after: seconds) { [weak self] in
                guard let self, self.tightnessWait == wait else { return }
                self.nextTightnessStep()
            }
            return
        case .read:
            request = about(.state, BandTightness.read)
        case .act(let subject, let action):
            tightness("Asked \(subject.word) action \(action).")
            request = about(subject, action)
        case .run(let subject, let value, let way):
            let value = value ?? tightnessValues[subject]
            tightnessWay = "\(subject.word) \(way)"
            tightness("Asked \(subject.word) action \(BandTightness.run)\(value.map { " value \($0)" } ?? ""): \(way).")
            request = about(subject, BandTightness.run, value)
        case .streams(let flag):
            // Once the wrist state has changed there is an answer, and the streams are left alone.
            if flag != nil, tightnessChange != nil { tightnessSteps = []; return nextTightnessStep() }
            let extra = flag.map { tightnessFlags + [$0] } ?? []
            tightness(flag == nil ? "Asked for the usual streams." : "Asked for streams with \(extra.map(String.init).joined(separator: " ")).")
            tightnessStreams = true
            let usual = BandProtocol.streamFlags(gyro: activeStreams?.gyro ?? false, orientation: activeStreams?.orientation ?? false, emg: activeEMG,
                                                 inference: activeWriting ? true : nil)
            request = (5, 4, BandTightness.flags(usual, with: extra))
        }
        guard let request else { tightness("Not sent: the band does not list this."); return nextTightnessStep() }
        do { try rpc(request.field == 4 ? "named_streams" : "named_trigger", request.channel, request.field, request.payload); tightnessAsked = step }
        catch { tightness("Could not ask the band."); closeTightness() }
    }

    private func tightnessAnswer(_ payload: Data) {
        guard tightnessSince != nil, let step = tightnessAsked else { return }
        func number(_ subject: BandTightness.Subject) -> Double? {
            tightnessTargets[subject].flatMap { BandTightness.number(inAnswer: payload, id: $0.setting.id) }
        }
        switch step {
        case .read:
            guard let state = number(.state) else { tightness("Wrist state: not readable. \(BandTightness.reply(payload))"); break }
            tightness("Wrist state reads \(BandTightness.plain(state)).")
            if let first = tightnessStates.first, state != first, tightnessChange == nil {
                tightnessChange = "wrist state went from \(BandTightness.plain(first)) to \(BandTightness.plain(state)), \(tightnessWay)"
            }
            tightnessStates.append(state)
        case .act(let subject, let action):
            tightness(BandTightness.reply(payload))
            if action == BandTightness.watch { tightnessWatching.append(subject) }
            if action == BandTightness.unwatch { tightnessWatching.removeAll { $0 == subject } }
            tightnessNumber(number(subject), from: "the answer")
        case .run(let subject, let value, let way):
            tightness(BandTightness.reply(payload))
            // A check the band will not run without a value is asked once more with 0, the value it took before.
            if value == nil, tightnessValues[subject] == nil, BandTightness.refused(payload), !tightnessClosing,
               let target = tightnessTargets[subject],
               BandTightness.request(subject, id: target.setting.id, name: target.setting.name, capability: target.capability, action: BandTightness.run, value: 0) != nil {
                tightnessValues[subject] = 0
                tightnessSteps.insert(.run(subject, value: 0, way: way), at: 0)
            }
            tightnessNumber(number(subject), from: "the answer")
        case .streams(let flag):
            let answer = BandTightness.streams(payload, extra: flag.map { tightnessFlags + [$0] } ?? [])
            tightness(answer.line)
            if let flag {
                // A flag the band will not take changes nothing, so the runs that would follow it are skipped.
                if answer.taken { tightnessFlags.append(flag) }
                else if let next = tightnessSteps.firstIndex(where: { if case .streams = $0 { return true }; return false }) { tightnessSteps.removeFirst(next) }
                else { tightnessSteps = [] }
            } else {
                tightnessStreams = false; tightnessFlags = []
                // Streams that were not confirmed are asked for again the usual way once the test ends.
                if !answer.taken { activeStreams = nil }
            }
        case .listen: break
        }
        tightnessAsked = nil
        nextTightnessStep()
    }

    /// A number from the band ends the search. What is left is putting things back.
    private func tightnessNumber(_ number: Double?, from source: String) {
        guard let number, tightnessFound == nil, !tightnessClosing else { return }
        tightnessFound = "\(BandTightness.plain(number)) arrived in \(source), \(tightnessWay.isEmpty ? "before any run" : tightnessWay)"
        tightness("Number: \(BandTightness.plain(number)).")
        tightnessSteps = []
        // While an answer is awaited, that answer moves the test on. Otherwise the wait is cut short.
        if tightnessAsked == nil { tightnessWait += 1; closeTightness() }
    }

    /// Puts back what the test changed: the usual streams, and updates stopped.
    private func closeTightness() {
        guard !tightnessClosing else { return endTightness() }
        tightnessClosing = true
        tightnessSteps = (tightnessStreams ? [.streams(nil)] : []) + tightnessWatching.map { .act($0, BandTightness.unwatch) }
        nextTightnessStep()
    }

    private func endTightness() {
        guard tightnessSince != nil else { return }
        var result = tightnessFound ?? tightnessChange ?? "no number arrived"
        if let first = tightnessStates.first, let last = tightnessStates.last {
            result += ". Wrist state read \(BandTightness.plain(first)) at first and \(BandTightness.plain(last)) at the end"
        }
        tightness("Done: \(result). \(tightnessHeard) other messages.")
        tightnessSince = nil; tightnessTargets = [:]; tightnessSteps = []; tightnessAsked = nil; tightnessWait += 1
        tightnessFlags = []; tightnessStreams = false; tightnessWatching = []; tightnessClosing = false
        proto?.watchesOther = update != nil
        onTightness?("")
        guard snapshot.state == .streaming else { return }
        do { try reconcileStreams() } catch { fail(error) }
    }

    /// Runs the band probe: tries stream switches and requests the app does not use, one at a
    /// time, and writes down what the band does. The usual streams are asked for again at the end.
    func startProbe(_ trials: [BandProbe.Trial]) {
        guard probe == nil else { return }
        guard snapshot.state == .streaming, let proto, update == nil, tightnessSince == nil, !writingWanted, pendingStreams == nil, !emgReading,
              settingRead == nil, settingWrite == nil else {
            record("band_probe", "Not started: the band is busy or not connected."); onProbe?(["Not started: the band is busy or not connected."], false); return
        }
        probe = BandProbe(trials, usual: BandProtocol.streamFlags(gyro: activeStreams?.gyro ?? false, orientation: activeStreams?.orientation ?? false, emg: activeEMG))
        proto.watchesOther = true
        record("band_probe", "Started: \(trials.count) to try.")
        stepProbe()
    }

    /// Ends the probe after whatever is on has been turned off.
    func stopProbe() {
        guard let probe else { return }
        probe.stop(); probeWait += 1
        stepProbe()
    }

    private func stepProbe() {
        guard let probe else { return }
        let ask = probe.next()
        switch ask {
        case .send(let channel, let field, let payload):
            do { try rpc(BandProbe.operation, channel, field, payload) } catch { return endProbe("Could not ask the band.") }
        case .listen(let seconds):
            probeWait += 1
            let wait = probeWait
            transport.perform(after: seconds) { [weak self] in
                guard let self, self.probeWait == wait else { return }
                self.stepProbe()
            }
        case .wait: break
        case .done: return endProbe()
        }
        let lines = probe.takeLines()
        lines.forEach { record("band_probe", $0) }
        onProbe?(lines + ["Trying \(probe.progress)."], true)
    }

    private func endProbe(_ problem: String? = nil) {
        guard let probe else { return }
        self.probe = nil; probeWait += 1
        let dropped = snapshot.state == .streaming ? nil : probe.on.map { "The link dropped while these were on: \($0)." } ?? "The link dropped."
        let lines = probe.takeLines() + [problem, dropped, "Done."].compactMap { $0 }
        lines.forEach { record("band_probe", $0) }
        onProbe?(lines, false)
        proto?.watchesOther = update != nil
        guard snapshot.state == .streaming else { return }
        // The usual streams are asked for the normal way, with every switch tried named as off.
        streamsOff = probe.off; activeStreams = nil
        do { try reconcileStreams() } catch { fail(error) }
    }

    /// Plays one of the band's own patterns, 1 or 2, in place of anything still playing.
    /// The reference implementation calls these its gesture feedback patterns.
    func perform(pattern: UInt64) {
        guard snapshot.state == .streaming, let proto, proto.canSendWristFeedback, update == nil, pattern == 1 || pattern == 2 else { return }
        buzzGeneration += 1
        buzzQueue = []; buzzResting = false
        record("band_buzz", "pattern \(pattern) requested.")
        do { try rpc("band_pattern", 6, 17, PB.field(2, PB.field(1, pattern))); patternInFlight = pattern }
        catch { record("band_buzz", "Send unconfirmed.") }
    }

    /// Sends the next pulse once the band has answered the last one and its gap has passed.
    private func sendNextPulse() {
        guard !buzzQueue.isEmpty, !buzzResting else { return }
        guard snapshot.state == .streaming, let proto else { buzzQueue = []; return }
        guard proto.canSendWristFeedback else { return }
        let pulse = buzzQueue.removeFirst()
        do {
            try rpc("wrist_feedback", 6, 17, pulse.payload); pulseSentAt = ProcessInfo.processInfo.systemUptime
            if buzzShown { onPulseSent?(pulse) }
        }
        catch { record("band_buzz", "Send unconfirmed."); buzzQueue = []; return }
        guard !buzzQueue.isEmpty else { return }
        buzzResting = true
        let generation = buzzGeneration
        transport.perform(after: Double(pulse.span) / 1000) { [weak self] in
            guard let self, self.buzzGeneration == generation else { return }
            self.buzzResting = false; self.sendNextPulse()
        }
    }

    private func clearHand() {
        snapshot.handSetting = HandSetting()
        for key in ["bandHand", "handReadAttempts"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func handle(_ signal: BandProtocol.Signal, receipt: ReceiptContext) throws {
        switch signal {
        case .enrolled(let identity): candidate = identity; identityConfirmation.enrolled()
        case .ready:
            keepLinkWay()
            let result = try identityConfirmation.authenticated {
                guard let id = snapshot.selected, let account = candidateAccount, var candidate, candidate.canAuthenticate else { throw BandError.authentication("No usable host identity is selected. Choose a saved identity or import the Mac QR.") }
                candidate.stage = candidate.bandPoint == nil ? "host_verified" : "verified"
                try identities.save(candidate, for: account)
                if candidatePending { try identities.clearPending(account) }
                identities.bind(id, to: account)
                candidatePending = false
                self.candidate = candidate
                try refreshIdentities()
            }
            if result == .reconnect {
                enrollment = nil; meta = nil; enrollmentAttempt = nil
                beginConnection(); return
            }
            guard result == .committed else { return }
            transition(.subscribing, "Enabling the band's gesture stream.")
            try rpc("request_active", 6, 5, PB.field(6, 2))
        case .reply(let operation, let payload):
            switch operation {
            case "request_active": try rpc("input_subscription", 5, 4)
            case "input_subscription": try reconcileStreams()
            case "emg_configuration":
                emgReading = false
                switch EMG.configuration(payload) {
                case .success(let summary): emgReady = true; emgStatus("EMG configuration OK: \(summary).")
                case .failure(let error): emgBlocked = error.localizedDescription; emgStatus(error.localizedDescription)
                }
                if snapshot.state == .streaming || pendingStreams == nil { try reconcileStreams() }
            case "start_streams":
                // The band's answer as numbers only, to see what a firmware reports about its streams.
                record("band_streams", (try? Fields(payload)).map { BandSettings.describe($0, depth: 0) } ?? "unreadable")
                activeStreams = pendingStreams
                pendingStreams = nil
                let emgOn = pendingEMG ?? false
                if emgOn != activeEMG { emgStatus(emgOn ? "EMG streaming." : "EMG stopped.") }
                activeEMG = emgOn; pendingEMG = nil
                activeWriting = pendingWriting ?? false; pendingWriting = nil
                if stoppingUntil != nil {
                    try rpc("stop_streams", 5, 4, BandProtocol.stopFlags)
                } else {
                    if snapshot.state != .streaming {
                        failures = 0; trustRetried = false
                        snapshot.startedAt = Date()
                        transition(.streaming, candidate?.bandPoint == nil ? "Receiving band gestures. Compatibility mode: band identity is unverified." : "Receiving band gestures.")
                        // A read or write of a named setting cut off by a lost link is not carried over.
                        settingRead = nil; settingWrite = nil; lastAnswered = nil
                        settingQueue = []; afterSettings = nil; afterSettingsRead = nil
                        endTightness()
                        requestHand()
                        resumeUpdate()
                    }
                    try reconcileStreams()
                }
            case "stop_streams": finishDisconnect()
            case "named_count", "named_describe", "named_read", "named_write", "named_verify": namedSetting(operation, payload)
            case "try_acknowledge":
                // One line for the first answer; a line per gesture would bury the journal.
                if !acknowledgementNoted { acknowledgementNoted = true; trial("acknowledge: \(answer(payload))") }
            case "try_pattern", "try_stop": trial("\(operation.dropFirst(4)): \(answer(payload))")
            case "try_info":
                let line = "The band now reports: \(BandInfo.describe(payload) ?? "nothing readable")."
                record("band_model", line); onModel?(line, trialModelWanted, modelGestures.usual, modelGestures.trial)
            case "try_writing":
                record("band_writing", "The band's answer to the \(writingWanted ? "handwriting" : "usual") state: \(answer(payload)) [\(BandSettings.describe(payload) ?? "no settings")].")
                if !writingWanted, !payload.isEmpty { UserDefaults.standard.removeObject(forKey: "bandStandbyToRestore") }
                try reconcileStreams()
            case "try_firmware":
                // The whole answer as numbers: update state, device state, and each item's kind and version.
                let numbers = (try? Fields(payload)).map { BandSettings.describe($0, depth: 0) } ?? "unreadable"
                let summary = (try? Fields(Fields(payload).bytes(8))).flatMap { BandUpdateStatus($0) }.map { "; \($0.summary)" } ?? ""
                trial("firmware: \(payload.isEmpty ? "no answer" : numbers + summary)")
            case "device_info":
                if let info = BandInfo.describe(payload) { record("band_info", info); onInfo?(info) }
                onDeviceReply?(payload)
            case "named_trigger", "named_streams": tightnessAnswer(payload)
            case BandProbe.operation: probe?.answered(payload); stepProbe()
            case "set_hand":
                if snapshot.handSetting.wrote() { try rpc("read_hand", 6, 5) }
            case "read_hand":
                if let haptics = BandSettings.haptics(payload) { heard(haptics: haptics) }
                standby = BandWriting.standby(payload) ?? standby
                settleWriting()
                if let settings = BandSettings.describe(payload), settings != lastSettings {
                    lastSettings = settings
                    record("band_settings", settings); onSettings?(settings)
                }
                let hand = Handedness.read(payload)
                if snapshot.handSetting.received(hand), let hand {
                    UserDefaults.standard.set(hand.rawValue, forKey: "bandHand")
                    UserDefaults.standard.set(0, forKey: "handReadAttempts")
                    record("hand", "Confirmed \(hand.rawValue) wrist.")
                }
                if let error = snapshot.handSetting.error { record("hand", error) }
                publish()
            default: break
            }
        case .ownership(let step):
            guard let meta, let attempt = enrollmentAttempt else { throw BandError.authentication("Enrollment login expired. Sign in again.") }
            onOwnership?(step, meta, attempt)
        case .emgUnavailable(let reason):
            emgReading = false; emgBlocked = reason
            emgStatus(reason)
            if pendingStreams != nil { pendingStreams = nil; pendingEMG = nil }
            try reconcileStreams()
        case .handUnavailable(let reason):
            snapshot.handSetting.fail(reason); record("hand", reason); publish()
        case .wristFeedback(let result):
            if let feedback = feedbackInFlight {
                record("wrist_feedback", "\(feedback.rawValue) \(result.rawValue)\(result == .accepted ? "" : ": " + (proto?.feedbackNote ?? "")).")
            } else if let pattern = patternInFlight {
                let note = proto?.feedbackNote ?? ""
                record("band_buzz", "Pattern \(pattern) \(result.rawValue): \(note).")
                onPattern?(pattern, result, note)
            } else {
                if result != .accepted { record("band_buzz", "Pulse \(result.rawValue): \(proto?.feedbackNote ?? "").") }
                if let sent = pulseSentAt { onPulse?(result, receipt.uptime - sent) }
                if let heard = answerHeardAt, result == .accepted { timed(answer: receipt.wallTime.timeIntervalSince1970 - heard) }
            }
            answerHeardAt = nil
            pulseSentAt = nil; patternInFlight = nil
            feedbackInFlight = nil
            sendPendingHand(); sendNextPulse(); publish()
        case .inference(let scores, let pipeline):
            guard writingWanted else { return }
            writingMessages += 1
            let shape = "\(scores.count) in a message, pipeline \(pipeline)"
            if shape != writingShape { writingShape = shape; record("band_writing", "Scores are arriving: \(shape).") }
            guard !scores.isEmpty, scores.count % BandWriting.symbols == 0 else { return }
            let before = writing.symbols.count
            for start in stride(from: 0, to: scores.count, by: BandWriting.symbols) { writing.push(Array(scores[start..<(start + BandWriting.symbols)])) }
            if writing.symbols.count != before || writingMessages % 50 == 0 { onWriting?(true, writing.text, writing.rows) }
        case .other(let kind, let channel, let payload):
            if let update, let proto, kind == 0x02000315, BandLink.route(channel) == BandTrial.channel {
                sendUpdate(update.receive(payload, ids: &proto.requestNumber, now: updateTime()))
                return
            }
            if let probe { probe.heard(kind: kind, payload: payload); return }
            // The journal is bounded, so a band that floods is cut off at 60 lines.
            guard tightnessSince != nil, tightnessHeard < 60 else { return }
            tightnessHeard += 1
            tightness(BandTightness.describe(kind: kind, channel: channel, payload: payload))
            if let heard = BandTightness.number(kind: kind, payload: payload, ids: tightnessTargets.values.map(\.setting.id)) {
                tightnessNumber(heard.value, from: heard.from)
            }
        case .emg(let values, let sequence, let timestamp):
            guard snapshot.state == .streaming else { return }
            onRaw?(RawSample(kind: .emg, uptime: receipt.uptime, sequence: sequence, timestamp: timestamp, emg: values))
        case .motion(let kind, let values, let sequence, let timestamp):
            guard snapshot.state == .streaming else { return }
            onRaw?(RawSample(kind: kind == .gyro ? .gyro : .orientation, uptime: receipt.uptime, sequence: sequence, timestamp: timestamp, values: values))
            if localMotion { onMotion?(kind, values) }
            onRelayEvent?(RelayWire.Event(kind: kind, sequence: sequence, timestamp: timestamp,
                                          phoneUptime: receipt.uptime, phoneTime: receipt.wallTime, values: values))
        case .gesture(let finger, let action, let derived, let synthetic, let sequence, let timestamp):
            let event = GestureEvent(id: UUID(), sessionID: sessionID, fingerCode: finger, actionCode: action, derivedActionCode: derived, synthetic: synthetic, sequence: sequence, deviceTimestamp: timestamp, received: receipt)
            if let previous = sequences.gap(sequence, stream: event.stream) {
                record("discontinuity", "\(event.stream.rawValue) gesture sequence changed from \(previous) to \(sequence); packet loss is not inferred.", receipt: receipt)
            }
            if snapshot.state == .streaming {
                onRaw?(RawSample(kind: .gesture, uptime: receipt.uptime, sequence: sequence, timestamp: timestamp,
                                 gesture: [finger, action, derived, synthetic ? 1 : 0]))
                onRelayEvent?(RelayWire.Event(kind: .gesture, sequence: sequence, timestamp: timestamp,
                                              phoneUptime: receipt.uptime, phoneTime: receipt.wallTime,
                                              gesture: [finger, action, derived, synthetic ? 1 : 0]))
            }
            answer(event)
            record("gesture", event: event, receipt: receipt)
            if proto?.gestureFromTrial == true {
                modelGestures.trial += 1
                if modelGestures.trial == 1 { record("band_model", "A gesture arrived marked as from the trial model.") }
            } else { modelGestures.usual += 1 }
            onModel?(nil, trialModelWanted, modelGestures.usual, modelGestures.trial)
            if acknowledgesGestures, !synthetic { tryOnBand("acknowledge", field: 11, BandTrial.acknowledge(gesture: sequence)) }
            snapshot.eventCount += 1; snapshot.events.insert(event, at: 0)
            if snapshot.events.count > 200 { snapshot.events.removeLast(snapshot.events.count - 200) }
            onGesture?(event)
            react(interpreter.feed(event))
            if interpreter.hasPending {
                transport.perform(after: GestureInterpreter.settle + 0.005) { [weak self] in
                    guard let self else { return }
                    self.react(self.interpreter.flush(now: ProcessInfo.processInfo.systemUptime))
                }
            }
            publish()
        }
    }
    private func react(_ gestures: [BandGesture]) {
        guard !gestures.isEmpty else { return }
        for gesture in gestures {
            if gesture.isNewGesture { snapshot.gestureTotal += 1 }
            snapshot.lastGesture = gesture
            record("band_gesture", gesture.title)
            onBandGesture?(gesture)
        }
        publish()
    }
    func ownershipCompleted(_ result: Result<PairCompletion, Error>, attempt: UUID) {
        guard attempt == enrollmentAttempt else { return }
        do {
            let completion = try result.get()
            guard let proto else { throw BandError.transport("Enrollment channel closed.") }
            try transport.write(proto.resume(completion))
            protocolProgress()
        } catch { fail(error) }
    }
    private func protocolProgress() {
        updateConnectionProgress()
        let link = proto?.linkNote ?? ""
        let message = "Protocol: \(proto?.stage ?? "closed"); enrollment: \(enrollment?.record.stage ?? "none")\(link.isEmpty ? "" : "; link: " + link)."
        logger.info("\(message, privacy: .public)")
        record("protocol", message)
        publish()
    }
    private func updateConnectionProgress() {
        snapshot.connectionAttempt.observeProtocolStage(proto?.stage)
    }
    func disconnect(_ completion: ((Bool) -> Void)? = nil) {
        if let completion { releaseCompletion = completion }
        if let update { update.abandon(); reportUpdate() }
        snapshot.connectionAttempt.stop()
        setIntent(false); reconnectAt = nil; scanUntil = nil; transport.stopScan(); enrollmentAttempt = nil; meta = nil
        if snapshot.issue != .stillReleasing { snapshot.issue = nil }
        guard snapshot.state != .disconnecting else { return }
        if snapshot.state == .streaming {
            transition(.disconnecting, "Stopping gesture subscription before releasing Bluetooth.")
            do {
                if pendingStreams == nil { try rpc("stop_streams", 5, 4, BandProtocol.stopFlags) }
                stoppingUntil = ProcessInfo.processInfo.systemUptime + 3
                return
            }
            catch { record("shutdown", "Could not request an acknowledged stream stop.") }
        }
        finishDisconnect()
    }
    /// Forgets the band on this phone. Saved credentials stay in the Keychain, so setting
    /// the same band up again does not need another Meta sign-in.
    func forget(_ completion: @escaping () -> Void) {
        disconnect { [weak self] _ in
            guard let self else { return }
            self.snapshot.selected = nil; self.snapshot.devices = []; self.snapshot.battery = nil; self.clearHand()
            self.snapshot.issue = nil; self.snapshot.events = []; self.snapshot.eventCount = 0
            self.snapshot.connectionAttempt = ConnectionAttempt()
            self.snapshot.lastGesture = nil; self.snapshot.gestureTotal = 0
            UserDefaults.standard.removeObject(forKey: "selectedBand")
            self.record("connection", "Band forgotten on this phone; credentials retained.")
            self.transition(.disconnected, "Band forgotten.")
            completion()
        }
    }
    private func finishDisconnect() {
        identityConfirmation.cancel()
        stoppingUntil = nil; proto = nil; enrollment = nil; candidate = nil; candidateAccount = nil; snapshot.startedAt = nil
        transition(.disconnecting, "Closing Bluetooth; waiting for local release confirmation.")
        transport.disconnect()
    }
    private func availability(_ ready: Bool, message: String) {
        available = ready; snapshot.bluetoothReady = ready
        if !ready {
            reconnectAt = nil; proto = nil; transport.close()
            snapshot.issue = transport.isUnauthorized ? .bluetoothDenied : .bluetoothOff
            if snapshot.wantsConnection {
                snapshot.connectionAttempt.begin()
                transition(.reconnecting, message)
            } else { snapshot.message = message; publish() }
        } else {
            if snapshot.issue == .bluetoothOff || snapshot.issue == .bluetoothDenied { snapshot.issue = nil }
            if snapshot.wantsConnection {
                // Bluetooth availability must not replace active connection progress.
                if !userRecoveryRequired, snapshot.state != .connecting { beginConnection() }
            } else { snapshot.message = message; publish() }
        }
    }
    /// The link dropped while the band was wanted. The transport has already left a
    /// pending connect in place (or iOS is reconnecting by itself), so nothing here
    /// depends on a timer that a suspended app could not run.
    private func linkLost(_ systemReconnecting: Bool) {
        update?.linkLost(); reportUpdate()
        proto = nil; sequences.reset(); interpreter.reset(); sessionID = UUID(); handRequested = false
        pendingStreams = nil; activeStreams = nil; resetEMG(); snapshot.startedAt = nil
        if stoppingUntil != nil || snapshot.state == .disconnecting { finishDisconnect(); return }
        guard snapshot.wantsConnection, enrollment == nil else {
            if enrollment != nil { fail(BandError.transport("Band disconnected during setup.")) }
            return
        }
        snapshot.connectionAttempt.begin()
        transition(.reconnecting, systemReconnecting ? "Link lost; iOS is reconnecting automatically." : "Link lost; a pending connect is waiting for the band.")
    }
    /// Notes that the band answered a record under the way in use, so it is kept from now on.
    private func keepLinkWay() {
        guard let proto, proto.linkIsGuess, proto.linkProven, !linkWayProven else { return }
        linkWayProven = true; linkWayTries = 0; linkWaysTried = 0
        UserDefaults.standard.set(linkWay, forKey: "bandLinkWay"); UserDefaults.standard.set(true, forKey: "bandLinkWayProven")
        record("protocol", "The band's records check out. Link: \(proto.linkNote). This way is kept.")
    }

    /// On firmware whose key rules are not written down, a failure before the band has sent
    /// one record that checks out may mean the wrong way was tried. This moves on to the next
    /// way and says whether to connect again at once.
    private func nextLinkWay(after error: BandError) -> Bool {
        keepLinkWay()
        guard let proto, proto.linkIsGuess, !proto.linkProven, !linkWayProven, enrollment == nil, ["encryption", "trust"].contains(proto.stage) else { return false }
        if let better = proto.betterWay {
            linkWay = better; linkWayTries = 0
            record("protocol", "Another way reads what the band sent. Trying way \(better + 1) next.")
        } else {
            linkWayTries += 1
            // A record that fails its check settles it. Otherwise each way gets two tries, since
            // the band can ignore the handshake that follows an abandoned one.
            if case .authentication = error { linkWayTries = 2 }
            if linkWayTries >= 2 { linkWay += 1; linkWayTries = 0 }
        }
        UserDefaults.standard.set(linkWay, forKey: "bandLinkWay")
        linkWaysTried += 1
        return linkWaysTried <= 80
    }

    private func fail(_ error: Error) {
        identityConfirmation.cancel()
        let error = error as? BandError ?? .wire("Band operation failed. Reconnect in the foreground.")
        let searching = nextLinkWay(after: error)
        if snapshot.state != .disconnecting, snapshot.wantsConnection || snapshot.connectionAttempt.outcome == .connecting {
            updateConnectionProgress()
            snapshot.connectionAttempt.fail(error)
        }
        let link = proto.map { $0.linkNote.isEmpty ? "" : " Link: \($0.linkNote)." } ?? ""
        let detail = "\(error.localizedDescription) Protocol: \(proto?.stage ?? "closed"); enrollment: \(enrollment?.record.stage ?? "none").\(link)"
        logger.error("\(detail, privacy: .public)")
        record("error", detail); proto = nil; snapshot.startedAt = nil
        update?.linkLost(); reportUpdate()
        if emgReading || pendingEMG == true {
            // Don't let EMG turn into a reconnect loop: one unexpected failure disables it for this run.
            emgHardBlocked = true; emgStatus("EMG disabled after a connection error while enabling it.")
        }
        resetEMG()
        if stoppingUntil != nil || snapshot.state == .disconnecting { transport.disconnect(); record("shutdown", "Stream stop was not acknowledged."); finishDisconnect(); return }
        let retryTrust = enrollment == nil && !trustRetried && ConnectionRetryPolicy.mayPass(error)
        if retryTrust { trustRetried = true }
        if enrollment != nil || (ConnectionRetryPolicy.stopsAutoConnect(error) && !retryTrust && !searching) {
            // Identity and ownership failures need the person; retrying cannot fix them.
            transport.disconnect()
            userRecoveryRequired = true; reconnectAt = nil; enrollment = nil; meta = nil; enrollmentAttempt = nil
            setIntent(false)
            try? refreshIdentities()
            snapshot.issue = SessionIssue.from(error)
            transition(.failed, detail + " Automatic connection is paused. Saved and pending identities were retained.")
        } else if snapshot.wantsConnection {
            failures += 1
            // While the ways of making keys are being worked through, the next try follows quickly.
            let delay = searching ? 2 : ConnectionRetryPolicy.backoff(failures: failures)
            transport.close()
            reconnectAt = ProcessInfo.processInfo.systemUptime + delay
            if case .storage = error { snapshot.issue = .phoneLocked }
            if ConnectionRetryPolicy.reportsSilence(error, failures: failures) { snapshot.issue = .bandNotResponding }
            transition(.reconnecting, detail + " Retry \(failures) in \(Int(delay)) s; automatic connection stays on.")
        } else {
            transport.disconnect()
            snapshot.issue = SessionIssue.from(error)
            transition(.failed, detail)
        }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let until = stoppingUntil, now >= until { record("shutdown", "Stream stop acknowledgement timed out."); finishDisconnect(); return }
        if let until = scanUntil, now >= until {
            scanUntil = nil; transport.stopScan(); transition(.disconnected, snapshot.devices.isEmpty ? "No bands found. \(transport.scanSummary)" : "Scan finished.")
        }
        if let until = reconnectAt, now >= until, available, snapshot.wantsConnection, !userRecoveryRequired { reconnectAt = nil; beginConnection() }
        if let since = waitingSince, now - since >= Self.notNearbyAfter, snapshot.wantsConnection, snapshot.issue == nil, available, enrollment == nil {
            snapshot.issue = .bandNotNearby; publish()
        }
        do { for signal in try proto?.tick(now: now) ?? [] { try handle(signal, receipt: context()) } }
        catch { fail(error) }
        sendNextPulse()
        if let update, let proto, snapshot.state == .streaming { sendUpdate(update.tick(ids: &proto.requestNumber, now: updateTime())) }
    }

    /// Puts the band in its handwriting state, where its own model reads what the hand writes,
    /// or back in its usual state. Turning it on turns the band's standby off, as the Meta app
    /// does, and turning it off puts the band's own standby time back.
    func setHandwriting(_ on: Bool) {
        guard writingWanted != on else { return }
        guard snapshot.state == .streaming, update == nil, tightnessSince == nil, probe == nil else {
            record("band_writing", "Not changed: the band is busy or not connected."); onWriting?(writingWanted, writing.text, writing.rows); return
        }
        if on, let standby, standby != 0 { UserDefaults.standard.set(Int(standby), forKey: "bandStandbyToRestore") }
        let kept = UInt64(max(0, UserDefaults.standard.integer(forKey: "bandStandbyToRestore")))
        do {
            try rpc("try_writing", 6, 5, BandWriting.state(on: on, standby: kept == 0 ? nil : kept))
            writingWanted = on
            if on { writing = BandWriting.Decoder(); writingMessages = 0; writingShape = ""; checkWriting() } else { lend(Self.writingLoan, false) }
            record("band_writing", on ? "Asked for the handwriting state, standby off." : "Asked for the usual state\(kept == 0 ? "" : ", standby back to \(kept) s").")
            onWriting?(on, writing.text, writing.rows)
        } catch {
            record("band_writing", "Not changed: the band is answering something else. Try again.")
            onWriting?(writingWanted, writing.text, writing.rows)
        }
    }

    /// After the band's settings are read on connecting: handwriting that was on is asked for
    /// again, since a new connection starts in the usual state, and a standby time that
    /// handwriting turned off and never put back is put back.
    private func settleWriting() {
        guard snapshot.state == .streaming, update == nil else { return }
        returnLoans([writingWanted ? nil : Self.writingLoan, trialModelWanted ? nil : Self.modelLoan].compactMap { $0 })
        if writingWanted, !activeWriting, pendingWriting != true {
            writingWanted = false
            setHandwriting(true)
        } else if !writingWanted {
            let kept = UInt64(max(0, UserDefaults.standard.integer(forKey: "bandStandbyToRestore")))
            guard standby == 0, kept != 0 else { return }
            do { try rpc("try_writing", 6, 5, BandWriting.state(on: false, standby: kept)); record("band_writing", "Standby put back to \(kept) s.") } catch {}
        }
    }

    /// Three seconds after handwriting is asked for: a band that still sends no rows of a
    /// hundred scores does not offer the handwriting state, and its data collection settings
    /// are tried.
    private func checkWriting() {
        writingTry += 1
        let attempt = writingTry
        transport.perform(after: 3) { [weak self] in
            guard let self, self.writingTry == attempt, self.writingWanted, self.snapshot.state == .streaming, self.writing.rows == 0 else { return }
            self.record("band_writing", "No handwriting scores from the handwriting state (\(self.writingShape.isEmpty ? "no scores at all" : self.writingShape)). Trying the data collection settings.")
            self.lend(Self.writingLoan, true)
        }
    }

    /// A change to named settings the band keeps, made for a while: the settings by name, the
    /// values they are given, where what they held is saved, and the words for the journal.
    private struct Loan { let key: String, names: [String], values: [UInt64], kind: String, what: String }
    /// Firmware that does not offer the handwriting state can still run its handwriting model
    /// through its data collection, as the public Mac app does.
    private static let writingLoan = Loan(key: "bandCollectionToRestore", names: [BandWriting.collection, BandWriting.model],
                                          values: [1, BandWriting.collectionModel], kind: "band_writing", what: "data collection with the handwriting model")
    /// The setting that looks like what selects the trial gesture model the band lists. No public source confirms it.
    private static let modelLoan = Loan(key: "bandModelToRestore", names: ["load-flash-model"], values: [1], kind: "band_model", what: "load flash model")

    /// Makes the change, or puts back what it replaced. What the settings held is saved before
    /// the first write and put back, last first, when asked or on the next connection if the
    /// app was closed in between. The settings are found by name, which needs the list read
    /// once. `done` hears whether the band now holds what was asked.
    private func lend(_ loan: Loan, _ on: Bool, mayRead: Bool = true, done: ((Bool) -> Void)? = nil) {
        let defaults = UserDefaults.standard
        let kept = (defaults.array(forKey: loan.key) as? [Int]).flatMap { $0.count == loan.names.count ? $0 : nil }
        guard on || kept != nil else { return }
        guard snapshot.state == .streaming, update == nil, afterSettings == nil else { done?(false); return }
        let settings = loan.names.compactMap { settingsByName[$0] }
        guard settings.count == loan.names.count, settings.allSatisfy(\.writable) else {
            guard mayRead, settingRead == nil, settingWrite == nil, tightnessSince == nil, probe == nil else {
                if !mayRead { record(loan.kind, "This firmware does not list the settings for \(loan.what).") }
                done?(false); return
            }
            afterSettingsRead = { [weak self] in self?.lend(loan, on, mayRead: false, done: done) }
            return readNamedSettings()
        }
        if on {
            // A value the band does not list among a setting's choices is not written.
            for (setting, value) in zip(settings, loan.values) {
                if let choices = capabilities[setting.id]?.choices, !choices.isEmpty, !choices.contains(Int64(value)) {
                    record(loan.kind, "This firmware does not offer \(value) for \(setting.name)."); done?(false); return
                }
            }
            let was = settings.map { Int($0.value ?? 0) }
            if kept == nil { defaults.set(was, forKey: loan.key) }
            record(loan.kind, "Asking for \(loan.what). The settings held \(was.map(String.init).joined(separator: ", ")).")
            writeSettings(zip(loan.names, loan.values).map { (name: $0, value: $1) }) { [weak self] held in
                self?.record(loan.kind, held ? "The band took \(loan.what)." : "The band did not take \(loan.what).")
                if held { done?(true) } else { self?.lend(loan, false) { _ in done?(false) } }
            }
        } else if let kept {
            record(loan.kind, "Putting back what \(loan.what) replaced: \(kept.map(String.init).joined(separator: ", ")).")
            writeSettings(zip(loan.names, kept).map { (name: $0, value: UInt64(max(0, $1))) }.reversed()) { [weak self] held in
                if held { defaults.removeObject(forKey: loan.key) }
                self?.record(loan.kind, held ? "The settings are back as they were." : "The settings could not be put back. It is tried again on the next connection.")
                done?(held)
            }
        }
    }

    /// Puts back each change that was left on the band, one after the other.
    private func returnLoans(_ loans: [Loan]) {
        guard let loan = loans.first else { return }
        let rest = Array(loans.dropFirst())
        guard UserDefaults.standard.array(forKey: loan.key) != nil else { return returnLoans(rest) }
        lend(loan, false) { [weak self] _ in self?.returnLoans(rest) }
    }

    /// Turns the band's "load flash model" setting on, to see whether that is what selects
    /// the trial gesture model it lists, or puts the setting back. The band keeps the setting,
    /// so the tests page asks the person first. Two seconds after, the band is asked what it
    /// runs, and gestures are counted by whether the band marks them as from the trial model.
    func setTrialModel(_ on: Bool) {
        func say(_ line: String) { record("band_model", line); onModel?(line, trialModelWanted, modelGestures.usual, modelGestures.trial) }
        guard snapshot.state == .streaming, update == nil, tightnessSince == nil, probe == nil, !writingWanted, afterSettings == nil else {
            return say("Not changed: the band is busy or not connected.")
        }
        guard on || UserDefaults.standard.array(forKey: Self.modelLoan.key) != nil else { trialModelWanted = false; return say("The setting is already as it was.") }
        say(on ? "Turning on load flash model." : "Putting load flash model back.")
        lend(Self.modelLoan, on) { [weak self] held in
            guard let self else { return }
            if held { self.trialModelWanted = on; self.modelGestures = (0, 0) }
            say(held ? (on ? "The band took the setting. Do some gestures." : "The setting is back as it was.") : "The band did not take the change.")
            self.transport.perform(after: 2) { [weak self] in
                guard let self, self.snapshot.state == .streaming else { return }
                do { try self.rpc("try_info", 3, 3) } catch {}
            }
        }
    }

    /// Starts a key install, a trial transfer, a discard or an install on the band. Vibration,
    /// motion streams and the other band tests stay off until it ends. The firmware tests
    /// page asks the person before any of them, and says an install cannot be undone.
    func startUpdate(_ plan: FirmwareUpdate.Plan) {
        guard update == nil else { return }
        guard snapshot.state == .streaming, let proto, tightnessSince == nil, probe == nil, settingRead == nil, settingWrite == nil, pendingStreams == nil, !emgReading else {
            let line = "Not started: the band is busy or not connected."
            record("band_update", line); onUpdate?([line], nil, .failed); return
        }
        let job = FirmwareUpdate(plan)
        update = job; updateShown = nil; updateSeen = ProcessInfo.processInfo.systemUptime
        buzzQueue = []; proto.watchesOther = true
        do { try reconcileStreams() } catch { fail(error); return }
        sendUpdate(job.begin(ids: &proto.requestNumber, now: updateTime()))
    }

    /// Stops the update and has the band discard what it holds.
    func stopUpdate() {
        guard let update else { return }
        if let proto, snapshot.state == .streaming { sendUpdate(update.stop(ids: &proto.requestNumber, now: updateTime())) }
        else { update.abandon(); reportUpdate() }
    }

    /// The band is streaming again after a dropped link, and the update asks it where to pick up.
    private func resumeUpdate() {
        guard let update, let proto else { return }
        proto.watchesOther = true
        updateSeen = ProcessInfo.processInfo.systemUptime
        sendUpdate(update.resume(ids: &proto.requestNumber, now: updateTime()))
    }

    private func updateTime() -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        updateClock += min(max(now - updateSeen, 0), 1); updateSeen = now
        return updateClock
    }

    private func sendUpdate(_ bodies: [Data]) {
        if let proto {
            do { for body in bodies { try transport.write(proto.post(channel: BandTrial.channel, body: body)) } }
            catch { reportUpdate(); fail(error); return }
        }
        reportUpdate()
    }

    /// Passes on what the update wrote, and clears it away once it has ended.
    private func reportUpdate() {
        guard let job = update else { return }
        let lines = job.takeLines(), progress = job.progress
        for line in lines { record("band_update", line) }
        // Progress is passed on in half percent steps, not for every chunk.
        func step(_ progress: FirmwareUpdate.Progress?) -> String { progress.map { "\($0.name) \($0.stage) \($0.sent * 200 / max($0.size, 1))" } ?? "" }
        let moved = step(progress) != step(updateShown)
        if moved { updateShown = progress }
        guard job.done else {
            if !lines.isEmpty || moved { onUpdate?(lines, progress, nil) }
            return
        }
        update = nil; updateShown = nil
        proto?.watchesOther = tightnessSince != nil
        onUpdate?(lines, nil, job.ending)
        // A band told to install is about to restart, so nothing more is asked of it.
        if snapshot.state == .streaming, !job.committed { do { try reconcileStreams() } catch { fail(error) } }
    }
    func exportJournal(_ completion: @escaping (Result<URL, Error>) -> Void) {
        do { if journal == nil { journal = try EventJournal() }; completion(.success(try journal!.export())) }
        catch { snapshot.journalError = "Could not export the journal."; publish(); completion(.failure(BandError.storage("Could not export the journal."))) }
    }
    func clearJournal() {
        do { if journal == nil { journal = try EventJournal() }; try journal?.clear(); snapshot.events = []; snapshot.eventCount = 0; snapshot.journalError = nil; publish() }
        catch { snapshot.journalError = "Could not clear the journal."; publish() }
    }
}
