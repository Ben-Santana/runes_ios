import Foundation

// Getting a recipe out of whatever was pasted: a link among other words, a page that
// publishes no recipe data, text too long for the on-device model, and the checks that
// say which lines of a sorted recipe to look at again. Rules only, Foundation only
// (Tests/CookImportTests.swift); the model itself is called from RecipeModel.swift.

enum RecipeImporter {
    // MARK: Links

    private static let url = try! NSRegularExpression(pattern: #"https?://[^\s<>"']+"#, options: [.caseInsensitive])

    /// The link in a short message such as "try this https://… tonight". Text that is
    /// itself a recipe and happens to cite its source is left as text.
    static func link(in text: String) -> URL? {
        if let whole = RecipeParser.link(in: text) { return whole }
        let ns = text as NSString
        let found = url.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard found.count == 1 else { return nil }
        let link = ns.substring(with: found[0].range).trimmingCharacters(in: CharacterSet(charactersIn: ".,)!?"))
        let rest = ns.replacingCharacters(in: found[0].range, with: " ")
        guard rest.split(whereSeparator: \.isWhitespace).count <= 12, let url = URL(string: link), url.host() != nil else { return nil }
        return url
    }

    // MARK: Pages

    private static func replace(_ pattern: String, _ replacement: String, in text: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
    }

    /// A page as the text a reader sees: no scripts, menus or footers, one line per
    /// paragraph, heading and list item. The page's title comes first.
    static func text(fromHTML html: String) -> String {
        // The page's own heading names the dish; failing that its title, which is
        // "Lemon chicken | Some Site": the dish, then where it is from.
        var title = ""
        for pattern in [#"<h1\b[^>]*>[\s\S]*?</h1>"#, #"<title[^>]*>[\s\S]*?</title>"#] where title.isEmpty {
            guard let found = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            title = RecipeParser.clean(String(html[found]))
            for separator in [" | ", " – ", " - "] { title = title.components(separatedBy: separator).first ?? title }
        }
        var body = html
        if let start = body.range(of: #"<body[^>]*>"#, options: [.regularExpression, .caseInsensitive]) { body = String(body[start.upperBound...]) }
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "aside", "form", "button", "iframe", "select", "figure"] {
            body = replace("<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", " ", in: body)
        }
        body = replace(#"<!--[\s\S]*?-->"#, " ", in: body)
        // The article, when the page says which part that is.
        for tag in ["article", "main"] {
            if let found = body.range(of: "<\(tag)\\b[^>]*>[\\s\\S]*</\(tag)>", options: [.regularExpression, .caseInsensitive]), body[found].count > 600 {
                body = String(body[found]); break
            }
        }
        body = replace(#"\s+"#, " ", in: body)
        body = replace(#"<li\b[^>]*>"#, "\n- ", in: body)
        body = replace(#"<h[1-6]\b[^>]*>"#, "\n\n", in: body)
        body = replace(#"<br\s*/?>|</(p|div|li|h[1-6]|tr|ul|ol|section|table)>"#, "\n", in: body)
        body = RecipeParser.decode(replace(#"<[^>]+>"#, "", in: body))
        var lines: [String] = []
        for raw in body.components(separatedBy: "\n") {
            let line = replace(#"[ \t\u{00A0}]+"#, " ", in: raw).trimmingCharacters(in: .whitespaces)
            if line == "-" || line.isEmpty || line == lines.last { continue }
            lines.append(line)
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || text.hasPrefix(title) ? text : title + "\n" + text
    }

    // MARK: Fitting the model

    /// Roughly what the on-device model takes in one go, leaving it room to answer.
    static let limit = 6000
    private static let tail = #"^(comments?|reviews?|leave a (reply|comment|review)|you (may|might) also like|related (recipes|posts)|more recipes|reader interactions|about the author)\b"#

    private static func looksLikeIngredient(_ line: String) -> Bool {
        let body = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
        return body.count <= 70 && Ingredients.split(body).amount != nil
    }

    /// The part of a long text most likely to be the recipe: from just before its
    /// ingredients, as much as fits. The first line, usually the name, is kept.
    static func window(_ text: String, limit: Int = limit) -> String {
        guard text.count > limit else { return text }
        var lines = text.components(separatedBy: "\n")
        if let end = lines.firstIndex(where: { $0.range(of: tail, options: [.regularExpression, .caseInsensitive]) != nil }), end > 8 {
            lines = Array(lines[..<end])
        }
        let title = lines.first ?? ""
        // The ingredient list: the first place three of five lines start with an amount.
        var start = 0
        for index in lines.indices where looksLikeIngredient(lines[index]) {
            if lines[index..<min(lines.count, index + 5)].filter(looksLikeIngredient).count >= 3 { start = max(0, index - 3); break }
        }
        var kept: [String] = start > 0 ? [title] : [], count = start > 0 ? title.count + 1 : 0
        for line in lines[start...] {
            // A line that doesn't fit is cut where the room ends: a recipe pasted as one
            // paragraph has no other place to cut.
            guard count + line.count + 1 <= limit else {
                if limit - count > 200 { kept.append(String(line.prefix(limit - count - 1))) }
                break
            }
            kept.append(line); count += line.count + 1
        }
        return kept.joined(separator: "\n")
    }

    /// Whether the rules read the text cleanly: it has headings for both halves and a
    /// list under each. Then no model is needed, and nothing was reworded.
    static func isClear(_ text: String, parsed: Recipe) -> Bool {
        RecipeParser.hasHeadings(text) && parsed.ingredients.count >= 2 && parsed.steps.count >= 2
    }

    // MARK: Checks

    /// A line of a sorted recipe that says something the pasted text didn't, or something
    /// the pasted text said that the recipe lost.
    struct Issue: Hashable, Sendable {
        var line: String
        var reason: String
    }

    private static let figure = try! NSRegularExpression(pattern: #"\d+\s+\d/\d|\d+/\d+|\d+(?:[.,]\d+)?\s?[½¼¾⅓⅔⅛]?|[½¼¾⅓⅔⅛]"#)

    /// The numbers in a text as values, so "1/2" and "½" are the same number.
    private static func figures(_ text: String) -> [Double] {
        let ns = text as NSString
        return figure.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            DurationFinder.value(ns.substring(with: $0.range).trimmingCharacters(in: .whitespaces))
        }
    }

    private static func has(_ value: Double, in values: [Double]) -> Bool { values.contains { abs($0 - value) < 0.01 } }

    /// Checks a recipe the model sorted against what was pasted. A model can drop, merge
    /// or invent; numbers, times, temperatures and the names of ingredients are the
    /// things that must not change, and they can be compared without understanding.
    static func check(_ recipe: Recipe, against source: String) -> [Issue] {
        var issues: [Issue] = []
        let numbers = figures(source)
        for item in recipe.ingredients where !item.hasSuffix(":") {
            let amounts = figures(item), head = Ingredients.head(of: item)
            if let head, !Ingredients.mentions(head, in: source) {
                issues.append(Issue(line: item, reason: "This ingredient isn’t in what you pasted."))
            } else if let head, let first = amounts.first, Ingredients.split(item).amount != nil {
                // The amount it starts with belongs to it; any other number only has to be there.
                if !Ingredients.states(first, of: head, in: source) || !amounts.dropFirst().allSatisfy({ has($0, in: numbers) }) {
                    issues.append(Issue(line: item, reason: "What you pasted gives another amount for this."))
                }
            } else if !amounts.allSatisfy({ has($0, in: numbers) }) {
                issues.append(Issue(line: item, reason: "This amount isn’t in what you pasted."))
            }
        }
        // "Prep time: 10 minutes" is about the whole recipe; no step has to say it.
        let method = replace(#"\b(prep|cook|cooking|total|active|inactive|resting|rest|chill|chilling|ready in)( time)?\s*[:\-–][^.\n|]*"#, "", in: source)
        let times = Set(DurationFinder.find(in: method).map(\.seconds))
        var kept: Set<Int> = []
        for step in recipe.steps {
            let found = DurationFinder.find(in: step)
            kept.formUnion(found.map(\.seconds))
            if let wrong = found.first(where: { !times.contains($0.seconds) }) {
                issues.append(Issue(line: step, reason: "“\(wrong.phrase)” isn’t a time in what you pasted."))
            } else if !figures(step).allSatisfy({ has($0, in: numbers) }) {
                issues.append(Issue(line: step, reason: "A number here isn’t in what you pasted."))
            }
        }
        // What was lost: a time or a temperature the pasted method gives and no step has.
        let written = (recipe.steps + (recipe.notes ?? [])).joined(separator: "\n")
        for duration in DurationFinder.find(in: method) where !kept.contains(duration.seconds) {
            let issue = Issue(line: duration.phrase, reason: "This time is in what you pasted, but in no step.")
            if !issues.contains(issue) { issues.append(issue) }
        }
        let heats = Set(figures(StepDetails.heat(in: written).map { (written as NSString).substring(with: $0) }.joined(separator: " ")).map { Int($0) })
        for heat in StepDetails.heat(in: method).map({ (method as NSString).substring(with: $0) }) {
            guard let degrees = figures(heat).first, !heats.contains(Int(degrees)) else { continue }
            let issue = Issue(line: heat, reason: "This temperature is in what you pasted, but in no step.")
            if !issues.contains(issue) { issues.append(issue) }
        }
        return issues
    }

    /// How much of the pasted text's wording is still in the recipe, 0 to 1. Low means
    /// detail was dropped or reworded: worth comparing with what was pasted before saving.
    static func coverage(of source: String, in recipe: Recipe) -> Double {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 4 })
        }
        let wanted = words(source)
        guard !wanted.isEmpty else { return 1 }
        let have = words(([recipe.title, recipe.yield ?? "", recipe.nutrition ?? ""] + recipe.ingredients + recipe.steps + (recipe.notes ?? [])).joined(separator: " "))
        return Double(wanted.intersection(have).count) / Double(wanted.count)
    }
}
