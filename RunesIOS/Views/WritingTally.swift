import SwiftUI

/// The ring seen from above, as a dial round the writing. Its beads fill one at a time as
/// the reader grows sure of the letter, and empty again if it never gets there. The letter
/// it settles on stands in the middle.
enum WritingTally {
    static func draw(_ scene: WritingScene, in canvas: inout GraphicsContext) {
        let writing = scene.writing, pad = scene.pad
        let centre = CGPoint(x: pad.midX, y: pad.midY), reach = pad.width / 2 - 13
        let last = writing.letters.last

        // How sure the reader is, 0 to 1, and what stands inside the dial.
        var level = 0.0
        switch writing.phase {
        case .waiting: break
        case .writing:
            level = writing.sure
            canvas.stroke(WritingScene.path(writing.strokes, in: pad), with: .color(.ink), style: WritingScene.hairline)
        case .read:
            guard let last else { break }
            level = last.sure
            canvas.stroke(WritingScene.path(last.strokes, in: pad).trimmedPath(from: scene.arrived(last.at, over: 0.3), to: 1), with: .color(.ink), style: WritingScene.hairline)
            scene.write(Text(String(last.character)).font(.geist(132, .medium, relativeTo: .largeTitle)).foregroundStyle(Color.ink),
                        at: centre, anchor: .center, shown: scene.arrived(last.at + 0.2, over: 0.25), in: &canvas)
        case .unread:
            let k = scene.arrived(writing.phaseAt, over: 0.4)
            level = writing.sure * (1 - k)
            canvas.stroke(WritingScene.path(writing.strokes, in: pad).trimmedPath(from: 0, to: 1 - k), with: .color(.ink), style: WritingScene.hairline)
        case .finished:
            let k = scene.arrived(writing.phaseAt, over: 0.5)
            level = (last?.sure ?? 1) * (1 - k) + k
            scene.write(Text(writing.text).font(.geist(44, .medium, relativeTo: .largeTitle)).tracking(-0.8).foregroundStyle(Color.ink),
                        at: centre, anchor: .center, shown: k, in: &canvas)
        }

        // The dial: a rule round the pad, and an arc in ink as far as the reader is sure.
        canvas.stroke(Path(ellipseIn: CGRect(x: centre.x - reach, y: centre.y - reach, width: reach * 2, height: reach * 2)), with: .color(.rule), lineWidth: Metric.hairline)
        var arc = Path()
        arc.addArc(center: centre, radius: reach, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * level), clockwise: false)
        canvas.stroke(arc, with: .color(.ink), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4 - .pi / 2
            let seat = CGPoint(x: centre.x + cos(angle) * reach, y: centre.y + sin(angle) * reach)
            // A bead is full once the arc has passed it.
            WritingScene.bead(&canvas, at: seat, radius: 12, inked: min(1, max(0, level * 8 - Double(index))))
        }

        scene.drawWord(top: scene.lower.minY + 4, in: &canvas)
        scene.drawSentence(in: &canvas)
        if level > 0.01 {
            scene.write(Text("\(Int((level * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(Color.muted),
                        at: CGPoint(x: scene.lower.maxX, y: scene.size.height - 6), anchor: .bottomTrailing, in: &canvas)
        }
    }
}
