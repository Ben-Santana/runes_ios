import Foundation

// The band's eight beads as the way a cook is shown: how full each one is, where each
// sits on the loop, what is at each place. Numbers only, so they are checked without
// a screen (Tests/CookTests.swift).

enum Beads {
    /// The band has eight, and so does every picture made of them.
    static let count = 8

    /// How full each bead is when `done` of `total` things are done: whole beads first,
    /// then part of the next. Five of sixteen ingredients out is two beads and a half.
    static func fills(_ done: Int, of total: Int) -> [Double] {
        guard total > 0 else { return Array(repeating: 0, count: count) }
        let level = Double(min(max(done, 0), total)) / Double(total) * Double(count)
        return (0..<count).map { min(1, max(0, level - Double($0))) }
    }

    /// The wrist dial as beads. Sixty steps of the dial fill the eight once round, and a
    /// second turn fills them again, so a bead reads from nothing to two.
    static func dial(steps: Int) -> [Double] {
        let level = Double(max(0, steps)) / 60 * Double(count)
        return (0..<count).map { min(1, max(0, level - Double($0))) + min(1, max(0, level - Double(count + $0))) }
    }

    /// A bead for each person cooked for; past eight they are counted round again.
    static func people(_ number: Int) -> [Double] {
        (0..<count).map { number > count + $0 ? 2 : number > $0 ? 1 : 0 }
    }

    /// Which of the eight places on the loop each of a few things takes, spread evenly
    /// so the gaps between them are as alike as eight allows.
    static func slots(for things: Int) -> [Int] {
        let number = min(max(things, 0), count)
        return (0..<number).map { $0 * count / number }
    }

    /// How many places to turn the loop to bring one slot to where another is, the
    /// short way round: from three back to four on.
    static func shortest(from: Int, to: Int) -> Int {
        let ahead = ((to - from) % count + count) % count
        return ahead > count / 2 ? ahead - count : ahead
    }
}

/// What is at one of the kitchen's places at a moment.
struct Station: Equatable, Sendable {
    var place: StationPlan.Place
    /// What is used there now: "Skillet", "Pot", "Blender".
    var vessel: String
    /// The timer going there, the one with least time left when there are several.
    var timer: CookTimer?
    /// Whether the step showing happens there.
    var here = false
    /// A time of the step showing that has not been started, in seconds.
    var waiting: Int?
}

extension StationPlan {
    /// The places a recipe uses, in the order it comes to them. A kitchen has more, but
    /// an empty burner is nothing to show.
    var used: [Place] {
        var seen: [Place] = []
        for spot in spots where !seen.contains(spot.place) { seen.append(spot.place) }
        return seen
    }
}

extension CookSession {
    /// Every place the recipe uses and what is there now.
    func stations(_ plan: StationPlan, at now: Date) -> [Station] {
        let cooking = !finished && !gathering
        return plan.used.map { place in
            let live = timers.filter { $0.isLive && plan.spot(step: $0.step).place == place }
            let timer = live.min { ($0.remaining(at: now), $0.step) < ($1.remaining(at: now), $1.step) }
            let here = cooking && plan.spot(step: step).place == place
            // The time the gestures are on, when it has not been started.
            let own = here && pickedTimer == nil && durations.indices.contains(slot) && self.timer(step: step, slot: slot)?.isLive != true
            let vessel = here ? plan.spot(step: step).vessel : timer.map { plan.spot(step: $0.step).vessel } ?? plan.vessel(at: place) ?? "Counter"
            return Station(place: place, vessel: vessel, timer: timer, here: here, waiting: own && timer == nil ? durations[slot].seconds : nil)
        }
    }

    /// How far the wait before starting this step's time has run, from nothing when
    /// the timer it lands with began to one at the moment to start.
    func approach(at now: Date) -> Double? {
        guard let landing = landing(at: now), durations.indices.contains(slot) else { return nil }
        let whole = landing.with.total - durations[slot].seconds
        return whole > 0 ? min(1, max(0, 1 - Double(landing.wait) / Double(whole))) : 1
    }
}
