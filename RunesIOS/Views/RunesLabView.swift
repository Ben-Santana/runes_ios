import SwiftUI

/// Settings → Developer → Runes lab. The beads over the active profile's combos and gestures,
/// to judge them in place. The band drives them as it would in Mappings; without one, touching
/// a row performs its gestures. Each row is written in the runes the beads carry, and inks in
/// step by step as it is made.
struct RunesLabScreen: View {
    @ObservedObject var store: MappingStore
    @StateObject private var feed = BeadsFeed()
    @State private var flashed: String?
    @State private var performing: Task<Void, Never>?

    @MainActor init(store: MappingStore? = nil) {
        self.store = store ?? .shared
    }

    /// The pause between a performed combo's gestures.
    private static let pace = Duration.milliseconds(420)

    private var combos: [Mapping] { store.active.combos.filter { $0.steps?.isEmpty == false } }
    /// The first combo without its last gesture: a combo started and left.
    private var unfinished: [ComboStep] {
        combos.first { $0.isLive && ($0.steps?.count ?? 0) > 1 }?.steps.map { Array($0.dropLast()) } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 0) {
                    Heading("Spells", count: combos.count)
                    ForEach(Array(combos.enumerated()), id: \.element.id) { index, mapping in
                        if index > 0 { Rule(inset: 0) }
                        row(mapping) {
                            ComboLine(title: title(mapping), steps: mapping.steps ?? [], detail: detail(mapping), made: made(mapping.steps ?? []))
                        }
                    }
                    if !unfinished.isEmpty {
                        Rule(inset: 0)
                        Button { perform(unfinished, matching: nil) } label: {
                            Text("Start one and leave it").font(.label).foregroundStyle(Color.muted)
                                .frame(maxWidth: .infinity, minHeight: Metric.tap, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(PressRow())
                    }
                    Note("Gestures stack round the ring only while they could still become one of these.")
                }
                VStack(alignment: .leading, spacing: 0) {
                    Heading("Gestures", count: store.active.gestures.count)
                    ForEach(Array(store.active.gestures.enumerated()), id: \.element.id) { index, mapping in
                        if index > 0 { Rule(inset: 0) }
                        row(mapping) {
                            HStack(spacing: 12) {
                                // One gesture is an instruction, not a sequence: it keeps the hand.
                                if let kind = mapping.motion { GestureIcon(gesture: kind, size: 22).frame(width: 28) }
                                Text(title(mapping)).font(.bodyText)
                                Spacer(minLength: 8)
                                Text(detail(mapping)).font(.caption).foregroundStyle(Color.muted).lineLimit(1)
                            }
                            .frame(minHeight: Metric.row)
                        }
                    }
                    Note("A gesture that starts no spell stands alone: it shows, then runs its mapping or fades.")
                }
            }
            .padding(.horizontal, Metric.gutter).padding(.top, 24).padding(.bottom, 40)
        }
        // In Mappings the beads would scroll with the page; here they stay put, to be watched
        // while a row further down is touched.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                BeadsStage(feed: feed, store: store, idle: "Touch a spell to cast it, or make it on the band.")
                    .padding(.horizontal, Metric.gutter).padding(.bottom, 14)
                Rule(inset: 0)
            }
            .background(Color.paper)
        }
        .page()
        .navigationTitle("Runes lab").navigationBarTitleDisplayMode(.inline)
        .onDisappear { performing?.cancel() }
    }

    // MARK: Rows

    private func row<Label: View>(_ mapping: Mapping, @ViewBuilder label: () -> Label) -> some View {
        Button {
            perform(mapping.steps ?? mapping.motion.map { [ComboStep($0)] } ?? [], matching: mapping.isLive ? mapping.id : nil)
        } label: {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metric.gutter)
                .background(flashed == mapping.id ? Color.soft : Color.clear)
                .padding(.horizontal, -Metric.gutter)
                .contentShape(Rectangle())
                .animation(.standard, value: flashed)
                .accessibilityElement(children: .combine)
        }
        .buttonStyle(PressRow())
    }

    private func title(_ mapping: Mapping) -> String { BeadsStage.title(mapping, in: store) }

    private func detail(_ mapping: Mapping) -> String {
        guard let first = mapping.actions.first else { return "Not set" }
        let text = first.label(profiles: store.library.profiles)
        return mapping.isLive ? text : "Off · \(text)"
    }

    /// How many of a combo's steps are on the beads now; nil when the beads are on some other path.
    private func made(_ steps: [ComboStep]) -> Int? {
        let shown = feed.steps
        guard !shown.isEmpty, shown.count <= steps.count, zip(steps, shown).allSatisfy({ $0.matches($1) }) else { return nil }
        return shown.count
    }

    /// Makes the gestures one after another, as a hand would. A mapping that is live runs
    /// with the last one; anything else is left for the beads to give up on.
    private func perform(_ steps: [ComboStep], matching id: String?) {
        performing?.cancel()
        performing = Task { @MainActor in
            for (index, step) in steps.enumerated() {
                feed.gesture(step)
                if index < steps.count - 1 {
                    try? await Task.sleep(for: Self.pace)
                    if Task.isCancelled { return }
                } else if let id {
                    feed.matched(id, tint: BeadsStage.tint(for: id, in: store))
                    flashed = id
                    try? await Task.sleep(for: .milliseconds(600))
                    if flashed == id { flashed = nil }
                }
            }
        }
    }
}

/// A combo written in runes. While it is being made, the steps still to come wait in faint.
private struct ComboLine: View {
    let title: String
    let steps: [ComboStep]
    let detail: String
    let made: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.bodyText)
                Spacer(minLength: 8)
                Text(detail).font(.caption).foregroundStyle(Color.muted).lineLimit(1)
            }
            HStack(spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    RuneStep(step: step, size: 24)
                        .foregroundStyle(made.map { index < $0 ? Color.ink : Color.faint } ?? Color.ink)
                }
            }
            .animation(.standard, value: made)
            .accessibilityElement().accessibilityLabel(steps.map(\.name).joined(separator: ", then "))
        }
        .padding(.vertical, 14)
    }
}
