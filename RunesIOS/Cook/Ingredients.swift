import Foundation

// Amounts in a recipe: an ingredient line split into how much and what, scaled to another
// number of servings, and matched to the steps that use it. Rules only, Foundation only
// (Tests/CookTests.swift).

/// "4 cloves garlic, sliced" as its amount and what it is.
struct IngredientLine: Hashable, Sendable {
    /// "4 cloves", "400 g", "½ cup"; nil when the line gives none.
    var amount: String?
    /// "garlic, sliced".
    var name: String
    /// The name without its preparation: "garlic".
    var short: String
}

/// An ingredient a step uses without saying how much: "4 cloves garlic".
struct StepUse: Hashable, Sendable {
    var index: Int
    var text: String
}

enum Ingredients {
    private static let number = #"(?:\d+\s+\d/\d|\d/\d+|\d+(?:[.,]\d+)?(?:\s*[½¼¾⅓⅔⅛])?|[½¼¾⅓⅔⅛])"#
    /// Units with a size. An amount in one of these scales wherever it is written.
    private static let measures = #"tablespoons?|tbsps?|tbs|teaspoons?|tsps?|cups?|grams?|g|kilograms?|kilos?|kg|milligrams?|mg|millilit(?:re|er)s?|ml|lit(?:re|er)s?|l|fl\.? ?oz|ounces?|oz|pounds?|lbs?|pints?|quarts?"#
    /// Words that count things; part of the amount on an ingredient line.
    private static let counts = #"cloves?|pinch(?:es)?|handfuls?|dash(?:es)?|splash(?:es)?|knobs?|sprigs?|slices?|sticks?|bunch(?:es)?|cans?|tins?|pieces?|packs?|packets?|stalks?|heads?|fillets?|rashers?|sheets?|drops?|jars?"#
    private static let range = #"\s*(?:-|–|—|to)\s*"#

    private static let leading = try! NSRegularExpression(
        pattern: "^(?:about\\s+|approx\\.?\\s+|~\\s*)?(\(number))(?!\\s*%)(?:\(range)(\(number)))?(?:\\s*(\(measures)|\(counts))\\b\\.?)?(?:\\s+of\\b)?\\s*",
        options: [.caseInsensitive])
    private static let measured = try! NSRegularExpression(
        pattern: "(?<![\\w/.,])(\(number))(?:\(range)(\(number)))?\\s*(\(measures))\\b", options: [.caseInsensitive])
    private static let token = try! NSRegularExpression(pattern: "\(number)|\\p{L}+")

    private static let metric: Set<String> = ["g", "kg", "mg", "ml", "l", "gram", "grams", "kilogram", "kilograms", "kilo", "kilos",
                                              "milligram", "milligrams", "millilitre", "millilitres", "milliliter", "milliliters",
                                              "litre", "litres", "liter", "liters"]
    /// Unit words that change with the number. Abbreviations stay as written.
    private static let plurals: [String: String] = [
        "cup": "cups", "teaspoon": "teaspoons", "tablespoon": "tablespoons", "gram": "grams", "ounce": "ounces", "pound": "pounds",
        "pint": "pints", "quart": "quarts", "litre": "litres", "liter": "liters", "clove": "cloves", "pinch": "pinches",
        "handful": "handfuls", "dash": "dashes", "splash": "splashes", "knob": "knobs", "sprig": "sprigs", "slice": "slices",
        "stick": "sticks", "bunch": "bunches", "can": "cans", "tin": "tins", "piece": "pieces", "pack": "packs", "packet": "packets",
        "stalk": "stalks", "head": "heads", "fillet": "fillets", "rasher": "rashers", "sheet": "sheets", "drop": "drops", "jar": "jars",
    ]
    private static let singulars = Dictionary(uniqueKeysWithValues: plurals.map { ($1, $0) })

    // MARK: A line

    static func split(_ text: String) -> IngredientLine {
        let ns = text as NSString
        var amount: String?, name = text.trimmingCharacters(in: .whitespaces)
        if let match = leading.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), match.range.length < ns.length {
            let unit = match.range(at: 3)
            let end = unit.location != NSNotFound ? NSMaxRange(unit) : NSMaxRange(match.range(at: match.range(at: 2).location != NSNotFound ? 2 : 1))
            amount = ns.substring(with: NSRange(location: match.range(at: 1).location, length: end - match.range(at: 1).location))
            name = ns.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespaces)
        }
        let short = name.components(separatedBy: CharacterSet(charactersIn: ",(;")).first?.trimmingCharacters(in: .whitespaces) ?? name
        return IngredientLine(amount: amount, name: name, short: short.isEmpty ? name : short)
    }

    /// The number of people a yield line names: 4 for "Serves 4".
    static func servings(in yield: String?) -> Int? {
        guard let yield, let found = yield.range(of: #"\d{1,3}"#, options: .regularExpression), let count = Int(yield[found]),
              (1...200).contains(count) else { return nil }
        return count
    }

    // MARK: Scaling

    /// "1½", "¾", "250", "2.5": a number the way a recipe writes it.
    static func format(_ value: Double, metric: Bool) -> String {
        func decimal(_ value: Double) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        }
        if metric { return value >= 10 ? String(Int(value.rounded())) : decimal(value) }
        let whole = value.rounded(.down), part = value - whole
        let marks: [(Double, String)] = [(0, ""), (0.125, "⅛"), (0.25, "¼"), (1.0 / 3, "⅓"), (0.5, "½"), (2.0 / 3, "⅔"), (0.75, "¾"), (1, "")]
        guard let near = marks.min(by: { abs($0.0 - part) < abs($1.0 - part) }), abs(near.0 - part) < 0.05 else { return decimal(value) }
        let count = Int(whole) + (near.0 == 1 ? 1 : 0)
        if near.1.isEmpty { return count == 0 ? decimal(value) : String(count) }
        return count == 0 ? near.1 : "\(count)\(near.1)"
    }

    private struct Edit { var range: NSRange; var text: String }

    /// The edits that scale one amount: its number, the upper end of a range, and the unit's plural.
    private static func edits(_ match: NSTextCheckingResult, in ns: NSString, by factor: Double) -> [Edit] {
        let unitRange = match.numberOfRanges > 3 ? match.range(at: 3) : NSRange(location: NSNotFound, length: 0)
        let unit = unitRange.location == NSNotFound ? nil : ns.substring(with: unitRange)
        let isMetric = unit.map { metric.contains($0.lowercased()) } ?? false
        var result: [Edit] = [], last = 0.0
        for group in [1, 2] where match.range(at: group).location != NSNotFound {
            guard let value = DurationFinder.value(ns.substring(with: match.range(at: group))) else { return [] }
            last = value * factor
            result.append(Edit(range: match.range(at: group), text: format(last, metric: isMetric)))
        }
        if let unit {
            let lower = unit.lowercased()
            if last > 1, let plural = plurals[lower] { result.append(Edit(range: unitRange, text: plural)) }
            if last <= 1, let singular = singulars[lower] { result.append(Edit(range: unitRange, text: singular)) }
        }
        return result
    }

    private static func apply(_ edits: [Edit], to text: String) -> String {
        var result = text as NSString, done = Int.max
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) where NSMaxRange(edit.range) <= done {
            result = result.replacingCharacters(in: edit.range, with: edit.text) as NSString
            done = edit.range.location
        }
        return result as String
    }

    /// An ingredient line for more or fewer people. The amount it starts with scales, and
    /// so does a measured amount later in the line ("zest and 2 tbsp juice").
    static func scale(_ text: String, by factor: Double) -> String {
        guard factor != 1 else { return text }
        let ns = text as NSString, all = NSRange(location: 0, length: ns.length)
        var changes: [Edit] = []
        var start = 0
        if let match = leading.firstMatch(in: text, range: all) {
            changes += edits(match, in: ns, by: factor)
            start = NSMaxRange(match.range)
            // "1 400 g tin": the size of the tin stays.
            if match.range(at: 3).location == NSNotFound,
               let size = measured.firstMatch(in: text, range: NSRange(location: start, length: ns.length - start)), size.range.location == start {
                start = NSMaxRange(size.range)
            }
        }
        for match in measured.matches(in: text, range: NSRange(location: start, length: ns.length - start)) {
            changes += edits(match, in: ns, by: factor)
        }
        return apply(changes, to: text)
    }

    /// A step for more or fewer people: measured amounts scale, and so does a count
    /// written just before an ingredient ("3 minced garlic cloves"). Times stay.
    static func scale(step: String, by factor: Double, ingredients: [String]) -> String {
        guard factor != 1 else { return step }
        let ns = step as NSString
        var changes = measured.matches(in: step, range: NSRange(location: 0, length: ns.length)).flatMap { edits($0, in: ns, by: factor) }
        for mention in mentions(in: step, of: ingredients) {
            guard let stated = mention.stated, !changes.contains(where: { NSIntersectionRange($0.range, stated).length > 0 }),
                  let value = DurationFinder.value(ns.substring(with: stated)) else { continue }
            changes.append(Edit(range: stated, text: format(value * factor, metric: false)))
        }
        return apply(changes, to: step)
    }

    // MARK: Which step uses what

    private struct Token { var word: String; var range: NSRange; var isNumber: Bool }
    private struct Mention { var index: Int; var location: Int; var stated: NSRange? }

    private static func stem(_ word: String) -> String {
        if word.count > 4, word.hasSuffix("ies") { return word.dropLast(3) + "y" }
        if word.count > 4, word.hasSuffix("oes") { return String(word.dropLast(2)) }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    private static func tokens(_ text: String) -> [Token] {
        let ns = text as NSString
        return token.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            let raw = ns.substring(with: $0.range)
            let isNumber = raw.unicodeScalars.first.map { !CharacterSet.letters.contains($0) } ?? false
            return Token(word: isNumber ? raw : stem(raw.lowercased()), range: $0.range, isNumber: isNumber)
        }
    }

    /// Words that describe an ingredient without naming it.
    private static let descriptors: Set<String> = [
        "large", "small", "medium", "big", "fresh", "freshly", "frozen", "dried", "dry", "ground", "whole", "tinned", "canned", "chopped",
        "sliced", "diced", "minced", "grated", "finely", "roughly", "thinly", "crushed", "peeled", "cooked", "raw", "ripe", "extra",
        "virgin", "low", "sodium", "fat", "free", "reduced", "unsalted", "salted", "plain", "baby", "green", "red", "white", "black",
        "yellow", "sweet", "hot", "light", "dark", "smoked", "protein", "boneless", "skinless", "skin", "organic", "zest", "juice",
        "and", "or", "the", "of", "for", "to", "plus", "with", "about", "into", "each", "optional", "taste", "serve", "more",
    ]
    /// Where an amount written before an ingredient can no longer belong to it.
    private static let boundaries: Set<String> = ["and", "then", "for", "until", "with", "the", "in", "into", "add", "plus", "or", "over",
                                                  "minute", "min", "hour", "second", "sec"]

    /// The words that name an ingredient: "garlic" for "garlic, sliced", "olive oil" for "extra virgin olive oil".
    private static func words(_ short: String) -> [String] {
        tokens(short).filter { !$0.isNumber && $0.word.count > 2 && !descriptors.contains($0.word) }.map(\.word)
    }

    private static func mentions(in step: String, of ingredients: [String]) -> [Mention] {
        let names = ingredients.map { line -> [String] in
            let parts = split(line)
            return parts.amount == nil || line.hasSuffix(":") ? [] : words(parts.short)
        }
        let heads = names.map(\.last)
        let found = tokens(step)
        var result: [Mention] = []
        for (index, name) in names.enumerated() {
            guard let head = name.last else { continue }
            for (position, token) in found.enumerated() where !token.isNumber && name.contains(token.word) {
                if token.word == head {
                    // "garlic powder" is not the garlic.
                    let next = position + 1 < found.count ? found[position + 1].word : ""
                    if names.enumerated().contains(where: { $0.offset != index && $0.element.contains(head) && $0.element.contains(next) && !name.contains(next) }) { continue }
                } else {
                    // "the basil" is the basil leaves, unless basil is something else on the list.
                    guard token.word.count > 3, !heads.enumerated().contains(where: { $0.offset != index && $0.element == token.word }) else { continue }
                }
                var stated: NSRange?
                for back in stride(from: position - 1, through: max(0, position - 4), by: -1) {
                    let earlier = found[back]
                    if earlier.isNumber {
                        let after = found[back + 1]
                        if !["minute", "min", "hour", "second", "sec"].contains(after.word) { stated = earlier.range }
                        break
                    }
                    if boundaries.contains(earlier.word) { break }
                }
                result.append(Mention(index: index, location: token.range.location, stated: stated))
            }
        }
        return result
    }

    /// The word that names an ingredient, as a stem: "tomato" for "800 g tinned whole tomatoes".
    static func head(of line: String) -> String? { words(split(line).short).last }
    /// Whether a text has a word, whatever its number: "tomato" is in "Crush the tomatoes".
    static func mentions(_ stemmed: String, in text: String) -> Bool { tokens(text).contains { !$0.isNumber && $0.word == stemmed } }

    /// Whether a text gives this amount for this thing: the number stands a few words
    /// before the word, or just after it. "a" and "two" count as numbers.
    static func states(_ value: Double, of stemmed: String, in text: String) -> Bool {
        let found = tokens(text)
        let counted: Set<String> = ["a", "an", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "twelve"]
        func number(_ token: Token) -> Double? {
            token.isNumber || counted.contains(token.word) ? DurationFinder.value(token.word) : nil
        }
        for (position, token) in found.enumerated() where !token.isNumber && token.word == stemmed {
            let near = found[max(0, position - 6)..<min(found.count, position + 4)]
            if near.contains(where: { number($0).map { abs($0 - value) < 0.01 } ?? false }) { return true }
        }
        return false
    }

    /// The ingredients a step uses without saying how much, in the order it names them.
    /// Under a step this saves scrolling back to the list with wet hands.
    static func uses(in step: String, of ingredients: [String]) -> [StepUse] {
        var first: [Int: Int] = [:]
        for mention in mentions(in: step, of: ingredients) where mention.stated == nil {
            first[mention.index] = min(first[mention.index] ?? .max, mention.location)
        }
        return first.sorted { $0.value < $1.value }.map { entry in
            let line = split(ingredients[entry.key])
            return StepUse(index: entry.key, text: [line.amount, line.short].compactMap { $0 }.joined(separator: " "))
        }
    }
}

/// What a cook glances back at a step for: how hot, and how to tell it is done.
enum StepDetails {
    private static let heat = try! NSRegularExpression(
        pattern: #"(?<![\w.])\d{2,3}\s?°\s?[CF]?(?![a-z])|(?<![\w.])\d{3}\s?[CF]\b|(?<![\w.])\d{2,3} degrees(?: [CF]\b)?|\bgas mark \d|\b(?:very low|low|medium[- ]low|medium[- ]high|medium|moderate|high|gentle)\s+heat\b"#,
        options: [.caseInsensitive])
    private static let until = try! NSRegularExpression(pattern: #"\buntil\b(?:(?!\buntil\b)[^.;!?])*"#, options: [.caseInsensitive])
    private static let cut = try! NSRegularExpression(pattern: #",?\s+(?:and then|then|before)\b"#, options: [.caseInsensitive])

    /// Where a step names a temperature or a heat: "390°F", "medium-high heat".
    static func heat(in step: String) -> [NSRange] {
        heat.matches(in: step, range: NSRange(location: 0, length: (step as NSString).length)).map(\.range)
    }

    /// What to look for: "until fragrant but not coloured", with where it starts.
    static func cues(in step: String) -> [(location: Int, text: String)] {
        let ns = step as NSString
        return until.matches(in: step, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            var text = ns.substring(with: match.range)
            if let stop = cut.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                text = (text as NSString).substring(to: stop.range.location)
            }
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,:"))
            return text.count > 8 ? (match.range.location, text) : nil
        }
    }

    /// How to tell a timer's food is done: the "until" in the sentence its time is in.
    static func cue(for duration: StepDuration, in step: String) -> String? {
        let ns = step as NSString
        let ends = CharacterSet(charactersIn: ".;!?")
        let before = ns.rangeOfCharacter(from: ends, options: .backwards, range: NSRange(location: 0, length: duration.location))
        let afterStart = duration.location + duration.length
        let after = ns.rangeOfCharacter(from: ends, range: NSRange(location: afterStart, length: ns.length - afterStart))
        let from = before.location == NSNotFound ? 0 : before.location, to = after.location == NSNotFound ? ns.length : after.location
        return cues(in: step).first { $0.location >= from && $0.location < to }?.text
    }
}

extension Recipe {
    /// How many it serves, when the yield says.
    var servings: Int? { Ingredients.servings(in: yield) }

    /// The recipe for more or fewer people. Times, notes and nutrition per serving stay.
    func scaled(by factor: Double) -> Recipe {
        guard factor != 1, factor > 0 else { return self }
        var copy = self
        copy.ingredients = ingredients.map { Ingredients.scale($0, by: factor) }
        copy.steps = steps.map { Ingredients.scale(step: $0, by: factor, ingredients: ingredients) }
        if let yield, let servings, let found = yield.range(of: #"\d{1,3}"#, options: .regularExpression) {
            copy.yield = yield.replacingCharacters(in: found, with: Ingredients.format(Double(servings) * factor, metric: false))
        }
        return copy
    }

    func scaled(to count: Int) -> Recipe {
        guard let servings, count > 0 else { return self }
        return scaled(by: Double(count) / Double(servings))
    }

    func uses(step index: Int) -> [StepUse] {
        steps.indices.contains(index) ? Ingredients.uses(in: steps[index], of: ingredients) : []
    }
}
