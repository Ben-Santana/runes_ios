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
    /// A link is on the clipboard, and whether the editor should take it by itself.
    @State private var copied = false
    @State private var fromClipboard = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var deleting: Recipe?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch store.listLook {
                case .contents: contents
                case .ledger: ledger
                }
                // A link copied in a browser or from a reel is one tap from being a recipe.
                if copied {
                    AddRow(title: "Add the link you copied") { fromClipboard = true; adding = true }
                    Hairline()
                }
                AddRow(title: "Add a recipe") { fromClipboard = false; adding = true }
                Note("Paste any recipe or a link to one. Runes sorts it into ingredients and steps, and the times in them become timers.")
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
            RecipeEditor(store: store, recipe: nil, pastes: fromClipboard) { saved in path.append(.recipe(saved.id)) }
                .onDisappear { copied = false }
        }
        .sheet(isPresented: $showSettings) { CookSettingsScreen(store: store) }
        // Knowing a link is there doesn't read it, so iOS asks nothing until it is used.
        .onAppear { copied = UIPasteboard.general.hasURLs }
        .onChange(of: scenePhase) { _, phase in if phase == .active { copied = UIPasteboard.general.hasURLs } }
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
        // With a few to choose from, the one cooked longest ago is put forward.
        if store.session == nil, store.recipes.count > 2,
           let pick = store.recipes.filter(\.isUsable).min(by: { ($0.lastCooked ?? .distantPast) < ($1.lastCooked ?? .distantPast) }) {
            Heading("Tonight?")
            ContentsRow(recipe: pick, note: RecipeBrief.reason(pick)) { path.append(.recipe(pick.id)) }
                .padding(.bottom, 24)
        }
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
    /// Said in place of the usual line under the name.
    var note: String? = nil
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
        if let note { return note }
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
    /// While cooking: the step showing is in ink, the ones behind it lighter, the ones ahead faint.
    var step: Int? = nil
    var finished = false
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let times = recipe.steps.prefix(40).map { DurationFinder.find(in: $0).reduce(0) { $0 + $1.seconds } }
        Canvas { context, size in
            let total = CGFloat(times.reduce(0, +)), gap: CGFloat = 7
            let spare = max(0, size.width - gap * CGFloat(times.count))
            var x: CGFloat = 0
            for (index, seconds) in times.enumerated() {
                // As a place in the recipe, steps with no time share the width evenly.
                let length = total > 0 ? spare * CGFloat(seconds) / total : step != nil ? spare / CGFloat(times.count) : 0
                let tall = seconds > 0 ? size.height : size.height / 2
                let here = step == index && !finished
                let shade = step == nil ? Color.ink : here ? Color.ink : finished || index < (step ?? 0) ? Color.ink.opacity(0.45) : Color.faint
                let weight = here ? 2 : Metric.hairline
                context.fill(Path(CGRect(x: x, y: size.height - tall, width: weight, height: tall)), with: .color(shade))
                if seconds > 0 || (here && total == 0) {
                    context.fill(Path(CGRect(x: x, y: size.height - weight, width: length + gap - 3, height: weight)), with: .color(shade))
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
    /// The model's one line about what goes wrong with this recipe.
    @State private var tip: String?
    /// A past receipt being read.
    @State private var reading: CookRecord?
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
                // What catches cooks out, said before the heat is on: found by rules, and
                // one line more from the model on the phone when it has something to add.
                let brief = RecipeBrief.lines(recipe) + (tip.map { [$0] } ?? [])
                if !brief.isEmpty {
                    Block {
                        ForEach(Array(brief.enumerated()), id: \.offset) { index, line in
                            if index > 0 { Hairline(delay: 0.03 * Double(index)) }
                            Text(line).font(.bodyText).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                        }
                    } header: { Heading("Before you start") }
                    .animation(.standard, value: tip)
                }
                if !shown.ingredients.isEmpty {
                    Block {
                        if let base, session == nil {
                            HStack(spacing: 12) {
                                Text("Servings").font(.bodyText)
                                if servings > 0, Int(servings) != base {
                                    Text("written for \(base)").font(.caption).foregroundStyle(Color.muted).transition(.opacity)
                                }
                                Spacer(minLength: 8)
                                NumberChip(value: Binding(get: { servings > 0 ? servings : Double(base) }, set: { servings = $0 }),
                                           range: 1...99, unit: "", label: "Servings")
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
                // Every time it was cooked, kept as the receipt it ended with.
                let receipts = store.records(for: recipe.id)
                if !receipts.isEmpty {
                    Block {
                        ForEach(Array(receipts.enumerated()), id: \.element.id) { index, record in
                            if index > 0 { Hairline(delay: 0.03 * Double(index)) }
                            Button { reading = record } label: {
                                HStack(spacing: 12) {
                                    Text(record.ended.formatted(date: .abbreviated, time: .shortened)).font(.bodyText)
                                    Spacer(minLength: 8)
                                    Text("\(record.minutes) min").font(.bodyText).monospacedDigit().foregroundStyle(Color.muted)
                                    Chevron()
                                }
                                .padding(.vertical, 12).contentShape(Rectangle())
                            }
                            .buttonStyle(PressRow())
                        }
                    } header: { Heading("Receipts", count: receipts.count) }
                }
            }
            .padding(.horizontal, Metric.gutter).padding(.top, 12).padding(.bottom, 24)
            .animation(.standard, value: count)
            .animation(.standard, value: recipe.notes)
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: recipe.id) { if RunesIOSApp.snapshotName == nil { tip = await RecipeModel.tip(for: recipe) } }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { endEditing() }.font(.label)
            }
        }
        .sheet(isPresented: $noting) { NoteSheet { store.addNote($0, to: recipe.id) } }
        .sheet(item: $reading) { record in ReceiptSheet(record: record) { store.forget(record.id) } }
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

/// A receipt from a cook that is over, to read again or throw away.
private struct ReceiptSheet: View {
    let record: CookRecord
    let forget: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView { CookReceipt(session: record.session, ended: record.ended, addNote: nil) }
                .page()
                .navigationTitle("Receipt").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Delete", role: .destructive) { forget(); dismiss() }.font(.label) }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) }
                }
        }
        .tint(Color.ink)
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

/// One page of text. Type or paste a recipe and it is sorted as you type; paste a link
/// and the page is fetched and its recipe put here as text, ready to correct. Text that
/// isn't laid out as a recipe (prose, a blog page, a message from a friend) is sorted by
/// the model on the phone, and the lines where its answer differs from what was pasted
/// are listed to check. Nothing is saved until Save.
struct RecipeEditor: View {
    @ObservedObject var store: CookStore
    let recipe: Recipe?
    let saved: (Recipe) -> Void
    @State private var text: String
    @State private var source: String?
    @State private var fetching = false
    @State private var problem: String?
    /// What was pasted, once the model has sorted it, to compare with.
    @State private var original: String?
    /// The part of it the model was given, which is what its answer is checked against.
    @State private var checked: String?
    /// The lines of the sorted recipe that differ from that. Worked out when the text changes, not on every draw.
    @State private var issues: [RecipeImporter.Issue] = []
    /// The text the editor last put there itself. A change away from it is the person's.
    @State private var placed: String?
    /// The pasted text was a whole page, which always has more words than its recipe.
    @State private var fromPage = false
    @State private var sorting: Task<Void, Never>?
    /// One sentence about how the text got here, when it wasn't the usual way.
    @State private var notice: String?
    @State private var comparing = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    /// Whether the editor takes what is on the clipboard as it opens, and saves by itself a
    /// recipe that came whole from a page's own data.
    private let pastes: Bool

    init(store: CookStore, recipe: Recipe?, text: String? = nil, original: String? = nil, pastes: Bool = false, saved: @escaping (Recipe) -> Void) {
        self.store = store; self.recipe = recipe; self.saved = saved; self.pastes = pastes
        _text = State(initialValue: text ?? recipe?.text ?? "")
        _source = State(initialValue: recipe?.source)
        _original = State(initialValue: original)
        _checked = State(initialValue: original.map { RecipeImporter.window($0) })
    }

    private var link: URL? { sorting == nil && original == nil ? RecipeImporter.link(in: text) : nil }
    private var parsed: Recipe { RecipeParser.parse(text) }
    private var model: RecipeModel.Availability { RunesIOSApp.snapshotName == nil ? RecipeModel.availability : .unsupported }
    /// Text the rules can't lay out, which the model can.
    private var unsorted: Bool {
        original == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 && !RecipeImporter.isClear(text, parsed: parsed)
    }
    private func findIssues() -> [RecipeImporter.Issue] {
        guard let checked, sorting == nil else { return [] }
        let recipe = parsed
        var found = RecipeImporter.check(recipe, against: checked)
        if !fromPage, RecipeImporter.coverage(of: checked, in: recipe) < 0.5 {
            found.append(RecipeImporter.Issue(line: "Much of what you pasted isn’t here.", reason: "Compare the two before saving."))
        }
        return found
    }

    /// Puts text in the editor without it counting as the person's typing.
    private func place(_ new: String) { placed = new; text = new }

    /// Lets go of the paste a sorted recipe is compared with.
    private func forget() { original = nil; checked = nil; fromPage = false }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.bodyText).lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .autocorrectionDisabled()
                        .disabled(sorting != nil)
                        .padding(.horizontal, Metric.gutter - 5)
                        .accessibilityLabel("Recipe text")
                    if text.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Paste a recipe, or a link to one.").font(.heading)
                            Text("Any recipe, however it is written. Runes sorts out the ingredients, the steps and the notes, and every time a step mentions becomes a timer.")
                                .font(.bodyText).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, Metric.gutter).padding(.top, 8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .animation(.standard, value: text.isEmpty)
                if !issues.isEmpty { IssueList(issues: issues) { comparing = true } }
                Rule(inset: 0)
                footer.padding(.horizontal, Metric.gutter).padding(.vertical, 12)
                    .frame(minHeight: 72)
                    .animation(.standard, value: fetching)
                    .animation(.standard, value: sorting != nil)
            }
            .animation(.standard, value: issues)
            .page()
            .navigationTitle(recipe == nil ? "New recipe" : "Edit recipe").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { sorting?.cancel(); dismiss() }.font(.label) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).font(.label).disabled(link != nil || sorting != nil || !parsed.isUsable)
                }
            }
            .onChange(of: text) { old, new in
                defer { issues = findIssues() }
                guard new != placed else { return }
                problem = nil; notice = nil
                // Typed over with a link or with something else entirely: the earlier paste no longer applies.
                if original != nil, sorting == nil, RecipeImporter.link(in: new) != nil || abs(new.count - old.count) > max(80, old.count / 2) { forget() }
            }
            .onChange(of: sorting == nil) { issues = findIssues() }
            .sheet(isPresented: $comparing) { OriginalSheet(text: original ?? "") }
        }
        .tint(Color.ink)
        .onAppear {
            issues = findIssues()
            if pastes, text.isEmpty { paste(); return }
            if recipe == nil, text.isEmpty { focused = true }
        }
    }

    /// One line under the text that says what Runes makes of it, and the one thing to do next.
    @ViewBuilder private var footer: some View {
        if let problem {
            HStack(spacing: 12) {
                Circle().fill(Color.ink).frame(width: 6, height: 6)
                Text(problem).font(.bodyText).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        } else if sorting != nil {
            status(.listChecks, "Sorting it on this phone", "Nothing leaves it. The lines appear as they are read.") {
                action("Stop") { sorting?.cancel() }
            }
        } else if let link {
            status(.link, link.host() ?? "Link", fetching ? "Reading the page…" : "A link. Runes can read the recipe from it.") {
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
                action("Paste", icon: .clipboardPaste) { paste() }
            }
        } else if unsorted, model == .ready {
            status(.info, "Not laid out as a recipe yet", "Runes can sort it into ingredients, steps and notes, on this phone.") {
                Button { sort(text, page: false) } label: {
                    Text("Sort it").font(.label).foregroundStyle(Color.paper)
                        .padding(.horizontal, 14).frame(minWidth: 84, minHeight: 36)
                        .background(Color.ink, in: RoundedRectangle(cornerRadius: Metric.control))
                }
                .buttonStyle(PressRow())
            }
        } else {
            let recipe = parsed
            let detail = notice ?? (recipe.isUsable ? recipe.summary : unsorted ? unsortedHint : "Put each step on its own line under a line that says Steps.")
            status(recipe.isUsable ? .check : .info, recipe.isUsable ? recipe.title : "No steps found yet", detail) {
                if original != nil { action("Compare") { comparing = true } }
            }
            .animation(.standard, value: recipe.summary)
        }
    }

    /// Why text that needs sorting isn't being offered it.
    private var unsortedHint: String {
        switch model {
        case .off: "Turn on Apple Intelligence in Settings and Runes can sort text like this. Or put Ingredients and Steps on lines of their own."
        case .downloading: "The model that sorts recipes is still downloading. Until then, put Ingredients and Steps on lines of their own."
        default: "Put each step on its own line under a line that says Steps."
        }
    }

    private func status<Trailing: View>(_ icon: Lucide, _ title: String, _ detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            LucideIcon(icon, size: 18).foregroundStyle(icon == .check ? Color.ink : Color.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.label).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            trailing()
        }
    }

    private func action(_ title: String, icon: Lucide? = nil, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 8) {
                if let icon { LucideIcon(icon, size: 16) }
                Text(title)
            }
            .font(.label)
            .padding(.horizontal, 14).frame(minHeight: 36)
            .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
        }
        .buttonStyle(PressRow())
    }

    private func paste() {
        guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else { problem = "The clipboard is empty. Copy a recipe or its link first."; return }
        forget(); notice = nil; problem = nil
        place(pasted)
        if let link = RecipeImporter.link(in: pasted) { fetch(link) }
        else if unsorted, model == .ready { sort(pasted, page: false) }
    }

    private func fetch(_ url: URL) {
        guard !fetching else { return }
        fetching = true; problem = nil; notice = nil; focused = false
        Task {
            do {
                switch try await store.fetch(url) {
                case .recipe(let fetched):
                    source = fetched.source
                    place(fetched.text)
                    // The publisher's own structure needs no checking: it is saved as it is.
                    if pastes, parsed.isUsable { fetching = false; save(); return }
                case .page(let page):
                    // No recipe data on the page: its words, sorted by the model when
                    // there is one, by the rules when there isn't.
                    source = url.absoluteString
                    if model == .ready { sort(page, page: true) }
                    else {
                        let rough = RecipeParser.parse(page)
                        place(rough.isUsable ? rough.text : RecipeImporter.window(page))
                        notice = rough.isUsable ? "This page publishes no recipe data, so this is a rough sort. Check it." : nil
                        if !rough.isUsable { problem = "Runes couldn’t find the recipe on that page. Its text is here to tidy." }
                    }
                }
            } catch {
                problem = error.localizedDescription
            }
            fetching = false
        }
    }

    /// Hands the text to the on-device model and shows its answer as it is written. If
    /// the model can't do it, the rules' best attempt stands, and says so.
    private func sort(_ pasted: String, page: Bool) {
        focused = false; notice = nil; fromPage = page
        sorting = Task {
            do {
                let sorted = try await RecipeModel.sort(pasted) { draft in place(draft.text) }
                guard sorted.isUsable else { throw CookError.noRecipe }
                original = pasted; checked = RecipeImporter.window(pasted, limit: RecipeModel.inputLimit)
                place(sorted.text)
            } catch {
                let rough = RecipeParser.parse(pasted)
                forget()
                place(page && rough.isUsable ? rough.text : page ? RecipeImporter.window(pasted) : pasted)
                if !Task.isCancelled { notice = "The model on this phone couldn’t sort this one. Put Ingredients and Steps on lines of their own." }
            }
            sorting = nil
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

/// The lines of a sorted recipe that don't match what was pasted, with the reason: the
/// model can drop, merge or change things, and these are the ones rules can catch.
private struct IssueList: View {
    let issues: [RecipeImporter.Issue]
    let compare: () -> Void
    private static let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule(inset: 0)
            HStack(alignment: .firstTextBaseline) {
                Text(issues.count == 1 ? "Check this" : "Check these \(issues.count)").font(.label)
                Spacer()
                Button("What you pasted", action: compare).font(.caption).foregroundStyle(Color.muted).buttonStyle(PressRow())
            }
            .padding(.top, 12).padding(.bottom, 6)
            ForEach(issues.prefix(Self.shown), id: \.self) { issue in
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.line).font(.bodyText).lineLimit(1)
                    Text(issue.reason).font(.caption).foregroundStyle(Color.muted).lineLimit(2)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }
            if issues.count > Self.shown {
                Text("and \(issues.count - Self.shown) more").font(.caption).foregroundStyle(Color.muted).padding(.vertical, 4)
            }
        }
        .padding(.horizontal, Metric.gutter).padding(.bottom, 8)
        .background(Color.soft)
    }
}

/// What was pasted, to compare the sorted recipe with.
private struct OriginalSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text).font(.bodyText).lineSpacing(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Metric.gutter)
            }
            .page()
            .navigationTitle("What you pasted").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
        }
        .tint(Color.ink)
    }
}

// MARK: Settings

struct CookSettingsScreen: View {
    @ObservedObject var store: CookStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosing: CookCommand?

    private enum Sound: String, CaseIterable { case on = "On", off = "Off" }
    private enum Voice: String, CaseIterable { case spoken = "Spoken", silent = "Silent" }

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
                        HairlineSegments(selection: Binding(get: { store.spoken ? Voice.spoken : .silent }, set: { store.setSpoken($0 == .spoken) }),
                                         options: Voice.allCases, title: \.rawValue)
                    } header: {
                        Heading("Questions")
                    } footer: {
                        Note("Hold the Ask gesture, or tap the microphone, and ask about the recipe out loud. The answer is worked out on this phone and shown in the step’s place; Spoken also says it. It needs Apple Intelligence and Runes in front.")
                    }
                    Block {
                        HairlineSegments(selection: Binding(get: { store.reads ? Sound.on : .off }, set: { store.setReads($0 == .on) }),
                                         options: Sound.allCases, title: \.rawValue)
                    } header: {
                        Heading("Read aloud")
                    } footer: {
                        Note("Says each step as you arrive at it, for when your eyes are on the pan.")
                    }
                    Block {
                        HairlineSegments(selection: Binding(get: { store.dial ? Sound.on : .off }, set: { store.setDial($0 == .on) }),
                                         options: Sound.allCases, title: \.rawValue)
                    } header: {
                        Heading("Wrist dial")
                    } footer: {
                        Note("Pinch your index finger and hold, turn your wrist to set the selected timer like the dial of a kitchen timer, and let go. On a step with no time it starts one, and while you get the ingredients out it sets how many you cook for. It keeps the band’s motion sensors on while you cook, which uses more battery.")
                    }
                    Block {
                        HairlineSegments(selection: Binding(get: { store.listLook }, set: { store.setListLook($0) }),
                                         options: CookListLook.allCases, title: \.title)
                        // Two rows: the looks made of beads, then the earlier ones.
                        HairlineSegments(selection: Binding(get: { store.cookingLook }, set: { store.setCookingLook($0) }),
                                         options: CookingLook.allCases.filter(\.beads), title: \.title)
                            .padding(.top, 12)
                        HairlineSegments(selection: Binding(get: { store.cookingLook }, set: { store.setCookingLook($0) }),
                                         options: CookingLook.allCases.filter { !$0.beads }, title: \.title)
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
