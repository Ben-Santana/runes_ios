import SwiftUI
import UIKit

// Cook: recipes read one step at a time, turned and timed from the band, so wet or
// floury hands never touch the phone. This file is the shelf of recipes, a recipe's page,
// the editor that reads pasted text or a link, and settings. The cooking screen itself is
// CookingView.swift. Drawn as a ledger, like Workouts: type and hairlines, no panels.

struct CookScreen: View {
    @ObservedObject var store: CookStore
    @Binding var path: [AppRoute]
    @State private var adding = false
    @State private var showSettings = false
    @State private var deleting: Recipe?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch store.listLook {
                case .contents: contents
                case .ledger: ledger
                }
                AddRow(title: "Add a recipe") { adding = true }
                Note("Paste a recipe or a link to one. Runes finds the steps, and the times in them become timers.")
                    .padding(.top, 8)
            }
            .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
            .animation(.entrance, value: store.recipes)
        }
        .page()
        .navigationTitle("Cook").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: { LucideIcon(.settings, size: 19).frame(width: 36, height: 36) }
                    .accessibilityLabel("Cook settings")
            }
        }
        .sheet(isPresented: $adding) {
            RecipeEditor(store: store, recipe: nil) { saved in path.append(.recipe(saved.id)) }
        }
        .sheet(isPresented: $showSettings) { CookSettingsScreen(store: store) }
        .confirmationDialog("Delete \(deleting?.title ?? "this recipe")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete recipe", role: .destructive) { if let deleting { store.delete(deleting.id) } }
        }
    }

    /// Today's rows: number, name, the recipe's line of time, and a play button.
    @ViewBuilder private var ledger: some View {
        if let session = store.session {
            CookingBanner(session: session) { path.append(.cooking) }
                .padding(.bottom, 28)
        }
        Heading("Recipes", count: store.recipes.count)
        ForEach(Array(store.recipes.enumerated()), id: \.element.id) { index, recipe in
            RecipeRow(index: index, recipe: recipe, cooking: store.session?.recipe.id == recipe.id,
                      open: { path.append(.recipe(recipe.id)) },
                      start: { begin(recipe) })
                .swipeToDelete(confirms: true) { deleting = recipe }
                .arrive(index)
            Hairline(delay: 0.05 * Double(index))
        }
    }

    /// A cookbook's contents page: what is cooking, what was cooked lately, and the rest.
    @ViewBuilder private var contents: some View {
        let recent = Array(store.recipes.filter { $0.lastCooked != nil }.sorted { ($0.lastCooked ?? .distantPast) > ($1.lastCooked ?? .distantPast) }.prefix(3))
        let rest = store.recipes.filter { recipe in !recent.contains { $0.id == recipe.id } }
        if let session = store.session {
            Heading("Cooking now")
            ContentsRow(recipe: session.recipe, session: session) { path.append(.cooking) }
                .padding(.bottom, 24)
        }
        if !recent.isEmpty {
            Heading("Recent")
            contentsRows(recent).padding(.bottom, 24)
        }
        Heading(recent.isEmpty ? "Recipes" : "All", count: rest.count)
        contentsRows(rest)
        Hairline()
    }

    private func contentsRows(_ recipes: [Recipe]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(recipes.enumerated()), id: \.element.id) { index, recipe in
                ContentsRow(recipe: recipe) { path.append(.recipe(recipe.id)) }
                    .swipeToDelete(confirms: true) { deleting = recipe }
                    .arrive(index)
            }
        }
    }

    /// Carries on with the recipe already being cooked, or starts this one.
    private func begin(_ recipe: Recipe) {
        if store.session?.recipe.id != recipe.id { store.start(recipe) }
        path.append(.cooking)
    }
}

/// The recipe being cooked: a pulsing dot, where it is, and its soonest timer.
private struct CookingBanner: View {
    let session: CookSession
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    PulseDot()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(session.recipe.title) · cooking").font(.label).lineLimit(1)
                        Text(session.finished ? "Finished" : session.position).font(.caption).foregroundStyle(Color.muted)
                    }
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let timer = session.live(at: context.date).first {
                            Text(timer.isRinging(at: context.date) ? "Done" : DurationFinder.clock(timer.remaining(at: context.date)))
                                .font(.heading).monospacedDigit().contentTransition(.numericText())
                        }
                    }
                    Chevron()
                }
                StepProgress(count: session.count, step: session.step, finished: session.finished)
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
        .accessibilityHint("Opens the recipe you’re cooking.")
    }
}

/// A recipe as type and ticks: number, name, one tick per step (taller where a step has
/// a timer), and a hairline play button.
private struct RecipeRow: View {
    let index: Int
    let recipe: Recipe
    let cooking: Bool
    let open: () -> Void
    let start: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(String(format: "%02d", index + 1))
                        .font(.geist(12, .medium, relativeTo: .caption)).monospacedDigit().foregroundStyle(Color.muted)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(recipe.title).font(.heading).lineLimit(2).multilineTextAlignment(.leading)
                        TimeLine(recipe: recipe)
                        Text(recipe.timeSummary).font(.caption).foregroundStyle(Color.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 18).contentShape(Rectangle())
            }
            .buttonStyle(PressRow())
            Button(action: start) {
                ZStack {
                    Circle().strokeBorder(Color.ink, lineWidth: Metric.hairline)
                    if cooking { OrbitDot(radius: 24) }
                    LucideIcon(.play, size: 16).offset(x: 1)
                }
                .frame(width: 48, height: 48).contentShape(Circle())
            }
            .buttonStyle(Ripple())
            .accessibilityLabel(cooking ? "Continue \(recipe.title)" : "Cook \(recipe.title)")
            .disabled(!recipe.isUsable).opacity(recipe.isUsable ? 1 : 0.3)
        }
    }
}

/// A recipe as a line in a cookbook's contents: its name, a dotted leader that draws
/// across, and what its timers add up to. The recipe being cooked shows its soonest timer.
private struct ContentsRow: View {
    let recipe: Recipe
    var session: CookSession? = nil
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(recipe.title).font(.heading).lineLimit(2).multilineTextAlignment(.leading).layoutPriority(1)
                    Leader().frame(minWidth: 16)
                    trailing.font(.geist(15, .medium, relativeTo: .body)).monospacedDigit().lineLimit(1).fixedSize().layoutPriority(2)
                }
                Text(caption).font(.caption).foregroundStyle(Color.muted).lineLimit(1)
            }
            .padding(.vertical, 14).contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
        .accessibilityElement(children: .combine)
        .accessibilityHint(session == nil ? "" : "Opens the recipe you’re cooking.")
    }

    @ViewBuilder private var trailing: some View {
        if let session {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let timer = session.live(at: context.date).first {
                    Text(timer.isRinging(at: context.date) ? "Time’s up" : DurationFinder.clock(timer.remaining(at: context.date)))
                        .contentTransition(.numericText())
                } else {
                    Text(session.finished ? "Done" : "\(session.step + 1) of \(session.count)")
                }
            }
        } else if recipe.timed > 0 {
            HStack(spacing: 5) {
                LucideIcon(.timer, size: 14).foregroundStyle(Color.muted)
                Text(DurationFinder.short(recipe.timed))
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("\(DurationFinder.short(recipe.timed)) on timers")
        } else {
            Text(recipe.steps.count == 1 ? "1 step" : "\(recipe.steps.count) steps").foregroundStyle(Color.muted)
        }
    }

    private var caption: String {
        if let session { return session.finished ? "Finished" : session.position }
        var parts = [recipe.yield, recipe.steps.count == 1 ? "1 step" : "\(recipe.steps.count) steps"].compactMap { $0 }
        if recipe.cooked > 0 { parts.append(recipe.cooked == 1 ? "cooked once" : "cooked \(recipe.cooked) times") }
        return parts.joined(separator: " · ")
    }
}

/// Dots to the trailing edge that draw in once, as in a table of contents.
private struct Leader: View {
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { $0.move(to: CGPoint(x: 1, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.midY)) }
        }
    }

    var body: some View {
        Line().trim(from: 0, to: drawn || reduceMotion ? 1 : 0)
            .stroke(Color.faint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 5]))
            .frame(height: 2).padding(.bottom, 3)
            .onAppear { withAnimation(.easeOut(duration: 0.6)) { drawn = true } }
            .accessibilityHidden(true)
    }
}

/// A recipe as a line of time: a tick where each step begins and, after a step that has a
/// time, a hairline as long as that time. It draws in once from the leading edge.
struct TimeLine: View {
    let recipe: Recipe
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let times = recipe.steps.prefix(40).map { DurationFinder.find(in: $0).reduce(0) { $0 + $1.seconds } }
        Canvas { context, size in
            let total = CGFloat(times.reduce(0, +)), gap: CGFloat = 7
            let spare = max(0, size.width - gap * CGFloat(times.count))
            var x: CGFloat = 0
            for seconds in times {
                let length = total > 0 ? spare * CGFloat(seconds) / total : 0
                let tall = seconds > 0 ? size.height : size.height / 2
                context.fill(Path(CGRect(x: x, y: size.height - tall, width: Metric.hairline, height: tall)), with: .color(Color.ink))
                if seconds > 0 {
                    context.fill(Path(CGRect(x: x, y: size.height - Metric.hairline, width: length + gap - 3, height: Metric.hairline)), with: .color(Color.ink))
                }
                x += gap + length
            }
        }
        .frame(height: 14)
        .mask(alignment: .leading) { Rectangle().scaleEffect(x: drawn || reduceMotion ? 1 : 0, anchor: .leading) }
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { drawn = true } }
        .accessibilityHidden(true)
    }
}

extension Recipe {
    /// "8 ingredients · 6 steps · 4 timers · 27 min timed".
    var timeSummary: String { timed > 0 ? "\(summary) · \(DurationFinder.short(timed)) timed" : summary }
}

/// One short hairline per step; a step with a timer stands taller.
struct StepTicks: View {
    let recipe: Recipe
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(recipe.steps.prefix(24).enumerated()), id: \.offset) { _, step in
                    Capsule().fill(Color.ink).frame(width: Metric.hairline, height: DurationFinder.find(in: step).isEmpty ? 7 : 14)
                }
            }
            Text(recipe.summary).font(.caption).foregroundStyle(Color.muted).lineLimit(1)
        }
        .frame(height: 16, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recipe.summary)
    }
}

/// Every step as a hairline segment: done in ink, the current one in ink too, the rest faint.
struct StepProgress: View {
    let count: Int
    let step: Int
    var finished = false
    var height: CGFloat = 2

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(1, count), id: \.self) { index in
                Capsule().fill(index <= step || finished ? Color.ink : Color.rule)
                    .opacity(index == step && !finished ? 1 : index < step || finished ? 0.45 : 1)
                    .frame(height: height)
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.15), value: step)
        .animation(.standard, value: finished)
        .accessibilityHidden(true)
    }
}

// MARK: A recipe

struct RecipeScreen: View {
    @ObservedObject var store: CookStore
    let recipeID: String
    @Binding var path: [AppRoute]
    @State private var editing = false
    @State private var confirmDelete = false
    /// How many to cook for; 0 is as the recipe is written.
    @State private var servings = 0.0
    /// Ingredients ticked off before cooking starts.
    @State private var ready: Set<Int> = []
    @State private var noting = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let recipe = store.recipe(recipeID) { content(recipe) }
            else { Text("This recipe was deleted.").font(.bodyText).foregroundStyle(Color.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .page()
        .navigationTitle("Recipe").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    menuItem("Edit", .pencil) { editing = true }
                    menuItem("Delete", .trash2, role: .destructive) { confirmDelete = true }
                } label: {
                    LucideIcon(.ellipsis, size: 20).frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .accessibilityLabel("More")
            }
        }
        .sheet(isPresented: $editing) {
            if let recipe = store.recipe(recipeID) { RecipeEditor(store: store, recipe: recipe) { _ in } }
        }
        .confirmationDialog("Delete this recipe?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete recipe", role: .destructive) { store.delete(recipeID); dismiss() }
        }
    }

    /// The page follows the servings chosen: amounts in the list and in the steps scale,
    /// times don't. While the recipe is being cooked it shows what is being cooked.
    private func content(_ recipe: Recipe) -> some View {
        let session = store.session?.recipe.id == recipe.id ? store.session : nil
        let base = recipe.servings
        let count = session?.recipe.servings ?? (servings > 0 ? Int(servings) : base)
        let shown = count.map(recipe.scaled(to:)) ?? recipe
        let ticked = session?.ready ?? ready
        return ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(recipe.title).font(.display).tracking(-0.6).fixedSize(horizontal: false, vertical: true)
                    Text(([shown.yield, recipe.sourceHost].compactMap { $0 } + [recipe.cooked > 0 ? (recipe.cooked == 1 ? "Cooked once" : "Cooked \(recipe.cooked) times") : nil]
                        .compactMap { $0 }).joined(separator: " · "))
                        .font(.caption).foregroundStyle(Color.muted)
                    if let nutrition = recipe.nutrition {
                        Text(nutrition).font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    TimeLine(recipe: recipe).padding(.top, 6)
                    Text(recipe.timeSummary).font(.caption).foregroundStyle(Color.muted)
                }
                if !shown.ingredients.isEmpty {
                    Block {
                        if let base, session == nil {
                            HStack(spacing: 12) {
                                Text("Amounts for").font(.bodyText)
                                Spacer(minLength: 8)
                                NumberChip(value: Binding(get: { servings > 0 ? servings : Double(base) }, set: { servings = $0 }),
                                           range: 1...99, unit: base == 1 ? "serving" : "servings", label: "Servings")
                            }
                            .padding(.vertical, 8)
                            Hairline()
                        }
                        ForEach(Array(shown.ingredients.enumerated()), id: \.offset) { index, item in
                            if index > 0 { Hairline(delay: 0.03 * Double(index)) }
                            IngredientRow(text: item, ready: ticked.contains(index)) {
                                if session != nil { store.toggle(ingredient: index) }
                                else if ready.contains(index) { ready.remove(index) } else { ready.insert(index) }
                            }
                        }
                    } header: {
                        Heading("Ingredients", count: shown.ingredients.count)
                    } footer: {
                        Note("Tap what you have out. The ticks come with you when you start cooking.")
                    }
                    .sensoryFeedback(.selection, trigger: ticked)
                }
                Block {
                    ForEach(Array(shown.steps.enumerated()), id: \.offset) { index, step in
                        SpineStep(index: index, last: index == shown.steps.count - 1, text: step, uses: shown.uses(step: index))
                    }
                } header: { Heading("Steps", count: shown.steps.count).padding(.bottom, 4) }
                NotesBlock(notes: recipe.notes ?? []) { noting = true }
            }
            .padding(.horizontal, Metric.gutter).padding(.top, 12).padding(.bottom, 24)
            .animation(.standard, value: count)
            .animation(.standard, value: recipe.notes)
        }
        .sheet(isPresented: $noting) { NoteSheet { store.addNote($0, to: recipe.id) } }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Rule(inset: 0)
                Button {
                    if session == nil { store.start(shown, ready: ready) }
                    path.append(.cooking)
                } label: { Text(session != nil ? "Continue cooking" : "Start cooking") }
                    .buttonStyle(CapsuleAction(filled: true))
                    .disabled(!recipe.isUsable)
                    .padding(.horizontal, Metric.gutter).padding(.top, 14).padding(.bottom, -8)
            }
            .background(Color.paper)
        }
    }
}

/// An ingredient as a ledger line: how much in its own column, then what. Tapping ticks it off.
private struct IngredientRow: View {
    let text: String
    let ready: Bool
    let toggle: () -> Void
    static let amountWidth: CGFloat = 84

    var body: some View {
        if text.hasSuffix(":") {
            Text(text.dropLast()).font(.label).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 16).padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)
        } else {
            let line = Ingredients.split(text)
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(line.amount ?? "").font(.bodyText).monospacedDigit().foregroundStyle(Color.muted)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: Self.amountWidth, alignment: .trailing)
                        .contentTransition(.numericText())
                    Text(line.name).font(.bodyText).strikethrough(ready, color: Color.muted)
                        .foregroundStyle(ready ? Color.muted : Color.ink)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    LucideIcon(.check, size: 14).opacity(ready ? 1 : 0)
                }
                .padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(PressRow())
            .animation(.standard, value: ready)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityAddTraits(ready ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// A step on the recipe's spine: its number in a circle on a line that runs down the page
/// and draws in once, inked where the step has a timer. Under its words, its times and
/// the amounts it uses without saying.
private struct SpineStep: View {
    let index: Int
    let last: Bool
    let text: String
    let uses: [StepUse]
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let node: CGFloat = 26

    var body: some View {
        let durations = DurationFinder.find(in: text)
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                segment.frame(height: 11).opacity(index > 0 ? 1 : 0)
                ZStack {
                    Circle().strokeBorder(durations.isEmpty ? Color.rule : Color.ink, lineWidth: durations.isEmpty ? Metric.hairline : 1.5)
                    Text("\(index + 1)").font(.geist(11, .medium, relativeTo: .caption)).monospacedDigit()
                        .foregroundStyle(durations.isEmpty ? Color.muted : Color.ink)
                }
                .frame(width: Self.node, height: Self.node)
                segment.frame(maxHeight: .infinity).opacity(last ? 0 : 1)
            }
            .frame(width: Self.node)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(text).font(.bodyText).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                if !durations.isEmpty {
                    HStack(spacing: 6) { ForEach(durations, id: \.self) { DurationChip(duration: $0) } }
                }
                if !uses.isEmpty {
                    Text(uses.map(\.text).joined(separator: " · ")).font(.caption).foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Uses \(uses.map(\.text).joined(separator: ", "))")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { withAnimation(.easeOut(duration: 0.3).delay(0.06 * Double(index))) { drawn = true } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(index + 1). \(text)")
    }

    private var segment: some View {
        Rectangle().fill(Color.rule).frame(width: Metric.hairline)
            .scaleEffect(y: drawn || reduceMotion ? 1 : 0, anchor: .top)
    }
}

/// Tips, storage, reheating and what to change next time: kept with the recipe, out of
/// the way of the steps.
struct NotesBlock: View {
    let notes: [String]
    var add: (() -> Void)? = nil
    var body: some View {
        Block {
            ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                if index > 0 { Hairline(delay: 0.03 * Double(index)) }
                Text(note).font(.bodyText).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            }
            if let add {
                if !notes.isEmpty { Hairline() }
                AddRow(title: "Add a note", action: add)
            }
        } header: { Heading("Notes", count: notes.isEmpty ? nil : notes.count) }
    }
}

/// One note, typed: what to do differently next time.
struct NoteSheet: View {
    let save: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        FormSheet("Note", done: "Save", canSave: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, save: { save(text) }) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Less salt next time", text: $text, axis: .vertical)
                    .font(.heading).lineLimit(1...6).focused($focused)
                FocusRule(active: focused)
                Note("Kept with the recipe, and shown when you finish cooking it.")
            }
        }
        .presentationDetents([.medium])
        .onAppear { focused = true }
    }
}

/// "Simmer · 15 min", as a quiet chip under a step.
struct DurationChip: View {
    let duration: StepDuration
    var body: some View {
        HStack(spacing: 5) {
            LucideIcon(.timer, size: 13)
            Text([duration.label, duration.short].compactMap { $0 }.joined(separator: " · ")).font(.caption).monospacedDigit()
        }
        .foregroundStyle(Color.muted)
        .padding(.horizontal, 8).frame(minHeight: 24)
        .overlay(Capsule().strokeBorder(Color.rule, lineWidth: Metric.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timer: \(duration.label ?? "step"), \(duration.short)")
    }
}

// MARK: Editor

/// One page of text. Paste a recipe and it is sorted as you type; paste a link and the
/// page is fetched and its recipe put here as text, ready to correct.
struct RecipeEditor: View {
    @ObservedObject var store: CookStore
    let recipe: Recipe?
    let saved: (Recipe) -> Void
    @State private var text: String
    @State private var source: String?
    @State private var fetching = false
    @State private var problem: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(store: CookStore, recipe: Recipe?, saved: @escaping (Recipe) -> Void) {
        self.store = store; self.recipe = recipe; self.saved = saved
        _text = State(initialValue: recipe?.text ?? "")
        _source = State(initialValue: recipe?.source)
    }

    private var link: URL? { RecipeParser.link(in: text) }
    private var parsed: Recipe { RecipeParser.parse(text) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.bodyText).lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .autocorrectionDisabled()
                        .padding(.horizontal, Metric.gutter - 5)
                        .accessibilityLabel("Recipe text")
                    if text.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Paste a recipe, or a link to one.").font(.heading)
                            Text("Start with its name. Runes sorts out the ingredients and the steps, and every time a step mentions becomes a timer.")
                                .font(.bodyText).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, Metric.gutter).padding(.top, 8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .animation(.standard, value: text.isEmpty)
                Rule(inset: 0)
                footer.padding(.horizontal, Metric.gutter).padding(.vertical, 12)
                    .frame(minHeight: 72)
                    .animation(.standard, value: fetching)
            }
            .page()
            .navigationTitle(recipe == nil ? "New recipe" : "Edit recipe").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.label) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).font(.label).disabled(link != nil || !parsed.isUsable)
                }
            }
            .onChange(of: text) { problem = nil }
        }
        .tint(Color.ink)
        .onAppear { if recipe == nil { focused = true } }
    }

    /// One line under the text that says what Runes makes of it, and the one thing to do next.
    @ViewBuilder private var footer: some View {
        if let problem {
            HStack(spacing: 12) {
                Circle().fill(Color.ink).frame(width: 6, height: 6)
                Text(problem).font(.bodyText).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        } else if let link {
            HStack(spacing: 12) {
                LucideIcon(.link, size: 18).foregroundStyle(Color.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.host() ?? "Link").font(.label).lineLimit(1)
                    Text(fetching ? "Reading the page…" : "A link. Runes can read the recipe from it.").font(.caption).foregroundStyle(Color.muted)
                }
                Spacer(minLength: 8)
                Button { fetch(link) } label: {
                    Group { if fetching { ProgressView().tint(Color.paper) } else { Text("Get recipe") } }
                        .font(.label).foregroundStyle(Color.paper)
                        .padding(.horizontal, 14).frame(minWidth: 104, minHeight: 36)
                        .background(Color.ink, in: RoundedRectangle(cornerRadius: Metric.control))
                }
                .buttonStyle(PressRow()).disabled(fetching)
            }
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack {
                Text("Nothing here yet.").font(.caption).foregroundStyle(Color.muted)
                Spacer()
                Button { paste() } label: {
                    HStack(spacing: 8) { LucideIcon(.clipboardPaste, size: 16); Text("Paste") }
                        .font(.label)
                        .padding(.horizontal, 14).frame(minHeight: 36)
                        .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
                }
                .buttonStyle(PressRow())
            }
        } else {
            let recipe = parsed
            HStack(alignment: .center, spacing: 12) {
                LucideIcon(recipe.isUsable ? .check : .info, size: 18).foregroundStyle(recipe.isUsable ? Color.ink : Color.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.isUsable ? recipe.title : "No steps found yet").font(.label).lineLimit(1)
                    Text(recipe.isUsable ? recipe.summary : "Put each step on its own line under a line that says Steps.")
                        .font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
            .animation(.standard, value: recipe.summary)
            .accessibilityElement(children: .combine)
        }
    }

    private func paste() {
        guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else { problem = "The clipboard is empty. Copy a recipe or its link first."; return }
        text = pasted
        if let link = RecipeParser.link(in: pasted) { fetch(link) }
    }

    private func fetch(_ url: URL) {
        guard !fetching else { return }
        fetching = true; problem = nil; focused = false
        Task {
            do {
                let fetched = try await store.fetch(url)
                source = fetched.source
                text = fetched.text
            } catch {
                problem = error.localizedDescription
            }
            fetching = false
        }
    }

    private func save() {
        var result = parsed
        if let recipe { result.id = recipe.id; result.added = recipe.added; result.cooked = recipe.cooked; result.lastCooked = recipe.lastCooked }
        result.source = source
        store.save(result)
        dismiss()
        saved(result)
    }
}

// MARK: Settings

struct CookSettingsScreen: View {
    @ObservedObject var store: CookStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosing: CookCommand?

    private enum Sound: String, CaseIterable { case on = "On", off = "Off" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    Block {
                        ForEach(Array(CookCommand.allCases.enumerated()), id: \.element) { index, command in
                            if index > 0 { Hairline(delay: 0.04 * Double(index)) }
                            TriggerRow(title: command.title, detail: command.detail,
                                       steps: store.controls.trigger(for: command)?.steps) { choosing = command }
                        }
                    } header: {
                        Heading("Gestures")
                    } footer: {
                        Note("A gesture or a combo each. While you cook, they turn the recipe’s pages and run its timers, and mappings that use their gestures are off.")
                    }
                    SwitchControlsBlock()
                    Block {
                        HairlineSegments(selection: Binding(get: { store.sounds ? Sound.on : .off }, set: { store.setSounds($0 == .on) }),
                                         options: Sound.allCases, title: \.rawValue)
                    } header: {
                        Heading("Sounds")
                    } footer: {
                        Note("A tick for each step, and a bell when a timer ends that rings until you stop it, also with the phone locked.")
                    }
                    Block {
                        HairlineSegments(selection: Binding(get: { store.buzz }, set: { store.setBuzz($0) }),
                                         options: CookBuzz.allCases, title: \.title)
                    } header: {
                        Heading("On the wrist")
                    } footer: {
                        Note("The band buzzes three times when a timer ends, until you stop it. Everything adds a light tap for each gesture it takes.")
                    }
                    Block {
                        HairlineSegments(selection: Binding(get: { store.listLook }, set: { store.setListLook($0) }),
                                         options: CookListLook.allCases, title: \.title)
                        HairlineSegments(selection: Binding(get: { store.cookingLook }, set: { store.setCookingLook($0) }),
                                         options: CookingLook.allCases, title: \.title)
                            .padding(.top, 12)
                    } header: {
                        Heading("Look")
                    } footer: {
                        Note("Temporary. The first is the recipe list, the second the cooking screen. Try each, pick one, and the other goes.")
                    }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
            }
            .page()
            .navigationTitle("Cook settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
            .sheet(item: $choosing) { command in
                let current = store.controls.trigger(for: command)
                let others = CookCommand.allCases.filter { $0 != command }
                TriggerSheet(title: command.title, caption: command.detail, rules: CommandTrigger.rules,
                             steps: current?.steps ?? [], intervalMs: current?.intervalMs ?? ComboRules.defaultTime,
                             taken: Set(others.compactMap(store.controls.gesture)),
                             feed: RunesIOSApp.snapshotName == nil ? .shared : nil,
                             note: { steps in
                    others.first { store.controls.trigger(for: $0)?.steps == steps }.map { "\($0.title) uses this; they’ll swap." }
                        ?? (CommandTrigger(steps: steps).usesMotion ? "Rotation, movement and air gestures keep the band’s motion sensors on while you cook, which uses more battery." : nil)
                }, save: { steps, interval in
                    store.setTrigger(steps.isEmpty ? nil : CommandTrigger(steps: steps, intervalMs: interval), for: command)
                })
            }
        }
        .tint(Color.ink)
    }
}
