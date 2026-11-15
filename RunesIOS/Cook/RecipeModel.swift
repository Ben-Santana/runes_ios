import Foundation
import FoundationModels

// The on-device language model, used for one thing: sorting a pasted recipe into its
// parts when the rules can't. Nothing leaves the phone and no key is involved. It is a
// small model, so it is told to copy rather than write, it answers into a fixed shape,
// and RecipeImporter.check compares what it wrote with what was pasted.

@Generable(description: "A cooking recipe sorted into its parts, copied from the text it was given")
struct SortedRecipe {
    @Guide(description: "The dish's name, without words like 'recipe' or 'the best'")
    var title: String
    @Guide(description: "How many it serves as the text says, such as 'Serves 4'. Empty if the text doesn't say.")
    var yield: String
    @Guide(description: "One ingredient per item with the amount the method uses, copied as written. From a shopping list with pack sizes, give the amount used, not the pack.")
    var ingredients: [String]
    @Guide(description: "The method in order, one action per item. Copy every time, temperature, amount and detail of technique as written, such as 'skin side down' or 'until golden'. Never shorten a step.")
    var steps: [String]
    @Guide(description: "Tips, storage, reheating and substitutions, one per item, copied as written. Empty if there are none.")
    var notes: [String]
    @Guide(description: "Nutrition per serving as one short line, such as '620 kcal · 55 g protein per serving'. Empty if the text doesn't say.")
    var nutrition: String
}

enum RecipeModel {
    enum Availability { case ready, downloading, off, unsupported }

    static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available: .ready
        case .unavailable(.modelNotReady): .downloading
        case .unavailable(.appleIntelligenceNotEnabled): .off
        default: .unsupported
        }
    }

    private static let instructions = """
    You sort the text of a recipe into its parts. Copy, don't write: use only what the text says, in its own words. \
    Never invent or change an ingredient, an amount, a time or a temperature. Keep every detail of how something is \
    done. Leave out stories, adverts, comments and anything that is not part of the recipe.
    """

    private static func recipe(_ title: String?, _ yield: String?, _ ingredients: [String]?, _ steps: [String]?, _ notes: [String]?, _ nutrition: String?) -> Recipe {
        func tidy(_ lines: [String]?) -> [String] {
            (lines ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let name = String((title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(Recipe.titleLimit))
        let serves = (yield ?? "").trimmingCharacters(in: .whitespacesAndNewlines), facts = (nutrition ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = tidy(notes)
        return Recipe(title: name.isEmpty ? Recipe.fallbackTitle : name, ingredients: tidy(ingredients), steps: tidy(steps),
                      yield: serves.isEmpty ? nil : serves, notes: kept.isEmpty ? nil : kept, nutrition: facts.isEmpty ? nil : facts)
    }

    /// Sorts text into a recipe, handing over what it has so far as it writes. Text too
    /// long for the model is tried once more on a narrower part before giving up.
    static func sort(_ text: String, partial: @escaping @MainActor (Recipe) -> Void) async throws -> Recipe {
        do {
            return try await run(RecipeImporter.window(text), partial: partial)
        } catch {
            guard text.count > RecipeImporter.limit / 2, !Task.isCancelled else { throw error }
            return try await run(RecipeImporter.window(text, limit: RecipeImporter.limit / 2), partial: partial)
        }
    }

    private static func run(_ text: String, partial: @escaping @MainActor (Recipe) -> Void) async throws -> Recipe {
        let session = LanguageModelSession(instructions: instructions)
        let stream = session.streamResponse(to: "Sort this recipe:\n\n" + text, generating: SortedRecipe.self,
                                            options: GenerationOptions(temperature: 0))
        var latest = recipe(nil, nil, nil, nil, nil, nil)
        for try await snapshot in stream {
            let draft = snapshot.content
            latest = recipe(draft.title, draft.yield, draft.ingredients, draft.steps, draft.notes, draft.nutrition)
            await partial(latest)
        }
        return latest
    }
}
