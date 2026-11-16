import Foundation

// Where in the kitchen each step of a recipe happens: one of four burners, the oven or
// the counter. Worked out from the words of the steps, so it is a good guess and not a
// fact; rules only, Foundation only (Tests/CookTests.swift).

struct StationPlan: Equatable, Sendable {
    /// A place something is cooked or made. The burners are named as they lie on a hob.
    enum Place: Int, CaseIterable, Sendable { case backLeft, backRight, frontLeft, frontRight, oven, counter }

    struct Spot: Equatable, Sendable {
        var place: Place
        /// What is used there: "Skillet", "Pot", "Air fryer", "Blender".
        var vessel: String
    }

    /// One for each step of the recipe.
    let spots: [Spot]

    private enum Kind { case burner, oven, counter }
    private static let vessels: [(name: String, pattern: String, kind: Kind)] = [
        ("Air fryer", #"air[- ]?fr"#, .oven),
        ("Oven", #"\boven\b|\bbak(e|ing)\b|\broast|\bbroil|\bgrill"#, .oven),
        ("Skillet", #"skillet|frying pan|\bpan\b|\bwok\b|saut[eé]|\bfry\b|\bsear"#, .burner),
        ("Pot", #"\bpot\b|saucepan|\bboil|simmer|\bdrain|\bpasta\b|spaghetti|penne|noodle"#, .burner),
        ("Blender", #"\bblend|food processor"#, .counter),
        ("Bowl", #"\bbowl\b|\bwhisk|\bmix\b|\btoss\b|marinat"#, .counter),
        ("Board", #"\bchop|\bslice|\bdice|\bmince|\bdivide|\bserve|\bplate\b|garnish|\btear\b"#, .counter),
    ]

    init(steps: [String]) {
        // The burners nearest the cook are taken first.
        let order: [Place] = [.frontLeft, .frontRight, .backLeft, .backRight]
        var burners: [String: Place] = [:]
        var result: [Spot] = []
        for step in steps {
            let text = step.lowercased()
            // A step with a time or a heat in it is one where something cooks.
            let cooks = !DurationFinder.find(in: step).isEmpty || !StepDetails.heat(in: step).isEmpty
            var found: (name: String, kind: Kind, at: Int)?
            for vessel in Self.vessels {
                guard let range = text.range(of: vessel.pattern, options: .regularExpression) else { continue }
                let at = text.distance(from: text.startIndex, to: range.lowerBound)
                // The place named first is where the step begins, except that in a step
                // where something cooks, where it cooks matters more than where it was mixed.
                let heat = vessel.kind != .counter
                let better = found.map { !cooks || ($0.kind != .counter) == heat ? at < $0.at : heat } ?? true
                if better { found = (vessel.name, vessel.kind, at) }
            }
            guard let found else {
                // A step that names no place carries on where the last one was.
                result.append(result.last ?? Spot(place: .counter, vessel: "Counter"))
                continue
            }
            switch found.kind {
            case .oven: result.append(Spot(place: .oven, vessel: found.name))
            case .counter: result.append(Spot(place: .counter, vessel: found.name))
            case .burner:
                let place = burners[found.name] ?? order[min(burners.count, order.count - 1)]
                burners[found.name] = place
                result.append(Spot(place: place, vessel: found.name))
            }
        }
        spots = result
    }

    func spot(step: Int) -> Spot { spots.indices.contains(step) ? spots[step] : Spot(place: .counter, vessel: "Counter") }
    /// What sits at a place over the whole recipe, if anything does.
    func vessel(at place: Place) -> String? { spots.first { $0.place == place }?.vessel }
}

/// What is worth knowing before a recipe is started, found by rules: what to start first,
/// what it takes up, where the long wait is, and the thing a later step expects to have
/// been kept. These are the places cooks say a recipe catches them out.
enum RecipeBrief {
    private static let kept = try! NSRegularExpression(pattern: #"\b(?:keep|keeping|reserve|reserving|save|set aside)\b[^.;]*"#, options: [.caseInsensitive])

    static func lines(_ recipe: Recipe) -> [String] {
        var lines: [String] = []
        if let first = StepDetails.headStarts(in: recipe.steps).first {
            lines.append("Start first: \(first.prefix(1).lowercased() + first.dropFirst()).")
        }
        let plan = StationPlan(steps: recipe.steps)
        let burners = Set(plan.spots.map(\.place)).subtracting([.oven, .counter]).count
        var kit: [String] = []
        if burners > 0 { kit.append(burners == 1 ? "one burner" : "\(burners) burners") }
        if let oven = plan.spots.first(where: { $0.place == .oven })?.vessel { kit.append("the \(oven.lowercased())") }
        if !kit.isEmpty { lines.append("Uses \(kit.joined(separator: " and ")).") }
        let waits = recipe.steps.enumerated().flatMap { index, step in DurationFinder.find(in: step).map { (step: index, time: $0) } }
        if let longest = waits.max(by: { $0.time.seconds < $1.time.seconds }), longest.time.seconds >= 300 {
            lines.append("Longest wait: \(longest.time.short) at step \(longest.step + 1)" + (longest.time.label.map { ", \($0.lowercased())" } ?? "") + ".")
        }
        for (index, step) in recipe.steps.enumerated() {
            let ns = step as NSString
            guard let match = kept.firstMatch(in: step, range: NSRange(location: 0, length: ns.length)) else { continue }
            let phrase = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            lines.append("Don’t miss at step \(index + 1): \(phrase.prefix(1).lowercased() + phrase.dropFirst()).")
            break
        }
        return lines
    }

    /// Why a recipe is suggested: it hasn't been cooked, or not for a while.
    static func reason(_ recipe: Recipe, now: Date = Date()) -> String {
        guard let last = recipe.lastCooked else { return recipe.cooked > 0 ? "Not cooked for a while" : "You haven’t cooked this yet" }
        let days = max(0, Int(now.timeIntervalSince(last) / 86_400))
        return days == 0 ? "Cooked today" : days == 1 ? "Last cooked yesterday" : "Last cooked \(days) days ago"
    }

    /// A place as taps on the wrist after an alarm, so which pan it is can be felt: one to
    /// four for the burners, counted from the front left, and a long one for the oven.
    static func wrist(_ place: StationPlan.Place) -> [BandBuzz] {
        switch place {
        case .frontLeft: [.tap]
        case .frontRight: [.tap, .tap]
        case .backLeft: [.tap, .tap, .tap]
        case .backRight: [.tap, .tap, .tap, .tap]
        case .oven: [.long]
        case .counter: []
        }
    }
}
