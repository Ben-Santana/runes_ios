import Foundation
import UserNotifications

/// Alarms that wake you with the band's motor instead of sound. The app has to be running
/// with the band streaming (the band's notifications keep a locked phone's app awake), so
/// a check runs every few seconds rather than relying on a scheduled system alarm. An
/// optional phone notification covers a band that has dropped off.
///
/// While one rings, the gestures chosen in Alarm settings snooze or stop it (none by default).
@MainActor
final class AlarmStore: ObservableObject {
    static let shared = AlarmStore()

    @Published private(set) var alarms: [Alarm] = []
    @Published private(set) var ringing: Alarm?
    @Published private(set) var snoozed: (alarm: Alarm, until: Date)?
    /// Whether the band can be vibrated right now (set by `SessionController`).
    @Published var bandReady = false
    @Published private(set) var controls = AlarmControls() { didSet { decider.configure(controls.mappings); reserve() } }
    /// Told which gestures the alarm holds: its triggers, only while ringing or snoozed.
    var onReserve: ((Set<GestureKind>) -> Void)? { didSet { reserve() } }
    private let decider = TriggerDecider()
    private let controlsKey = "runes.alarm.controls"

    /// Plays pulses on the band (set by `SessionController`).
    var onBuzz: (([BandPulse], String) -> Void)?
    /// Shows the alarm on the Live Activity; the text lights the Lock Screen (set by `SessionController`).
    var onActivity: ((AlarmActivityState?, LiveAlert?) -> Void)? { didSet { publish() } }

    private let key = "runes.alarms"
    private var lastCheck = Date()
    private var ticker: Timer?
    private var ringTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private static let maxRing: TimeInterval = 15 * 60

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Alarm].self, from: data) { alarms = saved }
        if let data = UserDefaults.standard.data(forKey: controlsKey),
           let saved = try? JSONDecoder().decode(AlarmControls.self, from: data) { controls = saved }
        decider.configure(controls.mappings)
        decider.onFire = { [weak self] id in
            guard let self, let command = self.controls.command(forMapping: id) else { return }
            switch command {
            case .snooze: if self.ringing != nil { self.snooze() }
            case .stop: self.stop()
            }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in AlarmStore.shared.tick() }
        }
        ticker?.tolerance = 1
    }

    var nextAlarm: (alarm: Alarm, at: Date)? {
        let now = Date()
        return alarms.filter(\.enabled).compactMap { a in a.next(after: now).map { (a, $0) } }.min { $0.1 < $1.1 }
    }

    // MARK: Editing

    func save(_ alarm: Alarm) {
        if let i = alarms.firstIndex(where: { $0.id == alarm.id }) { alarms[i] = alarm } else { alarms.append(alarm) }
        alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        persist()
    }

    func delete(_ id: UUID) { alarms.removeAll { $0.id == id }; persist() }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[i].enabled = on; persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(alarms) { UserDefaults.standard.set(data, forKey: key) }
        publish()
        scheduleBackups()
    }

    // MARK: Ringing

    private func tick() {
        let now = Date()
        defer { lastCheck = now }
        guard ringing == nil else { return }
        publish()
        if let s = snoozed, s.until <= now { snoozed = nil; ring(s.alarm); return }
        for alarm in alarms where alarm.enabled {
            guard let due = alarm.next(after: lastCheck), due <= now else { continue }
            // Several minutes late means the app was not running; a stale alarm is worse than none.
            guard now.timeIntervalSince(due) < 5 * 60 else { finish(alarm); continue }
            ring(alarm); return
        }
    }

    func ring(_ alarm: Alarm) {
        previewTask?.cancel()
        ringTask?.cancel()
        ringing = alarm
        publish(LiveAlert(title: alarm.label.isEmpty ? "Alarm" : alarm.label,
                          body: bandLine(alarm) ?? (alarm.canSnooze ? "Open this to snooze or stop." : "Open this to stop.")))
        let started = Date()
        ringTask = Task { [weak self] in
            var round = 0
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(started)
                guard elapsed < Self.maxRing else { self?.stop(); return }
                let level = AlarmStrength.level(step: alarm.strength, ramp: alarm.ramp, elapsed: elapsed)
                self?.onBuzz?(alarm.style.pulses(level: level, round: round), "alarm_\(alarm.style.rawValue)")
                let wait = alarm.style.roundLength(level: level, round: round)
                round += 1
                try? await Task.sleep(for: .milliseconds(Int(wait)))
            }
        }
    }

    func snooze() {
        guard let alarm = ringing else { return }
        guard alarm.canSnooze else { return stop() }
        silence()
        let until = Date().addingTimeInterval(TimeInterval(alarm.snoozeMinutes * 60))
        snoozed = (alarm, until)
        publish()
        if alarm.phoneBackup { addBackup(alarm, at: until.addingTimeInterval(60)) }
        onBuzz?([BandPulse(duration: 60, amplitude: 150)], "alarm_snoozed")
    }

    func stop() {
        let alarm = ringing ?? snoozed?.alarm
        silence()
        snoozed = nil
        if let alarm { finish(alarm) } else { publish() }
        onBuzz?([BandPulse(duration: 60, amplitude: 150, gap: 120), BandPulse(duration: 60, amplitude: 150)], "alarm_stopped")
    }

    func cancelSnooze() {
        let alarm = snoozed?.alarm
        snoozed = nil
        if let alarm { finish(alarm) } else { publish() }
    }

    /// A one-time alarm turns off once it's done; either way the backups are set up afresh.
    private func finish(_ alarm: Alarm) {
        if alarm.days.isEmpty, let i = alarms.firstIndex(where: { $0.id == alarm.id }) { alarms[i].enabled = false }
        persist()
    }

    private func silence() {
        ringTask?.cancel(); ringTask = nil
        if let id = ringing?.id.uuidString {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
        ringing = nil
        publish()
    }

    /// Opened from the Live Activity: an alarm that can't snooze stops there and then.
    func openedFromActivity() {
        if let ringing, !ringing.canSnooze { stop() }
    }

    var activityState: AlarmActivityState? {
        if let alarm = ringing {
            return AlarmActivityState(phase: .ringing, title: Self.title(alarm), at: nil, canSnooze: alarm.canSnooze)
        }
        if let s = snoozed {
            return AlarmActivityState(phase: .snoozed, title: Self.title(s.alarm), at: s.until, canSnooze: true)
        }
        // A set alarm stays off the Live Activity, or it would be there every night.
        return nil
    }

    /// "Double tap index to snooze · Hold middle to stop", from the chosen gestures.
    func bandLine(_ alarm: Alarm) -> String? {
        let parts = AlarmCommand.allCases.compactMap { c -> String? in
            guard let t = controls.trigger(for: c), t.isValid else { return nil }
            return "\(t.name) to \(c == .snooze && !alarm.canSnooze ? "stop" : c.title.lowercased())"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func title(_ alarm: Alarm) -> String { alarm.label.isEmpty ? alarm.style.title : alarm.label }

    private var lastPublished: AlarmActivityState?
    private func publish(_ alert: LiveAlert? = nil) {
        reserve()
        let state = activityState
        guard state != lastPublished || alert != nil else { return }
        lastPublished = state
        onActivity?(state, alert)
    }

    /// Two rounds of a style, so it can be felt while choosing it.
    func preview(_ style: AlarmStyle, strength: Int) {
        previewTask?.cancel()
        guard ringing == nil else { return }
        let level = AlarmStrength.level(strength)
        previewTask = Task { [weak self] in
            for round in 0..<2 {
                guard !Task.isCancelled else { return }
                self?.onBuzz?(style.pulses(level: level, round: round), "alarm_preview")
                try? await Task.sleep(for: .milliseconds(Int(style.roundLength(level: level, round: round))))
            }
        }
    }

    func setTrigger(_ trigger: CommandTrigger?, for command: AlarmCommand) {
        controls.setTrigger(trigger, for: command)
        if let data = try? JSONEncoder().encode(controls) { UserDefaults.standard.set(data, forKey: controlsKey) }
    }

    private var active: Bool { ringing != nil || snoozed != nil }
    private func reserve() { onReserve?(active ? controls.reserved : []) }

    /// Takes a band gesture that is one of the alarm's while it rings or is snoozed.
    func consume(_ gesture: BandGesture) -> Bool {
        guard active, let kind = GestureKind(gesture), controls.reserved.contains(kind) else { return false }
        decider.receive(kind)
        return true
    }

    // MARK: Phone backup

    /// A sounding notification a minute after each alarm, for alarms that ask for one. It is
    /// withdrawn when the alarm is snoozed or stopped first, so it only sounds if the band
    /// didn't wake you.
    private func scheduleBackups() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: alarms.map(\.id.uuidString))
        let now = Date()
        for alarm in alarms where alarm.enabled && alarm.phoneBackup && alarm.id != ringing?.id {
            if let at = alarm.next(after: now) { addBackup(alarm, at: at.addingTimeInterval(60)) }
        }
    }

    private func addBackup(_ alarm: Alarm, at date: Date) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = alarm.label.isEmpty ? "Alarm" : alarm.label
        content.body = "Your band alarm is ringing."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let request = UNNotificationRequest(identifier: alarm.id.uuidString, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { center.add(request) }
        }
    }
}
