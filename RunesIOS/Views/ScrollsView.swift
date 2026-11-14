import SwiftUI

// Capture's scrolls: the shelf of runes over the inbox, a scroll's page heading, and the
// sheet that makes or edits one. A scroll is a name, a rune and, optionally, a sentence on
// what belongs in it, which is what Apple Intelligence reads to file inscriptions there.

/// The scrolls as a line of runes, like an inscription read left to right. Each opens its
/// scroll; the last makes a new one.
struct ScrollShelf: View {
    let scrolls: [CaptureScroll]
    let counts: [String: Int]
    let open: (String) -> Void
    let new: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Heading("Scrolls", count: scrolls.isEmpty ? nil : scrolls.count)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(scrolls) { scroll in
                        Button { open(scroll.id) } label: { stave(scroll) }
                            .buttonStyle(Carve())
                            .accessibilityLabel("\(scroll.name), \(counts[scroll.id] ?? 0) inscriptions")
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                    Button(action: new) {
                        VStack(spacing: 10) {
                            ZStack {
                                Circle().strokeBorder(Color.muted, style: StrokeStyle(lineWidth: Metric.hairline, dash: [2, 3]))
                                LucideIcon(.plus, size: 15)
                            }
                            .frame(width: 40, height: 40).frame(height: 56)
                            Text("New").font(.label).foregroundStyle(Color.muted)
                        }
                        .frame(width: 76).padding(.vertical, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(Carve())
                }
                .padding(.horizontal, Metric.gutter)
                .animation(.spring(duration: 0.45, bounce: 0.2), value: scrolls.map(\.id))
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -Metric.gutter)
            if scrolls.isEmpty {
                Text("Keep inscriptions together in scrolls. New ones are filed into the right scroll as you make them.")
                    .font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stave(_ scroll: CaptureScroll) -> some View {
        VStack(spacing: 10) {
            RuneGlyph(rune: scroll.rune, size: 40).frame(height: 56)
            VStack(spacing: 2) {
                Text(scroll.name).font(.label).lineLimit(1)
                Text("\(counts[scroll.id] ?? 0)").font(.caption).monospacedDigit().foregroundStyle(Color.muted)
                    .contentTransition(.numericText())
            }
        }
        .frame(width: 76).padding(.vertical, 12).contentShape(Rectangle())
    }
}

/// A rune on the shelf presses in like a stamp.
private struct Carve: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.4), value: configuration.isPressed)
    }
}

/// The top of a scroll's page: its rune cut large, its name, and what belongs in it.
struct ScrollHeader: View {
    let scroll: CaptureScroll
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CarvedRune(rune: scroll.rune, size: 76).padding(.leading, -8)
            Text(scroll.name).font(.geist(34, .medium, relativeTo: .largeTitle)).tracking(-1)
                .padding(.top, 14)
            if !scroll.purpose.isEmpty {
                Text(scroll.purpose).font(.bodyText).foregroundStyle(Color.muted).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            Text("\(scroll.rune.name), the rune of \(scroll.rune.meaning)")
                .font(.caption).foregroundStyle(Color.muted).padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(scroll.name). \(scroll.purpose). \(count) inscriptions.")
    }
}

/// Makes a scroll, or edits one: its name, what belongs in it, and its rune. With Apple
/// Intelligence on, the rune is chosen from the name until one is picked by hand.
struct ScrollEditor: View {
    enum Mode: Identifiable {
        case new
        case edit(CaptureScroll)
        var id: String { if case .edit(let scroll) = self { scroll.id } else { "new" } }
    }

    let mode: Mode
    /// Apple Intelligence can suggest the rune.
    var scribe = false
    let save: (String, Rune, String) -> Void

    @State private var name: String
    @State private var purpose: String
    @State private var rune: Rune
    @State private var picked: Bool
    @State private var suggesting = false
    @FocusState private var field: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field { case name, purpose }

    init(mode: Mode, scribe: Bool = false, save: @escaping (String, Rune, String) -> Void) {
        self.mode = mode; self.scribe = scribe; self.save = save
        switch mode {
        case .new:
            _name = State(initialValue: ""); _purpose = State(initialValue: ""); _rune = State(initialValue: .raidho); _picked = State(initialValue: false)
        case .edit(let scroll):
            _name = State(initialValue: scroll.name); _purpose = State(initialValue: scroll.purpose); _rune = State(initialValue: scroll.rune); _picked = State(initialValue: true)
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isNew: Bool { if case .new = mode { true } else { false } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    HStack(alignment: .center, spacing: 18) {
                        RuneGlyph(rune: rune, size: 64)
                            .id(rune)
                            .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .opacity))
                            .breathing(suggesting)
                            .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Name", text: $name)
                                .font(.geist(26, .medium, relativeTo: .title)).tracking(-0.5)
                                .focused($field, equals: .name)
                                .submitLabel(.next).onSubmit { field = .purpose }
                                .accessibilityLabel("Scroll name")
                            FocusRule(active: field == .name)
                        }
                    }
                    .animation(.spring(duration: 0.4, bounce: 0.25), value: rune)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What goes in it").font(.label)
                        TextField("Work plans, meetings, the relay test", text: $purpose, axis: .vertical)
                            .font(.bodyText).lineSpacing(3)
                            .focused($field, equals: .purpose)
                        FocusRule(active: field == .purpose)
                        Note(scribe ? "Optional. Apple Intelligence reads this to decide which inscriptions belong here."
                                    : "Optional. A reminder of what this scroll is for.")
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Heading("Rune")
                        RuneGrid(selection: Binding(get: { rune }, set: { rune = $0; picked = true }))
                            .padding(.top, 8)
                        Note(caption)
                            .contentTransition(.opacity)
                            .animation(.standard, value: caption)
                    }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 12).padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .page()
            .navigationTitle(isNew ? "New scroll" : "Edit scroll").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.bodyText) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Make" : "Save") {
                        save(trimmed, rune, purpose)
                        dismiss()
                    }
                    .font(.label).disabled(trimmed.isEmpty)
                }
            }
            .onAppear { if isNew { field = .name } }
            // The rune follows the name until one is picked.
            .task(id: "\(trimmed)|\(purpose)") { await suggest() }
        }
        .tint(Color.ink)
        .presentationDetents([.large])
    }

    private var caption: String {
        if suggesting { return "Choosing a rune for \(trimmed)…" }
        let meaning = "\(rune.name), the rune of \(rune.meaning)."
        return picked ? meaning : scribe && !trimmed.isEmpty ? "\(meaning) Chosen by Apple Intelligence; pick another if you like." : meaning
    }

    private func suggest() async {
        guard !picked, !trimmed.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(650))
        guard !Task.isCancelled, !picked else { return }
        guard scribe else { withAnimation { rune = Rune.fallback(for: trimmed) }; return }
        suggesting = true
        let chosen = await CaptureScribe.rune(for: trimmed, purpose: purpose)
        suggesting = false
        guard !Task.isCancelled, !picked else { return }
        withAnimation { rune = chosen }
    }
}

/// All twenty-four runes in the order of the futhark, the chosen one ringed.
private struct RuneGrid: View {
    @Binding var selection: Rune
    @Namespace private var ns

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 6), spacing: 4) {
            ForEach(Rune.allCases) { rune in
                let on = rune == selection
                Button { withAnimation(.spring(duration: 0.4, bounce: 0.25)) { selection = rune } } label: {
                    ZStack {
                        if on {
                            Circle().strokeBorder(Color.ink, lineWidth: Metric.hairline)
                                .matchedGeometryEffect(id: "ring", in: ns)
                        }
                        RuneGlyph(rune: rune, size: 24).foregroundStyle(on ? Color.ink : Color.muted)
                    }
                    .frame(width: 48, height: 48)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(rune.name), \(rune.meaning)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}
