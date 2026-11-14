import AVFoundation
import SwiftUI
import UIKit

// Capture: make a gesture, say it, and it is written down as an inscription. The screen is
// a shelf of scrolls over an inbox of inscriptions by day, over one control, the circle: hold
// it to record, or tap it to record until the next tap. The band's gesture (a hold by
// default; any gesture or combo in settings) does the same. A scroll's page is the same
// screen narrowed to that scroll, and what is recorded there is kept in it. Apple
// Intelligence names each inscription and files loose ones (CaptureScribe). Pocket mode, in
// settings, keeps the microphone open so the band can record with the phone locked.

struct CaptureScreen: View {
    @ObservedObject var store: CaptureStore
    @Binding var path: [AppRoute]
    /// The scroll whose page this is; nil for the inbox.
    var scrollID: String? = nil
    @State private var showSettings = false
    @State private var editing: ScrollEditor.Mode?
    @State private var confirmUnroll = false
    @State private var appeared = false
    @State private var token = UUID().uuidString
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private var scroll: CaptureScroll? { scrollID.flatMap(store.scroll) }

    var body: some View {
        CaptureView(notes: store.inscriptions(in: scrollID), scrolls: store.scrolls, scroll: scroll, naming: store.naming,
                    controls: store.controls, recordingSince: store.recordingSince, listening: store.listening,
                    releaseEnds: store.endRelease != nil, problem: store.problem, arrived: store.arrived, meter: store.meter,
                    actions: CaptureActions(begin: store.begin, finish: store.finish,
                                            open: { path.append(.note($0)) }, delete: store.delete, resolve: resolve,
                                            openScroll: { path.append(.scroll($0)) }, newScroll: { editing = .new },
                                            move: store.move))
            .page()
            .navigationTitle(scrollID == nil ? "Capture" : "").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if let scroll {
                        Menu {
                            Button { editing = .edit(scroll) } label: { Label { Text("Edit scroll") } icon: { Lucide.pencil.image(size: 18) } }
                            Button(role: .destructive) { confirmUnroll = true } label: { Label { Text("Unroll scroll") } icon: { Lucide.trash2.image(size: 18) } }
                        } label: { LucideIcon(.ellipsis, size: 20).frame(width: 36, height: 36).contentShape(Rectangle()) }
                            .accessibilityLabel("Scroll options")
                    } else {
                        Button { showSettings = true } label: { LucideIcon(.settings, size: 19).frame(width: 36, height: 36) }
                            .accessibilityLabel("Capture settings")
                    }
                }
            }
            .sheet(isPresented: $showSettings) { CaptureSettingsScreen(store: store) }
            .sheet(item: $editing) { mode in
                ScrollEditor(mode: mode, scribe: store.controls.scribe && store.scribeStatus == .ready) { name, rune, purpose in
                    switch mode {
                    case .new: store.addScroll(name: name, rune: rune, purpose: purpose)
                    case .edit(var scroll):
                        scroll.name = name; scroll.rune = rune; scroll.purpose = purpose
                        store.updateScroll(scroll)
                    }
                }
            }
            .confirmationDialog("Unroll \(scroll?.name ?? "this scroll")?", isPresented: $confirmUnroll, titleVisibility: .visible) {
                Button("Unroll scroll", role: .destructive) { if let scrollID { store.deleteScroll(scrollID); dismiss() } }
            } message: { Text("Its inscriptions are kept, loose in Capture.") }
            // The band's gesture belongs to Capture while one of its screens can be seen.
            .onAppear { appeared = true; shown(scenePhase == .active); store.filing = scrollID; store.prepare() }
            .onDisappear {
                appeared = false; shown(false)
                if store.filing == scrollID, scrollID != nil { store.filing = nil }
                if !store.listening, !store.anyVisible { store.finish() }
            }
            .onChange(of: scenePhase) { _, phase in shown(appeared && phase == .active) }
    }

    private func shown(_ on: Bool) { store.setVisible(token, on) }

    private func resolve(_ problem: CaptureStore.Problem) {
        if problem == .denied, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        else { store.dismissProblem() }
    }
}

struct CaptureActions {
    var begin: () -> Void = {}
    var finish: () -> Void = {}
    var open: (String) -> Void = { _ in }
    var delete: (String) -> Void = { _ in }
    var resolve: (CaptureStore.Problem) -> Void = { _ in }
    var openScroll: (String) -> Void = { _ in }
    var newScroll: () -> Void = {}
    var move: (String, String?) -> Void = { _, _ in }
}

/// Capture as values and closures, so previews can show any state.
struct CaptureView: View {
    let notes: [CaptureNote]
    var scrolls: [CaptureScroll] = []
    /// The scroll whose page this is; nil for the inbox.
    var scroll: CaptureScroll? = nil
    var naming: Set<String> = []
    let controls: CaptureControls
    let recordingSince: Date?
    let listening: Bool
    /// True while a recording under way ends when a held finger lets go.
    var releaseEnds = false
    var problem: CaptureStore.Problem? = nil
    var arrived: String? = nil
    @ObservedObject var meter: CaptureMeter
    var actions = CaptureActions()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if listening {
                        PocketStatus(trigger: controls.trigger)
                        Hairline()
                    }
                    if let problem {
                        NoticeCard(sentence: problem.sentence, actionTitle: problem == .denied ? "Open Settings" : "OK") { actions.resolve(problem) }
                            .padding(.top, 16).transition(.opacity)
                    }
                    if let scroll {
                        ScrollHeader(scroll: scroll, count: notes.count).padding(.top, 20)
                        if notes.isEmpty { scrollEmpty(scroll) } else { inbox }
                    } else {
                        if !notes.isEmpty || !scrolls.isEmpty {
                            ScrollShelf(scrolls: scrolls, counts: counts, open: actions.openScroll, new: actions.newScroll)
                                .padding(.top, 24)
                        }
                        if notes.isEmpty { empty } else { inbox }
                    }
                }
                .padding(.horizontal, Metric.gutter).padding(.bottom, 24)
                .animation(.spring(duration: 0.45, bounce: 0.12), value: notes.map(\.id))
                .animation(.spring(duration: 0.45, bounce: 0.12), value: notes.map(\.scroll))
                .animation(.standard, value: problem)
            }
            .scrollBounceBehavior(.basedOnSize)
            Rule(inset: 0)
            RecordDock(recordingSince: recordingSince, trigger: controls.trigger, releaseEnds: releaseEnds, into: scroll?.name, meter: meter,
                       begin: actions.begin, finish: actions.finish)
        }
    }

    private var counts: [String: Int] {
        notes.reduce(into: [:]) { counts, note in if let scroll = note.scroll { counts[scroll, default: 0] += 1 } }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(controls.trigger.holds ? "Hold, speak, let go." : "Say it, and it’s inscribed.").font(.display).tracking(-0.6)
            Text("\(controls.trigger.start) and say what’s on your mind. \(controls.trigger.holds ? "When you let go" : "Do it again"), and Runes inscribes it here on your phone.")
                .font(.bodyText).foregroundStyle(Color.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 36)
        .accessibilityElement(children: .combine)
    }

    private func scrollEmpty(_ scroll: CaptureScroll) -> some View {
        Text("Nothing is kept in \(scroll.name) yet. Record on this page and it’s kept here; inscriptions that belong here are filed as you make them.")
            .font(.bodyText).foregroundStyle(Color.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            .padding(.top, 28)
    }

    private var inbox: some View {
        ForEach(Array(CaptureDay.group(notes).enumerated()), id: \.element.id) { section, day in
            Heading(day.title, count: day.notes.count).padding(.top, section == 0 ? 28 : 36)
            ForEach(Array(day.notes.enumerated()), id: \.element.id) { index, note in
                if index > 0 { Hairline(delay: 0.03 * Double(index)) }
                Button { actions.open(note.id) } label: {
                    NoteRow(note: note, scroll: scroll == nil ? note.scroll.flatMap { id in scrolls.first { $0.id == id } } : nil,
                            naming: naming.contains(note.id))
                }
                    .buttonStyle(PressRow())
                    .contextMenu { moveMenu(note) }
                    .swipeToDelete { actions.delete(note.id) }
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
    }

    @ViewBuilder private func moveMenu(_ note: CaptureNote) -> some View {
        if !scrolls.isEmpty {
            Section("Keep in") {
                ForEach(scrolls) { scroll in
                    Button { actions.move(note.id, scroll.id) } label: {
                        Label { Text(scroll.name) } icon: { if note.scroll == scroll.id { Lucide.check.image(size: 18) } }
                    }
                }
                if note.scroll != nil { Button("Take out of scroll") { actions.move(note.id, nil) } }
            }
        }
        Button(role: .destructive) { actions.delete(note.id) } label: { Label { Text("Delete") } icon: { Lucide.trash2.image(size: 18) } }
    }
}

/// Shown over the inscriptions while pocket mode is on, since the microphone is.
private struct PocketStatus: View {
    let trigger: CaptureTrigger

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                PulseDot()
                Text("Pocket mode is listening").font(.label)
            }
            Text("\(trigger.start) anywhere to record, also with your phone locked. Turn it off in settings.")
                .font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

/// Pocket mode: one switch, and exactly what it does.
private struct PocketRow: View {
    let listening: Bool
    let trigger: CaptureTrigger
    let set: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { listening }, set: set)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if listening { PulseDot().transition(.scale.combined(with: .opacity)) }
                    Text(listening ? "Listening" : "Listen from your pocket").font(.label)
                }
                Text(listening ? "\(trigger.start) anywhere to record, also with your phone locked. The microphone is on; nothing is kept until you do."
                     : "Record from the band with your phone locked. The microphone stays on while this is.")
                    .font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            }
            .animation(.standard, value: listening)
        }
        .toggleStyle(HairlineSwitch())
        .padding(.vertical, 14)
        .sensoryFeedback(.impact(weight: .light), trigger: listening)
    }
}

/// An inscription in the inbox: when, its title and first lines, its shape and length, and
/// in the inbox, the rune of the scroll it is kept in.
private struct NoteRow: View {
    let note: CaptureNote
    /// Its scroll, shown in the inbox; nil on a scroll's own page or while loose.
    var scroll: CaptureScroll?
    var naming = false
    /// Wide enough for "12:45 PM", so every row's words start on one line.
    @ScaledMetric(relativeTo: .caption) private var timeWidth: CGFloat = 58

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(note.at, format: .dateTime.hour().minute())
                .font(.geist(12, .medium, relativeTo: .caption)).monospacedDigit().foregroundStyle(Color.muted)
                .lineLimit(1).frame(width: timeWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if note.hasWords {
                    Text(note.title == nil && naming ? "Naming…" : note.heading)
                        .font(.geist(16, .medium, relativeTo: .headline)).lineLimit(2).multilineTextAlignment(.leading)
                        .foregroundStyle(note.title == nil && naming ? Color.muted : Color.ink)
                        .breathing(naming)
                        .contentTransition(.opacity)
                }
                Text(note.summary).font(.bodyText).lineSpacing(3).lineLimit(note.hasWords ? 2 : 3).multilineTextAlignment(.leading)
                    .foregroundStyle(Color.muted)
                    .breathing(note.state == .transcribing)
                    .contentTransition(.opacity)
                HStack(spacing: 10) {
                    Waveform(peaks: note.peaks, progress: 0, bars: 28).frame(width: 84, height: 12)
                    Text(CaptureRules.clock(note.duration)).font(.caption).monospacedDigit().foregroundStyle(Color.muted)
                    Spacer(minLength: 8)
                    if let scroll {
                        HStack(spacing: 5) {
                            RuneGlyph(rune: scroll.rune, size: 13)
                            Text(scroll.name).font(.caption).lineLimit(1)
                        }
                        .foregroundStyle(Color.muted)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
                    }
                }
                .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 15).contentShape(Rectangle())
        .animation(.standard, value: note.text)
        .animation(.spring(duration: 0.5, bounce: 0.2), value: scroll?.id)
        .animation(.standard, value: note.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(note.at.formatted(date: .omitted, time: .shortened)). \(note.hasWords ? note.heading + ". " : "")\(note.summary)\(scroll.map { ". In \($0.name)" } ?? "")")
        .accessibilityHint("Opens the inscription.")
    }
}

/// A recording as hairline bars, each as tall as that moment was loud. Bars before
/// `progress` are ink; the rest wait in the faint stroke.
struct Waveform: View {
    let peaks: [Float]
    var progress: Double
    var bars = CaptureRules.bars

    var body: some View {
        let heights = CaptureRules.waveform(peaks, bars: bars)
        Canvas { context, size in
            guard !heights.isEmpty else { return }
            let step = size.width / CGFloat(heights.count)
            let width = max(1, min(2, step * 0.45))
            for (index, height) in heights.enumerated() {
                let h = max(width, size.height * CGFloat(height))
                let rect = CGRect(x: CGFloat(index) * step + (step - width) / 2, y: (size.height - h) / 2, width: width, height: h)
                let played = Double(index) + 0.5 <= progress * Double(heights.count)
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(played ? Color.ink : Color.faint))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Recording

/// The circle and what it is doing. Hold it to record and let go to save; a tap starts a
/// recording that the next tap saves. The band's gesture does the same from anywhere on
/// this screen, and the circle shows it.
private struct RecordDock: View {
    let recordingSince: Date?
    let trigger: CaptureTrigger
    /// The recording under way was begun by a hold on the band and ends when it lets go.
    let releaseEnds: Bool
    /// The scroll what is recorded here is kept in.
    var into: String? = nil
    @ObservedObject var meter: CaptureMeter
    let begin: () -> Void
    let finish: () -> Void

    @State private var pressedAt: Date?
    /// True when this press started the recording, rather than landing on one under way.
    @State private var startedHere = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var recording: Bool { recordingSince != nil }

    var body: some View {
        VStack(spacing: 8) {
            status.frame(height: 44)
            ZStack {
                if recording, !reduceMotion {
                    // The voice, as rings: louder speech pushes them further out.
                    ForEach(0..<3, id: \.self) { ring in
                        Circle().stroke(Color.ink, lineWidth: Metric.hairline)
                            .frame(width: 84, height: 84)
                            .scaleEffect(1 + meter.level * (0.1 + 0.1 * Double(ring)) + 0.05 * Double(ring + 1))
                            .opacity(0.5 - 0.14 * Double(ring))
                    }
                    .animation(.spring(duration: 0.18, bounce: 0), value: meter.level)
                    .transition(.opacity)
                }
                Circle().fill(recording ? Color.ink : Color.paper)
                Circle().strokeBorder(Color.ink, lineWidth: Metric.hairline)
                LucideIcon(.mic, size: 28).foregroundStyle(recording ? Color.paper : Color.ink)
            }
            .frame(width: 84, height: 84)
            .scaleEffect(pressedAt != nil && !reduceMotion ? 0.94 : 1)
            .animation(.lively, value: pressedAt != nil)
            .animation(.standard, value: recording)
            .frame(width: 160, height: 128)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressedAt == nil else { return }
                    pressedAt = Date()
                    startedHere = !recording
                    if !recording { begin() }
                }
                .onEnded { _ in
                    let held = Date().timeIntervalSince(pressedAt ?? Date())
                    pressedAt = nil
                    // A press on a recording under way saves it. A quick tap that started
                    // one leaves it running; a hold saves on release.
                    if !startedHere || held >= 0.35 { finish() }
                })
            .sensoryFeedback(trigger: recording) { _, now in now ? .impact(weight: .medium) : .success }
            .accessibilityElement()
            .accessibilityLabel(recording ? "Save recording" : "Record an inscription")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if recording { finish() } else { begin() } }
        }
        .padding(.top, 14).padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var status: some View {
        if let since = recordingSince {
            VStack(spacing: 2) {
                TimelineView(.periodic(from: since, by: 0.25)) { context in
                    Text(CaptureRules.clock(max(0, context.date.timeIntervalSince(since))))
                        .font(.geist(24, .medium, relativeTo: .title2)).monospacedDigit().contentTransition(.numericText())
                }
                Text((pressedAt != nil && startedHere) || releaseEnds ? "Let go to save" : trigger.holds ? "Tap to save" : "Tap, or make the gesture again, to save")
                    .font(.caption).foregroundStyle(Color.muted).contentTransition(.opacity)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
            .accessibilityElement(children: .combine)
        } else {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        ForEach(Array(trigger.steps.enumerated()), id: \.offset) { index, step in
                            if index > 0 { LucideIcon(.chevronRight, size: 9).foregroundStyle(Color.faint) }
                            StepIcon(step: step, size: 16)
                        }
                    }
                    Text(trigger.holds ? "or hold the circle" : "or tap the circle").font(.caption)
                }
                if let into { Text("Kept in \(into)").font(.caption).lineLimit(1) }
            }
            .foregroundStyle(Color.muted)
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(trigger.start), \(trigger.holds ? "or hold the circle" : "or tap the circle")\(into.map { ". Kept in \($0)" } ?? "")")
        }
    }
}

// MARK: An inscription

struct NoteScreen: View {
    @ObservedObject var store: CaptureStore
    let noteID: String
    @State private var text = ""
    @State private var title = ""
    @State private var loaded = false
    @State private var confirmDelete = false
    @StateObject private var player = NotePlayer()
    @FocusState private var editing: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field { case title, text }

    var body: some View {
        Group {
            if let note = store.note(noteID) { content(note) }
            else { Text("This inscription was deleted.").font(.bodyText).foregroundStyle(Color.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .page()
        .navigationTitle("Inscription").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editing != nil {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = nil }.font(.label) }
            } else if let note = store.note(noteID) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if note.hasWords {
                            menuItem("Copy", .copy) { UIPasteboard.general.string = note.text }
                            ShareLink(item: note.text) { Label { Text("Share") } icon: { Lucide.share.image(size: 18) } }
                            if store.controls.scribe, store.scribeStatus == .ready { menuItem("Name it again", .penTool) { store.nameAgain(noteID) } }
                        }
                        if note.state != .transcribing { menuItem("Inscribe it again", .rotateCcw) { store.transcribeAgain(noteID) } }
                        menuItem("Delete", .trash2, role: .destructive) { confirmDelete = true }
                    } label: {
                        LucideIcon(.ellipsis, size: 20).frame(width: 36, height: 36).contentShape(Rectangle())
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .confirmationDialog("Delete this inscription?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete inscription", role: .destructive) { player.stop(); store.delete(noteID); dismiss() }
        } message: { Text("Its recording is deleted too.") }
        .onAppear { if !loaded, let note = store.note(noteID) { text = note.text; title = note.title ?? ""; loaded = true } }
        .onDisappear { player.stop(); save() }
        .onChange(of: editing) { _, now in if now == nil { save() } }
        // Words and a title that arrive while it is open appear, unless they are being edited.
        .onChange(of: store.note(noteID)?.text) { _, new in if let new, editing != .text { text = new } }
        .onChange(of: store.note(noteID)?.title) { _, new in if let new, editing != .title { title = new } }
    }

    private func save() {
        guard store.note(noteID) != nil else { return }
        store.setText(text.trimmingCharacters(in: .whitespacesAndNewlines), for: noteID)
        store.setTitle(title, for: noteID)
    }

    private func content(_ note: CaptureNote) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(store.naming.contains(noteID) ? "Naming…" : note.heading, text: $title, axis: .vertical)
                        .font(.geist(26, .medium, relativeTo: .title)).tracking(-0.5)
                        .focused($editing, equals: .title)
                        .submitLabel(.done)
                        .onChange(of: title) { _, new in
                            // Return ends the title rather than starting a second line.
                            if new.contains("\n") { title = new.replacingOccurrences(of: "\n", with: ""); editing = nil }
                        }
                        .breathing(store.naming.contains(noteID) && title.isEmpty)
                        .accessibilityLabel("Title")
                    Text(note.at.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                        .font(.caption).foregroundStyle(Color.muted)
                }
                ScrollPicker(store: store, note: note)
                VStack(alignment: .leading, spacing: 10) {
                    TextField(note.state == .transcribing ? "Inscribing…" : "No words yet. Type them here.", text: $text, axis: .vertical)
                        .font(.geist(19, relativeTo: .title3)).lineSpacing(6)
                        .focused($editing, equals: .text)
                        .accessibilityLabel("Inscription text")
                    FocusRule(active: editing == .text)
                }
                PlayerBar(player: player, note: note, url: store.url(for: note))
                if note.state == .unavailable, !note.hasWords {
                    Note("This phone couldn’t put the recording into words. The recording is kept; you can type the inscription yourself.")
                } else if note.state == .pending {
                    Note("The words for this inscription are made the next time Runes is open on screen.")
                }
            }
            .padding(.horizontal, Metric.gutter).padding(.top, 16).padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// Which scroll an inscription is kept in, and who put it there. Opens a menu of the scrolls.
private struct ScrollPicker: View {
    @ObservedObject var store: CaptureStore
    let note: CaptureNote
    @State private var making = false

    var body: some View {
        let current = note.scroll.flatMap(store.scroll)
        Menu {
            ForEach(store.scrolls) { scroll in
                Button { store.move(note.id, to: scroll.id) } label: {
                    Label { Text(scroll.name) } icon: { if scroll.id == note.scroll { Lucide.check.image(size: 18) } }
                }
            }
            if current != nil { Button("Take out of scroll") { store.move(note.id, to: nil) } }
            Divider()
            Button { making = true } label: { Label { Text("New scroll…") } icon: { Lucide.plus.image(size: 18) } }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if let current {
                        RuneGlyph(rune: current.rune, size: 18).transition(.scale(scale: 0.6).combined(with: .opacity))
                    } else {
                        Circle().strokeBorder(Color.muted, style: StrokeStyle(lineWidth: Metric.hairline, dash: [2, 3])).frame(width: 18, height: 18)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(current?.name ?? "Loose").font(.label)
                    Text(detail(current)).font(.caption).foregroundStyle(Color.muted)
                }
                Spacer(minLength: 8)
                LucideIcon(.chevronDown, size: 14).foregroundStyle(Color.muted)
            }
            .padding(.vertical, 12).padding(.horizontal, Metric.inset)
            .overlay(RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.rule, lineWidth: Metric.hairline))
            .contentShape(Rectangle())
            .animation(.spring(duration: 0.4, bounce: 0.2), value: note.scroll)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(current.map { "Kept in \($0.name)" } ?? "Loose, in no scroll")
        .accessibilityHint("Chooses a scroll.")
        .sensoryFeedback(.selection, trigger: note.scroll)
        .sheet(isPresented: $making) {
            ScrollEditor(mode: .new, scribe: store.controls.scribe && store.scribeStatus == .ready) { name, rune, purpose in
                let scroll = store.addScroll(name: name, rune: rune, purpose: purpose)
                store.move(note.id, to: scroll.id)
            }
        }
    }

    private func detail(_ scroll: CaptureScroll?) -> String {
        guard scroll != nil else { return store.scrolls.isEmpty ? "Make a scroll to keep inscriptions together" : "In no scroll yet" }
        return note.filed == .scribe ? "Filed by Apple Intelligence" : "Filed by you"
    }
}

/// Play and pause, the recording's shape filling with ink as it plays, and the time.
/// Drag across the shape to move through it.
private struct PlayerBar: View {
    @ObservedObject var player: NotePlayer
    let note: CaptureNote
    let url: URL

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { player.toggle(url) } label: {
                    ZStack {
                        Circle().strokeBorder(Color.ink, lineWidth: Metric.hairline)
                        LucideIcon(player.playing ? .pause : .play, size: 16).offset(x: player.playing ? 0 : 1)
                    }
                    .frame(width: 48, height: 48).contentShape(Circle())
                }
                .buttonStyle(Ripple())
                .accessibilityLabel(player.playing ? "Pause" : "Play recording")
                GeometryReader { geo in
                    Waveform(peaks: note.peaks, progress: player.progress)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            player.seek(url, to: min(1, max(0, value.location.x / max(1, geo.size.width))))
                        })
                }
                .frame(height: 32)
                Text(CaptureRules.clock(player.progress > 0 ? player.progress * note.duration : note.duration))
                    .font(.label).monospacedDigit().foregroundStyle(Color.muted)
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .padding(.vertical, 16)
            Rule(inset: 0)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: player.playing)
    }
}

/// Plays one note's recording.
@MainActor
final class NotePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    /// 0 at the start (or stopped) → 1 at the end.
    @Published private(set) var progress = 0.0
    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private static let holder = "capture.player"

    private func load(_ url: URL) -> AVAudioPlayer? {
        if let player { return player }
        guard let new = try? AVAudioPlayer(contentsOf: url) else { return nil }
        new.delegate = self
        player = new
        return new
    }

    func toggle(_ url: URL) {
        guard let player = load(url) else { return }
        if player.isPlaying { pause(); return }
        guard (try? AudioHub.activate(Self.holder)) != nil, player.play() else { return }
        playing = true
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func seek(_ url: URL, to fraction: Double) {
        guard let player = load(url) else { return }
        player.currentTime = fraction * player.duration
        progress = fraction
    }

    private func pause() {
        player?.pause()
        playing = false
        ticker?.invalidate(); ticker = nil
        AudioHub.release(Self.holder)
    }

    func stop() {
        guard player != nil else { return }
        pause()
        player = nil; progress = 0
    }

    private func tick() {
        guard let player, player.duration > 0 else { return }
        progress = player.currentTime / player.duration
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.pause()
            self.progress = 0
        }
    }
}

// MARK: Settings

struct CaptureSettingsScreen: View {
    @ObservedObject var store: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var clearing = false
    @State private var choosingTrigger = false

    private enum Microphone: String, CaseIterable { case phone = "iPhone", headset = "Headphones" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    Block {
                        PocketRow(listening: store.listening, trigger: store.controls.trigger, set: store.setListening)
                    } header: {
                        Heading("Pocket mode")
                    }
                    if let problem = store.problem, problem != .interrupted {
                        NoticeCard(sentence: problem.sentence, actionTitle: problem == .denied ? "Open Settings" : "OK") {
                            if problem == .denied, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            else { store.dismissProblem() }
                        }
                    }
                    Block {
                        TriggerRow(title: "Record an inscription",
                                   detail: store.controls.trigger.holds ? "Records while you hold, and saves when you let go."
                                                                        : "Starts recording. Make it again to save.",
                                   steps: store.controls.trigger.steps) { choosingTrigger = true }
                    } header: {
                        Heading("Band gesture")
                    } footer: {
                        Note("Any gesture or a combo. While Capture is open or pocket mode is on, it belongs to Capture and mappings that use it are off. To record from every screen without reserving a gesture, give a mapping the “Record a Capture note” action instead.")
                    }
                    Block {
                        Toggle(isOn: Binding(get: { store.controls.scribe }, set: store.setScribe)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Name and file inscriptions").font(.label)
                                Text("Titles each inscription and keeps loose ones in the scroll they belong to. Ones you place yourself stay where you put them.")
                                    .font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(HairlineSwitch())
                        .padding(.vertical, 14)
                    } header: {
                        Heading("Apple Intelligence")
                    } footer: {
                        Note(store.controls.scribe ? store.scribeStatus.sentence : "Inscriptions are named from their first words, and you file them yourself.")
                    }
                    Block {
                        HairlineSegments(selection: Binding(get: { store.controls.headset ? Microphone.headset : .phone },
                                                            set: { store.setHeadset($0 == .headset) }),
                                         options: Microphone.allCases, title: \.rawValue)
                    } header: {
                        Heading("Microphone")
                    } footer: {
                        Note("The iPhone’s microphone leaves music in your headphones at full quality. Headphones hear you better from a pocket, but wireless ones drop to call quality for as long as the microphone is on.")
                    }
                    Block {
                        HairlineSegments(selection: Binding(get: { store.controls.feedback }, set: { store.setFeedback($0) }),
                                         options: CaptureFeedback.allCases, title: \.label)
                    } header: {
                        Heading("Feedback")
                    } footer: {
                        Note(store.controls.feedback == .buzz
                             ? "The phone buzzes once when recording starts and twice when it is saved, three times if it was too short to keep. Away from Runes, a notification says the same."
                             : "A tick when recording starts and a note when it is saved, so you know without looking. In pocket mode these are the only sign: the Lock Screen stays as it is.")
                    }
                    Note("Recordings, their words and their titles stay on this phone. iOS and Apple Intelligence work on the device; nothing is sent anywhere.")
                    if !store.notes.isEmpty {
                        Button("Delete all inscriptions") { clearing = true }.buttonStyle(.quiet)
                            .confirmationDialog("Delete all inscriptions?", isPresented: $clearing, titleVisibility: .visible) {
                                Button("Delete \(store.notes.count == 1 ? "1 inscription" : "\(store.notes.count) inscriptions")", role: .destructive, action: store.deleteAll)
                            } message: { Text("Every inscription and its recording is deleted. Scrolls are kept.") }
                    }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
            }
            .page()
            .navigationTitle("Capture settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
            .sheet(isPresented: $choosingTrigger) { CaptureTriggerSheet(store: store) }
        }
        .tint(Color.ink)
    }
}

/// Chooses the gesture, or builds the combo, that records. One that ends with a finger
/// held records for as long as the hold; anything else starts and, made again, saves.
struct CaptureTriggerSheet: View {
    @ObservedObject var store: CaptureStore

    var body: some View {
        let current = store.controls.trigger
        TriggerSheet(title: "Record an inscription",
                     rules: .gestureOrCombo(CaptureTrigger.singleChoices, next: CaptureTrigger.comboChoices, allowsNone: false),
                     steps: current.steps, intervalMs: current.intervalMs,
                     feed: RunesIOSApp.snapshotName == nil ? .shared : nil,
                     note: { steps in
            CaptureTrigger(steps: steps).holds ? "Ends with a hold: it records while you hold and saves when you let go."
                                               : "Make it to start recording, and again to save."
        }, save: { steps, interval in store.setTrigger(CaptureTrigger(steps: steps, intervalMs: interval)) })
    }
}

#if DEBUG
extension PreviewFixtures {
    static func peaks(_ seed: Int, count: Int = 112) -> [Float] {
        (0..<count).map { i in
            let x = Double(i + seed * 17)
            return Float(max(0.05, abs(sin(x * 0.31) * sin(x * 0.07 + Double(seed))) * (0.5 + 0.5 * abs(sin(x * 0.011)))))
        }
    }
    static var scrolls: [CaptureScroll] {
        [CaptureScroll(id: "scroll-relay", name: "Relay", rune: .raidho, purpose: "The band relay: tests, numbers, who to ask."),
         CaptureScroll(id: "scroll-ideas", name: "Ideas", rune: .kenaz, purpose: "Design ideas for the ring and the app."),
         CaptureScroll(id: "scroll-home", name: "Home", rune: .othala, purpose: "The flat, groceries, bills."),
         CaptureScroll(id: "scroll-body", name: "Training", rune: .uruz)]
    }
    static var notes: [CaptureNote] {
        let now = Date()
        func note(_ minutesAgo: Double, _ seconds: Double, _ text: String, _ state: CaptureNote.State = .done,
                  title: String? = nil, scroll: String? = nil, filed: CaptureNote.Filing? = .scribe) -> CaptureNote {
            CaptureNote(id: "note-\(Int(minutesAgo))", at: now.addingTimeInterval(-minutesAgo * 60), duration: seconds, text: text, state: state, file: "preview.m4a",
                        peaks: peaks(Int(minutesAgo)), title: title, scroll: scroll, filed: scroll == nil ? nil : filed)
        }
        return [
            note(1, 6, "", .transcribing),
            note(34, 11, "Ask Maya whether the relay test can move to Thursday, and send her the locked-phone numbers first.", title: "Move the relay test to Thursday", scroll: "scroll-relay"),
            note(190, 4, "Oat milk, lemons, and the good olive oil.", title: "Oat milk, lemons, olive oil", scroll: "scroll-home"),
            note(60 * 26, 19, "Idea for the ring: let the pods lean toward the finger that tapped, then settle. It should feel like the band noticed you.", title: "Pods lean toward the tapping finger", scroll: "scroll-ideas"),
            note(60 * 27, 8, "Call the landlord about the boiler before Friday.", title: "Call the landlord about the boiler", scroll: "scroll-home", filed: .hand),
            note(60 * 30, 7, "Sunday long run, keep it easy, then stretch the left calf.", title: "Easy long run on Sunday"),
            note(60 * 75, 5, "", .unavailable),
        ]
    }
    @MainActor static func capture(recording: Bool = false, listening: Bool = false, empty: Bool = false, noScrolls: Bool = false, trigger: CaptureTrigger = .standard) -> CaptureStore {
        let store = CaptureStore(preview: empty ? [] : notes, scrolls: empty || noScrolls ? [] : scrolls, naming: empty ? [] : ["note-1800"],
                                 recording: recording ? Date().addingTimeInterval(-7) : nil, listening: listening, level: recording ? 0.7 : 0)
        store.setTrigger(trigger)
        return store
    }
}

#Preview("Capture") { NavigationStack { CaptureScreen(store: PreviewFixtures.capture(), path: .constant([])) } }
#Preview("Capture · recording") { NavigationStack { CaptureScreen(store: PreviewFixtures.capture(recording: true, listening: true), path: .constant([])) } }
#Preview("Capture · empty") { NavigationStack { CaptureScreen(store: PreviewFixtures.capture(empty: true), path: .constant([])) } }
#Preview("Scroll") { NavigationStack { CaptureScreen(store: PreviewFixtures.capture(), path: .constant([]), scrollID: "scroll-home") } }
#Preview("New scroll") { ScrollEditor(mode: .new, scribe: true) { _, _, _ in } }
#Preview("Note") { NavigationStack { NoteScreen(store: PreviewFixtures.capture(), noteID: PreviewFixtures.notes[1].id) } }
#endif

private extension CaptureFeedback {
    var label: String {
        switch self {
        case .sounds: "Sounds"
        case .buzz: "Buzz"
        case .off: "Off"
        }
    }
}
