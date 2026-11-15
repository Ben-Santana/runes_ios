// Isolated checks for Cook's import: a link among other words, a page read as text, text cut to what the on-device
// model takes, and the comparison of a sorted recipe with what was pasted. The model itself is not run here.
//
//     swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Cook/RecipeParser.swift RunesIOS/Cook/Ingredients.swift \
//       RunesIOS/Cook/RecipeImporter.swift Tests/CookImportTests.swift -o /private/tmp/runes-cook-import-tests && /private/tmp/runes-cook-import-tests
import Foundation

@main
struct CookImportTests {
    static func main() {
        // MARK: Links
        precondition(RecipeImporter.link(in: "https://example.com/soup")?.host() == "example.com")
        precondition(RecipeImporter.link(in: "Try this tonight: https://example.com/recipes/dal. Looks good!")?.path() == "/recipes/dal")
        precondition(RecipeImporter.link(in: "Dal\nIngredients\n200 g lentils\n1 tsp turmeric\nMethod\nSimmer the lentils for 20 minutes then season well and serve.\nFrom https://example.com/dal") == nil,
                     "A recipe that cites its source is still a recipe")
        precondition(RecipeImporter.link(in: "https://a.example/x and https://b.example/y") == nil && RecipeImporter.link(in: "No link here") == nil)

        // MARK: A page with no recipe data
        let html = """
        <html><head><title>Garlic butter salmon | Some Kitchen</title><style>p { color: red }</style>
        <script>var tracking = "Bake for 99 minutes";</script></head>
        <body><nav><a href="/">Home</a><a href="/recipes">Recipes</a></nav>
        <article><h1>Garlic butter salmon</h1>
        <p>My grandmother made this every Sunday &amp; so do I.</p>
        <h2>Ingredients</h2><ul><li>2 salmon fillets, skin on</li><li>30&nbsp;g butter</li><li>3 cloves garlic</li></ul>
        <h2>Instructions</h2><ol><li>Heat a pan over a medium-high heat.</li>
        <li>Cook the salmon <b>skin side down</b> for 4 minutes, until the skin is crisp.</li>
        <li>Turn, add the butter and garlic, and cook for 2 minutes more.</li></ol>
        <h3>Notes</h3><p>Keeps for 2 days in the fridge.</p></article>
        <footer>Copyright Some Kitchen</footer></body></html>
        """
        let page = RecipeImporter.text(fromHTML: html)
        precondition(page.hasPrefix("Garlic butter salmon") && !page.contains("tracking") && !page.contains("Home") && !page.contains("Copyright"), page)
        precondition(page.contains("- 30 g butter") && page.contains("My grandmother made this every Sunday & so do I."), page)
        let fromPage = RecipeParser.parse(page)
        precondition(fromPage.title == "Garlic butter salmon" && fromPage.ingredients == ["2 salmon fillets, skin on", "30 g butter", "3 cloves garlic"], "\(fromPage)")
        precondition(fromPage.steps.count == 3 && fromPage.steps[1] == "Cook the salmon skin side down for 4 minutes, until the skin is crisp.", "\(fromPage.steps)")
        precondition(fromPage.notes == ["Keeps for 2 days in the fridge."] && fromPage.timerCount == 2)
        precondition(RecipeImporter.isClear(page, parsed: fromPage), "Headings and a list under each: the rules are enough")
        precondition(RecipeImporter.text(fromHTML: "<p>One</p><p>Two<br>Three</p>") == "One\nTwo\nThree")

        // MARK: Prose is not clear
        let prose = "Salmon. Take 2 salmon fillets and cook them skin side down in 30 g butter for 4 minutes, then turn and cook 2 minutes more."
        precondition(!RecipeImporter.isClear(prose, parsed: RecipeParser.parse(prose)))

        // MARK: Text too long for the model
        let story = (0..<120).map { "Paragraph \($0) of a long story about a holiday and a market stall that sold the best tomatoes anyone had seen." }
        let long = (["Tomato soup"] + story + ["Ingredients", "1 onion, chopped", "800 g tinned tomatoes", "2 tbsp cream", "Method",
                                              "Soften the onion for 5 minutes.", "Add the tomatoes and simmer for 20 minutes.", "Comments", "Lovely! I added 3 carrots."]).joined(separator: "\n")
        let cut = RecipeImporter.window(long)
        precondition(cut.count <= RecipeImporter.limit && cut.hasPrefix("Tomato soup\n") && cut.contains("800 g tinned tomatoes") && cut.contains("simmer for 20 minutes"), cut)
        precondition(!cut.contains("carrots") && !cut.contains("Paragraph 3 "), "Comments and the story go")
        precondition(RecipeImporter.window("Short text") == "Short text")
        precondition(RecipeImporter.window(long, limit: 200).count <= 200)

        // MARK: Checking a sorted recipe against what was pasted
        let pasted = """
        Honestly the best salmon. Prep time: 5 minutes.
        You need 2 salmon fillets, 30 g butter and 3 cloves of garlic. Get a pan over a medium-high heat or the oven to 200°C.
        Cook the salmon skin side down for 4 minutes until crisp, turn it, add the butter and garlic and give it 2 minutes more.
        """
        let good = Recipe(title: "Salmon", ingredients: ["2 salmon fillets", "30 g butter", "3 cloves garlic"],
                          steps: ["Get a pan over a medium-high heat or the oven to 200°C.", "Cook the salmon skin side down for 4 minutes until crisp.",
                                  "Turn it, add the butter and garlic and give it 2 minutes more."])
        precondition(RecipeImporter.check(good, against: pasted).isEmpty, "\(RecipeImporter.check(good, against: pasted))")
        precondition(RecipeImporter.coverage(of: pasted, in: good) > 0.6)

        var wrong = good
        wrong.ingredients = ["4 salmon fillets", "30 g butter", "3 cloves garlic", "1 lemon"]
        let amounts = RecipeImporter.check(wrong, against: pasted)
        precondition(amounts.map(\.line) == ["4 salmon fillets", "1 lemon"] && amounts[0].reason.contains("another amount") && amounts[1].reason.contains("ingredient"), "\(amounts)")
        precondition(RecipeImporter.check(Recipe(title: "x", ingredients: ["2 eggs", "1 pinch salt"], steps: ["Beat."]), against: "Beat two eggs with a pinch of salt.").isEmpty,
                     "Numbers in words are numbers")
        wrong = good
        wrong.ingredients[2] = "3 cloves shallot"
        precondition(RecipeImporter.check(wrong, against: pasted).map(\.reason) == ["This ingredient isn’t in what you pasted."])
        wrong = good
        wrong.steps[1] = "Cook the salmon skin side down for 6 minutes until crisp."
        let times = RecipeImporter.check(wrong, against: pasted)
        precondition(times.count == 2 && times[0].reason.contains("6 minutes") && times[1].line == "4 minutes", "A changed time is flagged, and so is the one it replaced: \(times)")
        wrong = good
        wrong.steps[0] = "Get a pan hot."
        precondition(RecipeImporter.check(wrong, against: pasted).map(\.line) == ["200°C"], "\(RecipeImporter.check(wrong, against: pasted))")
        wrong = good
        wrong.steps = ["Cook the salmon."]
        precondition(RecipeImporter.check(wrong, against: pasted).count == 3 && RecipeImporter.coverage(of: pasted, in: wrong) < 0.6,
                     "\(RecipeImporter.check(wrong, against: pasted)) \(RecipeImporter.coverage(of: pasted, in: wrong))")
        // "½" and "1/2" are the same amount.
        precondition(RecipeImporter.check(Recipe(title: "x", ingredients: ["½ cup cream"], steps: ["Stir in the cream."]), against: "Stir in 1/2 cup cream.").isEmpty)
        // A time the page gives for the whole recipe isn't one a step must have.
        precondition(RecipeImporter.check(good, against: pasted + "\nTotal time: 45 minutes").isEmpty)

        print("Cook import checks passed")
    }
}
