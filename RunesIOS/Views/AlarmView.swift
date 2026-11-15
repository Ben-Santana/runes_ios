import SwiftUI

// Alarm: wakes you with the band's motor, silently, so nobody else hears it. Each alarm
// picks a style (gentle to insistent, one with no steady rhythm) and a strength.

struct AlarmScreen: View {
    @ObservedObject var store: AlarmStore
    @State private var editing: Alarm?
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                summary
                Block {
                    ForEach(store.alarms) { alarm in
                        row(alarm)
                        Hairline(inset: 0)
                    }
                    AddRow(title: "New alarm") { editing = Alarm() }
                } header: {
                    Heading("Alarms", count: store.alarms.count)
                } footer: {
                    VStack(alignment: .leading, spacing: 0) {
                        GestureHint(store: store)
                        Note(store.controls.isEmpty
                             ? "Keep Runes open in the background with the band connected overnight. Choose band gestures to snooze or stop in Alarm settings."
                             : "Keep Runes open in the background with the band connected overnight.")
                    }
                }
            }
            .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
        }
        .page()
        .navigationTitle("Alarm").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { alarm in AlarmEditor(store: store, alarm: alarm) }
        .sheet(isPresented: $showSettings) { AlarmSettingsScreen(store: store) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                IconButton(.settings, size: 19) { showSettings = true }.accessibilityLabel("Alarm settings")
            }
        }
        .fullScreenCover(isPresented: .constant(store.ringing != nil)) { AlarmRingingView(store: store) }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            CarvedRune(rune: .dagaz, size: 44).foregroundStyle(store.nextAlarm == nil && store.snoozed == nil ? Color.muted : Color.ink)
                .padding(.bottom, 10)
            if let snoozed = store.snoozed {
                Text("Snoozed until \(snoozed.until.formatted(date: .omitted, time: .shortened))").font(.display).tracking(-0.6)
                Button("Turn off") { store.cancelSnooze() }.buttonStyle(.quiet)
            } else if let next = store.nextAlarm {
                Text(next.at.formatted(date: .omitted, time: .shortened)).font(.display).tracking(-0.6)
                Text("Next alarm, \(next.at.formatted(.relative(presentation: .named)))").font(.bodyText).foregroundStyle(Color.muted)
            } else {
                Text("No alarm set").font(.display).tracking(-0.6)
            }
            if !store.bandReady {
                Text("The band isn’t connected, so it can’t vibrate.").font(.caption).foregroundStyle(Color.destructive)
            }
        }
    }

    private func row(_ alarm: Alarm) -> some View {
        HStack(spacing: 12) {
            Button { editing = alarm } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(alarm.timeText).font(.geist(30, .medium)).monospacedDigit()
                        .foregroundStyle(alarm.enabled ? Color.ink : Color.muted)
                    Text([alarm.label.isEmpty ? nil : alarm.label, alarm.repeatText, alarm.style.title,
                          AlarmStrength.title(alarm.strength)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Color.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("", isOn: Binding(get: { alarm.enabled }, set: { store.setEnabled(alarm.id, $0) }))
                .labelsHidden().toggleStyle(HairlineSwitch())
        }
        .padding(.vertical, 12)
        .contextMenu { Button("Delete", role: .destructive) { store.delete(alarm.id) } }
    }
}

struct AlarmEditor: View {
    @ObservedObject var store: AlarmStore
    @State var alarm: Alarm
    @Environment(\.dismiss) private var dismiss

    private var time: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            alarm.hour = c.hour ?? 7; alarm.minute = c.minute ?? 0
        })
    }

    private var isNew: Bool { !store.alarms.contains { $0.id == alarm.id } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity)
                    Block {
                        days
                        Hairline()
                        TextField("Label", text: $alarm.label).font(.bodyText).padding(.vertical, 14)
                    } header: { Heading("Repeat") }
                    styleBlock
                    strengthBlock
                    Block {
                        Toggle(isOn: $alarm.ramp) { titled("Build up", "Starts two steps softer and climbs a step each minute.") }
                            .toggleStyle(HairlineSwitch()).padding(.vertical, 12)
                        Hairline()
                        Stepper(value: $alarm.snoozeMinutes, in: 0...30) {
                            titled("Snooze", alarm.canSnooze ? "\(alarm.snoozeMinutes) minutes" : "Off: the snooze gesture, or opening the Live Activity, stops it")
                        }
                        .padding(.vertical, 12)
                        Hairline()
                        Toggle(isOn: $alarm.phoneBackup) { titled("Phone backup", "Sounds the phone a minute later if you haven’t snoozed or stopped it.") }
                            .toggleStyle(HairlineSwitch()).padding(.vertical, 12)
                    } header: { Heading("Waking") }
                    if !isNew {
                        Button("Delete alarm") { store.delete(alarm.id); dismiss() }
                            .buttonStyle(.quiet).foregroundStyle(Color.destructive)
                    }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
            }
            .page()
            .navigationTitle(isNew ? "New alarm" : "Edit alarm").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.label) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { alarm.enabled = true; store.save(alarm); dismiss() }.font(.label)
                }
            }
        }
        .tint(Color.ink)
    }

    private func titled(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.bodyText)
            Text(detail).font(.caption).foregroundStyle(Color.muted)
        }
    }

    private var days: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { day in
                let on = alarm.days.contains(day)
                Button {
                    if on { alarm.days.remove(day) } else { alarm.days.insert(day) }
                } label: {
                    Text(symbols[day - 1]).font(.label)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .foregroundStyle(on ? Color.paper : Color.ink)
                        .background(Circle().fill(on ? Color.ink : Color.clear))
                        .overlay(Circle().strokeBorder(Color.rule, lineWidth: Metric.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 12)
        .sensoryFeedback(.selection, trigger: alarm.days)
    }

    private var styleBlock: some View {
        Block {
            ForEach(AlarmStyle.allCases) { style in
                Button {
                    alarm.style = style
                    store.preview(style, strength: alarm.strength)
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(style.title).font(.bodyText)
                            Text(style.detail).font(.caption).foregroundStyle(Color.muted)
                        }
                        Spacer()
                        IntensityDots(value: style.aggression)
                        LucideIcon(.check, size: 16).opacity(alarm.style == style ? 1 : 0)
                    }
                    .padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(alarm.style == style ? .isSelected : [])
                if style != AlarmStyle.allCases.last { Hairline() }
            }
        } header: {
            Heading("Style")
        } footer: {
            Note("Tap a style to feel it on the band. Dots show how insistent it is.")
        }
    }

    private var strengthBlock: some View {
        Block {
            HStack {
                Text(AlarmStrength.title(alarm.strength)).font(.bodyText)
                Spacer()
                Button("Feel it") { store.preview(alarm.style, strength: alarm.strength) }.buttonStyle(.quiet)
            }
            .padding(.top, 12)
            Slider(value: Binding(get: { Double(alarm.strength) }, set: { alarm.strength = Int($0.rounded()) }),
                   in: 1...5, step: 1)
                .padding(.vertical, 8)
                .accessibilityValue(AlarmStrength.title(alarm.strength))
        } header: { Heading("Strength") }
    }
}

private struct IntensityDots: View {
    let value: Int
    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Circle().fill(i <= value ? Color.ink : Color.rule).frame(width: 5, height: 5)
            }
        }
        .accessibilityLabel("Intensity \(value) of 5")
    }
}

/// The band's controls for a ringing alarm, written in the gesture runes; nothing when unset.
private struct GestureHint: View {
    @ObservedObject var store: AlarmStore
    var canSnooze = true

    var body: some View {
        let set = AlarmCommand.allCases.compactMap { c in store.controls.trigger(for: c).flatMap { $0.isValid ? (c, $0) : nil } }
        if !set.isEmpty {
            HStack(spacing: 18) {
                ForEach(set, id: \.0) { command, trigger in
                    HStack(spacing: 6) {
                        HStack(spacing: 2) { ForEach(Array(trigger.steps.enumerated()), id: \.offset) { RuneStep(step: $0.element, size: 16) } }
                            .foregroundStyle(Color.ink)
                        Text(command == .snooze && !canSnooze ? "Stop" : command.title)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(trigger.name) to \(command.title.lowercased())")
                }
            }
            .font(.caption).foregroundStyle(Color.muted).padding(.top, 12)
        }
    }
}

/// While an alarm rings: the time, and one big button. Snooze when the alarm can, else Stop.
struct AlarmRingingView: View {
    @ObservedObject var store: AlarmStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    private var canSnooze: Bool { store.ringing?.canSnooze ?? false }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                CarvedRune(rune: .dagaz, size: 56)
                TimelineView(.everyMinute) { _ in
                    Text(Date().formatted(date: .omitted, time: .shortened))
                        .font(.geist(64, .medium)).monospacedDigit().tracking(-1.5)
                }
                if let alarm = store.ringing {
                    Text(alarm.label.isEmpty ? alarm.style.title : alarm.label).font(.heading).foregroundStyle(Color.muted)
                }
            }
            .padding(.top, 48)

            Button(action: canSnooze ? store.snooze : store.stop) {
                VStack(spacing: 14) {
                    if let steps = store.controls.trigger(for: canSnooze ? .snooze : .stop)?.steps, !steps.isEmpty {
                        HStack(spacing: 4) { ForEach(Array(steps.enumerated()), id: \.offset) { RuneStep(step: $0.element, size: 32) } }
                    } else {
                        LucideIcon(canSnooze ? .bell : .check, size: 32)
                    }
                    Text(canSnooze ? "Snooze" : "Stop").font(.geist(34, .medium)).tracking(-0.8)
                    if let alarm = store.ringing, canSnooze {
                        Text("\(alarm.snoozeMinutes) minutes").font(.label).foregroundStyle(Color.muted)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    Circle().strokeBorder(Color.rule, lineWidth: Metric.hairline)
                        .scaleEffect(breathe ? 1.04 : 0.96)
                    Circle().strokeBorder(Color.ink, lineWidth: 1.5).padding(18)
                }
                .contentShape(Circle())
            }
            .buttonStyle(RingPress())
            .padding(.vertical, 32)
            .sensoryFeedback(.impact, trigger: store.ringing == nil)
            .accessibilityHint(canSnooze ? "Snoozes the alarm" : "Stops the alarm")

            if canSnooze {
                Button("Stop") { store.stop() }.buttonStyle(.secondary)
            }
            GestureHint(store: store, canSnooze: canSnooze)
        }
        .padding(.horizontal, Metric.gutter).padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper.ignoresSafeArea())
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

private struct RingPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.standard, value: configuration.isPressed)
    }
}

/// Which band gesture or combo snoozes and stops an alarm. Both start unset, so nothing
/// on the band touches an alarm until chosen here.
struct AlarmSettingsScreen: View {
    @ObservedObject var store: AlarmStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosing: AlarmCommand?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    Block {
                        ForEach(Array(AlarmCommand.allCases.enumerated()), id: \.element) { index, command in
                            if index > 0 { Hairline(delay: 0.04 * Double(index)) }
                            TriggerRow(title: command.title, detail: command.detail,
                                       steps: store.controls.trigger(for: command)?.steps) { choosing = command }
                        }
                    } header: {
                        Heading("Band gestures")
                    } footer: {
                        Note("A gesture or a combo each, or none. They belong to the alarm only while it rings or is snoozed; the rest of the time your mappings have them.")
                    }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
            }
            .page()
            .navigationTitle("Alarm settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
            .sheet(item: $choosing) { command in
                let current = store.controls.trigger(for: command)
                let others = AlarmCommand.allCases.filter { $0 != command }
                TriggerSheet(title: command.title, caption: command.detail, rules: AlarmControls.rules,
                             steps: current?.steps ?? [], intervalMs: current?.intervalMs ?? ComboRules.defaultTime,
                             taken: Set(others.compactMap(store.controls.gesture)),
                             feed: RunesIOSApp.snapshotName == nil ? .shared : nil,
                             note: { steps in
                    others.first { store.controls.trigger(for: $0)?.steps == steps }.map { "\($0.title) uses this; they’ll swap." }
                }, save: { steps, interval in
                    store.setTrigger(steps.isEmpty ? nil : CommandTrigger(steps: steps, intervalMs: interval), for: command)
                })
            }
        }
        .tint(Color.ink)
    }
}
