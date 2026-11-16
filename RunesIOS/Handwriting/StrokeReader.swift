import Foundation

/// Reads letters from pen strokes on the phone, with no model on the band. It is fed the pen
/// events of any source (a finger on the glass, a script, the wrist's own path through the
/// air) and passes them on with what it made of them.
///
/// A letter is whatever is written before the pen has rested for `letterRest`, so a letter
/// can take two strokes. It is matched against `LetterForms` by shape alone: where it was
/// written and how large do not matter, which way up it is does. A long strike from right to
/// left takes the last letter back. A longer rest ends the word.
struct StrokeReader: Sendable {
    /// Seconds the pen rests before a letter is read, and before a word is finished.
    static let letterRest = 0.5, wordRest = 1.6
    /// A reading less sure than this is not kept.
    static let floor = 0.45
    /// Seconds between guesses while the pen is moving.
    static let guessEvery = 0.08

    private var strokes: [[WritingPoint]] = []
    private var penDown = false
    private var restingSince: TimeInterval?
    private var guessedAt: TimeInterval = -.infinity
    private var kept = 0

    /// Takes a pen event and gives back what the screen should hear: the event itself, and
    /// a guess now and then while the pen moves.
    mutating func pen(_ event: WritingEvent, at now: TimeInterval) -> [WritingEvent] {
        switch event {
        case .began(let point):
            strokes.append([point]); penDown = true; restingSince = nil
        case .moved(let point):
            guard penDown, !strokes.isEmpty else { return [] }
            strokes[strokes.count - 1].append(point)
            if now - guessedAt >= Self.guessEvery, let reading = Self.read(strokes) {
                guessedAt = now
                return [event, .guessed(reading.character, sure: reading.sure)]
            }
        case .lifted:
            guard penDown else { return [] }
            penDown = false; restingSince = now
        default:
            return []
        }
        return [event]
    }

    /// When `tick` next has something to say, if the pen stays up.
    var nextTick: TimeInterval? {
        guard let restingSince, !penDown else { return nil }
        return restingSince + (strokes.isEmpty ? Self.wordRest : Self.letterRest)
    }

    /// Call when time has passed with the pen up: reads the letter, or finishes the word.
    mutating func tick(at now: TimeInterval) -> [WritingEvent] {
        guard let due = nextTick, now >= due else { return [] }
        if strokes.isEmpty {
            restingSince = nil
            guard kept > 0 else { return [] }
            kept = 0
            return [.finished]
        }
        let written = strokes
        strokes = []; restingSince = now
        if Self.isStrike(written) {
            guard kept > 0 else { return [.unread] }
            kept -= 1
            return [.erased]
        }
        guard let reading = Self.read(written), reading.sure >= Self.floor else { return [.unread] }
        kept += 1
        return [.read(reading.character, sure: reading.sure)]
    }

    // MARK: Matching

    private static let samples = 48
    private static let templates: [(character: Character, shape: [WritingPoint])] =
        LetterForms.letters.map { ($0, normalize(LetterForms.strokes(for: $0))) }

    /// One stroke, much wider than tall, drawn from right to left.
    static func isStrike(_ strokes: [[WritingPoint]]) -> Bool {
        guard strokes.count == 1, let first = strokes[0].first, let last = strokes[0].last else { return false }
        let ys = strokes[0].map(\.y), tall = ys.max()! - ys.min()!, wide = first.x - last.x
        return wide > 0.3 && tall < wide * 0.25 && LetterForms.length(strokes[0]) < wide * 1.3
    }

    /// The best reading of some strokes: the letter, how sure, and the letter it could be instead.
    static func read(_ strokes: [[WritingPoint]]) -> (character: Character, sure: Double, other: Character)? {
        let ranked = rank(strokes)
        guard ranked.count > 1 else { return nil }
        let best = ranked[0], next = ranked[1]
        // Sure when the shape is close to a letter and not nearly as close to another.
        let close = exp(-9 * best.distance), apart = min(1, 0.55 + 2.2 * (next.distance - best.distance) / max(next.distance, 1e-9))
        return (best.character, min(1, close * apart * 1.25), next.character)
    }

    /// Every letter with how far the strokes are from it, nearest first.
    static func rank(_ strokes: [[WritingPoint]]) -> [(character: Character, distance: Double)] {
        let shape = normalize(strokes)
        guard shape.count == samples else { return [] }
        return templates.map { ($0.character, distance(shape, $0.shape)) }.sorted { $0.1 < $1.1 }
    }

    /// The strokes as `samples` points shared out by length, centred, and scaled so the
    /// longer side of their box is 1. Empty when nothing was drawn.
    static func normalize(_ strokes: [[WritingPoint]]) -> [WritingPoint] {
        let drawn = strokes.filter { !$0.isEmpty }
        let lengths = drawn.map(LetterForms.length), total = lengths.reduce(0, +)
        guard total > 1e-6 else { return [] }
        // Every stroke gets at least two points, so the dot of an i is not lost.
        var counts = lengths.map { max(2, Int(($0 / total * Double(samples)).rounded())) }
        let longest = lengths.indices.max { lengths[$0] < lengths[$1] }!
        counts[longest] = max(2, counts[longest] + samples - counts.reduce(0, +))
        guard counts.reduce(0, +) == samples else { return [] }
        var points: [WritingPoint] = []
        for (stroke, count) in zip(drawn, counts) {
            let own = LetterForms.length(stroke)
            for index in 0..<count { points.append(LetterForms.point(along: stroke, at: own * Double(index) / Double(count - 1))) }
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        let scale = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        guard scale > 1e-9 else { return [] }
        let cx = xs.reduce(0, +) / Double(samples), cy = ys.reduce(0, +) / Double(samples)
        return points.map { WritingPoint(($0.x - cx) / scale, ($0.y - cy) / scale) }
    }

    /// The mean gap between two shapes point by point in the order written, letting either
    /// run up to six points ahead of the other.
    private static func distance(_ a: [WritingPoint], _ b: [WritingPoint]) -> Double {
        let n = samples, band = 6
        var previous = [Double](repeating: .infinity, count: n + 1), row = previous
        previous[0] = 0
        for i in 1...n {
            for k in 0...n { row[k] = .infinity }
            for j in max(1, i - band)...min(n, i + band) {
                let gap = hypot(a[i - 1].x - b[j - 1].x, a[i - 1].y - b[j - 1].y)
                row[j] = gap + min(previous[j - 1], previous[j], row[j - 1])
            }
            swap(&previous, &row)
        }
        return previous[n] / Double(n)
    }
}

/// Turns the wrist's path through the air into pen events, for writing with the band and no
/// model at all. The pen is down while a finger is held to the thumb, which the band already
/// reports, and the point is where the forearm points, which the app already receives for air
/// gestures. Nothing here asks the band for anything.
struct MotionPen: Sendable {
    /// How much of the writing box a full swing of the forearm crosses.
    static let reach = 1.6
    /// Where the forearm pointed when the letter began. It is kept between the strokes of
    /// one letter, so a second stroke lands where it was made.
    private var reference: [Double]?
    private var penDown = false
    /// Whether the stroke under way has its first point yet.
    private var stroking = false

    /// A finger came down on the thumb or let go.
    mutating func hold(_ down: Bool) -> [WritingEvent] {
        guard down != penDown else { return [] }
        penDown = down
        guard !down, stroking else { return [] }
        stroking = false
        return [.lifted]
    }

    /// The band's orientation as a unit quaternion in w, x, y, z order.
    mutating func orientation(_ q: [Double]) -> [WritingEvent] {
        guard penDown, q.count == 4 else { return [] }
        if reference == nil { reference = q }
        let swing = AirMatcher.wristPoint(q, reference: reference!)
        let point = WritingPoint(0.5 + swing[0] * Self.reach, 0.5 - swing[1] * Self.reach)
        defer { stroking = true }
        return [stroking ? .moved(point) : .began(point)]
    }

    /// A letter was read or given up: the next one starts from wherever the wrist is then.
    mutating func settle() { reference = nil }
}
