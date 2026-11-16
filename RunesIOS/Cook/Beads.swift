import Foundation

// The band's eight beads as the way a cook is shown: how full each one is, where each
// sits on a loop, which step each one carries. Numbers only, so they are checked without
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

    /// Where a timer's bead sits on its rod: nothing at the end where time is up, one at
    /// the far end for the longest time. The root of the share left, so the last minutes
    /// move furthest and two times of any length are side by side when they have the
    /// same time to go.
    static func reach(_ seconds: Int, of longest: Int) -> Double {
        guard longest > 0 else { return 0 }
        return min(1, max(0, Double(seconds) / Double(longest))).squareRoot()
    }

    /// What a bead on the strand of steps stands for.
    enum Mark: Equatable, Sendable {
        /// Getting the ingredients out, before step one.
        case ready
        case step(Int)
        /// The recipe finished.
        case done
    }

    /// The eight beads of the strand and which of them is now. A recipe of six steps
    /// fills them exactly: ready, the six, done. A shorter one leaves beads spare at the
    /// end. A longer one shows the eight around now, three behind it where there are
    /// that many, so what was just started stays in sight.
    static func strand(steps: Int, now: Mark) -> (marks: [Mark?], now: Int) {
        let all: [Mark] = [.ready] + (0..<max(0, steps)).map(Mark.step) + [.done]
        let at = all.firstIndex(of: now) ?? 0
        guard all.count > count else {
            return (all + Array(repeating: nil, count: count - all.count), at)
        }
        let first = min(max(0, at - 3), all.count - count)
        return (Array(all[first..<first + count]), at - first)
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
    /// The mark on the strand for where the cook is.
    var mark: Beads.Mark { finished ? .done : gathering ? .ready : .step(step) }

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
