import SwiftUI

/// A bead for each letter. The eight beads hang on a string; the one being written comes up
/// large to be written in, and goes back to its place carrying its letter. When the word is
/// finished the string closes into the ring, with the word round the front of it.
enum WritingStrand {
    static func draw(_ scene: WritingScene, in canvas: inout GraphicsContext) {
        let writing = scene.writing, pad = scene.pad, lower = scene.lower
        let middle = CGPoint(x: pad.midX, y: pad.midY), large = pad.width / 2 - 2
        let pitch = lower.width / 8, small = min(18, pitch * 0.4), level = lower.minY + 34
        func seat(_ index: Int) -> CGPoint { CGPoint(x: lower.minX + pitch * (Double(index) + 0.5), y: level) }
        let count = writing.letters.count, last = writing.letters.last
        let finished = writing.phase == .finished

        // Every bead: where it is, how large, and how much of its letter shows.
        var centres = (0..<8).map(seat), radii = Array(repeating: small, count: 8), lettered = Array(repeating: 1.0, count: 8)
        var closing = 0.0
        /// Brings a bead up from its seat to be written in, as `k` goes from 0 to 1.
        func raise(_ index: Int, _ k: Double) {
            guard index < 8 else { return }
            centres[index] = WritingScene.mix(seat(index), middle, k); radii[index] = small + (large - small) * k
        }
        switch writing.phase {
        case .waiting, .unread, .writing:
            raise(count, writing.phase == .waiting ? scene.arrived(writing.phaseAt, over: 0.4) : 1)
        case .read:
            guard let last else { break }
            // The bead just written goes down to its seat, and the next comes up.
            let down = scene.arrived(last.at, over: 0.45)
            raise(count - 1, 1 - down); lettered[count - 1] = down >= 1 ? scene.arrived(last.at + 0.45, over: 0.15) : 0
            raise(count, scene.arrived(last.at + 0.35, over: 0.4))
        case .finished:
            raise(count, 1 - scene.arrived(writing.phaseAt, over: 0.35))
            // The word sits across the front of the ring, its middle nearest the viewer.
            let scale = pad.width / 150
            for index in 0..<8 {
                let k = scene.arrived(writing.phaseAt + 0.3 + Double(index) * 0.04, over: 0.7)
                let angle = .pi / 2 + (Double(count - 1) / 2 - Double(index)) * .pi / 4
                var place = WritingScene.mix(centres[index], WritingScene.ringSeat(angle, centre: middle, scale: scale), k)
                place.y -= sin(.pi * k) * 16
                centres[index] = place; radii[index] += (12 * scale * 0.78 - small) * k
            }
            closing = scene.arrived(writing.phaseAt + 0.3, over: 0.7)
        }

        var string = Path()
        string.move(to: CGPoint(x: lower.minX, y: level)); string.addLine(to: CGPoint(x: lower.maxX, y: level))
        canvas.stroke(string.trimmedPath(from: closing, to: 1), with: .color(.rule), lineWidth: Metric.hairline)

        // Beads further back are drawn first, so the front of the ring lies over the back.
        for index in (0..<8).sorted(by: { centres[$0].y < centres[$1].y }) {
            let centre = centres[index], radius = radii[index]
            let held = index < count, waiting = index == count && !finished
            WritingScene.bead(&canvas, at: centre, radius: radius, stroke: held || waiting ? .ink.opacity(0.75) : .faint)
            let box = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            var inside = canvas
            inside.clip(to: Path(ellipseIn: box.insetBy(dx: 1, dy: 1)))
            if waiting, writing.phase == .writing || writing.phase == .unread {
                let kept = writing.phase == .unread ? 1 - scene.arrived(writing.phaseAt, over: 0.4) : 1
                inside.stroke(WritingScene.path(writing.strokes, in: box).trimmedPath(from: 0, to: kept), with: .color(.ink), style: WritingScene.hairline)
            }
            guard held else { continue }
            if index == count - 1, writing.phase == .read, let last, lettered[index] < 1, radius > small + 0.5 {
                // The hand's line runs out as the bead goes down to its seat.
                let down = scene.arrived(last.at, over: 0.45)
                inside.stroke(WritingScene.path(last.strokes, in: box).trimmedPath(from: down, to: 1), with: .color(.ink), style: WritingScene.hairline)
            } else {
                // The letter is set at the string's size and grows with its bead on the ring.
                var label = canvas
                label.translateBy(x: centre.x, y: centre.y); label.scaleBy(x: radius / small, y: radius / small)
                let text = label.resolve(Text(String(writing.letters[index].character)).font(.label).foregroundStyle(Color.ink)), size = text.measure(in: scene.size)
                label.clip(to: Path(CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width * lettered[index], height: size.height)))
                label.draw(text, at: .zero, anchor: .center)
            }
        }
        if finished {
            scene.write(Text(writing.text).font(.display).tracking(-0.6).foregroundStyle(Color.ink), at: CGPoint(x: lower.minX, y: lower.minY + 4),
                        shown: scene.arrived(writing.phaseAt + 0.6, over: 0.4), in: &canvas)
        }
        scene.drawSentence(in: &canvas)
    }
}
