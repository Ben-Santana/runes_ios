import AVFoundation
import SwiftUI
import UIKit

// Scribe (Capture in code): make the combo, say it, and it is written down as an inscription.
// The screen is the sets, as rune balls, over the loose inscriptions by day; the combo waits
// at the bottom, and a rune rises there while recording. Drag a loose inscription onto a set to
// keep it there. A set's page (SetPage) records into that set. Apple Intelligence names each
// inscription and files loose ones (CaptureScribe). Pocket mode, in settings, keeps the
// microphone open so the band can record with the phone locked.

struct CaptureScreen: View {
    @ObservedObject var store: CaptureStore
    @Binding var path: [AppRoute]
    /// The scroll whose page this is; nil for the inbox.
    var scrollID: String? = nil
    @State private var showSettings = false
    @State private var editing: ScrollEditor.Mode?
    @State private var confirmUnroll = false
    /// A set's page is reading one of its inscriptions, whose own menu takes the set's place.
    @State private var setReading = false
    @State private var appeared = false
    @State private var token = UUID().uuidString
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private var scroll: CaptureScroll? { scrollID.flatMap(store.scroll) }

    var body: some View {
        Group {
            if let scrollID {
                SetPage(store: store, setID: scrollID, reading: $setReading)
            } else {
                CaptureView(notes: store.notes.filter { $0.scroll == nil }, scrolls: store.scrolls, naming: store.naming,
                            controls: store.controls, recordingSince: store.shownSince, listening: store.listening, comboReached: store.comboReached,
                            problem: store.problem, arrived: store.arrived, meter: store.meter,
                            actions: CaptureActions(toggle: { store.toggle() },
                                                    open: { path.append(.note($0)) }, delete: store.delete, resolve: resolve,
                                                    openScroll: { path.append(.scroll($0)) },
                                                    move: store.move))
            }
        }
            .page()
            .navigationTitle(scrollID == nil ? "Scribe" : scroll?.name ?? "").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if scrollID == nil {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Menu {
                            Button { store.toggle() } label: {
                                Label { Text(store.shownSince != nil ? "Save inscription" : "Record an inscription") } icon: { Lucide.mic.image(size: 18) }
                            }
                            Button { editing = .new } label: { Label { Text("New set") } icon: { Lucide.plus.image(size: 18) } }
                        } label: { LucideIcon(.plus, size: 20).frame(width: 36, height: 36).contentShape(Rectangle()) }
                            .accessibilityLabel("New")
                        Button { showSettings = true } label: { LucideIcon(.settings, size: 19).frame(width: 36, height: 36) }
                            .accessibilityLabel("Scribe settings")
                    }
                }
                if let scroll, !setReading {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { editing = .edit(scroll) } label: { Label { Text("Edit set") } icon: { Lucide.pencil.image(size: 18) } }
                            Button(role: .destructive) { confirmUnroll = true } label: { Label { Text("Delete set") } icon: { Lucide.trash2.image(size: 18) } }
                        } label: { LucideIcon(.ellipsis, size: 20).frame(width: 36, height: 36).contentShape(Rectangle()) }
                            .accessibilityLabel("Set options")
                    }
                }
            }
            .sheet(isPresented: $showSettings) { CaptureSettingsScreen(store: store) }
            .sheet(item: $editing) { mode in
                ScrollEditor(mode: mode, scribe: store.controls.scribe && store.scribeStatus == .ready) { name, glyph, purpose in
                    switch mode {
                    case .new: store.addScroll(name: name, glyph: glyph, purpose: purpose)
                    case .edit(var scroll):
                        scroll.name = name; scroll.glyph = glyph; scroll.purpose = purpose
                        store.updateScroll(scroll)
                    }
                }
            }
            .confirmationDialog("Delete \(scroll?.name ?? "this set")?", isPresented: $confirmUnroll, titleVisibility: .visible) {
                Button("Delete set", role: .destructive) { if let scrollID { store.deleteScroll(scrollID); dismiss() } }
            } message: { Text("Its inscriptions are kept, loose in Scribe.") }
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
    var toggle: () -> Void = {}
    var open: (String) -> Void = { _ in }
    var delete: (String) -> Void = { _ in }
    var resolve: (CaptureStore.Problem) -> Void = { _ in }
    var openScroll: (String) -> Void = { _ in }
    var move: (String, String?) -> Void = { _, _ in }
}

/// Capture as values and closures, so previews can show any state.
struct CaptureView: View {
    let notes: [CaptureNote]
    var scrolls: [CaptureScroll] = []
    var naming: Set<String> = []
    let controls: CaptureControls
    let recordingSince: Date?
    let listening: Bool
    var comboReached = 0
    var problem: CaptureStore.Problem? = nil
    var arrived: String? = nil
    @ObservedObject var meter: CaptureMeter
    var actions = CaptureActions()

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let problem {
                        NoticeCard(sentence: problem.sentence, actionTitle: problem == .denied ? "Open Settings" : "OK") { actions.resolve(problem) }
                            .padding(.top, 16).transition(.opacity)
                    }
                    if !scrolls.isEmpty {
                        SetShelf(sets: scrolls, open: actions.openScroll, drop: { actions.move($0, $1) })
                            .padding(.top, 20)
                    }
                    if !notes.isEmpty { inbox } else if scrolls.isEmpty { empty }
                }
                .padding(.horizontal, Metric.gutter).padding(.bottom, 120)
                .animation(.spring(duration: 0.45, bounce: 0.12), value: notes.map(\.id))
                .animation(.spring(duration: 0.45, bounce: 0.12), value: notes.map(\.scroll))
                .animation(.standard, value: problem)
            }
            .scrollBounceBehavior(.basedOnSize)
            ScribeDock(trigger: controls.trigger, recordingSince: recordingSince, meter: meter, reached: comboReached, toggle: actions.toggle)
        }
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

    private var inbox: some View {
        ForEach(Array(CaptureDay.group(notes).enumerated()), id: \.element.id) { section, day in
            Heading(day.title, count: day.notes.count).padding(.top, section == 0 ? 28 : 36)
            ForEach(Array(day.notes.enumerated()), id: \.element.id) { index, note in
                if index > 0 { Hairline(delay: 0.03 * Double(index)) }
                Button { actions.open(note.id) } label: {
                    NoteRow(note: note, scroll: note.scroll.flatMap { id in scrolls.first { $0.id == id } },
                            naming: naming.contains(note.id))
                }
                    .buttonStyle(PressRow())
                    // Lifted, the row keeps rounded corners rather than a square backing.
                    .contentShape(.dragPreview, RoundedRectangle(cornerRadius: Metric.panel))
                    .draggable(note.id) {
                        HStack(spacing: 8) {
                            RuneBallView(rune: note.mark, size: 26)
                            Text(note.heading).font(.label).lineLimit(1)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.paper, in: Capsule())
                        .contentShape(.dragPreview, Capsule())
                    }
                    .swipeToDelete { actions.delete(note.id) }
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
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
                            RuneBallView(rune: scroll.mark, size: 15)
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

/// The bottom of Scribe: the combo that records, as its runes, and while recording, a rune that
/// pops up and swells with the voice. Touching either does what the combo does.
struct ScribeDock: View {
    let trigger: CaptureTrigger
    let recordingSince: Date?
    @ObservedObject var meter: CaptureMeter
    /// Whether the combo shows while nothing is recording.
    var showsCombo = true
    /// How many of the combo's steps have been made: those beads turn over to ink.
    var reached = 0
    let toggle: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            if let since = recordingSince {
                RecordingRune(since: since, meter: meter)
                    .onTapGesture(perform: toggle)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Recording. Save it")
                    .accessibilityAddTraits(.isButton)
                    .transition(.scale(scale: 0.3, anchor: .bottom).combined(with: .opacity))
            } else if showsCombo {
                HStack(spacing: 0) {
                    ForEach(Array(trigger.steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 { Rectangle().fill(Color.ink.opacity(0.55)).frame(width: 12, height: 1.25) }
                        let made = index < reached
                        LivingBall(rune: InscriptionRune(rawValue: step.gesture.rawValue) ?? .tapIndex, size: 32, seed: Double(index), inverted: made)
                            .scaleEffect(made ? 1.12 : 1)
                            .animation(.spring(duration: 0.3, bounce: 0.45), value: made)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.paper, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.rule, lineWidth: Metric.hairline))
                .contentShape(Capsule())
                .onTapGesture(perform: toggle)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Record an inscription: \(trigger.name)")
                .accessibilityAddTraits(.isButton)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 14)
        // Paper rises behind it, so what scrolls underneath doesn't cross the rune.
        .background(alignment: .bottom) {
            if recordingSince != nil || showsCombo {
                LinearGradient(colors: [Color.paper.opacity(0), Color.paper.opacity(0.92), Color.paper], startPoint: .top, endPoint: .bottom)
                    .frame(height: recordingSince != nil ? 330 : 90)
                    .padding(.bottom, -40)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.35), value: recordingSince != nil)
        .sensoryFeedback(trigger: recordingSince != nil) { _, now in now ? .impact(weight: .medium) : .success }
    }
}

/// A large ball that rises while a recording is under way. Ripples leave it in time with the
/// voice, and the runes circle it like words being gathered.
private struct RecordingRune: View {
    let since: Date
    @ObservedObject var meter: CaptureMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let radius = 58.0
    private static let orbit: [InscriptionRune] = [.tapIndex, .music, .swipeUp, .light, .holdMiddle, .time, .rotation, .home, .doubleTapIndex, .air]

    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                Canvas { context, size in draw(&context, size: size, at: timeline.date) }
            }
            .frame(width: 400, height: 300)
            TimelineView(.periodic(from: since, by: 0.25)) { context in
                Text(CaptureRules.clock(max(0, context.date.timeIntervalSince(since))))
                    .font(.geist(17, .medium, relativeTo: .headline)).monospacedDigit().contentTransition(.numericText())
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.rule, lineWidth: Metric.hairline))
        }
        .contentShape(Rectangle())
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, at date: Date) {
        let ink = Color.ink, level = reduceMotion ? 0 : meter.level
        let age = date.timeIntervalSince(since), t = date.timeIntervalSinceReferenceDate
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = Self.radius * (1 + 0.07 * level)
        func circle(_ radius: Double) -> Path { Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)) }

        if !reduceMotion {
            // Ripples, one every 0.55 s and a burst as it starts; louder speech sends them further and darker.
            let period = 0.55, life = 1.7
            let newest = Int(floor(age / period))
            for born in max(0, newest - Int(life / period) - 1)...max(0, newest) {
                let u = (age - Double(born) * period) / life
                guard u >= 0, u < 1 else { continue }
                let eased = 1 - pow(1 - u, 3)
                context.stroke(circle(r + 6 + eased * (55 + 25 * level)), with: .color(ink.opacity((1 - u) * (0.22 + 0.45 * level))), lineWidth: 1.25)
            }
            if age < 0.6 {
                let u = age / 0.6
                context.stroke(circle(r + 80 * (1 - pow(1 - u, 3))), with: .color(ink.opacity(0.6 * (1 - u))), lineWidth: 2)
            }
        }

        // The other runes circle it on a tilted ring, drawn in closer as the voice rises: those
        // on the far side pass behind it.
        func orbiters(front: Bool, _ context: inout GraphicsContext) {
            guard !reduceMotion else { return }
            let count = Self.orbit.count
            let reach = r + 70 - 12 * level + 4 * sin(t * 1.3)
            let arrive = 1 - pow(1 - min(1, age / 0.8), 3)
            for (index, rune) in Self.orbit.enumerated() {
                let angle = t * 0.45 + Double(index) / Double(count) * 2 * .pi
                let depth = sin(angle)
                guard (depth >= 0) == front else { continue }
                let at = CGPoint(x: centre.x + cos(angle) * reach * arrive, y: centre.y + depth * reach * 0.38 * arrive)
                let k = (0.8 + 0.2 * depth) * (0.9 + 0.3 * level)
                let placed = rune.path.applying(CGAffineTransform(translationX: at.x, y: at.y)
                    .rotated(by: sin(t * 0.9 + Double(index)) * 0.4).scaledBy(x: k, y: k).translatedBy(x: -12, y: -12))
                let alpha = (front ? 0.55 + 0.35 * depth + 0.1 * level : 0.15 + 0.15 * (1 + depth)) * arrive
                context.stroke(placed, with: .color(ink.opacity(alpha)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        orbiters(front: false, &context)

        // The ball itself, plain, swelling with the voice.
        let pop = reduceMotion ? 1 : 1 + 2.4 * pow(min(1, age / 0.45) - 1, 3) + 1.4 * pow(min(1, age / 0.45) - 1, 2)
        let ball = circle(r * max(0.01, pop))
        context.fill(ball, with: .color(Color.paper))
        context.stroke(ball, with: .color(ink), lineWidth: 1.25)
        orbiters(front: true, &context)
    }
}

// MARK: An inscription

/// Sharing an inscription's recording, and its words once it has some.
struct ShareChoices: View {
    let store: CaptureStore
    let note: CaptureNote

    var body: some View {
        let url = store.url(for: note)
        if FileManager.default.fileExists(atPath: url.path) {
            ShareLink(item: url, preview: SharePreview(note.heading)) {
                Label { Text("Share audio") } icon: { Lucide.audioWaveform.image(size: 18) }
            }
        }
        if note.hasWords {
            ShareLink(item: note.text, preview: SharePreview(note.heading)) {
                Label { Text("Share text") } icon: { Lucide.share.image(size: 18) }
            }
        }
    }
}

struct NoteScreen: View {
    @ObservedObject var store: CaptureStore
    let noteID: String
    @State private var title = ""
    @State private var loaded = false
    @State private var confirmDelete = false
    @State private var makingSet = false
    @StateObject private var player = NotePlayer()
    @StateObject private var words = InscriptionText()
    @FocusState private var editing: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field { case title }

    var body: some View {
        Group {
            if let note = store.note(noteID) { content(note) }
            else { Text("This inscription was deleted.").font(.bodyText).foregroundStyle(Color.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .page()
        .navigationTitle("Inscription").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editing != nil || words.focused {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = nil; words.resign() }.font(.label) }
            } else if let note = store.note(noteID) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ShareChoices(store: store, note: note)
                        if note.hasWords {
                            menuItem("Copy", .copy) { UIPasteboard.general.string = note.text }
                            if store.controls.scribe, store.scribeStatus == .ready { menuItem("Name it again", .penTool) { store.nameAgain(noteID) } }
                        }
                        if note.state != .transcribing { menuItem("Inscribe it again", .rotateCcw) { store.transcribeAgain(noteID) } }
                        // A loose inscription is put in a set from here; one in a set shows its set on the page.
                        if note.scroll.flatMap(store.scroll) == nil {
                            Menu {
                                SetChoices(store: store, note: note, making: $makingSet)
                            } label: { Label { Text("Add to set") } icon: { Lucide.plus.image(size: 18) } }
                        }
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
        .sheet(isPresented: $makingSet) {
            ScrollEditor(mode: .new, scribe: store.controls.scribe && store.scribeStatus == .ready) { name, glyph, purpose in
                let scroll = store.addScroll(name: name, glyph: glyph, purpose: purpose)
                store.move(noteID, to: scroll.id)
            }
        }
        .onAppear { if !loaded, let note = store.note(noteID) { words.load(note.text, marks: note.marks); title = note.title ?? ""; loaded = true } }
        .onDisappear { player.stop(); save() }
        .onChange(of: editing) { _, now in if now == nil { save() } }
        .onChange(of: words.focused) { _, now in if !now { save() } }
        // While the recording plays (or is paused part way), its words ink as they are said.
        .onChange(of: player.progress) { follow() }
        .onChange(of: player.playing) { follow() }
        // Words and a title that arrive while it is open appear, unless they are being edited.
        .onChange(of: store.note(noteID)?.text) { _, new in
            if let note = store.note(noteID), !words.focused, new != words.saved.text { words.load(note.text, marks: note.marks) }
        }
        .onChange(of: store.note(noteID)?.title) { _, new in if let new, editing != .title { title = new } }
    }

    private func follow() {
        guard let note = store.note(noteID) else { return }
        let on = player.source == store.url(for: note) && (player.playing || player.progress > 0)
        words.follow(on ? player.progress * note.duration : nil, spoken: note.spoken, duration: note.duration)
    }

    private func save() {
        guard store.note(noteID) != nil else { return }
        let saved = words.saved
        store.setText(saved.text, marks: saved.marks, for: noteID)
        store.setTitle(title, for: noteID)
    }

    private func content(_ note: CaptureNote) -> some View {
        GeometryReader { page in
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
                if note.scroll.flatMap(store.scroll) != nil { ScrollPicker(store: store, note: note, making: $makingSet) }
                VStack(alignment: .leading, spacing: 10) {
                    // With no words yet, the rest of the page is the box to type them in.
                    InscriptionTextView(model: words)
                        .overlay(alignment: .topLeading) {
                            if words.isEmpty {
                                Text(note.state == .transcribing ? "Inscribing…" : "No words yet. Type them here.")
                                    .font(.geist(19, relativeTo: .title3)).foregroundStyle(Color.muted)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(maxHeight: words.roomy ? .infinity : nil, alignment: .top)
                        .contentShape(Rectangle())
                        .onTapGesture { words.focus() }
                    FocusRule(active: words.focused)
                }
                .frame(maxHeight: words.roomy ? .infinity : nil, alignment: .top)
                PlayerBar(player: player, note: note, url: store.url(for: note))
                if note.state == .unavailable, !note.hasWords {
                    Note("This phone couldn’t put the recording into words. The recording is kept; you can type the inscription yourself.")
                } else if note.state == .pending {
                    Note("The words for this inscription are made the next time Runes is open on screen.")
                }
            }
            .padding(.horizontal, Metric.gutter).padding(.top, 16).padding(.bottom, 40)
            .frame(minHeight: page.size.height, alignment: .top)
        }
        .scrollDismissesKeyboard(.interactively)
        }
    }
}

/// The sets an inscription can be put in, a way out of its set, and a new one.
private struct SetChoices: View {
    @ObservedObject var store: CaptureStore
    let note: CaptureNote
    @Binding var making: Bool

    var body: some View {
        ForEach(store.scrolls) { scroll in
            Button { store.move(note.id, to: scroll.id) } label: {
                Label { Text(scroll.name) } icon: { if scroll.id == note.scroll { Lucide.check.image(size: 18) } }
            }
        }
        if note.scroll.flatMap(store.scroll) != nil { Button("Take out of set") { store.move(note.id, to: nil) } }
        Divider()
        Button { making = true } label: { Label { Text("New set…") } icon: { Lucide.plus.image(size: 18) } }
    }
}

/// Which scroll an inscription is kept in, and who put it there. Opens a menu of the scrolls.
private struct ScrollPicker: View {
    @ObservedObject var store: CaptureStore
    let note: CaptureNote
    @Binding var making: Bool

    var body: some View {
        let current = note.scroll.flatMap(store.scroll)
        Menu {
            SetChoices(store: store, note: note, making: $making)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if let current {
                        RuneBallView(rune: current.mark, size: 20).transition(.scale(scale: 0.6).combined(with: .opacity))
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
        .accessibilityLabel(current.map { "Kept in \($0.name)" } ?? "Loose, in no set")
        .accessibilityHint("Chooses a set.")
        .sensoryFeedback(.selection, trigger: note.scroll)
    }

    private func detail(_ scroll: CaptureScroll?) -> String {
        guard scroll != nil else { return store.scrolls.isEmpty ? "Make a set to keep inscriptions together" : "In no set yet" }
        return note.filed == .scribe ? "Filed by Apple Intelligence" : "Filed by you"
    }
}

/// Play and pause, the recording's shape filling with ink as it plays, and the time.
/// Drag across the shape to move through it.
struct PlayerBar: View {
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
    /// The recording loaded, until stopped.
    @Published private(set) var source: URL?
    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private static let holder = "capture.player"

    private func load(_ url: URL) -> AVAudioPlayer? {
        if let player { return player }
        guard let new = try? AVAudioPlayer(contentsOf: url) else { return nil }
        new.delegate = self
        player = new
        source = url
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
        player = nil; progress = 0; source = nil
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
                        Note("Any gesture or a spell. While Scribe is open or pocket mode is on, it belongs to Scribe and mappings that use it are off. To record from every screen without reserving a gesture, give a mapping the “Record a Scribe note” action instead.")
                    }
                    Block {
                        Toggle(isOn: Binding(get: { store.controls.scribe }, set: store.setScribe)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Name and file inscriptions").font(.label)
                                Text("Titles each inscription and keeps loose ones in the set they belong to. Ones you place yourself stay where you put them.")
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
                            } message: { Text("Every inscription and its recording is deleted. Sets are kept.") }
                    }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
            }
            .page()
            .navigationTitle("Scribe settings").navigationBarTitleDisplayMode(.inline)
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
        [CaptureScroll(id: "scroll-relay", name: "Relay", rune: .raidho, purpose: "The band relay: tests, numbers, who to ask.", glyph: .voice),
         CaptureScroll(id: "scroll-ideas", name: "Ideas", rune: .kenaz, purpose: "Design ideas for the ring and the app.", glyph: .light),
         CaptureScroll(id: "scroll-home", name: "Home", rune: .othala, purpose: "The flat, groceries, bills.", glyph: .home),
         CaptureScroll(id: "scroll-body", name: "Training", rune: .uruz, glyph: .movement)]
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

    /// The first inscription with no words, or with some of them formatted.
    @MainActor static func formatted(empty: Bool) -> CaptureStore {
        let store = capture()
        let text = empty ? "" : store.note("note-34")?.text ?? ""
        store.setText(text, marks: empty ? nil : [TextMark(start: 0, length: 8, bold: true),
                                                   TextMark(start: 21, length: 10, italic: true, highlight: .yellow),
                                                   TextMark(start: 41, length: 11, bold: true, color: .blue)], for: "note-34")
        return store
    }
}

#Preview("Capture") { NavigationStack { CaptureScreen(store: PreviewFixtures.capture(), path: .constant([])) } }
#Preview("Capture · recording") { NavigationStack { CaptureScreen(store: PreviewFixtures.capture(recording: true, listening: true), path: .constant([])) } }
#Preview("Capture · empty") { NavigationStack { CaptureScreen(store: PreviewFixtures.capture(empty: true), path: .constant([])) } }
#Preview("Set") { NavigationStack { CaptureScreen(store: PreviewFixtures.capture(), path: .constant([]), scrollID: "scroll-home") } }
#Preview("New set") { ScrollEditor(mode: .new, scribe: true) { _, _, _ in } }
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
