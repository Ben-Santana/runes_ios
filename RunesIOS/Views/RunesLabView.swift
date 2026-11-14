import SwiftUI

/// Settings → Developer → Runes lab. A stand-in for the Mappings page with the beads where
/// its strip of recent gestures is, to judge them in place. The band drives them as it would
/// there; without one, touching a mapping performs its gestures.
struct RunesLabScreen: View {
    @ObservedObject var store: MappingStore
    @StateObject private var feed = BeadsFeed()
    @State private var flashed: String?
    @State private var heardThrough = 0
    @State private var performing: Task<Void, Never>?

    @MainActor init(store: MappingStore? = nil) {
        self.store = store ?? .shared
    }

    /// The pause between a performed combo's gestures.
    private static let pace = Duration.milliseconds(420)
    private static let nothing: [ComboStep] = [.swipeDown, .tapMiddle, .swipeLeft].steps

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                MappingGroup("Gestures") {
                    ForEach(Array(store.active.gestures.enumerated()), id: \.element.id) { index, mapping in
                        if index > 0 { Rule() }
                        row(mapping, title: nil)
                    }
                }
                MappingGroup("Combos", caption: "A mapping that is off or not set comes to nothing, as it would on the band.") {
                    ForEach(Array(store.active.combos.filter { $0.steps?.isEmpty == false }.enumerated()), id: \.element.id) { index, mapping in
                        row(mapping, title: mapping.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Combo \(index + 1)")
                        Rule()
                    }
                    Button { perform(Self.nothing, matching: nil) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Gestures that match nothing").font(.bodyText)
                            StepChips(steps: Self.nothing, compact: true)
                        }
                        .padding(.horizontal, Metric.inset).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: Metric.rowTall, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Metric.gutter)
        }
        // In Mappings the beads would scroll with the page; here they stay put, to be watched
        // while a mapping further down is touched.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                GestureBeads(feed: feed).panel()
                Text("Where Mappings shows your recent gestures. Use your band, or touch a mapping to perform it.")
                    .font(.caption).foregroundStyle(Color.muted).padding(.horizontal, 2)
            }
            .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 12)
            .background(Color.paper)
        }
        .page()
        .navigationTitle("Runes lab").navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.impact(weight: .light), trigger: feed.steps.count) { _, count in count > 0 }
        .sensoryFeedback(.success, trigger: feed.matches)
        .onAppear { heardThrough = store.recent.last?.id ?? 0 }
        .onChange(of: store.recent) { _, recent in
            // The band: every new gesture goes to the beads.
            for gesture in recent where gesture.id > heardThrough { feed.gesture(gesture.step) }
            heardThrough = recent.last?.id ?? heardThrough
        }
        .onChange(of: store.lastFired?.at) { _, _ in
            if let fired = store.lastFired { feed.matched(tint: tint(for: fired.id)) }
        }
        .onDisappear { performing?.cancel() }
    }

    private func row(_ mapping: Mapping, title: String?) -> some View {
        Button {
            perform(mapping.steps ?? mapping.motion.map { [ComboStep($0)] } ?? [], matching: mapping.isLive ? mapping.id : nil)
        } label: {
            MappingRow(mapping: mapping, title: title, profiles: store.library.profiles, flashed: flashed == mapping.id)
        }
        .buttonStyle(.plain)
    }

    /// A mapping's colour. Mappings have none of their own yet, so each takes one by its place in the profile.
    private func tint(for id: String) -> Int {
        store.active.mappings.firstIndex { $0.id == id } ?? 0
    }

    /// Makes the gestures one after another, as a hand would. The match lands with the last one.
    private func perform(_ steps: [ComboStep], matching id: String?) {
        performing?.cancel()
        performing = Task { @MainActor in
            for (index, step) in steps.enumerated() {
                feed.gesture(step)
                guard index == steps.count - 1 else {
                    try? await Task.sleep(for: Self.pace)
                    if Task.isCancelled { return }
                    continue
                }
                if let id {
                    feed.matched(tint: tint(for: id))
                    flashed = id
                    try? await Task.sleep(for: .milliseconds(600))
                    if flashed == id { flashed = nil }
                } else {
                    try? await Task.sleep(for: .milliseconds(900))
                    if !Task.isCancelled { feed.missed() }
                }
            }
        }
    }
}
