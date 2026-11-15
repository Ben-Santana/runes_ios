// Runs the on-device model on a pasted recipe on this Mac and prints what it made of it and
// what the checks say, so import quality can be judged without a phone. Needs macOS 26 with
// Apple Intelligence turned on; without it, it prints why the model can't run.
//
//     xcrun --sdk macosx swiftc -parse-as-library -module-cache-path /private/tmp/runes-swift-module-cache \
//       RunesIOS/Cook/RecipeParser.swift RunesIOS/Cook/Ingredients.swift RunesIOS/Cook/RecipeImporter.swift RunesIOS/Cook/RecipeModel.swift \
//       Tools/RecipeImportProbe.swift -o /private/tmp/runes-recipe-probe && /private/tmp/runes-recipe-probe recipe.txt
import Foundation

@main
struct RecipeImportProbe {
    static func main() async {
        guard CommandLine.arguments.count > 1, let text = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) else {
            print("Usage: runes-recipe-probe <text file with a pasted recipe>"); return
        }
        let rules = RecipeParser.parse(text)
        print("Rules: \(rules.summary); clear: \(RecipeImporter.isClear(text, parsed: rules))")
        guard RecipeModel.availability == .ready else { print("Model: \(RecipeModel.availability), so nothing to run."); return }
        do {
            let started = Date()
            let recipe = try await RecipeModel.sort(text) { _ in }
            print(String(format: "Model: %.1f s\n", Date().timeIntervalSince(started)))
            print(recipe.text)
            let issues = RecipeImporter.check(recipe, against: text)
            print("\nCoverage \(Int(RecipeImporter.coverage(of: text, in: recipe) * 100))%, \(issues.count) to check")
            for issue in issues { print("- \(issue.line): \(issue.reason)") }
        } catch {
            print("Model failed: \(error)")
        }
    }
}
