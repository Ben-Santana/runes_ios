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
