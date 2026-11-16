// Isolated checks for Cook: times found in a step, pasted text sorted into a recipe, a recipe read from a web page,
// a recipe being cooked (steps, timers that start, pause, reset and take a minute one at a time, the band's gestures),
// where each step happens, and the eight beads a cook is shown with.
//
//     swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift \
//       RunesIOS/Persistence/IdentityStore.swift RunesIOS/Mappings/MappingModel.swift RunesIOS/Mappings/AirGesture.swift RunesIOS/Mappings/MappingEngine.swift \
//       RunesIOS/Mappings/TriggerRules.swift RunesIOS/Mappings/CommandTrigger.swift \
//       Shared/ProfileIcon.swift Shared/SVGPath.swift Shared/LucideData.swift \
//       RunesIOS/Cook/RecipeParser.swift RunesIOS/Cook/Ingredients.swift RunesIOS/Cook/CookDial.swift RunesIOS/Cook/CookModel.swift RunesIOS/Cook/CookAsk.swift \
//       RunesIOS/Cook/Stations.swift RunesIOS/Cook/Beads.swift \
//       Tests/CookTests.swift -o /private/tmp/runes-cook-tests && /private/tmp/runes-cook-tests
import Foundation

@main
struct CookTests {
    static func seconds(_ text: String) -> [Int] { DurationFinder.find(in: text).map(\.seconds) }

    static func main() {
        // MARK: Times in a step
        precondition(seconds("Simmer for 20 minutes.") == [1200])
        precondition(seconds("Bake 25-30 min until golden") == [1500], "A range runs to its lower end")
        precondition(seconds("Cook for 10 to 12 minutes") == [600])
        precondition(seconds("Roast for 1 hour 30 minutes") == [5400], "Hours and minutes are one time")
        precondition(seconds("Braise for 1 hour and 15 minutes.") == [4500])
        precondition(seconds("Rest for 1½ hours") == [5400])
        precondition(seconds("Chill for 1 1/2 hours") == [5400])
        precondition(seconds("Leave for an hour") == [3600])
        precondition(seconds("Leave for an hour and a half") == [5400])
        precondition(seconds("Prove for half an hour") == [1800])
        precondition(seconds("Whisk for 30 seconds") == [30])
        precondition(seconds("Blend 30 seconds to 1 minute") == [30], "A range across units is one time")
        precondition(seconds("A 5-minute rest helps") == [300])
        precondition(seconds("Cook for a few minutes") == [180])
        precondition(seconds("Fry for two minutes each side") == [120])
        precondition(seconds("Sear 3 minutes, then simmer 20 minutes") == [180, 1200], "Two times in a step are two timers")
        precondition(seconds("Microwave for 45 s") == [45])
        // Things that look like times and aren't.
        precondition(seconds("Add 2 medium onions and 400 g tomatoes") == [])
        precondition(seconds("Heat the oven to 200 C") == [])
        precondition(seconds("Use a 23 cm tin and 10 ml oil") == [])
        precondition(seconds("Serves 4 hungry people") == [])
        precondition(seconds("Wait a second") == [], "Too short to be worth a timer")
        precondition(seconds("Add 3 slices of bread") == [])
        precondition(seconds("Cook for 9 minutes, or a minute less than the packet says") == [540], "A comparison isn't a time to wait for")
        precondition(seconds("Cook 1 minute more") == [60])

        let simmer = DurationFinder.find(in: "Crush the tomatoes into the pan and simmer for 15 minutes, stirring now and then.")[0]
        precondition(simmer.label == "Simmer" && simmer.phrase == "15 minutes" && simmer.short == "15 min")
        let text = "Crush the tomatoes into the pan and simmer for 15 minutes, stirring now and then." as NSString
        precondition(text.substring(with: NSRange(location: simmer.location, length: simmer.length)) == "15 minutes")
        precondition(DurationFinder.find(in: "Cook, stirring often, for 8 minutes.")[0].label == "Cook", "The main verb wins over what the hands do")
        precondition(DurationFinder.find(in: "Whisk for 30 seconds")[0].label == "Whisk")
        precondition(DurationFinder.find(in: "Drain. Then set aside for 10 minutes")[0].label == "Set aside")
        precondition(DurationFinder.find(in: "After 5 minutes, add the cream")[0].label == nil)
        precondition(DurationFinder.short(5400) == "1 h 30" && DurationFinder.short(3600) == "1 h" && DurationFinder.short(90) == "1 min 30 s")
        precondition(DurationFinder.clock(1182) == "19:42" && DurationFinder.clock(3900) == "1:05:00" && DurationFinder.clock(-3) == "0:00")

        // MARK: Pasted text
        let pasted = """
        Tomato soup

        A quick one for cold days.
        Prep time: 10 minutes
        Serves 4

        ## Ingredients
        - 1 onion, chopped
        • 800 g tinned tomatoes
        For the topping
        2 tbsp cream

        Method:
        1. Soften the onion in oil for 5 minutes.
        2. Add the tomatoes and simmer
           for 20 minutes.
        3) Blend until smooth.

        Notes
        Freezes well for 3 months.
        """
        let soup = RecipeParser.parse(pasted)
        precondition(soup.title == "Tomato soup")
        precondition(soup.yield == "Serves 4")
        precondition(soup.ingredients == ["1 onion, chopped", "800 g tinned tomatoes", "For the topping:", "2 tbsp cream"], "\(soup.ingredients)")
        precondition(soup.steps == ["Soften the onion in oil for 5 minutes.", "Add the tomatoes and simmer for 20 minutes.", "Blend until smooth."], "\(soup.steps)")
        precondition(soup.timerCount == 2 && soup.summary == "4 ingredients · 3 steps · 2 timers")
        precondition(soup.isUsable)
        precondition(soup.notes == ["Freezes well for 3 months."] && soup.nutrition == nil, "\(String(describing: soup.notes))")

        // The text a recipe shows in the editor reads back as the same recipe.
        let again = RecipeParser.parse(soup.text)
        precondition(again.title == soup.title && again.ingredients == soup.ingredients && again.steps == soup.steps && again.yield == soup.yield)
        precondition(again.notes == soup.notes)
        let starter = RecipeParser.parse(Recipe.starter.text)
        precondition(starter.steps == Recipe.starter.steps && starter.ingredients == Recipe.starter.ingredients && starter.title == Recipe.starter.title)
        precondition(Recipe.starter.timerCount == 4)
        let salmon = RecipeParser.parse(Recipe.salmonPasta.text)
        precondition(salmon.steps == Recipe.salmonPasta.steps && salmon.ingredients == Recipe.salmonPasta.ingredients && salmon.title == Recipe.salmonPasta.title)
        precondition(salmon.notes == Recipe.salmonPasta.notes && salmon.nutrition == Recipe.salmonPasta.nutrition, "Notes and nutrition read back")
        precondition(Recipe.salmonPasta.notes?.count == 3 && Recipe.salmonPasta.nutrition == "620 kcal · 55 g protein per serving")
        precondition(Recipe.salmonPasta.steps.allSatisfy { !$0.contains("kcal") && !$0.contains("Reheat") }, "Storage and nutrition are not steps")

        // Tips, storage and nutrition have their own place; they are never steps or ingredients.
        var kept = Recipe(title: "Rice", ingredients: [], steps: ["Boil for 10 minutes."], notes: ["Tip: rinse it first.", "Two lines\nof one note."])
        kept = RecipeParser.parse(kept.text)
        precondition(kept.notes == ["Tip: rinse it first.", "Two lines of one note."] && RecipeParser.parse(kept.text).notes == kept.notes, "\(String(describing: kept.notes))")
        let noted = RecipeParser.parse("""
        Dal
        Ingredients
        200 g red lentils
        1 tsp turmeric
        Method
        1. Simmer the lentils with the turmeric for 20 minutes.
        Tip: A squeeze of lemon lifts it.
        2. Season and serve.
        Storage
        - Keeps 4 days in the fridge.
        Makes a good freezer meal.
        Nutrition per serving
        Calories: 310 kcal
        Protein: 18 g
        """)
        precondition(noted.steps.count == 2 && noted.ingredients.count == 2 && noted.yield == nil, "\(noted)")
        precondition(noted.notes == ["A squeeze of lemon lifts it.", "Keeps 4 days in the fridge.", "Makes a good freezer meal."], "\(String(describing: noted.notes))")
        precondition(noted.nutrition == "Calories: 310 kcal · Protein: 18 g", "\(String(describing: noted.nutrition))")
        let notedAgain = RecipeParser.parse(noted.text)
        precondition(notedAgain.notes == noted.notes && notedAgain.nutrition == noted.nutrition && notedAgain.steps == noted.steps)
        precondition(RecipeParser.parse("Tea\nSteps\n1. Steep for 3 minutes.\nNutrition: 2 kcal").nutrition == "2 kcal")
        // A recipe saved before notes existed still loads.
        let old = try! JSONDecoder().decode(Recipe.self, from: Data(#"{"id":"x","title":"Old","ingredients":[],"steps":["Eat."],"added":0,"cooked":0}"#.utf8))
        precondition(old.notes == nil && old.nutrition == nil && old.steps == ["Eat."])
        precondition((0..<6).map { Recipe.salmonPasta.durations(step: $0).map(\.phrase) } == [["8–12 minutes"], ["3 minutes"], ["6–8 minutes", "2–3 minutes"], [], [], []])

        // No headings at all: short lines that start like amounts are ingredients, sentences are steps.
        let bare = RecipeParser.parse("""
        Garlic bread
        1 baguette
        50 g butter
        2 cloves garlic
        Mash the garlic into the butter and spread it on the sliced baguette.
        Bake for 12 minutes until the edges are crisp.
        """)
        precondition(bare.title == "Garlic bread" && bare.ingredients.count == 3 && bare.steps.count == 2, "\(bare)")

        // An ingredients heading but none for the method.
        let half = RecipeParser.parse("Toast\nIngredients\n2 slices bread\nbutter\nToast the bread for 2 minutes, then butter it while it is hot.")
        precondition(half.ingredients == ["2 slices bread", "butter"] && half.steps.count == 1, "\(half)")

        // One long paragraph becomes a step per sentence.
        let paragraph = RecipeParser.parse("Rice\nSteps\n" + "Rinse the rice until the water runs clear. Put it in a pan with 1.5 times its volume of water. Bring to the boil, cover, and cook for 12 minutes. Take it off the heat and leave it covered for 10 minutes. Fluff with a fork.")
        precondition(paragraph.steps.count == 5 && paragraph.steps[1].contains("1.5 times"), "\(paragraph.steps)")

        precondition(!RecipeParser.parse("").isUsable && RecipeParser.parse("").title == Recipe.fallbackTitle)
        precondition(!RecipeParser.parse("Just a title").isUsable)

        precondition(RecipeParser.link(in: "  https://example.com/recipes/soup \n")?.host() == "example.com")
        precondition(RecipeParser.link(in: "Soup https://example.com") == nil && RecipeParser.link(in: "example.com") == nil)
        precondition(RecipeParser.link(in: "ftp://example.com/soup") == nil)

        // MARK: Amounts
        func line(_ text: String) -> [String?] { let l = Ingredients.split(text); return [l.amount, l.name, l.short] }
        precondition(line("400 g spaghetti") == ["400 g", "spaghetti", "spaghetti"])
        precondition(line("4 cloves garlic, sliced") == ["4 cloves", "garlic, sliced", "garlic"])
        precondition(line("½ cup low-sodium vegetable broth") == ["½ cup", "low-sodium vegetable broth", "low-sodium vegetable broth"])
        precondition(line("1 large lemon, zest and 2 tbsp juice") == ["1", "large lemon, zest and 2 tbsp juice", "large lemon"])
        precondition(line("Parmesan, to serve") == [nil, "Parmesan, to serve", "Parmesan"])
        precondition(line("2% milk") == [nil, "2% milk", "2% milk"] && line("16 oz 2% cottage cheese")[0] == "16 oz")
        precondition(line("1 cup of flour") == ["1 cup", "flour", "flour"] && line("2-3 tbsp oil")[0] == "2-3 tbsp" && line("1 1/2 cups sugar")[0] == "1 1/2 cups")
        precondition(line("1/2 cup sugar") == ["1/2 cup", "sugar", "sugar"] && Ingredients.scale("1/2 cup sugar", by: 2) == "1 cup sugar")
        precondition(line("400g tin tomatoes")[0] == "400g" && line("2 garlic cloves") == ["2", "garlic cloves", "garlic cloves"])
        func scaled(_ text: String, _ factor: Double) -> String { Ingredients.scale(text, by: factor) }
        precondition(scaled("400 g spaghetti", 2) == "800 g spaghetti" && scaled("800 g tinned whole tomatoes", 1.5) == "1200 g tinned whole tomatoes")
        precondition(scaled("4 cloves garlic, sliced", 0.25) == "1 clove garlic, sliced" && scaled("1 pinch chilli flakes", 2) == "2 pinches chilli flakes")
        precondition(scaled("½ cup broth", 3) == "1½ cups broth" && scaled("1 tsp salt", 0.5) == "½ tsp salt" && scaled("2-3 tbsp oil", 2) == "4-6 tbsp oil")
        precondition(scaled("1 large lemon, zest and 2 tbsp juice", 2) == "2 large lemon, zest and 4 tbsp juice", scaled("1 large lemon, zest and 2 tbsp juice", 2))
        precondition(scaled("Parmesan, to serve", 2) == "Parmesan, to serve" && scaled("1 400 g tin tomatoes", 2) == "2 400 g tin tomatoes")
        precondition(scaled("1.5 kg potatoes", 2) == "3 kg potatoes" && scaled("1 cup rice", 1.0 / 3) == "⅓ cup rice" && scaled("3 eggs", 1) == "3 eggs")
        precondition(Ingredients.servings(in: "Serves 4") == 4 && Ingredients.servings(in: "Makes 12 cookies") == 12 && Ingredients.servings(in: "Serves 4-6") == 4)
        precondition(Ingredients.servings(in: nil) == nil && Ingredients.servings(in: "Serves a crowd") == nil)
        let doubled = Recipe.starter.scaled(to: 8)
        precondition(doubled.yield == "Serves 8" && doubled.ingredients[0] == "800 g spaghetti" && doubled.ingredients[7] == "Parmesan, to serve")
        precondition(doubled.id == Recipe.starter.id && doubled.timerCount == 4 && doubled.steps[2] == Recipe.starter.steps[2], "Times never scale")
        precondition(Recipe.starter.scaled(to: 4) == Recipe.starter && Recipe(title: "x", ingredients: ["1 egg"], steps: ["Fry."]).scaled(to: 3).ingredients == ["1 egg"])

        // What a step uses: the amounts it doesn't state itself, in the order it names them.
        func uses(_ recipe: Recipe, _ step: Int) -> [String] { recipe.uses(step: step).map(\.text) }
        precondition(uses(.starter, 0) == [] && uses(.starter, 4) == [])
        precondition(uses(.starter, 1) == ["3 tbsp olive oil", "4 cloves garlic", "1 pinch chilli flakes"], "\(uses(.starter, 1))")
        precondition(uses(.starter, 2) == ["800 g tinned whole tomatoes", "1 tsp salt"], "\(uses(.starter, 2))")
        precondition(uses(.starter, 3) == ["400 g spaghetti"] && uses(.starter, 5) == ["1 handful basil leaves"], "\(uses(.starter, 5))")
        precondition(uses(.salmonPasta, 0) == ["1 large lemon", "1 lb salmon"], "\(uses(.salmonPasta, 0))")
        precondition(uses(.salmonPasta, 1) == ["8 oz protein penne", "12 oz frozen broccoli florets"], "\(uses(.salmonPasta, 1))")
        precondition(uses(.salmonPasta, 2) == ["8 oz sliced mushrooms", "1 cup frozen green peas", "5 oz baby spinach", "1 tsp Italian seasoning"], "\(uses(.salmonPasta, 2))")
        precondition(uses(.salmonPasta, 3) == ["16 oz 2% cottage cheese", "25 g Parmesan", "½ cup low-sodium vegetable broth"], "\(uses(.salmonPasta, 3))")
        precondition(Ingredients.uses(in: "Stir in the butter.", of: ["100 g butter, divided"]).map(\.text) == ["100 g butter (divided)"], "Only part of it goes in here")
        // Scaled, a step's own amounts follow; its times and temperatures don't.
        let big = Recipe.salmonPasta.scaled(by: 2)
        precondition(big.steps[0].hasPrefix("Mix 2 tsp smoked paprika, 2 tsp garlic powder, 1 tsp salt, 1 tsp black pepper") && big.steps[0].contains("390°F for 8–12 minutes"), big.steps[0])
        precondition(big.steps[2].contains("Heat 2 tsp olive oil") && big.steps[2].contains("Add 6 minced garlic cloves") && big.steps[2].contains("6–8 minutes"), big.steps[2])
        precondition(big.steps[1].contains("at least 2 cups of the pasta water") && big.steps[1].contains("last 3 minutes"), big.steps[1])
        precondition(big.steps[3].contains("4 garlic cloves, 4 tbsp lemon juice"), big.steps[3])
        precondition(big.ingredients[0] == "2 lb salmon" && big.ingredients[9] == "10 cloves garlic" && big.yield == "Serves 8")
        precondition(big.notes == Recipe.salmonPasta.notes && (0..<6).map { big.durations(step: $0).map(\.seconds) } == (0..<6).map { Recipe.salmonPasta.durations(step: $0).map(\.seconds) })

        // Only an amount is scaled: not a temperature, a size, a time or a setting that happens to stand before an ingredient.
        func scaledStep(_ text: String) -> String { Ingredients.scale(step: text, by: 2, ingredients: ["1 kg potatoes", "2 onions", "4 chicken thighs"]) }
        for fixed in ["Preheat the oven to 400°F. Toss potatoes in oil.", "In a 12-inch skillet, sauté onions until soft.", "Roast at gas mark 6 potatoes first.",
                      "Give the 1 hr chicken thighs a turn.", "Step 2: potatoes go in."] {
            precondition(scaledStep(fixed) == fixed, scaledStep(fixed))
        }
        precondition(scaledStep("Add the 2 onions and 500 g potatoes.") == "Add the 4 onions and 1000 g potatoes.", scaledStep("Add the 2 onions and 500 g potatoes."))
        // Numbers a recipe can throw at it.
        precondition(line("70% dark chocolate")[0] == nil && scaled("70% dark chocolate", 2) == "70% dark chocolate")
        precondition(scaled("1,000 g flour", 2) == "2000 g flour" && scaled("¼ tsp salt", 0.125) != "0 tsp salt", scaled("¼ tsp salt", 0.125))
        precondition(scaled("99999999999999999999 g sugar", 2).hasSuffix("g sugar"), "A number too large to count doesn't stop the app")
        precondition(Recipe(title: "x", ingredients: ["1 egg"], steps: ["Fry."], yield: "Serves 4-6").scaled(to: 8).yield == "Serves 8-12")

        // MARK: Details in a step
        func heat(_ text: String) -> [String] { StepDetails.heat(in: text).map { (text as NSString).substring(with: $0) } }
        precondition(heat(Recipe.salmonPasta.steps[0]) == ["390°F", "145°F"] && heat(Recipe.starter.steps[1]) == ["medium heat"], "\(heat(Recipe.salmonPasta.steps[0]))")
        precondition(heat("Heat the oven to 200 C, or gas mark 6.") == ["200 C", "gas mark 6"] && heat(Recipe.salmonPasta.steps[2]) == ["medium-high heat"])
        precondition(heat("Add 200 g flour and 3 cloves, about 20 of them") == [] && heat("Bake at 180 degrees for 20 minutes") == ["180 degrees"])
        precondition(StepDetails.cues(in: Recipe.starter.steps[1]).map(\.text) == ["until fragrant but not coloured"])
        precondition(StepDetails.cues(in: "Fry until soft, then add the garlic until it smells good.").map(\.text) == ["until soft", "until it smells good"])
        let mushrooms = Recipe.salmonPasta.durations(step: 2)
        precondition(StepDetails.cue(for: mushrooms[0], in: Recipe.salmonPasta.steps[2]) == "until their water has gone and they are deeply browned")
        precondition(StepDetails.cue(for: mushrooms[1], in: Recipe.salmonPasta.steps[2]) == nil, "The cue belongs to the time in its own sentence")
        precondition(StepDetails.cue(for: Recipe.salmonPasta.durations(step: 0)[0], in: Recipe.salmonPasta.steps[0]) == "until the centre reaches 145°F")
        precondition(StepDetails.cue(for: Recipe.starter.durations(step: 3)[0], in: Recipe.starter.steps[3]) == nil)

        // MARK: A web page
        let html = """
        <html><head><script type="application/ld+json">{"@type":"WebSite","name":"Site"}</script>
        <script type='application/ld+json'>
        {"@context":"https://schema.org","@graph":[{"@type":"Person","name":"A Cook"},
          {"@type":["Recipe","NewsArticle"],"name":"Lemon &amp; herb chicken","recipeYield":["4","4 servings"],
           "recipeIngredient":["1 chicken (, jointed)","2 lemons, <b>zested</b>"],
           "nutrition":{"@type":"NutritionInformation","calories":"410 calories","proteinContent":"38 grams protein","fatContent":"22","servingSize":"1 portion"},
           "recipeInstructions":[
             {"@type":"HowToSection","name":"Roast","itemListElement":[
               {"@type":"HowToStep","text":"Heat the oven to 200&deg;C."},
               {"@type":"HowToStep","text":"<p>Roast for 1 hour&nbsp;15 minutes.</p>"}]},
             {"@type":"HowToStep","text":"Rest for 10 minutes before carving."}]}]}
        </script></head><body></body></html>
        """
        guard let chicken = RecipeParser.recipe(fromHTML: html, source: "https://www.example.com/chicken") else { preconditionFailure("No recipe found") }
        precondition(chicken.title == "Lemon & herb chicken" && chicken.yield == "Serves 4")
        precondition(chicken.ingredients == ["1 chicken (jointed)", "2 lemons, zested"], "\(chicken.ingredients)")
        precondition(chicken.steps == ["Heat the oven to 200°C.", "Roast for 1 hour 15 minutes.", "Rest for 10 minutes before carving."], "\(chicken.steps)")
        precondition(chicken.sourceHost == "example.com" && chicken.durations(step: 1).map(\.seconds) == [4500])
        precondition(chicken.nutrition == "410 kcal · 38 g protein · 22 g fat per serving", "\(String(describing: chicken.nutrition))")
        let plain = RecipeParser.recipe(fromHTML: "<script type=\"application/ld+json\">{\"@type\":\"Recipe\",\"name\":\"Tea\",\"recipeInstructions\":\"1. Boil water.\\n2. Steep for 3 minutes.\"}</script>", source: nil)
        precondition(plain?.steps == ["Boil water.", "Steep for 3 minutes."], "\(String(describing: plain?.steps))")
        precondition(RecipeParser.recipe(fromHTML: "<html><body>No data here</body></html>", source: nil) == nil)
        precondition(RecipeParser.recipe(fromHTML: "<script type=\"application/ld+json\">{broken</script>", source: nil) == nil)

        // MARK: Cooking
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var cook = CookSession(recipe: .starter, at: t0)
        precondition(cook.step == 0 && cook.count == 6 && cook.position == "Step 1 of 6" && !cook.finished)
        precondition(cook.apply(.previous, at: t0) == .step(0) && cook.gathering && cook.apply(.next, at: t0) == .step(0) && !cook.gathering, "Before the first step are the ingredients")
        precondition(cook.apply(.timer, at: t0) == nil, "The first step mentions no time")
        // A step with no time gets a minute of its own to count; more minutes go to it.
        guard case .started(let own)? = cook.apply(.addMinute, at: t0) else { preconditionFailure("A minute should start") }
        precondition(own.total == 60 && own.label == "Step 1" && own.step == 0 && cook.slots == 1 && cook.selectedTimer?.id == own.id)
        guard case .extended(let ownMore)? = cook.apply(.addMinute, at: t0.addingTimeInterval(10)) else { preconditionFailure("Should extend") }
        precondition(ownMore.id == own.id && ownMore.total == 120 && ownMore.end == t0.addingTimeInterval(120))
        guard case .paused? = cook.apply(.timer, at: t0.addingTimeInterval(20)), case .resumed? = cook.apply(.timer, at: t0.addingTimeInterval(30)) else { preconditionFailure("Its own timer pauses and starts") }
        precondition(cook.apply(.reset, at: t0) == .reset && cook.timers.isEmpty && cook.slots == 0)
        precondition(cook.apply(.reset, at: t0) == nil && cook.apply(.timerDown, at: t0) == nil && cook.selectedTimer == nil)
        precondition(cook.apply(.next, at: t0) == .step(1))

        // Step 2: "cook for 2 minutes". The timer gesture starts it, pauses it, and starts it again.
        guard case .started(let garlic)? = cook.apply(.timer, at: t0) else { preconditionFailure("Timer should start") }
        precondition(garlic.total == 120 && garlic.label == "Cook" && garlic.step == 1 && garlic.remaining(at: t0) == 120)
        precondition(cook.running(at: t0).count == 1 && cook.ringing(at: t0).isEmpty && cook.selectedTimer?.id == garlic.id)
        precondition(garlic.progress(at: t0.addingTimeInterval(60)) == 0.5)
        guard case .paused(let held)? = cook.apply(.timer, at: t0.addingTimeInterval(30)) else { preconditionFailure("Timer should pause") }
        precondition(held.isPaused && held.paused == 90 && held.remaining(at: t0.addingTimeInterval(500)) == 90, "Paused time stands still")
        precondition(!held.isRunning(at: t0.addingTimeInterval(500)) && !held.isRinging(at: t0.addingTimeInterval(500)) && held.progress(at: t0) == 0.25)
        precondition(cook.running(at: t0.addingTimeInterval(40)).isEmpty && cook.nextEnd(after: t0.addingTimeInterval(40)) == nil, "A paused timer never rings")
        precondition(cook.live(at: t0.addingTimeInterval(40)).count == 1, "It is still worth showing")
        // A minute goes to a paused timer too.
        guard case .extended(let fatter)? = cook.apply(.addMinute, at: t0.addingTimeInterval(45)) else { preconditionFailure("Should extend") }
        precondition(fatter.paused == 150 && fatter.total == 180)
        guard case .resumed(let going)? = cook.apply(.timer, at: t0.addingTimeInterval(100)) else { preconditionFailure("Timer should start again") }
        precondition(going.paused == nil && going.end == t0.addingTimeInterval(250) && going.isRunning(at: t0.addingTimeInterval(101)))
        // Reset puts it back as it was before it was started.
        precondition(cook.apply(.reset, at: t0.addingTimeInterval(110)) == .reset && cook.timers.isEmpty && cook.selectedTimer == nil)
        precondition(cook.apply(.reset, at: t0.addingTimeInterval(111)) == nil, "Nothing to reset")
        precondition(cook.apply(.timerDown, at: t0) == nil && cook.apply(.timerUp, at: t0) == nil, "One time on this step: nothing to move between")
        guard case .started(let garlic2)? = cook.apply(.timer, at: t0) else { preconditionFailure("Timer should start") }

        // Step 3's simmer runs alongside.
        cook.apply(.next, at: t0.addingTimeInterval(30))
        guard case .started(let simmer3)? = cook.apply(.timer, at: t0.addingTimeInterval(30)) else { preconditionFailure("Timer should start") }
        precondition(simmer3.total == 900 && simmer3.label == "Simmer")
        precondition(cook.live(at: t0.addingTimeInterval(31)).map(\.label) == ["Cook", "Simmer"], "Least time left first")
        precondition(cook.nextEnd(after: t0.addingTimeInterval(31)) == t0.addingTimeInterval(120))

        // Another minute goes to the selected timer while nothing rings.
        guard case .extended(let longer)? = cook.apply(.addMinute, at: t0.addingTimeInterval(40)) else { preconditionFailure("Should extend") }
        precondition(longer.id == simmer3.id && longer.total == 960 && longer.end == t0.addingTimeInterval(990))

        // The garlic rings at two minutes; the timer gesture stops it rather than pausing the simmer.
        let rung = t0.addingTimeInterval(125)
        precondition(cook.ringing(at: rung).map(\.id) == [garlic2.id] && cook.timer(step: 1, slot: 0)!.remaining(at: rung) == 0)
        guard case .extended(let more)? = cook.apply(.addMinute, at: rung) else { preconditionFailure("Should extend") }
        precondition(more.id == garlic2.id && more.end == rung.addingTimeInterval(60) && more.total == 60, "A rung timer starts again with a minute")
        precondition(cook.ringing(at: rung).isEmpty)
        let rungAgain = rung.addingTimeInterval(61)
        precondition(cook.ringing(at: rungAgain).count == 1)
        precondition(cook.apply(.timer, at: rungAgain) == .stopped)
        precondition(cook.ringing(at: rungAgain).isEmpty && cook.live(at: rungAgain).map(\.label) == ["Simmer"])
        precondition(cook.timer(step: 1, slot: 0)?.stopped == true && cook.selectedTimer?.isRunning(at: rungAgain) == true, "The simmer was left alone")

        // A timer's own button: one that rang and was stopped starts afresh; a ringing one stops by itself.
        guard case .started(let afresh)? = cook.toggle(step: 1, slot: 0, at: rungAgain) else { preconditionFailure("Should start afresh") }
        precondition(cook.timers.filter { $0.step == 1 }.count == 1 && afresh.id != garlic2.id && afresh.total == 120)
        precondition(cook.toggle(step: 1, slot: 0, at: rungAgain.addingTimeInterval(130)) == .stopped)
        precondition(cook.timer(step: 2, slot: 0)?.stopped == false)
        cook.reset(step: 1, slot: 0)
        precondition(cook.timer(step: 1, slot: 0) == nil)
        precondition(cook.start(step: 0, slot: 0, at: rungAgain) == nil && cook.start(step: 9, slot: 0, at: rungAgain) == nil)

        // To the end and back.
        cook.go(to: 5)
        precondition(cook.isLast && cook.apply(.next, at: rungAgain) == .finished && cook.finished && cook.position == "Done")
        precondition(cook.apply(.next, at: rungAgain) == nil && cook.apply(.reset, at: rungAgain) == nil)
        precondition(cook.apply(.previous, at: rungAgain) == .step(5) && !cook.finished)
        cook.go(to: 99); precondition(cook.step == 5)
        cook.toggle(ingredient: 2); cook.toggle(ingredient: 4); cook.toggle(ingredient: 2); cook.toggle(ingredient: 40)
        precondition(cook.ready == [4])

        // A session survives being saved, timers and all.
        let saved = try! JSONEncoder().encode(cook)
        precondition(try! JSONDecoder().decode(CookSession.self, from: saved) == cook)

        // MARK: A step with several times
        let steak = RecipeParser.parse("Steak\nSteps\n1. Sear for 3 minutes, turn and cook for 2 minutes more, then rest for 5 minutes.\n2. Slice and serve.")
        var pan = CookSession(recipe: steak, at: t0)
        precondition(pan.durations.map(\.seconds) == [180, 120, 300] && pan.slot == 0 && pan.selectedTimer == nil)
        // Each is started, paused, reset and extended on its own; the commands act on the one selected.
        guard case .started(let sear)? = pan.apply(.timer, at: t0) else { preconditionFailure("Should start") }
        precondition(sear.slot == 0 && sear.total == 180)
        precondition(pan.apply(.timerDown, at: t0) == .selected(1) && pan.slot == 1 && pan.selectedTimer == nil)
        guard case .started(let turn)? = pan.apply(.timer, at: t0.addingTimeInterval(10)) else { preconditionFailure("Should start the second") }
        precondition(turn.slot == 1 && turn.total == 120 && pan.running(at: t0.addingTimeInterval(11)).count == 2)
        guard case .paused(let turnHeld)? = pan.apply(.timer, at: t0.addingTimeInterval(20)) else { preconditionFailure("Should pause the second") }
        precondition(turnHeld.slot == 1 && pan.timer(step: 0, slot: 0)?.isRunning(at: t0.addingTimeInterval(21)) == true, "The first keeps counting")
        guard case .extended(let turnMore)? = pan.apply(.addMinute, at: t0.addingTimeInterval(25)) else { preconditionFailure("Should extend the second") }
        precondition(turnMore.slot == 1 && turnMore.paused == 170 && pan.timer(step: 0, slot: 0)?.total == 180)
        precondition(pan.apply(.timerDown, at: t0) == .selected(2) && pan.apply(.timerDown, at: t0) == .selected(0), "Round to the first again")
        precondition(pan.apply(.timerUp, at: t0) == .selected(2) && pan.apply(.timerUp, at: t0) == .selected(1))
        precondition(pan.apply(.reset, at: t0.addingTimeInterval(30)) == .reset && pan.timer(step: 0, slot: 1) == nil && pan.timer(step: 0, slot: 0) != nil)
        // With the selected one idle, a minute goes to the one that is counting.
        guard case .extended(let searMore)? = pan.apply(.addMinute, at: t0.addingTimeInterval(40)) else { preconditionFailure("Should extend the first") }
        precondition(searMore.slot == 0 && searMore.total == 240)
        // Choosing directly, and leaving the step, which starts the next step at its first time.
        pan.select(slot: 2); precondition(pan.slot == 2)
        pan.select(slot: 7); precondition(pan.slot == 2, "No such timer")
        pan.apply(.next, at: t0); precondition(pan.slot == 0 && pan.durations.isEmpty && pan.selectedTimer == nil)
        pan.apply(.previous, at: t0); precondition(pan.slot == 0)
        pan.go(to: 0, slot: 1); precondition(pan.step == 0 && pan.slot == 1)
        precondition(try! JSONDecoder().decode(CookSession.self, from: try! JSONEncoder().encode(pan)) == pan)

        // MARK: Timers on other steps
        // Up and down move through this step's times and then every other timer still going,
        // so a pan left on step 1 can be paused, extended or reset from step 4.
        var hob = CookSession(recipe: .starter, at: t0)
        guard case .started(let water)? = hob.apply(.addMinute, at: t0) else { preconditionFailure("A minute should start") }
        hob.apply(.next, at: t0)
        precondition(hob.slots == 1 && hob.others.map(\.id) == [water.id] && hob.selection == 0 && hob.pickedTimer == nil && hob.selectedTimer == nil)
        precondition(hob.apply(.timerDown, at: t0) == .selected(1) && hob.pickedTimer?.id == water.id && hob.selectedTimer?.id == water.id && hob.slot == 0)
        guard case .extended(let waterMore)? = hob.apply(.addMinute, at: t0.addingTimeInterval(5)) else { preconditionFailure("Should extend the other step's timer") }
        precondition(waterMore.id == water.id && waterMore.total == 120)
        guard case .paused(let waterHeld)? = hob.apply(.timer, at: t0.addingTimeInterval(10)) else { preconditionFailure("Should pause it") }
        precondition(waterHeld.id == water.id && hob.timer(step: 1, slot: 0) == nil, "This step's time was not started instead")
        precondition(hob.apply(.timerDown, at: t0) == .selected(0) && hob.pickedTimer == nil)
        guard case .started(let garlicHob)? = hob.apply(.timer, at: t0.addingTimeInterval(12)) else { preconditionFailure("Should start this step's") }
        precondition(garlicHob.step == 1 && hob.apply(.timerUp, at: t0) == .selected(1) && hob.selectedTimer?.id == water.id)
        precondition(hob.apply(.reset, at: t0) == .reset && hob.timer(step: 0, slot: 0) == nil && hob.selectedTimer?.id == garlicHob.id, "Back to this step's own")
        precondition(hob.apply(.timerDown, at: t0) == nil, "One timer left: nothing to move between")
        // On a step with no time, a selected timer takes the minute; without one the step gets its own.
        hob.go(to: 0)
        precondition(hob.slots == 0 && hob.selection == nil && hob.selectedTimer == nil, "A step with no time has nothing selected")
        precondition(hob.apply(.timerDown, at: t0) == .selected(0) && hob.selectedTimer?.id == garlicHob.id, "so the first swipe reaches the one timer there is")
        guard case .paused? = hob.apply(.timer, at: t0.addingTimeInterval(15)), case .resumed? = hob.apply(.timer, at: t0.addingTimeInterval(15)) else { preconditionFailure("It takes the commands") }
        hob.go(to: 0)
        precondition(hob.apply(.timerUp, at: t0) == .selected(0) && hob.selectedTimer?.id == garlicHob.id, "Either way round")
        hob.go(to: 0)
        guard case .started(let rest)? = hob.apply(.addMinute, at: t0.addingTimeInterval(20)) else { preconditionFailure("A minute of its own") }
        precondition(rest.step == 0 && hob.timer(step: 1, slot: 0)?.total == 120)
        precondition(hob.apply(.timerDown, at: t0) == .selected(1) && hob.selectedTimer?.id == garlicHob.id)
        hob.apply(.next, at: t0)
        precondition(hob.pickedTimer == nil && hob.others.map(\.id) == [rest.id], "Leaving the step lets go of it")
        hob.pick(rest.id); precondition(hob.selectedTimer?.id == rest.id)
        hob.go(to: 0); hob.pick(garlicHob.id); hob.pick(rest.id)
        precondition(hob.pickedTimer == nil && hob.selectedTimer?.id == rest.id, "Picking this step's own timer selects its slot")
        // A timer that rang and was stopped is no longer in the round.
        precondition(hob.apply(.timer, at: t0.addingTimeInterval(500)) == .stopped && hob.others.isEmpty && hob.slots == 0)
        precondition(try! JSONDecoder().decode(CookSession.self, from: try! JSONEncoder().encode(hob)) == hob)

        // MARK: Getting ready
        // Before step one the ingredients are showing: up and down move along them, the timer gesture ticks one off.
        var ready = CookSession(recipe: .starter, at: t0, gather: true)
        precondition(ready.gathering && ready.position == "Getting ready" && ready.marked == 0 && ready.durations.isEmpty && ready.slots == 0)
        precondition(ready.apply(.timer, at: t0) == .selected(1) && ready.ready == [0], "Ticked, and on to the next")
        precondition(ready.apply(.timerDown, at: t0) == .selected(2) && ready.apply(.timerUp, at: t0) == .selected(1) && ready.apply(.timerUp, at: t0) == .selected(0))
        precondition(ready.apply(.timerUp, at: t0) == .selected(7) && ready.apply(.timer, at: t0) == .selected(1) && ready.ready == [0, 7], "Round the end, and past what is already out")
        ready.apply(.timerUp, at: t0)
        precondition(ready.marked == 0 && ready.apply(.timer, at: t0) == .selected(0) && ready.ready == [7], "Ticked by mistake, it comes off and the mark stays")
        precondition(ready.apply(.addMinute, at: t0) == nil && ready.apply(.reset, at: t0) == nil && ready.timers.isEmpty, "No timer belongs to getting ready")
        precondition(ready.apply(.next, at: t0) == .step(0) && !ready.gathering && ready.step == 0 && ready.position == "Step 1 of 6")
        precondition(ready.apply(.previous, at: t0) == .step(0) && ready.gathering && ready.apply(.previous, at: t0) == nil, "Back from step one is the ingredients")
        ready.serve(8)
        precondition(ready.recipe.ingredients[0] == "800 g spaghetti" && ready.recipe.yield == "Serves 8" && ready.ready == [7], "Servings changed while getting ready")
        ready.serve(6); ready.serve(4); ready.serve(0)
        precondition(ready.recipe == Recipe.starter, "Back to what was written, exactly")
        ready.go(to: 3); precondition(!ready.gathering && ready.ready == [7])
        precondition(try! JSONDecoder().decode(CookSession.self, from: try! JSONEncoder().encode(ready)) == ready)
        precondition(!CookSession(recipe: Recipe(title: "x", ingredients: [], steps: ["Eat."]), at: t0, gather: true).gathering, "Nothing to get out")
        precondition(CookAsk.context(CookSession(recipe: .starter, at: t0, gather: true), at: t0).contains("Now: the cook is getting the ingredients out."))

        // MARK: A sentence at a time
        var paced = CookSession(recipe: .starter, at: t0)
        paced.paced = true
        paced.go(to: 1)
        precondition(paced.beats.count == 2 && paced.beatIndex == 0 && paced.beats[1].hasPrefix("Add the garlic"), "\(paced.beats)")
        precondition(paced.apply(.next, at: t0) == .step(1) && paced.beatIndex == 1 && paced.step == 1, "Next is the step's next sentence")
        precondition(paced.apply(.next, at: t0) == .step(2) && paced.beatIndex == 0, "and after its last, the next step")
        precondition(paced.apply(.previous, at: t0) == .step(1) && paced.beatIndex == 1, "Back arrives where the cook just was")
        precondition(paced.apply(.previous, at: t0) == .step(1) && paced.beatIndex == 0 && paced.durations.count == 1, "The step's timers stay the step's")
        paced.paced = false
        precondition(paced.apply(.next, at: t0) == .step(2) && paced.beatIndex == 0)
        precondition(try! JSONDecoder().decode(CookSession.self, from: try! JSONEncoder().encode(paced)) == paced)

        // MARK: The wrist, felt
        precondition(DialTime.count(0) == [] && DialTime.count(40) == [.tap] && DialTime.count(7 * 60) == [.long, .tap, .tap] && DialTime.count(15 * 60 + 1) == [.long, .long, .long, .tap])
        precondition(CookEvent.step(1).wrist == .tap && CookEvent.reset.wrist == .flutter && CookEvent.finished.wrist == .heartbeat)

        // What to start before step one.
        precondition(StepDetails.headStarts(in: ["Chop the onions.", "Preheat the oven to 200°C. Line a tray.", "Meanwhile, bring a large pot of salted water to a boil.", "Heat the oven to 200°C again."])
                     == ["Preheat the oven to 200°C", "Bring a large pot of salted water to a boil", "Heat the oven to 200°C again"])
        precondition(StepDetails.headStarts(in: Recipe.starter.steps).isEmpty && StepDetails.headStarts(in: Recipe.salmonPasta.steps).isEmpty, "The first step is next anyway")

        // MARK: Where each step happens
        let salmonPlan = StationPlan(steps: Recipe.salmonPasta.steps)
        precondition(salmonPlan.spots.map(\.vessel) == ["Air fryer", "Pot", "Skillet", "Blender", "Skillet", "Board"], "\(salmonPlan.spots.map(\.vessel))")
        precondition(salmonPlan.spots.map(\.place) == [.oven, .frontLeft, .frontRight, .counter, .frontRight, .counter], "The skillet stays on its burner")
        let starterPlan = StationPlan(steps: Recipe.starter.steps)
        precondition(starterPlan.spots.map(\.vessel) == ["Pot", "Skillet", "Skillet", "Pot", "Pot", "Board"], "\(starterPlan.spots.map(\.vessel))")
        precondition(starterPlan.vessel(at: .frontLeft) == "Pot" && starterPlan.vessel(at: .backLeft) == nil && starterPlan.spot(step: 99).place == .counter)
        precondition(StationPlan(steps: ["Wait.", "Wait more."]).spots.map(\.vessel) == ["Counter", "Counter"], "No place named: the counter")

        // Before you start, by rules.
        precondition(RecipeBrief.lines(.starter) == ["Uses 2 burners.", "Longest wait: 15 min at step 3, simmer.", "Don’t miss at step 4: keep a cup of the cooking water."], "\(RecipeBrief.lines(.starter))")
        let brief = RecipeBrief.lines(.salmonPasta)
        precondition(brief.first == "Uses 2 burners and the air fryer." && brief.contains { $0.hasPrefix("Don’t miss at step 2: keeping at least 1 cup") }, "\(brief)")
        precondition(RecipeBrief.lines(Recipe(title: "Toast", ingredients: [], steps: ["Chop.", "Preheat the oven to 200°C."])).first == "Start first: preheat the oven to 200°C.")
        var cooked = Recipe.starter
        precondition(RecipeBrief.reason(cooked, now: t0) == "You haven’t cooked this yet")
        cooked.lastCooked = t0.addingTimeInterval(-3 * 86_400 - 60)
        precondition(RecipeBrief.reason(cooked, now: t0) == "Last cooked 3 days ago")
        precondition(RecipeBrief.wrist(.frontRight) == [.tap, .tap] && RecipeBrief.wrist(.oven) == [.long] && RecipeBrief.wrist(.counter).isEmpty)

        // MARK: Landing together
        // The sauce simmers for fifteen minutes; the spaghetti takes nine. Started six minutes in, both are done at once.
        var together = CookSession(recipe: .starter, at: t0)
        together.go(to: 2); together.start(step: 2, slot: 0, at: t0)
        precondition(together.landing(at: t0) == nil, "This step's own time is already going")
        together.go(to: 3)
        guard let land = together.landing(at: t0.addingTimeInterval(60)) else { preconditionFailure("The spaghetti should wait") }
        precondition(land.wait == 300 && land.with.label == "Simmer", "\(land.wait)")
        precondition(together.landing(at: t0.addingTimeInterval(400)) == nil, "Past the moment, there is nothing to wait for")
        precondition(together.due(at: t0.addingTimeInterval(60)) == nil && together.due(at: t0.addingTimeInterval(360))?.label == "Simmer"
                     && together.due(at: t0.addingTimeInterval(400))?.label == "Simmer", "From the moment on it is due, while the sauce still counts")
        precondition(together.due(at: t0.addingTimeInterval(901)) == nil, "The sauce is done: nothing to land with")
        together.apply(.timer, at: t0.addingTimeInterval(360))
        precondition(together.landing(at: t0.addingTimeInterval(361)) == nil && together.running(at: t0.addingTimeInterval(361)).map(\.end) == [t0.addingTimeInterval(900), t0.addingTimeInterval(900)], "Started then, they end together")
        var alone = CookSession(recipe: .starter, at: t0)
        alone.go(to: 3)
        precondition(together.due(at: t0.addingTimeInterval(361)) == nil, "Started, it is due for nothing")
        precondition(alone.landing(at: t0) == nil && alone.due(at: t0) == nil, "Nothing else is counting")

        // MARK: The eight beads
        precondition(Beads.fills(5, of: 16) == [1, 1, 0.5, 0, 0, 0, 0, 0], "Whole beads, then part of the next")
        precondition(Beads.fills(16, of: 16).allSatisfy { $0 == 1 } && Beads.fills(20, of: 16) == Beads.fills(16, of: 16) && Beads.fills(3, of: 0).allSatisfy { $0 == 0 })
        precondition(Beads.dial(steps: 15) == [1, 1, 0, 0, 0, 0, 0, 0] && Beads.dial(steps: 60).allSatisfy { $0 == 1 }, "Sixty steps are once round")
        precondition(Beads.dial(steps: 75) == [2, 2, 1, 1, 1, 1, 1, 1] && Beads.dial(steps: -4).allSatisfy { $0 == 0 }, "A second turn fills them again")
        precondition(Beads.people(4) == [1, 1, 1, 1, 0, 0, 0, 0] && Beads.people(10) == [2, 2, 1, 1, 1, 1, 1, 1])
        precondition(Beads.slots(for: 5) == [0, 1, 3, 4, 6] && Beads.slots(for: 4) == [0, 2, 4, 6] && Beads.slots(for: 8) == Array(0..<8) && Beads.slots(for: 0).isEmpty)
        precondition(Beads.shortest(from: 0, to: 3) == 3 && Beads.shortest(from: 6, to: 0) == 2 && Beads.shortest(from: 1, to: 6) == -3 && Beads.shortest(from: 0, to: 4) == 4)

        // What is at each place the salmon uses, a minute after the air fryer went on.
        let kitchenPlan = StationPlan(steps: Recipe.salmonPasta.steps)
        precondition(kitchenPlan.used == [.oven, .frontLeft, .frontRight, .counter])
        var kitchen = CookSession(recipe: .salmonPasta, at: t0)
        kitchen.start(step: 0, slot: 0, at: t0)
        kitchen.go(to: 1)
        let minute = t0.addingTimeInterval(60)
        let places = kitchen.stations(kitchenPlan, at: minute)
        precondition(places.map(\.vessel) == ["Air fryer", "Pot", "Skillet", "Blender"], "\(places.map(\.vessel))")
        precondition(places[0].timer?.step == 0 && !places[0].here && places[1].here && places[1].waiting == 180 && places[1].timer == nil && places[2].waiting == nil)
        // The penne waits four minutes of the five between the fryer starting and the moment to begin.
        precondition(abs((kitchen.approach(at: minute) ?? 0) - 0.2) < 1e-9 && kitchen.approach(at: t0.addingTimeInterval(299)).map { $0 > 0.99 } == true)
        kitchen.apply(.timer, at: t0.addingTimeInterval(300))
        let after = kitchen.stations(kitchenPlan, at: t0.addingTimeInterval(301))
        precondition(after[1].timer?.step == 1 && after[1].waiting == nil && kitchen.approach(at: t0.addingTimeInterval(301)) == nil, "Started, it is a timer and waits for nothing")
        kitchen.go(to: 5); kitchen.apply(.next, at: t0.addingTimeInterval(400))
        precondition(kitchen.finished && kitchen.stations(kitchenPlan, at: t0.addingTimeInterval(400)).allSatisfy { !$0.here }, "Finished, the cook is nowhere")

        // MARK: The wrist dial
        // Still, the sensor's offset is learned; held, a steady turn about one axis comes out in degrees.
        var wrist = WristDial()
        var clock: UInt64 = 0
        func feed(_ values: [Double], samples: Int) -> Double {
            var turned = 0.0
            for _ in 0..<samples { clock += 10_000; turned += wrist.gyro(values, timestamp: clock) ?? 0 }
            return turned
        }
        precondition(feed([3, -2, 1], samples: 800) == 0 && !wrist.engaged, "Nothing is turned until the pinch is held")
        wrist.engage()
        precondition(abs(feed([3, -2, 1], samples: 100)) < 0.3, "A still hand doesn't turn the dial")
        let quarter = feed([3, -2 + 1286, 1], samples: 100)
        precondition(abs(quarter - 90) < 3, "One second at this rate is a quarter turn: \(quarter)")
        precondition(abs(feed([3 + 600, -2 - 1286, 1], samples: 100) + 90) < 3, "Back again, on the axis it began on, whatever the others do")
        clock += 400_000
        precondition(wrist.gyro([3, 1284, 1], timestamp: clock) == nil, "Samples were lost: that turn is unknown")
        wrist.release()
        precondition(feed([3, 1284, 1], samples: 50) == 0)

        var time = DialTime()
        precondition(time.turn(3, from: 0) == 0 && time.turn(1.5, from: 0) == 10, "Four degrees a step")
        precondition(time.turn(40, from: 90) == 330, "Ten seconds a step to two minutes, then thirty")
        time = DialTime()
        precondition(time.turn(-8, from: 120) == 100 && time.turn(-400, from: 100) == 0 && time.turn(-40, from: 0) == 0, "Down to nothing, never below")
        time = DialTime()
        precondition(time.turn(8, from: 125) == 180 && time.turn(8, from: 900) == 1020 && time.turn(.nan, from: 60) == 60, "Odd times snap to the step")
        time = DialTime()
        precondition(time.turn(3, from: 60) == 60 && time.turn(-2, from: 60) == 60 && time.turn(-3, from: 60) == 50, "Turning back starts the step again")

        // Let go, and the selected timer takes the time the dial shows.
        var dialled = CookSession(recipe: .starter, at: t0)
        precondition(dialled.dialSeconds(at: t0) == 0 && dialled.dial(to: 0, at: t0) == nil, "A hold with no turn does nothing")
        guard case .started(let boil)? = dialled.dial(to: 240, at: t0) else { preconditionFailure("A step with no time gets one from the dial") }
        precondition(boil.total == 240 && boil.label == "Step 1" && dialled.selectedTimer?.id == boil.id && dialled.dialSeconds(at: t0.addingTimeInterval(40)) == 200)
        guard case .extended(let longerBoil)? = dialled.dial(to: 300, at: t0.addingTimeInterval(40)) else { preconditionFailure("A counting timer is set to what the dial shows") }
        precondition(longerBoil.end == t0.addingTimeInterval(340) && longerBoil.total == 300 && longerBoil.isRunning(at: t0.addingTimeInterval(41)))
        dialled.apply(.timer, at: t0.addingTimeInterval(50))
        guard case .extended(let heldBoil)? = dialled.dial(to: 60, at: t0.addingTimeInterval(60)) else { preconditionFailure("A paused timer too") }
        precondition(heldBoil.paused == 60 && heldBoil.total == 300, "and it stays paused")
        precondition(dialled.dial(to: 0, at: t0.addingTimeInterval(70)) == .reset && dialled.timers.isEmpty, "Dialled down to nothing, it is gone")
        dialled.apply(.next, at: t0)
        precondition(dialled.dialSeconds(at: t0) == 120, "A time the step mentions starts the dial there")
        guard case .started(let shorter)? = dialled.dial(to: 90, at: t0) else { preconditionFailure("and starts from where the dial was left") }
        precondition(shorter.total == 90 && shorter.label == "Cook" && shorter.slot == 0 && dialled.timer(step: 1, slot: 0)?.id == shorter.id)
        dialled.go(to: 0); dialled.apply(.timerDown, at: t0)
        precondition(dialled.pickedTimer?.id == shorter.id && dialled.dialSeconds(at: t0.addingTimeInterval(30)) == 60)
        guard case .extended(let other)? = dialled.dial(to: 600, at: t0.addingTimeInterval(30)) else { preconditionFailure("Another step's timer, once picked") }
        precondition(other.id == shorter.id && other.total == 600 && dialled.timers.count == 1)

        // MARK: A question
        // What the model is told: the recipe, where the cook is, and what the timers are doing.
        var asked = CookSession(recipe: .salmonPasta, at: t0)
        asked.start(step: 0, slot: 0, at: t0)
        asked.go(to: 2)
        let told = CookAsk.context(asked, at: t0.addingTimeInterval(60))
        precondition(told.hasPrefix("Recipe: Creamy lemon-garlic salmon pasta (Serves 4)") && told.contains("- 5 cloves garlic") && told.contains("3. Heat 1 tsp olive oil"), told)
        precondition(told.contains("Now: the cook is on step 3 of 6.") && told.contains("Timers: Fry from step 1, 7 min left."), told)
        precondition(told.contains("- Refrigerate and eat within 3–4 days, or freeze.") && told.contains("Nutrition: 620 kcal"))
        precondition(CookAsk.context(CookSession(recipe: .starter, at: t0), at: t0).hasSuffix("Timers: none running."))
        let short = CookAsk.context(asked, at: t0, limit: 1500)
        precondition(short.count <= 1500 && !short.contains("Refrigerate") && short.contains("Now: the cook is on step 3"), "Too long: notes go first, then the ends of long steps. \(short.count)")
        asked.go(to: 5); asked.apply(.next, at: t0)
        precondition(CookAsk.context(asked, at: t0).contains("Now: the recipe is finished.") && asked.apply(.ask, at: t0) == nil)

        // MARK: Gestures
        var controls = CookControls.standard
        precondition(controls.command(for: .swipeRight) == .next && controls.command(for: .doubleTapIndex) == .timer)
        precondition(controls.command(for: .swipeDown) == .timerDown && controls.command(for: .swipeUp) == .timerUp && controls.command(for: .holdMiddle) == .ask)
        precondition(controls.gesture(for: .reset) == nil, "The dial turned down to nothing clears a timer")
        precondition(controls.reserved == [.swipeRight, .swipeLeft, .swipeUp, .swipeDown, .doubleTapIndex, .tapIndex, .doubleTapMiddle, .tapMiddle, .holdMiddle, .releaseMiddle])
        controls.set(.swipeRight, for: .timer)
        precondition(controls.gesture(for: .timer) == .swipeRight && controls.gesture(for: .next) == .doubleTapIndex, "Taking a gesture swaps")
        controls.set(nil, for: .addMinute)
        precondition(controls.gesture(for: .addMinute) == nil && !controls.reserved.contains(.doubleTapMiddle))
        controls.set(.holdIndex, for: .previous)
        precondition(controls.reserved.contains(.releaseIndex))
        let stored = try! JSONEncoder().encode(controls)
        precondition(try! JSONDecoder().decode(CookControls.self, from: stored) == controls, "None stays None once saved")
        // Settings saved before reset and timer selection existed get those gestures, unless something has them.
        let older = try! JSONDecoder().decode(CookControls.self, from: Data(#"{"gestures":["next","swipe-right","previous","swipe-up","timer","double-tap-index"]}"#.utf8))
        precondition(older.gesture(for: .reset) == nil && older.gesture(for: .ask) == .holdMiddle && older.gesture(for: .timerDown) == .swipeDown)
        // Saved with the old defaults, the middle hold moves from reset to asking; one given to something else stays.
        func before(_ gestures: [CookCommand: GestureKind]) -> CookControls {
            let now = String(decoding: try! JSONEncoder().encode(CookControls(gestures: gestures)), as: UTF8.self)
            return try! JSONDecoder().decode(CookControls.self, from: Data(now.replacingOccurrences(of: "\"version\":4", with: "\"version\":3").utf8))
        }
        let moved = before([.reset: .holdMiddle, .next: .swipeRight])
        precondition(moved.gesture(for: .ask) == .holdMiddle && moved.gesture(for: .reset) == nil && moved.gesture(for: .next) == .swipeRight, "\(moved.triggers)")
        let stays = before([.next: .holdMiddle])
        precondition(stays.gesture(for: .next) == .holdMiddle && stays.gesture(for: .ask) == nil)
        precondition(try! JSONDecoder().decode(CookControls.self, from: JSONEncoder().encode(stays)).gesture(for: .ask) == nil, "None stays None once saved")
        precondition(older.gesture(for: .timerUp) == nil && older.gesture(for: .previous) == .swipeUp, "A gesture already in use is left where it is")

        // A command can take a combo. The engine Mappings uses decides when it was made.
        controls = .standard
        let twice = CommandTrigger(steps: [.swipeUp, .swipeUp].steps, intervalMs: 500)
        controls.setTrigger(twice, for: .addMinute)
        precondition(controls.trigger(for: .addMinute) == twice && controls.gesture(for: .addMinute) == nil && controls.command(for: .doubleTapMiddle) == nil)
        precondition(!controls.reserved.contains(.doubleTapMiddle) && !controls.reserved.contains(.tapMiddle) && controls.reserved.contains(.swipeUp))
        precondition(try! JSONDecoder().decode(CookControls.self, from: JSONEncoder().encode(controls)) == controls, "Combos round-trip")
        var engine = MappingEngine(mappings: controls.mappings)
        func made(_ events: [MappingEngine.Event]) -> [CookCommand] {
            events.compactMap { if case .fire(let id, _) = $0 { controls.command(forMapping: id) } else { nil } }
        }
        precondition(made(engine.receive(.swipeRight, at: 0)) == [.next])
        precondition(made(engine.receive(.swipeUp, at: 1)).isEmpty, "A swipe up waits for the combo that starts with it")
        precondition(made(engine.tick(at: 1.2)).isEmpty && made(engine.tick(at: 1.6)) == [.timerUp], "and is the previous timer once the combo's time runs out")
        precondition(made(engine.receive(.swipeUp, at: 3) + engine.receive(.swipeUp, at: 3.3) + engine.tick(at: 5)) == [.addMinute], "Twice in time adds a minute, and only that")
        controls.setTrigger(twice, for: .ask)
        precondition(controls.trigger(for: .ask) == twice && controls.gesture(for: .addMinute) == .holdMiddle, "Taking a combo swaps too")
        precondition(!controls.usesMotion, "No motion step, no motion sensors")
        controls.setTrigger(CommandTrigger(steps: [ComboStep(.holdIndex), .movement(.z), ComboStep(.releaseIndex)]), for: .next)
        precondition(controls.usesMotion && controls.reserved.isSuperset(of: [.movement, .holdIndex, .releaseIndex]))
        engine = MappingEngine(mappings: controls.mappings)
        precondition(made(engine.receive(.holdIndex, at: 10) + engine.receive(.movement(.z), at: 14) + engine.receive(.releaseIndex, at: 15)) == [.next],
                     "Held, so the movement has no time limit")

        print("Cook checks passed")
    }
}
