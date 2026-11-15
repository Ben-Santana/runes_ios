import Foundation

// A quick question while cooking, answered from the recipe on the table. This file is what
// the model is told: how to answer, the recipe, where the cook is in it and what the timers
// are doing. Foundation only (Tests/CookTests.swift); the microphone, the model and the
// voice are in CookAssistant.swift.

enum CookAsk {
    static let instructions = """
    You are helping someone who is cooking and has their hands full. They ask a quick question out loud. \
    Answer in one or two short sentences, in plain words, the way a person standing next to them would. \
    Take amounts, times, temperatures and the order of things from the recipe you are given, and say the number itself. \
    For anything the recipe doesn't cover, such as a substitute or how to tell something is done, use sound general \
    cooking knowledge. Where food safety comes into it, give the safe answer. If you don't know, say so. \
    No lists and no headings.
    """

    /// The recipe and the state of the cooking, as text. Notes go first when it is too long,
    /// then the ends of long steps.
    static func context(_ session: CookSession, at now: Date = Date(), limit: Int = 5000) -> String {
        let recipe = session.recipe
        func text(notes: Bool, step cap: Int) -> String {
            var lines = ["Recipe: \(recipe.title)" + (recipe.yield.map { " (\($0))" } ?? "")]
            if !recipe.ingredients.isEmpty { lines += ["Ingredients:"] + recipe.ingredients.map { "- \($0)" } }
            lines += ["Steps:"] + recipe.steps.enumerated().map { "\($0.offset + 1). \($0.element.count > cap ? String($0.element.prefix(cap)) + "…" : $0.element)" }
            if notes, let kept = recipe.notes, !kept.isEmpty { lines += ["Notes:"] + kept.map { "- \($0)" } }
            if let nutrition = recipe.nutrition { lines.append("Nutrition: \(nutrition)") }
            lines.append(session.finished ? "Now: the recipe is finished." : "Now: the cook is on step \(session.step + 1) of \(session.count).")
            let timers = session.live(at: now).map { timer -> String in
                let state = timer.isRinging(at: now) ? "time is up" : "\(DurationFinder.short(timer.remaining(at: now))) left" + (timer.isPaused ? ", paused" : "")
                return "\(timer.label) from step \(timer.step + 1), \(state)"
            }
            lines.append(timers.isEmpty ? "Timers: none running." : "Timers: " + timers.joined(separator: "; ") + ".")
            return lines.joined(separator: "\n")
        }
        for (notes, cap) in [(true, Int.max), (false, Int.max), (false, 400), (false, 160)] {
            let whole = text(notes: notes, step: cap)
            if whole.count <= limit { return whole }
        }
        return String(text(notes: false, step: 160).prefix(limit))
    }
}
