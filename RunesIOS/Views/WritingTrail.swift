import SwiftUI

/// The ring unrolled into a string of beads that follows the finger. The line it leaves is
/// the writer's own hand, and each letter that is read is kept on the line below as it was
/// written. The beads wait at the end of the line for the next.
enum WritingTrail {
    /// The side of the box a kept letter is drawn in, and how far one stands from the next.
    private static let side = 62.0, advance = 38.0
    /// How far apart the beads follow each other, in points.
    private static let gap = 14.0

    static func draw(_ scene: WritingScene, in canvas: inout GraphicsContext) {
        let writing = scene.writing, pad = scene.pad, lower = scene.lower
        let baseline = lower.minY + 70
        func box(_ index: Int) -> CGRect {
            CGRect(x: lower.minX - side * 0.2 + Double(index) * advance, y: baseline - side * 0.75, width: side, height: side)
        }
        /// The beads at rest: a short row on the line, after the last letter kept.
        func cursor(after count: Int) -> [CGPoint] {
            (0..<8).map { CGPoint(x: lower.minX + Double(count) * advance + 6 + Double($0) * 9, y: baseline - 4.5) }
        }
        /// The beads strung back along some strokes from where they end.
        func trail(_ strokes: [[WritingPoint]]) -> [CGPoint] {
            (0..<8).map { index in
                var left = Double(index) * gap / pad.width
                for stroke in strokes.reversed() {
                    let own = LetterForms.length(stroke)
                    if left <= own { return WritingScene.place(LetterForms.point(along: stroke, at: own - left), in: pad) }
                    left -= own
                }
                return WritingScene.place(strokes.first?.first ?? WritingPoint(0.5, 0.5), in: pad)
            }
        }

        var line = Path()
        line.move(to: CGPoint(x: lower.minX, y: baseline)); line.addLine(to: CGPoint(x: lower.maxX, y: baseline))
        canvas.stroke(line, with: .color(.rule), lineWidth: Metric.hairline)

        let count = writing.letters.count
        var beads = cursor(after: count), strung = 0.0, nib = false
        var arriving: Int?
        switch writing.phase {
        case .waiting: break
        case .writing:
            strung = scene.arrived(writing.phaseAt, over: 0.18); nib = writing.penDown
            let along = trail(writing.strokes)
            beads = zip(beads, along).map { WritingScene.mix($0, $1, strung) }
            canvas.stroke(WritingScene.path(writing.strokes, in: pad), with: .color(.ink), style: WritingScene.hairline)
        case .read:
            guard let last = writing.letters.last else { break }
            // The ink runs out of the large letter and into the small one, and the beads go with it.
            let k = scene.arrived(last.at, over: 0.45)
            arriving = count - 1; strung = 1 - k
            beads = zip(trail(last.strokes), beads).map { WritingScene.mix($0, $1, k) }
            canvas.stroke(WritingScene.path(last.strokes, in: pad).trimmedPath(from: k, to: 1), with: .color(.ink), style: WritingScene.hairline)
            canvas.stroke(WritingScene.path(last.strokes, in: box(count - 1)).trimmedPath(from: 0, to: k), with: .color(.ink), style: WritingScene.hairline)
        case .unread:
            // The line is taken back the way it came, and the beads go back with its end.
            let back = scene.arrived(writing.phaseAt, over: 0.4), home = scene.arrived(writing.phaseAt + 0.4, over: 0.25)
            let left = LetterForms.cut(writing.strokes, from: 0, to: 1 - back)
            strung = 1 - home
            beads = zip(trail(left.isEmpty ? [[writing.strokes.first?.first ?? WritingPoint(0.5, 0.5)]] : left), beads).map { WritingScene.mix($0, $1, home) }
            canvas.stroke(WritingScene.path(left, in: pad), with: .color(.ink), style: WritingScene.hairline)
        case .finished:
            let k = scene.arrived(writing.phaseAt, over: 0.5)
            var under = Path()
            under.move(to: CGPoint(x: lower.minX, y: baseline)); under.addLine(to: CGPoint(x: lower.minX + Double(count) * advance, y: baseline))
            canvas.stroke(under.trimmedPath(from: 0, to: k), with: .color(.ink), lineWidth: Metric.hairline)
            scene.write(Text(writing.text).font(.display).tracking(-0.6).foregroundStyle(Color.ink), at: CGPoint(x: lower.minX, y: baseline + 14), shown: k, in: &canvas)
        }
        for (index, letter) in writing.letters.enumerated() where index != arriving {
            canvas.stroke(WritingScene.path(letter.strokes, in: box(index)), with: .color(.ink), style: WritingScene.hairline)
        }
        // The last bead of the string is drawn first, so the one at the pen is on top.
        for index in beads.indices.reversed() {
            let radius = 3.5 + (4.5 - Double(index) * 0.55) * strung
            WritingScene.bead(&canvas, at: beads[index], radius: radius, inked: index == 0 && nib ? 1 : 0)
        }
        scene.drawSentence(in: &canvas)
    }
}
