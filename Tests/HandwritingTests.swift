// swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Handwriting/Writing.swift RunesIOS/Handwriting/LetterForms.swift RunesIOS/Handwriting/StrokeReader.swift RunesIOS/Handwriting/WritingScript.swift RunesIOS/Mappings/AirGesture.swift Tests/HandwritingTests.swift -o /private/tmp/runes-handwriting-tests && /private/tmp/runes-handwriting-tests
// Checks the phone's own stroke reader, the sample script and the writing state. No Bluetooth.
import Foundation

@main
struct HandwritingTests {
    /// A hand's version of a letter: slanted, a little off size, and unsteady.
    static func wobbly(_ strokes: [[WritingPoint]], seed: Double, slant: Double = 0.12, wobble: Double = 0.012) -> [[WritingPoint]] {
        strokes.enumerated().map { number, stroke in
            stroke.enumerated().map { index, point in
                let phase = seed * 7.3 + Double(number) * 2.1 + Double(index) * 0.45
                let x = 0.2 + (point.x + (0.75 - point.y) * slant) * (0.55 + 0.1 * sin(seed))
                let y = 0.1 + point.y * (0.6 + 0.08 * cos(seed * 1.7))
                return WritingPoint(x + wobble * sin(phase), y + wobble * cos(phase * 1.3))
            }
        }
    }

    static func main() {
        // Every letter reads as itself when written cleanly, and when written by an unsteady hand.
        var misread: [String] = [], least = 1.0
        for letter in LetterForms.letters {
            let clean = StrokeReader.read(LetterForms.strokes(for: letter))
            precondition(clean?.character == letter, "\(letter) reads as \(String(describing: clean?.character))")
            for seed in 1...12 {
                let reading = StrokeReader.read(wobbly(LetterForms.strokes(for: letter), seed: Double(seed)))!
                if reading.character != letter { misread.append("\(letter) as \(reading.character)") }
                else { least = min(least, reading.sure) }
            }
        }
        print("misread \(misread.count) of \(LetterForms.letters.count * 12): \(misread)")
        print("least sure of a right reading: \(least)")
        precondition(misread.count <= LetterForms.letters.count * 12 / 20, "More than one unsteady letter in twenty is misread")

        // A scribble is not a letter.
        let scribble = [(0..<60).map { WritingPoint(0.5 + 0.3 * sin(Double($0) * 0.9), 0.5 + 0.25 * cos(Double($0) * 1.7)) }]
        let nonsense = StrokeReader.read(scribble)
        print("scribble: \(String(describing: nonsense))")
        precondition((nonsense?.sure ?? 0) < StrokeReader.floor, "A scribble must not be kept")

        // A strike from right to left is not a letter either.
        precondition(StrokeReader.isStrike([[WritingPoint(0.8, 0.5), WritingPoint(0.5, 0.52), WritingPoint(0.2, 0.5)]]))
        precondition(!StrokeReader.isStrike([[WritingPoint(0.2, 0.5), WritingPoint(0.8, 0.5)]]), "Left to right is not a strike")

        // The sample script, read by the reader as the screen would hear it.
        var reader = StrokeReader(), writing = Writing(), heard: [WritingEvent] = [], sawUnread = false
        func pass(_ events: [WritingEvent], at now: TimeInterval) {
            for event in events {
                heard.append(event); writing.apply(event, at: now)
                if event == .unread { sawUnread = true; precondition(writing.phase == .unread && !writing.strokes.isEmpty) }
            }
        }
        var clock = 0.0
        for step in WritingScript.sample {
            // Time passes in small steps, as it would on a screen.
            while clock < step.at {
                clock = min(step.at, clock + 0.02)
                pass(reader.tick(at: clock), at: clock)
            }
            pass(reader.pen(step.event, at: clock), at: clock)
        }
        while writing.phase != .finished, clock < WritingScript.sample.last!.at + 5 { clock += 0.02; pass(reader.tick(at: clock), at: clock) }
        precondition(writing.phase == .finished && writing.text == "runes", "The sample reads as \(writing.text)")
        precondition(sawUnread, "The sample has one letter that is not read")
        precondition(heard.contains { if case .guessed = $0 { true } else { false } }, "Guesses arrive while writing")
        print("sample: \(writing.text), sure \(writing.letters.map { String(format: "%.2f", $0.sure) })")

        // A strike takes the last letter back, and a new word starts clean.
        func write(_ strokes: [[WritingPoint]]) {
            for stroke in strokes {
                pass(reader.pen(.began(stroke[0]), at: clock), at: clock)
                for point in stroke.dropFirst() { clock += 0.01; pass(reader.pen(.moved(point), at: clock), at: clock) }
                pass(reader.pen(.lifted, at: clock), at: clock)
                clock += 0.1
            }
            clock += StrokeReader.letterRest; pass(reader.tick(at: clock), at: clock)
        }
        write(LetterForms.strokes(for: "o")); write(LetterForms.strokes(for: "k"))
        precondition(writing.text == "ok", "A new word replaces the last, got \(writing.text)")
        write([[WritingPoint(0.85, 0.5), WritingPoint(0.5, 0.5), WritingPoint(0.15, 0.5)]])
        precondition(writing.text == "o", "A strike takes back one letter")

        // A reader that only hears letters still gives the screen strokes to draw.
        var heardOnly = Writing()
        heardOnly.apply(.read("r", sure: 0.9), at: 1)
        precondition(heardOnly.letters.first?.strokes == LetterForms.strokes(for: "r"))

        // The wrist's path through the air, with a finger held, reads as the letter it traced.
        var pen = MotionPen(), air = StrokeReader(), airWriting = Writing(), time = 100.0
        func feel(_ events: [WritingEvent]) {
            for event in events { for out in air.pen(event, at: time) { airWriting.apply(out, at: time) } }
        }
        /// The quaternion that points the forearm at a place in the writing box.
        func pointing(_ point: WritingPoint) -> [Double] {
            let x = (point.x - 0.5) / MotionPen.reach, z = (point.y - 0.5) / MotionPen.reach
            let y = (1 - x * x - z * z).squareRoot()
            let q = [1 + y, z, 0, -x], norm = (q.reduce(0) { $0 + $1 * $1 }).squareRoot()
            return q.map { $0 / norm }
        }
        for stroke in LetterForms.strokes(for: "n") {
            feel(pen.orientation(pointing(stroke[0])))
            precondition(airWriting.strokes.isEmpty, "Nothing is written until a finger is held")
            feel(pen.hold(true))
            for point in stroke { time += 0.02; feel(pen.orientation(pointing(point))) }
            feel(pen.hold(false))
        }
        time += StrokeReader.letterRest
        for out in air.tick(at: time) { airWriting.apply(out, at: time) }
        pen.settle()
        precondition(airWriting.text == "n", "The air letter reads as \(airWriting.text)")

        print("Handwriting tests passed")
    }
}
