import SwiftUI

// Shared pieces for setting triggers: the band feed the creator listens to, the sheet that
// wraps `ComboCreator` (Views/ComboCreator.swift) for a draft, and the rows and chips that show one.

struct BandFeed: ViewModifier {
    @ObservedObject var feed: MappingStore
    let heard: ([MappingStore.RecentGesture]) -> Void
    func body(content: Content) -> some View {
        content.onChange(of: feed.recent) { _, recent in heard(recent) }
    }
}

extension View {
    @ViewBuilder func bandFeed(_ feed: MappingStore?, heard: @escaping ([MappingStore.RecentGesture]) -> Void) -> some View {
        if let feed { modifier(BandFeed(feed: feed, heard: heard)) } else { self }
    }
}

extension Axis { var label: String { rawValue.uppercased() } }
extension RotationDirection {
    var label: String { switch self { case .left: "←\u{FE0E} Left"; case .right: "Right →\u{FE0E}"; case .any: "Either way" } }
}

// MARK: Sheet

/// Sets one trigger: the composer over a draft, with Cancel and Save.
struct TriggerSheet: View {
    let title: String
    /// What the trigger will do, in a sentence.
    var caption: String? = nil
    let rules: TriggerRules
    var taken: Set<GestureKind> = []
    var feed: MappingStore? = nil
    /// A sentence about a draft: who else uses it, what it will do.
    var note: ([ComboStep]) -> String? = { _ in nil }
    /// Why a draft can't be saved though its steps are allowed: something else is set off by them.
    var blocked: ([ComboStep]) -> String? = { _ in nil }
    /// Whether the draft may not be the switch-controls combo. Only that combo's own sheet turns this off.
    var checksSwitch = true
    /// The steps and the time between them. No steps means none.
    let save: ([ComboStep], Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var steps: [ComboStep]
    @State private var interval: Int
    @State private var dismissal = 0
    private let initial: [ComboStep]

    private var showsTiming: Bool { rules.buildsCombos && (rules.comboOnly || steps.count > 1) }

    init(title: String, caption: String? = nil, rules: TriggerRules, steps: [ComboStep], intervalMs: Int = ComboRules.defaultTime,
         taken: Set<GestureKind> = [], feed: MappingStore? = nil, note: @escaping ([ComboStep]) -> String? = { _ in nil },
         blocked: @escaping ([ComboStep]) -> String? = { _ in nil }, checksSwitch: Bool = true,
         save: @escaping ([ComboStep], Int) -> Void) {
        self.title = title; self.caption = caption; self.rules = rules; self.taken = taken; self.feed = feed; self.note = note; self.save = save
        self.blocked = blocked; self.checksSwitch = checksSwitch
        initial = steps
        _steps = State(initialValue: steps)
        _interval = State(initialValue: ComboRules.times.contains(intervalMs) ? intervalMs : ComboRules.defaultTime)
    }

    /// What stops these steps being saved: the caller's reason, or the switch-controls combo using them.
    private var clash: String? {
        blocked(steps) ?? (checksSwitch ? ControlSwitch.shared.clash(steps) : nil)
    }

    /// The time between steps and a way to clear the trigger, under the creator's Settings tab. Nil when there are neither.
    private var settings: AnyView? {
        let clears = rules.allowsNone && !initial.isEmpty
        guard rules.buildsCombos || clears else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: 20) {
            if showsTiming {
                VStack(alignment: .leading, spacing: 8) {
                    IntervalSlider(value: $interval, allowsNoLimit: false)
                    Text("While a finger is held, there’s no time limit. A gesture that starts a spell waits until the spell finishes or runs out of time.")
                        .font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                }
            } else if rules.buildsCombos {
                Text("Add a second step to set the time between steps.").font(.caption).foregroundStyle(Color.muted)
            }
            if clears {
                Button("Set to none") { save([], interval); dismiss() }.buttonStyle(.quiet)
            }
        })
    }

    var body: some View {
        NavigationStack {
            GeometryReader { page in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let caption {
                        Text(caption).font(.bodyText).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    ComboCreator(steps: $steps, interval: $interval, rules: rules, note: clash ?? note(steps), taken: taken, feed: feed,
                                 dismissal: dismissal, settingsTab: settings, pageHeight: page.size.height)
                }
                .padding(Metric.gutter)
                .animation(.standard, value: showsTiming)
            }
            .scrollBounceBehavior(.basedOnSize)
            }
            .page()
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.label) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(steps, interval); dismiss() }.font(.label).disabled(!rules.isValid(steps) || clash != nil)
                }
            }
        }
        .tint(Color.ink)
        .presentationDetents([.large])
    }
}

// MARK: Row and chip

/// A ledger row for something the band does: what it is, and the trigger that does it.
struct TriggerRow: View {
    let title: String
    var detail: String? = nil
    /// Nil or empty reads "None".
    let steps: [ComboStep]?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.bodyText)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(Color.muted)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                TriggerChip(steps: steps).fixedSize()
            }
            .padding(.vertical, 14).contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
        .accessibilityHint("Chooses the gesture or spell.")
    }
}

/// A trigger drawn small: its gesture's icon, or a combo's icons in order.
struct TriggerGlyphs: View {
    let steps: [ComboStep]
    var size: CGFloat = 15
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 { LucideIcon(.chevronRight, size: size * 0.6).foregroundStyle(Color.faint) }
                StepIcon(step: step, size: size)
            }
        }
        .accessibilityElement().accessibilityLabel(steps.map(\.name).joined(separator: ", then "))
    }
}

/// A gesture, a combo's steps, or "None", as a hairline capsule.
struct TriggerChip: View {
    /// The trigger's steps; nil or empty reads "None".
    let steps: [ComboStep]?
    /// A long combo shows this many steps and counts the rest.
    private static let shown = 5
    init(trigger: ScoreTrigger?) { steps = trigger?.steps }
    init(steps: [ComboStep]?) { self.steps = steps }
    var body: some View {
        Group {
            if let steps, steps.count == 1 {
                GestureChip(gesture: steps[0].gesture)
            } else if let steps, !steps.isEmpty {
                let visible = steps.count > Self.shown ? Array(steps.prefix(Self.shown - 1)) : steps
                HStack(spacing: 3) {
                    TriggerGlyphs(steps: visible)
                    if steps.count > visible.count {
                        Text("+\(steps.count - visible.count)").font(.caption).foregroundStyle(Color.muted).monospacedDigit().padding(.leading, 3)
                    }
                }
                .padding(.horizontal, 10).frame(minHeight: 30)
                .overlay(Capsule().strokeBorder(Color.rule, lineWidth: Metric.hairline))
                .accessibilityElement().accessibilityLabel(steps.map(\.name).joined(separator: ", then "))
            } else {
                GestureChip(gesture: nil)
            }
        }
        .animation(.standard, value: steps)
    }
}

// MARK: Layout

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    /// Space between lines; the same as between chips unless set.
    var lineSpacing: CGFloat? = nil
    private var gap: CGFloat { lineSpacing ?? spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + gap * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + gap
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if next > width, !current.items.isEmpty { rows.append(current); current = ([index], size.width, size.height) }
            else { current = (current.items + [index], next, max(current.height, size.height)) }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
