import Foundation

/// The lower case alphabet as it is written by hand, a stroke at a time, in the unit writing
/// box: the tops of small letters at 0.36, the line they stand on at 0.75. The reader matches
/// what is written against these, and the screens use them wherever a letter has to be drawn
/// as a hand would draw it.
enum LetterForms {
    /// The corners each stroke passes through, before it is rounded.
    private static let corners: [Character: [[(Double, Double)]]] = [
        "a": [[(0.72, 0.45), (0.55, 0.35), (0.34, 0.44), (0.28, 0.6), (0.42, 0.75), (0.6, 0.7), (0.72, 0.5), (0.72, 0.36), (0.72, 0.62), (0.76, 0.75)]],
        "b": [[(0.3, 0.08), (0.3, 0.75), (0.3, 0.5), (0.45, 0.36), (0.66, 0.42), (0.72, 0.58), (0.58, 0.75), (0.3, 0.7)]],
        "c": [[(0.7, 0.45), (0.52, 0.35), (0.33, 0.45), (0.28, 0.58), (0.4, 0.73), (0.58, 0.75), (0.72, 0.66)]],
        "d": [[(0.7, 0.45), (0.52, 0.35), (0.33, 0.45), (0.28, 0.6), (0.42, 0.75), (0.62, 0.7), (0.72, 0.5), (0.72, 0.08), (0.72, 0.75)]],
        "e": [[(0.3, 0.56), (0.7, 0.54), (0.66, 0.4), (0.5, 0.35), (0.33, 0.44), (0.28, 0.58), (0.4, 0.73), (0.58, 0.75), (0.72, 0.66)]],
        "f": [[(0.68, 0.14), (0.56, 0.08), (0.46, 0.16), (0.44, 0.75)], [(0.3, 0.4), (0.62, 0.4)]],
        "g": [[(0.72, 0.45), (0.55, 0.35), (0.34, 0.44), (0.28, 0.6), (0.42, 0.75), (0.6, 0.7), (0.72, 0.5), (0.72, 0.36), (0.72, 0.9), (0.6, 1.0), (0.4, 0.98), (0.3, 0.9)]],
        "h": [[(0.3, 0.08), (0.3, 0.75), (0.3, 0.5), (0.45, 0.36), (0.62, 0.38), (0.7, 0.5), (0.7, 0.75)]],
        "i": [[(0.5, 0.36), (0.5, 0.75)], [(0.5, 0.2), (0.5, 0.23)]],
        "j": [[(0.55, 0.36), (0.55, 0.9), (0.45, 1.0), (0.32, 0.94)], [(0.55, 0.2), (0.55, 0.23)]],
        "k": [[(0.3, 0.08), (0.3, 0.75)], [(0.68, 0.36), (0.32, 0.58), (0.7, 0.75)]],
        "l": [[(0.5, 0.08), (0.5, 0.68), (0.56, 0.75)]],
        "m": [[(0.2, 0.36), (0.2, 0.75), (0.2, 0.48), (0.3, 0.36), (0.42, 0.38), (0.48, 0.5), (0.48, 0.75), (0.48, 0.48), (0.58, 0.36), (0.7, 0.38), (0.78, 0.5), (0.78, 0.75)]],
        "n": [[(0.3, 0.36), (0.3, 0.75), (0.3, 0.5), (0.44, 0.36), (0.6, 0.38), (0.7, 0.5), (0.7, 0.75)]],
        "o": [[(0.5, 0.35), (0.33, 0.45), (0.28, 0.58), (0.4, 0.73), (0.58, 0.74), (0.72, 0.6), (0.68, 0.42), (0.5, 0.35)]],
        "p": [[(0.3, 0.36), (0.3, 1.0), (0.3, 0.5), (0.45, 0.36), (0.66, 0.42), (0.72, 0.56), (0.58, 0.75), (0.3, 0.7)]],
        "q": [[(0.72, 0.45), (0.55, 0.35), (0.34, 0.44), (0.28, 0.6), (0.42, 0.75), (0.6, 0.7), (0.72, 0.5), (0.72, 0.36), (0.72, 1.0)]],
        "r": [[(0.34, 0.36), (0.34, 0.75), (0.34, 0.52), (0.44, 0.4), (0.58, 0.35), (0.7, 0.4)]],
        "s": [[(0.68, 0.42), (0.52, 0.35), (0.36, 0.4), (0.36, 0.5), (0.5, 0.56), (0.64, 0.62), (0.64, 0.7), (0.5, 0.75), (0.32, 0.7)]],
        "t": [[(0.48, 0.14), (0.48, 0.66), (0.56, 0.75), (0.66, 0.72)], [(0.32, 0.36), (0.66, 0.36)]],
        "u": [[(0.3, 0.36), (0.3, 0.6), (0.38, 0.73), (0.54, 0.74), (0.7, 0.6), (0.7, 0.36), (0.7, 0.75)]],
        "v": [[(0.28, 0.36), (0.5, 0.75), (0.72, 0.36)]],
        "w": [[(0.2, 0.36), (0.35, 0.75), (0.5, 0.42), (0.65, 0.75), (0.8, 0.36)]],
        "x": [[(0.3, 0.36), (0.7, 0.75)], [(0.7, 0.36), (0.3, 0.75)]],
        "y": [[(0.3, 0.36), (0.32, 0.6), (0.44, 0.74), (0.6, 0.7), (0.7, 0.55), (0.7, 0.36), (0.7, 0.9), (0.58, 1.0), (0.4, 0.97)]],
        "z": [[(0.3, 0.36), (0.7, 0.36), (0.3, 0.75), (0.7, 0.75)]],
    ]
    /// Letters made of straight lines keep their corners.
    private static let angular: Set<Character> = ["k", "v", "w", "x", "z"]

    static let letters: [Character] = corners.keys.sorted()

    private static let forms: [Character: [[WritingPoint]]] = corners.reduce(into: [:]) { forms, entry in
        forms[entry.key] = entry.value.map { stroke in
            let points = stroke.map { WritingPoint($0.0, $0.1) }
            return angular.contains(entry.key) ? points : rounded(points)
        }
    }

    /// The strokes of a letter, or none for anything outside the alphabet.
    static func strokes(for character: Character) -> [[WritingPoint]] { forms[character] ?? [] }

    /// A curve through every corner, six steps to each span.
    private static func rounded(_ points: [WritingPoint]) -> [WritingPoint] {
        guard points.count > 2 else { return points }
        var curve: [WritingPoint] = []
        for index in 0..<points.count - 1 {
            let before = points[max(0, index - 1)], from = points[index], to = points[index + 1], after = points[min(points.count - 1, index + 2)]
            for step in 0..<6 {
                let t = Double(step) / 6, t2 = t * t, t3 = t2 * t
                func blend(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
                    0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (3 * b - a - 3 * c + d) * t3)
                }
                curve.append(WritingPoint(blend(before.x, from.x, to.x, after.x), blend(before.y, from.y, to.y, after.y)))
            }
        }
        return curve + [points[points.count - 1]]
    }

    static func length(_ stroke: [WritingPoint]) -> Double {
        zip(stroke, stroke.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// The point a given distance along a stroke.
    static func point(along stroke: [WritingPoint], at distance: Double) -> WritingPoint {
        guard var last = stroke.first else { return WritingPoint(0.5, 0.5) }
        var left = max(0, distance)
        for next in stroke.dropFirst() {
            let span = hypot(next.x - last.x, next.y - last.y)
            if span >= left, span > 0 {
                let t = left / span
                return WritingPoint(last.x + (next.x - last.x) * t, last.y + (next.y - last.y) * t)
            }
            left -= span; last = next
        }
        return last
    }

    /// The part of some strokes between two fractions of their whole length, in the order
    /// they were written.
    static func cut(_ strokes: [[WritingPoint]], from: Double, to: Double) -> [[WritingPoint]] {
        let total = strokes.reduce(0) { $0 + length($1) }
        guard total > 0, to > from else { return [] }
        var start = 0.0, parts: [[WritingPoint]] = []
        for stroke in strokes {
            let own = length(stroke), low = from * total - start, high = to * total - start
            defer { start += own }
            guard high > 0, low < own, own > 0 else { continue }
            var part = [point(along: stroke, at: max(0, low))], along = 0.0
            for (a, b) in zip(stroke, stroke.dropFirst()) {
                along += hypot(b.x - a.x, b.y - a.y)
                if along > max(0, low), along < min(own, high) { part.append(b) }
            }
            part.append(point(along: stroke, at: min(own, high)))
            parts.append(part)
        }
        return parts
    }

    /// `count` points spread evenly over some strokes, in the order they were written. Where
    /// the pen went back over its own line, as up the stem of an n, that stretch is counted
    /// once, so the points mark the shape and not the journey.
    static func spread(_ strokes: [[WritingPoint]], count: Int) -> [WritingPoint] {
        var seen: [WritingPoint] = [], runs: [[WritingPoint]] = []
        for stroke in strokes {
            var run: [WritingPoint] = []
            let total = length(stroke), steps = max(1, Int(total / 0.012))
            for step in 0...steps {
                let point = point(along: stroke, at: total * Double(step) / Double(steps))
                // The last few points are the line it is on, so they are not a retrace.
                let retraced = seen.dropLast(6).contains { hypot($0.x - point.x, $0.y - point.y) < 0.03 }
                if retraced {
                    if run.count > 1 { runs.append(run) }
                    run = []
                } else {
                    run.append(point)
                }
                seen.append(point)
            }
            if run.count > 1 { runs.append(run) }
        }
        let total = runs.reduce(0) { $0 + length($1) }
        guard count > 0, total > 0 else { return Array(repeating: strokes.first?.first ?? WritingPoint(0.5, 0.5), count: count) }
        return (0..<count).map { index in
            var left = count == 1 ? 0 : total * Double(index) / Double(count - 1)
            for run in runs {
                let own = length(run)
                if left <= own + 1e-9 { return point(along: run, at: left) }
                left -= own
            }
            return runs[runs.count - 1].last!
        }
    }
}
