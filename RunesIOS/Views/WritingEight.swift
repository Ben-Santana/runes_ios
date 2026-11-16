import SwiftUI

/// The eight beads are the letter. They rest as the ring, spread along the line as it is
/// written, and when it is read they hop onto the letter itself and hold it until the next.
enum WritingEight {
    static func draw(_ scene: WritingScene, in canvas: inout GraphicsContext) {
        let writing = scene.writing, pad = scene.pad
        let scale = pad.width / 170
        let ring = WritingScene.ring(centre: CGPoint(x: pad.midX, y: pad.midY), scale: scale)
        func seats(_ strokes: [[WritingPoint]]) -> [CGPoint] { LetterForms.spread(strokes, count: 8).map { WritingScene.place($0, in: pad) } }
        func form(_ letter: Writing.Letter?) -> [[WritingPoint]] { letter.map { LetterForms.strokes(for: $0.character) } ?? [] }
        func line(_ strokes: [[WritingPoint]]) -> Path { WritingScene.path(strokes, in: pad) }

        // Where the beads come from and go to, when they set off and how long they take.
        var from = ring, to = ring, start = 0.0, time = 0.5, hops = false
        var fromRing = true, toRing = true
        // The hand's own line, and the letter's.
        var hand = Path(), letter = Path()
        let last = writing.letters.last
        switch writing.phase {
        case .waiting: break
        case .writing:
            let k = scene.arrived(writing.phaseAt, over: 0.2)
            if writing.before == .read { from = seats(form(last)); fromRing = false; letter = line(form(last)).trimmedPath(from: k, to: 1) }
            to = seats(writing.strokes); toRing = false; start = writing.phaseAt; time = 0.2
            hand = line(writing.strokes)
        case .read:
            guard let last else { break }
            let k = scene.arrived(last.at, over: 0.5)
            from = seats(last.strokes); to = seats(form(last)); fromRing = false; toRing = false; start = last.at; hops = true
            hand = line(last.strokes).trimmedPath(from: k, to: 1)
            letter = line(form(last)).trimmedPath(from: 0, to: k)
        case .unread:
            from = seats(writing.strokes); fromRing = false; start = writing.phaseAt; hops = true
            hand = line(writing.strokes).trimmedPath(from: 0, to: 1 - scene.arrived(writing.phaseAt, over: 0.5))
        case .finished:
            from = seats(form(last)); fromRing = false; start = writing.phaseAt; time = 0.6; hops = true
            letter = line(form(last)).trimmedPath(from: scene.arrived(writing.phaseAt, over: 0.4), to: 1)
        }
        canvas.stroke(letter, with: .color(.muted), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        canvas.stroke(hand, with: .color(.ink), style: WritingScene.hairline)

        var beads: [(centre: CGPoint, radius: Double, ringed: Double)] = []
        for index in 0..<8 {
            // Each bead sets off a beat after the one before, and hops if it has far to go.
            let k = scene.arrived(start + (hops ? Double(index) * 0.03 : 0), over: time)
            let far = min(1, hypot(to[index].x - from[index].x, to[index].y - from[index].y) / 70)
            let hop = hops ? sin(.pi * k) * far : 0
            var centre = WritingScene.mix(from[index], to[index], k)
            centre.y -= hop * 18
            let ringed = (fromRing ? 1 - k : 0) + (toRing ? k : 0)
            beads.append((centre, (9.5 + (12 * scale * 0.8 - 9.5) * ringed) * (1 + hop * 0.12), ringed))
        }
        for bead in beads where bead.ringed > 0.01 {
            // The ring's faint outline on the floor under each bead.
            let floor = CGRect(x: bead.centre.x - bead.radius * 0.8, y: bead.centre.y + bead.radius * 0.95, width: bead.radius * 1.6, height: bead.radius * 0.5)
            canvas.stroke(Path(ellipseIn: floor), with: .color(.ink.opacity(0.25 * bead.ringed)), lineWidth: 0.7)
        }
        for bead in beads.sorted(by: { $0.centre.y < $1.centre.y }) {
            WritingScene.bead(&canvas, at: bead.centre, radius: bead.radius)
        }
        scene.drawWord(top: scene.lower.minY + 4, in: &canvas)
        scene.drawSentence(in: &canvas)
    }
}
