import SwiftUI

// Where a trigger is set: its steps as beads on a string (Design/BeadString.swift), the same
// steps as hands under it, and below them tabs for the gestures that can be added, what the combo
// does, and its settings. Touching a bead or a hand shows what can be done to that step instead. `TriggerRules`
// decides whether that is one gesture, a combo, or either, so Mappings, Score, Capture, Workouts,
// Reels and Cook all set their gestures here. The string shows the time between steps as the
// gaps between beads. The band can make the steps too.

struct ComboCreator: View {
    @Binding var steps: [ComboStep]
    /// Milliseconds between steps; `ComboRules.noLimit` at the slider's first stop.
    @Binding var interval: Int
    var rules: TriggerRules = .combo
    /// Whether the combo is turned on. Turned off, the string freezes.
    var enabled = true
    /// Something wrong with the steps as they stand that the rules don't say. Nil shows nothing.
    var note: String? = nil
    /// Gestures something else already uses on their own, marked with a dot on the pad.
    var taken: Set<GestureKind> = []
    /// The band: steps can be made instead of chosen, and air shapes drawn.
    var feed: MappingStore? = nil
    /// Changes when something else on the page is touched, which lets go of the selected bead.
    var dismissal = 0
    /// What the combo does, under the Action tab. Nil leaves the tab out.
    var actionTab: AnyView? = nil
    /// The combo's other choices, under the Settings tab. Nil leaves the tab out.
    var settingsTab: AnyView? = nil
    /// The height of the page this heads; the string takes a little under half of it.
    let pageHeight: CGFloat

    enum Tab: Hashable {
        case add, action, settings
        var title: String {
            switch self { case .add: "Add"; case .action: "Action"; case .settings: "Settings" }
        }
    }

    private struct AirTarget: Identifiable { let id: Int }
    private static let space = "combo-creator"
    /// A finger's four keys to a row, then the swipes, then the wrist and the air.
    private static let rows: [[GestureKind]] = [
        [.tapIndex, .doubleTapIndex, .holdIndex, .releaseIndex],
        [.tapMiddle, .doubleTapMiddle, .holdMiddle, .releaseMiddle],
        [.swipeUp, .swipeDown, .swipeLeft, .swipeRight],
        [.rotation, .movement, .air],
    ]

    @State private var string = BeadString()
    @State private var selection: Int?
    @State private var tab: Tab = .add
    @State private var keyFrames: [GestureKind: CGRect] = [:]
    @State private var listening = false
    /// Listening for one gesture rather than a run of steps.
    @State private var listeningForOne = false
    @State private var heardThrough = 0
    @State private var lastTaken: (kind: GestureKind, at: Date)?
    @State private var stopTask: Task<Void, Never>?
    @State private var echo: GestureKind?
    @State private var echoes = 0
    @State private var airTarget: AirTarget?
    /// The bead being held and dragged to a new place.
    @State private var dragging: Int?
    @State private var droppedAt = Date.distantPast
    /// The key whose name is shown because it was held.
    @State private var named: GestureKind?
    @State private var heldKey: GestureKind?
    @State private var namings = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The bead the pad would change.
    private var selected: Int? { selection.flatMap { steps.indices.contains($0) ? $0 : nil } }
    private var padOpen: Bool { tab == .add }
    private var tabs: [Tab?] { [.add] + (actionTab == nil ? [] : [.action]) + (settingsTab == nil ? [] : [.settings]) }
    /// A step is selected to be changed from the pad rather than looked at.
    @State private var changing = false
    /// The selected step's tools show in place of the tabs' contents.
    private var editing: Bool { selected != nil && !changing }
    private var showsEnd: Bool { rules.buildsCombos ? steps.count < rules.maxSteps : steps.isEmpty }
    private var showsTiming: Bool { rules.buildsCombos && (rules.comboOnly || steps.count > 1) }
    /// Whether the band would be heard as one gesture: nothing chosen yet, or the one chosen is selected.
    private var wantsOne: Bool {
        !rules.buildsCombos || (!rules.comboOnly && (steps.isEmpty || (steps.count == 1 && selected != nil)))
    }
    /// Air shapes are drawn or recorded with the band's help.
    private var offered: Set<GestureKind> { rules.offered.subtracting(feed == nil ? [.air] : []) }
    /// What else uses a gesture only matters while one gesture is being chosen.
    private var marked: Set<GestureKind> { wantsOne ? taken.intersection(offered) : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stage
            hands
            if let sentence {
                Text(sentence).font(.caption).foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(sentence).transition(.opacity)
            }
            HairlineSegments(selection: Binding(get: { editing ? nil : tab }, set: { if let new = $0 { choose(new) } }),
                             options: tabs, title: \.title)
            Group {
                if editing, let index = selected { beadMenu(index) }
                else {
                    switch tab {
                    case .add: pad
                    case .action: actionTab
                    case .settings: settingsTab
                    }
                }
            }
            .transition(.opacity)
        }
        .coordinateSpace(.named(Self.space))
        .sensoryFeedback(.impact(weight: .medium), trigger: dragging != nil)
        .animation(.standard, value: steps)
        .animation(.standard, value: tab)
        .onChange(of: dismissal) { _, _ in stopListening(); selection = nil; changing = false }
        .animation(.standard, value: selection)
        .animation(.standard, value: listening)
        .sensoryFeedback(.impact(weight: .light), trigger: steps)
        .sensoryFeedback(.selection, trigger: selection)
        .sensoryFeedback(.selection, trigger: namings)
        .onAppear {
            string.sync(steps)
            // Always opens on Add. Where one gesture is the usual answer, the one there is ready to be changed.
            tab = .add
            if steps.count == 1, !rules.comboOnly { selection = 0; changing = true }
        }
        .onChange(of: steps) { _, steps in
            string.sync(steps)
            if let index = selection, !steps.indices.contains(index) { selection = nil }
        }
        .onDisappear(perform: stopListening)
        .bandFeed(feed, heard: heard)
        .sheet(item: $airTarget) { target in
            if let feed {
                AirGestureEditor(store: feed, initial: steps.indices.contains(target.id) ? steps[target.id].air : nil) { shape in
                    if steps.indices.contains(target.id) { steps[target.id] = .airShape(shape) }
                    else if steps.count < rules.maxSteps { steps.append(.airShape(shape)) }
                }
            }
        }
    }

    /// A tab touched lets go of the selected step; Add then adds to the end.
    private func choose(_ new: Tab) {
        if new != .add { stopListening() }
        selection = nil; changing = false
        tab = new
    }

    // MARK: Stage

    private var stage: some View {
        GeometryReader { proxy in
            BeadStringView(string: string, scene: scene(width: proxy.size.width))
                .contentShape(Rectangle())
                .gesture(reorder)
                .simultaneousGesture(SpatialTapGesture().onEnded { touch($0.location) })
                .accessibilityRepresentation { spoken }
        }
        .frame(height: max(260, pageHeight * 0.42))
    }

    private func scene(width: CGFloat) -> BeadStringScene {
        let times = ComboRules.times
        let place = times.firstIndex(of: interval).map { Double($0) / Double(times.count - 1) }
        let gap = showsTiming && place != nil ? Double(interval) / 1000 : nil
        return BeadStringScene(showsEnd: false, selected: selected, interval: gap,
                               tempo: place ?? 0.5, frozen: !enabled, bridges: TriggerRules.held(steps).bridges, listening: listening,
                               width: width, hang: width * 0.5, still: reduceMotion)
    }

    private func touch(_ point: CGPoint) {
        // The lift at the end of a drag isn't a touch.
        guard dragging == nil, Date().timeIntervalSince(droppedAt) > 0.3 else { return }
        switch string.hit(point) {
        case .bead(let index): toggle(index)
        case .end: addStep()
        case nil:
            stopListening(); selection = nil; changing = false
            string.poke(point)
        }
    }

    /// Selects a bead and shows what can be done to it, or lets go of it.
    private func toggle(_ index: Int) {
        stopListening()
        changing = false
        selection = selected == index ? nil : index
    }

    private func addStep() {
        selection = nil; changing = false
        tab = .add
    }

    // MARK: Dragging

    /// Held, a bead comes off the string and follows the finger; the others make way as it passes.
    private var reorder: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, let drag?) = value { moveDragged(drag) }
            }
            .onEnded { _ in endDrag() }
    }

    private func moveDragged(_ drag: DragGesture.Value) {
        if dragging == nil {
            guard steps.count > 1, case .bead(let index) = string.hit(drag.startLocation) else { return }
            stopListening()
            selection = index; dragging = index; changing = false
        }
        guard let from = dragging, steps.indices.contains(from) else { return }
        let to = string.slot(drag.location)
        if to != from {
            var moved = steps
            moved.insert(moved.remove(at: from), at: to)
            steps = moved
            string.sync(moved)
            dragging = to; selection = to
        }
        string.hold(to, at: drag.location)
    }

    private func endDrag() {
        if dragging != nil { droppedAt = Date() }
        dragging = nil
        string.release()
    }

    // MARK: Hands

    /// The steps again as hands, on a dark pill under the string: touching one selects its bead.
    private var hands: some View {
        HStack(spacing: 8) {
            if !steps.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        let on = selected == index
                        Button { toggle(index) } label: {
                            VStack(spacing: 3) {
                                GestureIcon(gesture: step.gesture, size: 22)
                                Circle().fill(on ? Color.paper : Color.clear).frame(width: 4, height: 4)
                            }
                            .foregroundStyle(on || selected == nil ? Color.paper : Color.paper.opacity(0.45))
                            .frame(width: 34, height: 40).contentShape(Rectangle())
                        }
                        .buttonStyle(KeyPress())
                        .accessibilityLabel(steps.count > 1 ? "Step \(index + 1), \(step.name)" : step.name)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 8).padding(.top, 4)
                .background(Color.ink, in: Capsule())
            }
            if showsEnd {
                Button(action: addStep) {
                    LucideIcon(.plus, size: 18)
                        .foregroundStyle(selected == nil ? Color.ink : Color.muted)
                        .frame(width: 34, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(KeyPress())
                .accessibilityLabel("Add a step")
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The string for VoiceOver: a button for each bead, and one for the end.
    private var spoken: some View {
        VStack {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Button(steps.count > 1 ? "Step \(index + 1), \(step.name)" : step.name) { toggle(index) }
                    .accessibilityHint("Selects it, to change, move or remove it.")
                    .accessibilityAddTraits(selected == index ? .isSelected : [])
            }
            if showsEnd {
                Button(steps.isEmpty ? (rules.buildsCombos && rules.comboOnly ? "Choose the first step" : "Choose a gesture") : "Add a step") {
                    addStep()
                }
                .accessibilityAddTraits(selected == nil ? .isSelected : [])
            }
        }
    }

    // MARK: Pad

    private var pad: some View {
        let offered = offered
        var visible: [[GestureKind?]] = Self.rows.filter { $0.contains(where: offered.contains) }
            .map { row in (0..<4).map { row.indices.contains($0) && offered.contains(row[$0]) ? row[$0] : nil } }
        // Record takes the last free place at the end of the pad, or a row of its own.
        let records = feed != nil
        if records, visible.last?.last.flatMap({ $0 }) != nil { visible.append([nil, nil, nil, nil]) }
        let lastRow = visible.count - 1
        return VStack(alignment: .leading, spacing: 6) {
            if let index = selected {
                Text("Changing step \(index + 1)").font(.caption).foregroundStyle(Color.muted)
            }
            ForEach(Array(visible.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { column in
                        if let kind = row[column] { key(kind, column: column) }
                        else if records, index == lastRow, column == 3 { recordKey }
                        else { Color.clear.frame(maxWidth: .infinity).frame(height: Self.keyHeight) }
                    }
                }
                // The two fingers, the swipes and the wrist stand a little apart.
                .padding(.top, index > 0 ? 4 : 0)
                .zIndex(row.contains { $0 != nil && $0 == named } ? 1 : 0)
            }
        }
    }

    private static let keyHeight: CGFloat = 54

    private func key(_ kind: GestureKind, column: Int) -> some View {
        let on = selected.map { steps[$0].gesture } == kind
        let can = on || canPlace(kind)
        let heard = echo == kind && !on
        let used = marked.contains(kind) && !on
        // Held, its name shows above it, kept on screen at the row's ends.
        let edge: Alignment = column == 0 ? .topLeading : column == 3 ? .topTrailing : .top
        return Button {
            // A hold names the key; letting go after it doesn't choose it.
            if named == kind, heldKey == kind { heldKey = nil; return }
            if can { place(kind) }
        } label: {
            GestureIcon(gesture: kind, size: 22)
                .foregroundStyle(on ? Color.paper : Color.ink)
                .frame(maxWidth: .infinity).frame(height: Self.keyHeight)
                .background(on ? Color.ink : heard ? Color.soft : Color.paper, in: RoundedRectangle(cornerRadius: Metric.control))
                .overlay(RoundedRectangle(cornerRadius: Metric.control)
                    .strokeBorder(heard ? Color.ink : Color.rule, lineWidth: on ? 0 : Metric.hairline))
                // The rune this hand is written as on its bead.
                .overlay(alignment: .topLeading) {
                    RuneIcon(gesture: kind, size: 12).foregroundStyle(on ? Color.paper.opacity(0.7) : Color.muted).padding(4)
                }
                .overlay(alignment: .topTrailing) {
                    if used { Circle().fill(Color.muted).frame(width: 4, height: 4).padding(6) }
                }
                .opacity(can ? 1 : 0.3)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyPress())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in name(kind) })
        .overlay(alignment: edge) {
            if named == kind {
                Text(kind.name).font(.label).foregroundStyle(Color.paper).lineLimit(1).fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.ink, in: Capsule())
                    .offset(y: -38)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(named == kind ? 1 : 0)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { keyFrames[kind] = $0 }
        .accessibilityLabel(kind.name)
        .accessibilityValue(used ? "Already used" : "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Shows a held key's name for a moment.
    private func name(_ kind: GestureKind) {
        namings += 1
        let mine = namings
        heldKey = kind
        withAnimation(.standard) { named = kind }
        Task {
            try? await Task.sleep(for: .milliseconds(1600))
            guard namings == mine else { return }
            heldKey = nil
            withAnimation(.standard) { named = nil }
        }
    }

    /// The last key on the pad, set apart: the band makes the steps instead.
    private var recordKey: some View {
        Button { listening ? stopListening() : startListening() } label: {
            VStack(spacing: 5) {
                ZStack {
                    if listening { PulseDot(tint: Color.destructive).scaleEffect(1.8) }
                    else { Circle().fill(Color.destructive).frame(width: 13, height: 13) }
                }
                .frame(width: 22, height: 22)
                // Both words take the same room, so the dot doesn't move when the label changes.
                ZStack {
                    Text("Record").opacity(listening ? 0 : 1)
                    Text("Stop").opacity(listening ? 1 : 0)
                }
                .font(.caption)
            }
            .foregroundStyle(listening ? Color.paper : Color.ink)
            .frame(maxWidth: .infinity).frame(height: Self.keyHeight)
            .background(listening ? Color.ink : Color.soft, in: RoundedRectangle(cornerRadius: Metric.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(KeyPress())
        .accessibilityLabel(listening ? "Stop recording" : wantsOne ? "Make it on your band" : "Record the steps on your band")
        .accessibilityHint("While it records, the band’s gestures don’t do anything else.")
    }

    // MARK: Selected bead

    /// What can be done to the selected step, shown in place of the tabs' contents.
    private func beadMenu(_ index: Int) -> some View {
        let step = steps[index]
        let removable = steps.count > 1 || rules.comboOnly || (rules.buildsCombos && rules.allowsNone)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if steps.count > 1 {
                    Text("Step \(index + 1) of \(steps.count)").font(.caption).foregroundStyle(Color.muted)
                        .monospacedDigit().contentTransition(.numericText())
                }
                Text(step.name).font(.label).contentTransition(.opacity)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 6) {
                menuKey(.pencil, "Change") { changing = true; tab = .add }
                if step.gesture.isAir, feed != nil { menuKey(.spline, "Shape") { airTarget = AirTarget(id: index) } }
                if steps.count > 1 {
                    menuKey(.arrowUp, "Move up", enabled: index > 0) { move(index, by: -1) }
                    menuKey(.arrowDown, "Move down", enabled: index < steps.count - 1) { move(index, by: 1) }
                }
                if removable { menuKey(.trash2, "Delete") { remove(index) } }
            }
            if step.gesture.isMotion {
                HairlineSegments(selection: Binding(get: { step.axis ?? .x }, set: { axis in change(index) { $0.axis = axis } }),
                                 options: Axis.allCases, title: \.label)
                    .accessibilityLabel("Axis")
            }
            if step.gesture == .rotation {
                HairlineSegments(selection: Binding(get: { step.direction ?? .any }, set: { direction in change(index) { $0.direction = direction } }),
                                 options: RotationDirection.allCases, title: \.label)
                    .accessibilityLabel("Direction")
            }
        }
    }

    private func menuKey(_ icon: Lucide, _ label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                LucideIcon(icon, size: 18)
                Text(label).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(Color.paper, in: RoundedRectangle(cornerRadius: Metric.control))
            .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
            .opacity(enabled ? 1 : 0.3)
            .contentShape(Rectangle())
        }
        .buttonStyle(KeyPress())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var sentence: String? {
        if listening {
            return listeningForOne ? "Listening. Make the gesture on your band." : "Listening. Make the steps on your band, in order."
        }
        if let problem = rules.problem(steps) { return problem }
        let legend = padOpen && !marked.isEmpty ? "Dotted gestures are already used. Choosing one swaps the two." : nil
        if steps.isEmpty {
            if rules.comboOnly { return legend }
            let start = rules.allowsNone ? "Not set. Choose a gesture" : "Choose a gesture"
            let prompt = rules.buildsCombos ? start + ", then add more after it for a spell." : start + "."
            return [prompt, legend].compactMap { $0 }.joined(separator: " ")
        }
        let said = selected == nil || padOpen ? note : nil
        let joined = [said, legend].compactMap { $0 }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    // MARK: Editing

    private func canPlace(_ kind: GestureKind) -> Bool {
        if kind.isAir, feed == nil { return false }
        if let index = selected { return rules.canReplace(index, with: kind, in: steps) }
        return rules.canAppend(kind, to: steps)
    }

    private func place(_ kind: GestureKind) {
        if kind.isAir { airTarget = AirTarget(id: selected ?? steps.count); return }
        if let index = selected {
            guard steps[index].gesture != kind else { return }
            // Swapping rotation for movement keeps the axis.
            steps[index] = ComboStep(kind, axis: steps[index].axis, direction: steps[index].direction)
        } else {
            string.origin = keyFrames[kind].map { CGPoint(x: $0.midX, y: $0.midY) }
            steps.append(ComboStep(kind))
            // Where one gesture can stand alone, it stays selected, so choosing again changes it.
            if steps.count == 1, !rules.comboOnly { selection = 0; changing = true }
        }
    }

    private func change(_ index: Int, _ edit: (inout ComboStep) -> Void) {
        guard steps.indices.contains(index) else { return }
        var step = steps[index]
        edit(&step)
        steps[index] = step
    }

    /// Takes a bead off and selects the one that takes its place, so the next touch removes that.
    private func remove(_ index: Int) {
        guard steps.indices.contains(index) else { return }
        let left = steps.count - 1
        steps.remove(at: index)
        selection = left == 0 ? nil : min(index, left - 1)
    }

    private func move(_ index: Int, by offset: Int) {
        guard steps.indices.contains(index), steps.indices.contains(index + offset) else { return }
        steps.swapAt(index, index + offset)
        selection = index + offset
    }

    // MARK: Band

    private func startListening() {
        guard let feed else { return }
        heardThrough = feed.recent.last?.id ?? 0
        lastTaken = nil
        listeningForOne = wantsOne
        if !listeningForOne { selection = nil }
        // Paused, the band's gestures reach the editor and nothing else.
        feed.paused = true
        listening = true
    }

    private func stopListening() {
        stopTask?.cancel(); stopTask = nil
        guard listening else { return }
        listening = false
        feed?.paused = false
    }

    private func heard(_ recent: [MappingStore.RecentGesture]) {
        let new = recent.filter { $0.id > heardThrough }
        guard let last = new.last else { return }
        heardThrough = last.id
        flash(last.gesture)
        guard listening else { return }
        // Motion is set by hand (axis, direction); only taps, holds and swipes are heard.
        var working = steps
        for item in new where !item.gesture.isMotion && !item.gesture.isAir { take(item.gesture, into: &working) }
        if working != steps { steps = working }
    }

    private func take(_ kind: GestureKind, into working: inout [ComboStep]) {
        let now = Date()
        if listeningForOne {
            guard rules.singles.contains(kind) else { return }
            working = [ComboStep(kind)]
            selection = 0
            // A double tap arrives after the tap that began it, so wait a moment before closing.
            stopTask?.cancel()
            stopTask = Task {
                try? await Task.sleep(for: .milliseconds(900))
                if !Task.isCancelled { stopListening() }
            }
            return
        }
        if let before = lastTaken, before.kind.doubleTap == kind, working.last?.gesture == before.kind, now.timeIntervalSince(before.at) < 1 {
            // The tap just heard was the first half of this double tap.
            working[working.count - 1] = ComboStep(kind)
        } else {
            guard rules.canAppend(kind, to: working) else { return }
            working.append(ComboStep(kind))
        }
        if working.count >= rules.maxSteps { stopListening() }
        lastTaken = (kind, now)
    }

    /// Lights the key for a gesture the band just made.
    private func flash(_ kind: GestureKind) {
        echoes += 1
        let mine = echoes
        withAnimation(.standard) { echo = kind }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if echoes == mine { withAnimation(.standard) { echo = nil } }
        }
    }
}

/// A key that gives under the finger and springs back.
private struct KeyPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.45), value: configuration.isPressed)
    }
}

/// The time between a combo's steps: one hairline with a stop for each choice, and no limit at its start.
struct IntervalSlider: View {
    @Binding var value: Int
    /// Whether the first stop is no limit at all. Only mappings' combos may wait forever.
    var allowsNoLimit = true
    @State private var dragging = false

    private var stops: [Int] { allowsNoLimit ? [ComboRules.noLimit] + ComboRules.times : ComboRules.times }
    private static let inset: CGFloat = 12
    private var index: Int { stops.firstIndex(of: value) ?? stops.firstIndex(of: ComboRules.defaultTime) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Time between steps").font(.label)
                Spacer(minLength: 8)
                Text(ComboRules.timeLabel(value)).font(.label).monospacedDigit()
                    .contentTransition(.numericText()).animation(.standard, value: value)
            }
            GeometryReader { proxy in
                let span = max(1, proxy.size.width - 2 * Self.inset), middle = proxy.size.height / 2
                let last = CGFloat(stops.count - 1)
                let x = Self.inset + span * CGFloat(index) / last
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.rule).frame(width: span, height: Metric.hairline).position(x: proxy.size.width / 2, y: middle)
                    Rectangle().fill(Color.ink).frame(width: x - Self.inset, height: 1.5).position(x: Self.inset + (x - Self.inset) / 2, y: middle)
                    ForEach(1..<stops.count, id: \.self) { stop in
                        Rectangle().fill(stop <= index ? Color.ink : Color.faint).frame(width: 1, height: 7)
                            .position(x: Self.inset + span * CGFloat(stop) / last, y: middle)
                    }
                    Circle().fill(Color.paper)
                        .overlay(Circle().strokeBorder(Color.ink, lineWidth: 1.5))
                        .frame(width: 22, height: 22)
                        .scaleEffect(dragging ? 1.25 : 1)
                        .position(x: x, y: middle)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        let stop = Int(((drag.location.x - Self.inset) / span * last).rounded())
                        let chosen = stops[min(stops.count - 1, max(0, stop))]
                        if chosen != value { value = chosen }
                    }
                    .onEnded { _ in dragging = false })
                .animation(.spring(duration: 0.3, bounce: 0.3), value: index)
                .animation(.lively, value: dragging)
            }
            .frame(height: 36)
            HStack {
                Text(ComboRules.timeLabel(stops.first ?? 0)); Spacer(); Text(ComboRules.timeLabel(ComboRules.times.last ?? 0))
            }
            .font(.caption).foregroundStyle(Color.muted).padding(.horizontal, 2)
        }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement()
        .accessibilityLabel("Time between steps")
        .accessibilityValue(ComboRules.timeLabel(value))
        .accessibilityAdjustableAction { direction in
            let next = index + (direction == .increment ? 1 : -1)
            if stops.indices.contains(next) { value = stops[next] }
        }
    }
}

private extension Optional where Wrapped == ComboCreator.Tab {
    var title: String { self?.title ?? "" }
}
