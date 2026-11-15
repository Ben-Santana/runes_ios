import SwiftUI

// Capture's sets (stored as scrolls): the shelf of rune balls over the inbox, a set's page, and
// the sheet that makes or edits one. A set is a name, a ball carrying one of the Runes glyphs
// and, optionally, a sentence on what belongs in it, which is what Apple Intelligence reads to
// file inscriptions there. On a set's page its inscriptions hang as beads down the left, each
// carrying a rune drawn for it; the one chosen is read on the right.

extension InscriptionRune {
    /// The glyph in the icons' 24-unit box.
    var path: Path {
        if let gesture { return GestureRune.path(gesture) }
        let dot = { (x: Double, y: Double) in
            "M\(x - 1.25) \(y)a1.25 1.25 0 1 0 2.5 0a1.25 1.25 0 1 0 -2.5 0ZM\(x - 0.5) \(y)a0.5 0.5 0 1 0 1 0a0.5 0.5 0 1 0 -1 0Z"
        }
        switch self {
        case .home: return SVGPath.cached("M5 20V11A7 7 0 0 1 19 11V20" + dot(12, 15))
        case .music: return SVGPath.cached("M12 17.5V5M12 5A4 4 0 0 1 16 9" + dot(10, 17.5))
        case .light: return SVGPath.cached("M8 12a4 4 0 1 0 8 0a4 4 0 1 0 -8 0ZM12 2.5V4.5M12 19.5V21.5M2.5 12H4.5M19.5 12H21.5")
        case .time: return SVGPath.cached("M5 4H19M5 20H19M5 4A7 8 0 0 0 19 4M5 20A7 8 0 0 1 19 20")
        case .voice: return SVGPath.cached("M11.36 7.4A6 6 0 0 1 11.36 16.6M15.28 4.22A11 11 0 0 1 15.28 19.78" + dot(7.5, 12))
        default: return Path()
        }
    }

    var name: String {
        if let gesture { return gesture.name }
        return rawValue.capitalized
    }
}

// MARK: Balls

/// A ball carrying a rune, drawn as the beads are: paper, a hairline, and the rune laid round it.
enum RuneBall {
    /// `yaw` turns it about the upright, `tilt` about the level, `roll` in the page, as it rolls.
    static func draw(_ context: inout GraphicsContext, rune: InscriptionRune, at centre: CGPoint, radius r: Double,
                     yaw: Double = 0, tilt: Double = 0, roll: Double = 0, alpha: Double = 1, inverted: Bool = false) {
        guard r > 0.5 else { return }
        let ink = Color.ink
        let body = Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
        context.fill(body, with: .color((inverted ? Color.ink : Color.paper).opacity(alpha)))
        context.stroke(body, with: .color(ink.opacity(alpha)), lineWidth: 1.25)

        let facing = SIMD3(sin(yaw) * cos(tilt), sin(tilt), cos(yaw) * cos(tilt))
        guard facing.z > 0.05 else { return }
        let turned = rune.path.applying(CGAffineTransform(translationX: 12, y: 12).rotated(by: roll).translatedBy(x: -12, y: -12))
        let k = r * 2 / 24
        let wrapped = RuneSphere.wrap(turned, scale: k, facing: facing, centre: centre, radius: r)
        context.stroke(wrapped, with: .color((inverted ? Color.paper : ink).opacity(0.85 * min(1, facing.z * 2.5) * alpha)),
                       style: StrokeStyle(lineWidth: 1.15 * k, lineCap: .round, lineJoin: .round))
    }
}

struct RuneBallView: View {
    let rune: InscriptionRune
    var size: CGFloat = 24
    var yaw = 0.0, tilt = 0.0, roll = 0.0
    var inverted = false

    var body: some View {
        Canvas { context, canvas in
            RuneBall.draw(&context, rune: rune, at: CGPoint(x: canvas.width / 2, y: canvas.height / 2), radius: min(canvas.width, canvas.height) / 2 - 1,
                          yaw: yaw, tilt: tilt, roll: roll, inverted: inverted)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A ball that turns a little on its own, as if held up to the light.
struct LivingBall: View {
    let rune: InscriptionRune
    var size: CGFloat = 44
    var seed = 0.0
    /// When it started rolling in from the right; nil when it is already in place.
    var arrived: Date? = nil
    var inverted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let roll = 0.85

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let u = arrived.map { min(1, max(0, timeline.date.timeIntervalSince($0) / Self.roll)) } ?? 1
            // Eased out with a little overshoot, so it rocks back as it stops.
            let e = reduceMotion ? 1 : 1 + 2.2 * pow(u - 1, 3) + 1.2 * pow(u - 1, 2)
            let travel = (1 - e) * 420
            let calm = reduceMotion ? 0 : 1.0
            RuneBallView(rune: rune, size: size,
                         yaw: calm * 0.34 * sin(t * 0.62 + seed * 1.7) * e, tilt: calm * 0.2 * sin(t * 0.47 + seed * 2.3) * e,
                         roll: Double(travel) / Double(size / 2), inverted: inverted)
                .offset(x: travel)
        }
        .frame(width: size, height: size)
    }
}

// MARK: Shelf

/// The sets as balls, centred. Up to four sit in one row; more stack in rows of as even a size
/// as they can, the larger ones on top. They roll in from the right when the shelf appears, and
/// turn a little where they rest. Each opens its set.
struct SetShelf: View {
    let sets: [CaptureScroll]
    let open: (String) -> Void
    /// An inscription dropped on a set: its id, and the set's.
    var drop: (String, String) -> Void = { _, _ in }
    @State private var arrivals: [String: Date] = [:]
    @State private var target: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 4) {
                ForEach(Array(Self.rows(sets.count).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(row, id: \.self) { index in
                            let set = sets[index]
                            Button { open(set.id) } label: { ball(set, index) }
                                .buttonStyle(Press())
                                .accessibilityLabel(set.name)
                                .dropDestination(for: String.self) { ids, _ in
                                    for id in ids { drop(id, set.id) }
                                    return !ids.isEmpty
                                } isTargeted: { on in
                                    if on { target = set.id } else if target == set.id { target = nil }
                                }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .animation(.spring(duration: 0.45, bounce: 0.2), value: sets.map(\.id))
            .animation(.spring(duration: 0.35, bounce: 0.4), value: target)
            .sensoryFeedback(.selection, trigger: target)
        }
        .onAppear { arrive(sets.map(\.id)) }
        .onChange(of: sets.map(\.id)) { _, ids in arrive(ids.filter { arrivals[$0] == nil }) }
    }

    /// Indices by row: one row up to four, then the fewest rows of four or less, evened out.
    static func rows(_ count: Int) -> [[Int]] {
        guard count > 0 else { return [] }
        let rows = (count + 3) / 4
        var next = 0
        return (0..<rows).map { row in
            let size = count / rows + (row < count % rows ? 1 : 0)
            defer { next += size }
            return Array(next..<next + size)
        }
    }

    private func arrive(_ ids: [String]) {
        let now = Date()
        for (index, id) in ids.enumerated() where arrivals[id] == nil { arrivals[id] = now.addingTimeInterval(0.1 + 0.09 * Double(index)) }
    }

    private func ball(_ set: CaptureScroll, _ index: Int) -> some View {
        VStack(spacing: 10) {
            LivingBall(rune: set.mark, size: 66, seed: Double(index), arrived: arrivals[set.id] ?? .distantFuture)
                .scaleEffect(target == set.id ? 1.18 : 1)
            Text(set.name).font(.label).lineLimit(1)
        }
        .frame(width: 88).padding(.vertical, 10).contentShape(Rectangle())
    }
}

/// A ball on the shelf gives under the finger.
private struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.4), value: configuration.isPressed)
    }
}

// MARK: A set's page

/// A set's inscriptions hang as beads on a string with their titles beside them, in a light
/// wind. Touch one and it is read in a panel that comes in from the right, while the string steps
/// aside to the left. Swipe the panel up for the next, down for the one before, and to the right to
/// put it away. Hold a bead for what can be done to it, or hold and drag it to rehang it, take it
/// out of the set, or delete it.
struct SetPage: View {
    @ObservedObject var store: CaptureStore
    let setID: String
    @Binding var reading: Bool
    @State private var chosen: String?
    @State private var forward = true
    @State private var atTop = true
    @State private var atBottom = true
    @State private var pull: CGFloat = 0
    @State private var acting: String?
    @State private var deleting: String?
    @State private var moving: String?
    @State private var reruning: NoteRef?
    @State private var lifted: String?
    @State private var over: Zone?
    @State private var zones: [Zone: CGRect] = [:]
    @StateObject private var player = NotePlayer()

    private struct NoteRef: Identifiable { let id: String }
    private enum Zone: Hashable { case out, delete }

    private var notes: [CaptureNote] { store.inscriptions(in: setID) }
    private var zonesTop: CGFloat { zones.values.map(\.minY).min() ?? .infinity }
    private var index: Int? {
        let notes = notes
        guard !notes.isEmpty else { return nil }
        return chosen.flatMap { id in notes.firstIndex { $0.id == id } } ?? 0
    }

    var body: some View {
        let notes = notes, index = index
        ZStack(alignment: .topLeading) {
            InscriptionString(notes: notes, selected: reading ? index : nil, reading: reading, naming: store.naming,
                              add: { store.toggle() },
                              lift: { id in withAnimation(.spring(duration: 0.3, bounce: 0.2)) { lifted = id } },
                              hover: { point in
                                  let zone = zone(at: point)
                                  if zone != over { withAnimation(.spring(duration: 0.25, bounce: 0.2)) { over = zone } }
                              },
                              release: release,
                              reorder: { store.reorder($0, in: setID) },
                              floor: zonesTop) { choose($0, in: notes) }
            if reading, let index { reader(notes, index).transition(.move(edge: .trailing)) }
            ScribeDock(trigger: store.controls.trigger, recordingSince: store.shownSince, meter: store.meter, showsCombo: false) { store.toggle() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .opacity(lifted == nil ? 1 : 0)
            if lifted != nil {
                dropZones
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: index) { _, _ in player.stop() }
        // The one read was deleted or moved away: read its neighbour, or go back to the string.
        .onChange(of: notes.map(\.id)) { old, new in follow(from: old, to: new) }
        .onChange(of: reading) { _, now in if !now { player.stop() } }
        .onDisappear { player.stop(); reading = false }
        // While one is read, a swipe never leaves the set: it puts the panel away instead.
        .background(SwipeBackLock(locked: reading))
        // While one is read, back puts the panel away rather than leaving the set.
        .navigationBarBackButtonHidden(reading)
        .toolbar {
            if reading, let index, notes.indices.contains(index) {
                ToolbarItem(placement: .topBarLeading) {
                    Button { withAnimation(.spring(duration: 0.4, bounce: 0.08)) { reading = false; pull = 0 } } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel("Back to the set")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu { actions(notes[index].id, confirmDelete: true) } label: {
                        LucideIcon(.ellipsis, size: 20).frame(width: 36, height: 36).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Inscription options")
                }
            }
        }
        .confirmationDialog(acting.flatMap { store.note($0)?.heading } ?? "Inscription",
                            isPresented: Binding(get: { acting != nil }, set: { if !$0 { acting = nil } }),
                            titleVisibility: .visible, presenting: acting) { id in
            actions(id, confirmDelete: false)
        }
        .background {
            Color.clear.confirmationDialog("Delete this inscription?",
                                           isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                           titleVisibility: .visible, presenting: deleting) { id in
                Button("Delete inscription", role: .destructive) { player.stop(); store.delete(id) }
            } message: { _ in Text("Its recording is deleted too.") }
        }
        .background {
            Color.clear.confirmationDialog("Move to",
                                           isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }),
                                           titleVisibility: .visible, presenting: moving) { id in
                destinations(id)
            }
        }
        .sheet(item: $reruning) { ref in
            RunePicker(current: store.note(ref.id)?.mark ?? .tapIndex) { store.setGlyph($0, for: ref.id) }
        }
        .sensoryFeedback(.selection, trigger: chosen)
        .sensoryFeedback(.impact(weight: .light), trigger: reading)
        .sensoryFeedback(.impact(weight: .medium), trigger: lifted)
        .sensoryFeedback(.selection, trigger: over)
    }

    /// What can be done to one inscription, from the menu at the top or by holding its bead.
    @ViewBuilder private func actions(_ id: String, confirmDelete: Bool) -> some View {
        Button { reruning = NoteRef(id: id) } label: {
            Label { Text("Change rune") } icon: { Lucide.circleDot.image(size: 18) }
        }
        // The menu at the top opens the sets in place; the hold's sheet asks for them in a second one.
        if confirmDelete {
            Menu { destinations(id) } label: {
                Label { Text("Move to") } icon: { Lucide.arrowRight.image(size: 18) }
            }
        } else {
            Button { moving = id } label: {
                Label { Text("Move to…") } icon: { Lucide.arrowRight.image(size: 18) }
            }
        }
        Button(role: .destructive) {
            if confirmDelete { deleting = id } else { player.stop(); store.delete(id) }
        } label: {
            Label { Text("Delete inscription") } icon: { Lucide.trash2.image(size: 18) }
        }
    }

    /// The other sets an inscription can go to, or out of this one.
    @ViewBuilder private func destinations(_ id: String) -> some View {
        ForEach(store.scrolls.filter { $0.id != setID }) { other in
            Button { store.move(id, to: other.id) } label: {
                Label { Text(other.name) } icon: { Lucide.arrowRight.image(size: 18) }
            }
        }
        Button { store.move(id, to: nil) } label: {
            Label { Text("Take out of set") } icon: { Lucide.x.image(size: 18) }
        }
    }

    /// Where a lifted bead can be let go besides the string: out of the set on the left, deleted on the right.
    private var dropZones: some View {
        HStack(spacing: 12) {
            dropZone(.out, title: "Take out", icon: .x)
            dropZone(.delete, title: "Delete", icon: .trash2)
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.bottom, 12)
    }

    private func dropZone(_ zone: Zone, title: String, icon: Lucide) -> some View {
        let on = over == zone
        return HStack(spacing: 8) {
            LucideIcon(icon, size: 18)
            Text(title).font(.label)
        }
        .foregroundStyle(on ? Color.paper : Color.ink)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Capsule().fill(on ? Color.ink : Color.paper))
        .overlay(Capsule().strokeBorder(Color.ink, style: StrokeStyle(lineWidth: Metric.hairline, dash: on ? [] : [4, 4])))
        .scaleEffect(on ? 1.06 : 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { zones[zone] = $0 }
        .accessibilityHidden(true)
    }

    private func zone(at point: CGPoint) -> Zone? {
        zones.first { $0.value.insetBy(dx: -8, dy: -24).contains(point) }?.key
    }

    /// A held bead let go. Not moved, its actions are offered; over a zone, it goes there. Anywhere
    /// else the string takes it back at its new place.
    private func release(_ id: String, at point: CGPoint, moved: Bool) -> Bool {
        let zone = zone(at: point)
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) { lifted = nil; over = nil }
        if !moved { acting = id; return true }
        switch zone {
        case .out: store.move(id, to: nil); return true
        case .delete: deleting = id; return true
        case nil: return false
        }
    }

    private func reader(_ notes: [CaptureNote], _ index: Int) -> some View {
        let note = notes[index]
        return ZStack(alignment: .topLeading) {
            InscriptionPane(store: store, note: note, place: (index + 1, notes.count),
                            url: store.url(for: note), player: player, atTop: $atTop, atBottom: $atBottom)
                .padding(.leading, 20)
                .id(note.id)
                .transition(.asymmetric(insertion: .move(edge: forward ? .bottom : .top).combined(with: .opacity),
                                        removal: .move(edge: forward ? .top : .bottom).combined(with: .opacity)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(Color.paper)
        .overlay(alignment: .leading) { Rectangle().fill(Color.rule).frame(width: Metric.hairline) }
        .contentShape(Rectangle())
        .offset(x: pull)
        .padding(.leading, InscriptionString.column)
        .simultaneousGesture(DragGesture(minimumDistance: 20)
            .onChanged { drag in
                let dx = drag.translation.width
                if dx > 0, dx > abs(drag.translation.height) * 1.3 { pull = dx } else if pull != 0 { pull = 0 }
            }
            .onEnded { drag in
                let dx = drag.translation.width, dy = drag.translation.height
                if pull > 0 {
                    if dx > 90 || drag.predictedEndTranslation.width > 220 {
                        withAnimation(.spring(duration: 0.4, bounce: 0.08)) { reading = false; pull = 0 }
                    } else {
                        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { pull = 0 }
                    }
                    return
                }
                guard abs(dy) > abs(dx) * 1.3, abs(dy) > 50 || abs(drag.predictedEndTranslation.height) > 140 else { return }
                if dy < 0, atBottom { step(to: index + 1, in: notes) } else if dy > 0, atTop { step(to: index - 1, in: notes) }
            })
    }

    private func follow(from old: [String], to new: [String]) {
        guard let chosen, !new.contains(chosen) else { return }
        let at = old.firstIndex(of: chosen) ?? 0
        withAnimation(.spring(duration: 0.4, bounce: 0.08)) {
            if new.isEmpty { reading = false; self.chosen = nil } else { forward = true; self.chosen = new[min(at, new.count - 1)] }
        }
    }

    private func choose(_ target: Int, in notes: [CaptureNote]) {
        guard notes.indices.contains(target) else { return }
        if reading { step(to: target, in: notes); return }
        chosen = notes[target].id
        withAnimation(.spring(duration: 0.45, bounce: 0.08)) { reading = true }
    }

    private func step(to target: Int, in notes: [CaptureNote]) {
        guard notes.indices.contains(target), target != index else { return }
        forward = target > (index ?? 0)
        withAnimation(.spring(duration: 0.42, bounce: 0.12)) { chosen = notes[target].id }
    }
}

/// Picks the rune an inscription's bead carries.
private struct RunePicker: View {
    let save: (InscriptionRune) -> Void
    @State private var glyph: InscriptionRune
    @Environment(\.dismiss) private var dismiss

    init(current: InscriptionRune, save: @escaping (InscriptionRune) -> Void) {
        self.save = save
        _glyph = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    LivingBall(rune: glyph, size: 72)
                        .id(glyph)
                        .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .opacity))
                    Note(glyph.name).contentTransition(.opacity)
                    GlyphGrid(selection: $glyph)
                }
                .animation(.spring(duration: 0.4, bounce: 0.25), value: glyph)
                .padding(.horizontal, Metric.gutter).padding(.top, 12).padding(.bottom, 32)
            }
            .page()
            .navigationTitle("Rune").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.bodyText) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(glyph); dismiss() }.font(.label) }
            }
        }
        .tint(Color.ink)
        .presentationDetents([.medium, .large])
    }
}

/// One inscription read on its set's page, and changed there: its title and words are edited
/// in place and its recording played.
private struct InscriptionPane: View {
    @ObservedObject var store: CaptureStore
    let note: CaptureNote
    let place: (Int, Int)
    let url: URL
    @ObservedObject var player: NotePlayer
    @Binding var atTop: Bool
    @Binding var atBottom: Bool
    @State private var title = ""
    @State private var text = ""
    @State private var loaded = false
    @State private var writing = false
    @FocusState private var editing: Field?

    private enum Field { case title, text }
    private struct Edges: Equatable { var top: Bool; var bottom: Bool }
    private var naming: Bool { store.naming.contains(note.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(place.0) of \(place.1)").font(.caption).monospacedDigit().foregroundStyle(Color.muted)
                    TextField(naming ? "Naming…" : note.heading, text: $title, axis: .vertical)
                        .font(.geist(26, .medium, relativeTo: .title)).tracking(-0.5)
                        .focused($editing, equals: .title)
                        .submitLabel(.done)
                        .onChange(of: title) { _, new in
                            // Return ends the title rather than starting a second line.
                            if new.contains("\n") { title = new.replacingOccurrences(of: "\n", with: ""); editing = nil }
                        }
                        .breathing(naming && title.isEmpty)
                        .accessibilityLabel("Title")
                    PlayerBar(player: player, note: note, url: url)
                        .padding(.vertical, 6)
                    Text(note.at.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                        .font(.caption).foregroundStyle(Color.muted)
                    VStack(alignment: .leading, spacing: 10) {
                        words
                        FocusRule(active: editing == .text)
                    }
                    .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 24).padding(.trailing, Metric.gutter).padding(.bottom, 120)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Edges.self) { geo in
            Edges(top: geo.contentOffset.y <= -geo.contentInsets.top + 4,
                  bottom: geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height + geo.contentInsets.bottom - 4)
        } action: { _, edges in atTop = edges.top; atBottom = edges.bottom }
        .toolbar {
            if editing != nil {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = nil }.font(.label) }
            }
        }
        .onAppear { if !loaded { title = note.title ?? ""; text = note.text; loaded = true } }
        .onDisappear(perform: save)
        .onChange(of: editing) { _, now in if now == nil { save(); writing = false } }
        // Words and a title that arrive while it is open appear, unless they are being edited.
        .onChange(of: note.text) { _, new in if editing != .text { text = new } }
        .onChange(of: note.title) { _, new in if let new, editing != .title { title = new } }
    }

    /// The words, read as plain text until touched. A long multi-line field would take the page's
    /// swipes for its own scrolling.
    @ViewBuilder private var words: some View {
        let placeholder = note.state == .transcribing ? "Inscribing…" : "No words yet. Type them here."
        if writing {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.geist(19, relativeTo: .title3)).lineSpacing(6)
                .focused($editing, equals: .text)
                .onAppear { editing = .text }
                .accessibilityLabel("Inscription text")
        } else {
            Text(text.isEmpty ? placeholder : text)
                .font(.geist(19, relativeTo: .title3)).lineSpacing(6)
                .foregroundStyle(text.isEmpty ? Color.muted : Color.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { writing = true }
                .breathing(note.state == .transcribing && text.isEmpty)
                .accessibilityLabel("Inscription text")
                .accessibilityValue(text)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Edits the words")
        }
    }

    private func save() {
        guard store.note(note.id) != nil else { return }
        store.setText(text.trimmingCharacters(in: .whitespacesAndNewlines), for: note.id)
        store.setTitle(title, for: note.id)
    }
}

/// A set's inscriptions as beads hung down a string in the set's order, each carrying its rune.
/// While nothing is being read the string hangs nearer the middle with each inscription's title
/// and first words beside its bead, and a light wind crosses it; the beads only drift a little.
/// While one is read it steps aside to the left edge and the air goes still.
struct InscriptionString: View {
    let notes: [CaptureNote]
    let selected: Int?
    let reading: Bool
    var naming: Set<String> = []
    /// Touching the dotted ring an empty set's string ends in.
    var add: () -> Void = {}
    /// A bead held long enough to be lifted.
    var lift: (String) -> Void = { _ in }
    /// Where a lifted bead is, on the screen.
    var hover: (CGPoint) -> Void = { _ in }
    /// A lifted bead let go, where and whether it was moved; true when it was dealt with elsewhere.
    var release: (String, CGPoint, Bool) -> Bool = { _, _, _ in false }
    /// The string's new order after a bead was rehung.
    var reorder: ([String]) -> Void = { _ in }
    /// Where on the screen the page's own drop zones begin; the page doesn't scroll over them.
    var floor: CGFloat = .infinity
    let select: (Int) -> Void
    @State private var dragID: String?
    @State private var dragY = 0.0
    /// Past the string's end a lifted bead comes off it and follows the finger anywhere.
    @State private var popped = false
    @State private var poppedAt = Date.distantPast
    @State private var contentLeft: CGFloat = 0
    @State private var position = ScrollPosition(edge: .top)
    @State private var scroll = ScrollGeometry?.none
    @State private var frame = CGRect.zero
    @State private var edging: Task<Void, Never>?
    @State private var zonesTop: CGFloat = .infinity
    @State private var dragMoved = false
    @State private var dragPoint = CGPoint.zero
    @State private var target = 0
    @State private var contentTop: CGFloat = 0
    @State private var since = Date()
    @State private var chosenAt = Date.distantPast
    @State private var movedAt = Date.distantPast
    @State private var width: CGFloat = 0
    @State private var viewport: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How wide the string's column is while one is read.
    static let column: CGFloat = 92
    private static let radius = 22.0, gap = 30.0, lead = 36.0
    private static var pitch: Double { 2 * radius + gap }
    /// Room under the last bead, so it can be scrolled up past the record button.
    private static let foot = 130.0
    private static let move = 0.5

    private var height: Double { Self.lead + Double(notes.count + 1) * Self.pitch + Self.foot }
    /// The beads in the order they hang now: while one is lifted, the rest make room where it would go.
    private var shown: [CaptureNote] {
        guard let dragID, let lifted = notes.first(where: { $0.id == dragID }) else { return notes }
        var rest = notes.filter { $0.id != dragID }
        rest.insert(lifted, at: min(max(0, target), rest.count))
        return rest
    }
    private var selectedID: String? { selected.flatMap { notes.indices.contains($0) ? notes[$0].id : nil } }
    /// Where the string hangs across the page in each mode.
    private func hang(_ width: Double, reading: Bool) -> Double { reading ? Double(Self.column) / 2 : max(Double(Self.column) / 2, width * 0.24) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    TimelineView(.animation(paused: reduceMotion)) { timeline in
                        Canvas { context, size in draw(&context, size: size, at: timeline.date) }
                    }
                    .frame(height: max(height, Double(viewport)))
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: Self.lead)
                        ForEach(shown) { note in
                            row(note)
                                .onTapGesture { if let index = notes.firstIndex(where: { $0.id == note.id }) { select(index) } }
                                .gesture(BeadHold(began: { began(note.id) }, changed: { moved($0, by: $1) }, ended: { point in
                                    if let point { dragPoint = point } else { dragMoved = true }
                                    letGo(note.id)
                                }))
                                .id(note.id)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(note.heading). \(note.summary)")
                                .accessibilityAddTraits(selectedID == note.id ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction { if let index = notes.firstIndex(where: { $0.id == note.id }) { select(index) } }
                        }
                        Button(action: add) {
                            Color.clear.frame(width: 2 * Self.radius + 20, height: Self.pitch).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, max(0, hang(Double(width), reading: reading) - Self.radius - 10))
                        .animation(.spring(duration: Self.move, bounce: 0.08), value: reading)
                        .accessibilityLabel("Record an inscription in this set")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin in
                    contentTop = origin.y; contentLeft = origin.x
                    follow()
                }
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geo in scroll = geo }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .scrollIndicators(.hidden)
            .scrollDisabled(dragID != nil)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
            .onChange(of: selected) { _, index in
                chosenAt = Date()
                guard let index, notes.indices.contains(index) else { return }
                withAnimation(.spring(duration: 0.5, bounce: 0.1)) { proxy.scrollTo(notes[index].id, anchor: .center) }
            }
            .onChange(of: reading) { _, _ in movedAt = Date() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: notes.count)
        .sensoryFeedback(.selection, trigger: dragID == nil ? -1 : target)
        .sensoryFeedback(.impact(weight: .light), trigger: popped)
        .animation(.easeOut(duration: 0.15), value: popped)
        .onChange(of: floor, initial: true) { _, now in zonesTop = now }
    }

    /// Hold a bead to lift it; drag it along the string to rehang it, or off to the page's zones.
    private func began(_ id: String) {
        target = notes.firstIndex { $0.id == id } ?? 0
        dragMoved = false
        dragY = Self.lead + Double(target) * Self.pitch + Self.pitch / 2
        popped = false
        dragID = id
        lift(id)
        edging?.cancel()
        edging = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                let now = Date()
                edge(by: now.timeIntervalSince(last))
                last = now
            }
        }
    }

    private func moved(_ point: CGPoint, by translation: CGSize) {
        guard dragID != nil else { return }
        if hypot(translation.width, translation.height) > 8 { dragMoved = true }
        dragPoint = point
        follow()
        hover(point)
    }

    /// Puts the lifted bead under the finger, which stays put on the screen while the page scrolls under it.
    private func follow() {
        guard dragID != nil else { return }
        dragY = Double(dragPoint.y - contentTop)
        // It comes off a little past the string's end and goes back on a little above it.
        let end = Self.lead + Double(notes.count) * Self.pitch
        let off = popped ? dragY > end - Self.pitch * 0.3 : dragY > end + Self.pitch * 0.2
        if off != popped { popped = off; poppedAt = Date() }
        let slot = Int(((dragY - Self.lead) / Self.pitch).rounded(.down))
        let next = min(max(0, slot), max(0, notes.count - 1))
        if next != target { withAnimation(.spring(duration: 0.3, bounce: 0.15)) { target = next } }
    }

    /// Near the top or bottom of the page, a held bead scrolls it, faster the nearer the edge.
    private func edge(by dt: Double) {
        guard dragID != nil, dragMoved, let scroll, dt > 0 else { return }
        let band = 150.0, fastest = 1300.0
        let top = Double(frame.minY), bottom = Double(min(frame.maxY, zonesTop))
        let y = Double(dragPoint.y)
        var speed = 0.0
        if y > bottom - band, y <= bottom { speed = fastest * pow((y - (bottom - band)) / band, 2) }
        if y < top + band { speed = -fastest * pow(min(1, (top + band - y) / band), 2) }
        guard speed != 0 else { return }
        let lowest = -Double(scroll.contentInsets.top)
        let highest = max(lowest, Double(scroll.contentSize.height - scroll.containerSize.height - scroll.contentInsets.top))
        let now = Double(scroll.contentOffset.y)
        let next = min(highest, max(lowest, now + speed * dt))
        guard abs(next - now) > 0.1 else { return }
        position.scrollTo(y: next + Double(scroll.contentInsets.top))
    }

    /// The finger lifted from a held bead.
    private func letGo(_ id: String) {
        guard dragID == id else { return }
        edging?.cancel(); edging = nil
        popped = false
        let order = shown.map(\.id), moved = dragMoved
        let taken = release(id, dragPoint, moved)
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
            if !taken, moved, order != notes.map(\.id) { reorder(order) }
            dragID = nil
        }
    }

    /// A bead's place to touch and, beside it, its title and first words.
    private func row(_ note: CaptureNote) -> some View {
        let x = hang(Double(width), reading: reading)
        return HStack(spacing: 14) {
            Color.clear.frame(width: 2 * Self.radius + 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title == nil && naming.contains(note.id) ? "Naming…" : note.heading)
                    .font(.label).foregroundStyle(Color.ink).lineLimit(1)
                Text(note.summary).font(.caption).foregroundStyle(Color.muted).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(reading ? 0 : dragID == note.id ? (popped ? 0 : 0.35) : 1)
            .offset(x: reading ? 24 : 0)
        }
        .padding(.leading, max(0, x - Self.radius - 8))
        .padding(.trailing, Metric.gutter)
        .frame(width: reading ? Self.column : max(width, Self.column), height: Self.pitch, alignment: .leading)
        .contentShape(Rectangle())
        .animation(.spring(duration: Self.move, bounce: 0.08), value: reading)
    }

    private static func ease(_ u: Double) -> Double { let u = min(1, max(0, u)); return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2 }

    private func draw(_ context: inout GraphicsContext, size: CGSize, at date: Date) {
        let ink = Color.ink, r = Self.radius
        let t = date.timeIntervalSinceReferenceDate, age = date.timeIntervalSince(since)
        let still = reduceMotion
        // How far the string has gone over to reading: 0 hung in the middle, 1 at the edge.
        let shift = still ? 1.0 : Self.ease(date.timeIntervalSince(movedAt) / Self.move)
        let side = reading ? shift : 1 - shift
        let x = hang(size.width, reading: false) + (hang(size.width, reading: true) - hang(size.width, reading: false)) * side
        let breeze = 1 - side

        if !still, breeze > 0.01 { drawWind(&context, size: size, t: t, fade: breeze) }

        // Each bead drops onto the string in turn when the page opens.
        func grown(_ index: Int) -> Double {
            if still { return 1 }
            let u = min(1, max(0, (age - 0.05 * Double(min(index, 12))) / 0.4))
            return 1 + 2.4 * pow(u - 1, 3) + 1.4 * pow(u - 1, 2)
        }
        let gust = max(0, sin(t * 0.31) + sin(t * 0.53 + 1.7) - 0.9)
        let notes = shown
        var centres: [CGPoint] = notes.indices.map { index in
            let depth = min(1, Double(index + 1) / 3)
            let sway = still ? 0 : (1.6 + 2.2 * breeze * (1 + gust)) * sin(t * 0.55 - Double(index) * 0.45) * depth
            let drop = (1 - min(1, grown(index))) * -18
            return CGPoint(x: x + sway, y: Self.lead + Double(index) * Self.pitch + Self.pitch / 2 + drop)
        }

        // A lifted bead follows the finger, off the string.
        let liftedAt = dragID.flatMap { id in notes.firstIndex { $0.id == id } }
        let stringCentres = centres.enumerated().filter { $0.offset != liftedAt }.map(\.element)
        if let liftedAt {
            // On the string it rides beside it; off, it goes quickly to the finger.
            let u = still ? 1 : Self.ease(date.timeIntervalSince(poppedAt) / 0.18)
            let off = popped ? u : 1 - u
            let free = Double(dragPoint.x - contentLeft)
            centres[liftedAt] = CGPoint(x: x + 14 + (free - x - 14) * off, y: dragY)
        }
        let reach = still ? 1 : min(1, age / 0.5)
        // The string ends in a dotted ring, below the last bead, that records the next one.
        let ringR: Double = notes.isEmpty ? r : r * 0.72
        let slot: Double = Double(notes.count - (popped && liftedAt != nil ? 1 : 0)) * Self.pitch
        let lift: Double = notes.isEmpty ? 0 : 6
        let ringX: Double = stringCentres.last.map { Double($0.x) } ?? Double(x)
        let ringY: Double = Self.lead + slot + Self.pitch / 2 - lift
        let ring = CGPoint(x: ringX, y: ringY)
        var points: [CGPoint] = [CGPoint(x: x, y: -6)]
        points.append(contentsOf: stringCentres)
        points.append(CGPoint(x: ring.x, y: ring.y - ringR))
        for index in 0..<(points.count - 1) {
            var line = Path()
            line.move(to: points[index]); line.addLine(to: points[index + 1])
            let shade: GraphicsContext.Shading = index == 0
                ? .linearGradient(Gradient(colors: [ink.opacity(0), ink.opacity(0.55)]), startPoint: points[0], endPoint: points[1])
                : .color(ink.opacity(0.55))
            context.stroke(line.trimmedPath(from: 0, to: reach), with: shade, style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
        }
        let circle = Path(ellipseIn: CGRect(x: ring.x - ringR, y: ring.y - ringR, width: 2 * ringR, height: 2 * ringR))
        context.fill(circle, with: .color(Color.paper))
        context.stroke(circle, with: .color(ink.opacity(reach)), style: StrokeStyle(lineWidth: 1.25, dash: [3, 3.5], dashPhase: still ? 0 : -t * 5))
        var plus = Path()
        let arm = ringR * 0.38
        plus.move(to: CGPoint(x: ring.x - arm, y: ring.y)); plus.addLine(to: CGPoint(x: ring.x + arm, y: ring.y))
        plus.move(to: CGPoint(x: ring.x, y: ring.y - arm)); plus.addLine(to: CGPoint(x: ring.x, y: ring.y + arm))
        context.stroke(plus, with: .color(ink.opacity(reach)), style: StrokeStyle(lineWidth: 1.25, lineCap: .round))

        let spin = min(1, max(0, date.timeIntervalSince(chosenAt) / 0.55))
        let settle = still ? 1 : 1 + 2.4 * pow(min(1, date.timeIntervalSince(chosenAt) / 0.3) - 1, 3) + 1.4 * pow(min(1, date.timeIntervalSince(chosenAt) / 0.3) - 1, 2)
        // The lifted bead is drawn last, over the rest.
        let drawOrder = notes.indices.filter { $0 != liftedAt } + (liftedAt.map { [$0] } ?? [])
        for index in drawOrder {
            let note = notes[index]
            let centre = centres[index], scale = grown(index)
            let on = selectedID == note.id
            let up = liftedAt == index
            var yaw = still ? 0 : (0.22 + 0.12 * breeze) * sin(t * 0.7 + Double(index) * 1.9)
            // The bead just chosen turns right round on the string.
            if on, !still, spin < 1 { yaw += Self.ease(spin) * 2 * .pi }
            RuneBall.draw(&context, rune: note.mark, at: centre, radius: r * scale * (up ? 1.18 : on ? 1.06 : 1), yaw: yaw, alpha: min(1, scale))
            if on {
                let ring = r * 1.06 + 13 - 6 * settle
                context.stroke(Path(ellipseIn: CGRect(x: centre.x - ring, y: centre.y - ring, width: 2 * ring, height: 2 * ring)),
                               with: .color(ink.opacity(min(1, settle))), lineWidth: 1.25)
            }
        }
    }

    /// Wind lines and leaves crossing the page from the left, a few to every screenful.
    private func drawWind(_ context: inout GraphicsContext, size: CGSize, t: Double, fade: Double) {
        let width = size.width, span = width + 120
        let count = max(5, Int(size.height / 140))
        for mote in 0..<count {
            let seed = Double(mote) * 7.31
            let leaf = mote % 3 == 0
            let speed = (leaf ? 26 : 44) + 22 * (0.5 + 0.5 * sin(seed * 3.1))
            let across = (t * speed + seed * 97).truncatingRemainder(dividingBy: span) - 60
            let lane = (0.5 + 0.5 * sin(seed * 12.9898)) * (size.height - 40) + 20
            let edge = sin(.pi * min(1, max(0, (across + 40) / (width + 80))))
            let alpha = edge * fade
            guard alpha > 0.01 else { continue }
            if leaf {
                let y = lane + 10 * sin(t * 0.9 + seed)
                let length = 7 + 3 * (0.5 + 0.5 * sin(seed * 5.7))
                let turn = seed + t * 1.3 + 0.8 * sin(t * 2.1 + seed)
                let flat = max(0.18, abs(cos(t * 1.7 + seed)))
                var shape = Path()
                shape.move(to: CGPoint(x: -length / 2, y: 0))
                shape.addQuadCurve(to: CGPoint(x: length / 2, y: 0), control: CGPoint(x: 0, y: -length * 0.45))
                shape.addQuadCurve(to: CGPoint(x: -length / 2, y: 0), control: CGPoint(x: 0, y: length * 0.45))
                shape.move(to: CGPoint(x: -length * 0.8, y: 0)); shape.addLine(to: CGPoint(x: length / 2, y: 0))
                let placed = CGAffineTransform(translationX: across, y: y).rotated(by: turn).scaledBy(x: 1, y: flat)
                context.stroke(shape.applying(placed), with: .color(Color.muted.opacity(0.7 * alpha)),
                               style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
            } else {
                let length = 18 + 22 * (0.5 + 0.5 * sin(seed * 2.3))
                var line = Path()
                for piece in 0...10 {
                    let along = Double(piece) / 10
                    let point = CGPoint(x: across - length * (1 - along), y: lane + 2.2 * sin(along * 4 + t * 2.4 + seed))
                    if piece == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                context.stroke(line, with: .color(Color.muted.opacity(0.35 * alpha)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
        }
    }
}

// MARK: Making and editing

/// Makes a set, or edits one: its name, what belongs in it, and the rune on its ball.
struct ScrollEditor: View {
    enum Mode: Identifiable {
        case new
        case edit(CaptureScroll)
        var id: String { if case .edit(let scroll) = self { scroll.id } else { "new" } }
    }

    let mode: Mode
    /// Apple Intelligence files inscriptions by what goes in it.
    var scribe = false
    let save: (String, InscriptionRune, String) -> Void

    @State private var name: String
    @State private var purpose: String
    @State private var glyph: InscriptionRune
    @FocusState private var field: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field { case name, purpose }

    init(mode: Mode, scribe: Bool = false, save: @escaping (String, InscriptionRune, String) -> Void) {
        self.mode = mode; self.scribe = scribe; self.save = save
        switch mode {
        case .new:
            _name = State(initialValue: ""); _purpose = State(initialValue: "")
            _glyph = State(initialValue: InscriptionRune.allCases.randomElement() ?? .tapIndex)
        case .edit(let scroll):
            _name = State(initialValue: scroll.name); _purpose = State(initialValue: scroll.purpose); _glyph = State(initialValue: scroll.mark)
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isNew: Bool { if case .new = mode { true } else { false } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    HStack(alignment: .center, spacing: 18) {
                        LivingBall(rune: glyph, size: 64)
                            .id(glyph)
                            .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .opacity))
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Name", text: $name)
                                .font(.geist(26, .medium, relativeTo: .title)).tracking(-0.5)
                                .focused($field, equals: .name)
                                .submitLabel(.next).onSubmit { field = .purpose }
                                .accessibilityLabel("Set name")
                            FocusRule(active: field == .name)
                        }
                    }
                    .animation(.spring(duration: 0.4, bounce: 0.25), value: glyph)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What goes in it").font(.label)
                        TextField("Work plans, meetings, the relay test", text: $purpose, axis: .vertical)
                            .font(.bodyText).lineSpacing(3)
                            .focused($field, equals: .purpose)
                        FocusRule(active: field == .purpose)
                        Note(scribe ? "Optional. Apple Intelligence reads this to decide which inscriptions belong here."
                                    : "Optional. A reminder of what this set is for.")
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Heading("Rune")
                        GlyphGrid(selection: $glyph).padding(.top, 8)
                        Note(glyph.name).contentTransition(.opacity).animation(.standard, value: glyph)
                    }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 12).padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .page()
            .navigationTitle(isNew ? "New set" : "Edit set").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.bodyText) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Make" : "Save") {
                        save(trimmed, glyph, purpose)
                        dismiss()
                    }
                    .font(.label).disabled(trimmed.isEmpty)
                }
            }
            .onAppear { if isNew { field = .name } }
        }
        .tint(Color.ink)
        .presentationDetents([.large])
    }
}

/// The Runes glyphs as balls, the chosen one ringed.
private struct GlyphGrid: View {
    @Binding var selection: InscriptionRune
    @Namespace private var ns

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 5), spacing: 6) {
            ForEach(InscriptionRune.allCases) { rune in
                let on = rune == selection
                Button { withAnimation(.spring(duration: 0.4, bounce: 0.25)) { selection = rune } } label: {
                    ZStack {
                        if on {
                            Circle().strokeBorder(Color.ink, lineWidth: Metric.hairline)
                                .matchedGeometryEffect(id: "ring", in: ns)
                        }
                        RuneBallView(rune: rune, size: 38).opacity(on ? 1 : 0.7)
                    }
                    .frame(width: 54, height: 54)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(rune.name)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Turns off the navigation stack's swipe back, from the edge and from anywhere on the page,
/// while `locked`, and gives it back when unlocked or gone.
/// A bead's hold. UIKit's long press leaves a swipe to the scroll view until the hold is recognised,
/// where a SwiftUI long press sequenced into a drag claims every touch on the row.
private struct BeadHold: UIGestureRecognizerRepresentable {
    var began: () -> Void
    /// Where the finger is on the screen, and how far it has come since the hold.
    var changed: (CGPoint, CGSize) -> Void
    /// Where it was let go, or nil when the hold was cancelled.
    var ended: (CGPoint?) -> Void

    final class Coordinator { var start = CGPoint.zero }
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let hold = UILongPressGestureRecognizer()
        hold.minimumPressDuration = 0.35
        return hold
    }

    func handleUIGestureRecognizerAction(_ hold: UILongPressGestureRecognizer, context: Context) {
        let point = context.converter.location(in: .global)
        switch hold.state {
        case .began:
            context.coordinator.start = point
            began()
            changed(point, .zero)
        case .changed:
            let start = context.coordinator.start
            changed(point, CGSize(width: point.x - start.x, height: point.y - start.y))
        case .ended: ended(point)
        case .cancelled, .failed: ended(nil)
        default: break
        }
    }
}

private struct SwipeBackLock: UIViewControllerRepresentable {
    let locked: Bool

    final class Probe: UIViewController {
        var locked = false { didSet { apply() } }
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); apply() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); apply() }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); set(true) }
        private func apply() { set(!locked) }
        private func set(_ enabled: Bool) {
            guard let navigation = navigationController ?? parent?.navigationController else { return }
            navigation.interactivePopGestureRecognizer?.isEnabled = enabled
            navigation.interactiveContentPopGestureRecognizer?.isEnabled = enabled
        }
    }

    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ probe: Probe, context: Context) { probe.locked = locked }
}
