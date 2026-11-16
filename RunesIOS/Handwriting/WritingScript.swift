import Foundation

/// A sample of handwriting as timed pen events, so the screens can be judged without a band.
/// It waits, writes r and u, makes a scribble that cannot be read, then writes n, e and s and
/// rests, which finishes the word. Only the pen is scripted: the letters are read by whatever
/// reader the events are given to.
enum WritingScript {
    struct Step: Sendable {
        /// Seconds from the start of the sample.
        let at: TimeInterval
        let event: WritingEvent
    }

    static let sample: [Step] = {
        var steps: [Step] = [], clock = 1.2
        let scribble = [(0...14).map { WritingPoint(0.3 + 0.4 * abs(sin(Double($0) * 0.55)), 0.34 + 0.026 * Double($0) + 0.1 * sin(Double($0) * 1.9)) }]
        let written: [[[WritingPoint]]] = ["r", "u"].map(LetterForms.strokes) + [scribble] + ["n", "e", "s"].map(LetterForms.strokes)
        for (number, strokes) in written.enumerated() {
            for (part, stroke) in strokes.enumerated() {
                let hand = stroke.enumerated().map { index, point -> WritingPoint in
                    // A hand's slant and unsteadiness, the same every time the sample plays.
                    let phase = Double(number) * 3.1 + Double(part) * 1.7 + Double(index) * 0.5
                    return WritingPoint(point.x + (0.75 - point.y) * 0.1 + 0.006 * sin(phase), point.y + 0.006 * cos(phase * 1.3))
                }
                let length = LetterForms.length(hand), time = min(1.4, max(0.22, length * 0.8)), frames = max(2, Int(time * 60))
                for frame in 0...frames {
                    // The pen starts and stops gently.
                    let along = Double(frame) / Double(frames), eased = along * along * (3 - 2 * along)
                    let point = LetterForms.point(along: hand, at: length * eased)
                    steps.append(Step(at: clock + time * along, event: frame == 0 ? .began(point) : .moved(point)))
                }
                clock += time
                steps.append(Step(at: clock, event: .lifted))
                clock += 0.2
            }
            // Long enough for the letter to be read and looked at before the next.
            clock += StrokeReader.letterRest + 0.6
        }
        return steps
    }()
}
