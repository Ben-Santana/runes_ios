import SwiftUI

/// The written bead rolls down to a shelf and stands with the ones before it, turning a little
/// as if held up to the light. The word is read along the shelf in the writer's own hand, and
/// a fresh bead rolls in to be written on.
enum WritingShelf {
    /// How large a bead is on the shelf, how far apart they stand, and how long one takes to get there.
    private static let small = 23.0, pitch = 52.0, roll = 0.8

    static func draw(_ scene: WritingScene, in context: inout GraphicsContext) {
        let writing = scene.writing, pad = scene.pad, width = scene.size.width
        let level = pad.centre.y + pad.radius + 76
        func seat(_ index: Int) -> CGPoint { CGPoint(x: Metric.gutter + small + Double(index) * pitch, y: level) }

        var shelf = Path()
        shelf.move(to: CGPoint(x: Metric.gutter, y: level + small + 1)); shelf.addLine(to: CGPoint(x: width - Metric.gutter, y: level + small + 1))
        context.stroke(shelf, with: .color(.rule), lineWidth: Metric.hairline)

        // The bead to write on. A fresh one rolls in from the right once the last has left.
        if writing.phase == .read {
            let arrived = WritingEase.back((scene.since(writing.letters.last?.at ?? 0) - 0.2) / 0.85)
            let travel = (1 - arrived) * (width / 2 + pad.radius + 20)
            CarvedBall.draw(&context, strokes: [], at: CGPoint(x: pad.centre.x + travel, y: pad.centre.y), radius: pad.radius)
        } else {
            scene.drawPad(&context, at: pad.centre, radius: pad.radius)
        }

        for (index, letter) in writing.letters.enumerated() {
            let age = scene.since(letter.at), k = WritingEase.clamp(age / roll)
            // Eased out with a little overshoot, so the bead rocks back as it stops.
            let along = WritingEase.back(k), rest = seat(index)
            let centre = WritingScene.mix(pad.centre, rest, along)
            let radius = pad.radius + (small - pad.radius) * WritingEase.out(k)
            // It rolls one whole turn on the way: the letter goes forward and under, comes back
            // over the top and lands the right way up. Then it turns a little where it stands.
            var way = SIMD2(rest.x - pad.centre.x, pad.centre.y - rest.y)
            way /= max(1, (way * way).sum().squareRoot())
            let calm = scene.still ? 0 : WritingEase.clamp((age - roll) / 0.8), seed = Double(index)
            let facing = k < 1 ? CarvedBall.rolled(SIMD3(0, 0, 1), along: way, by: along * 2 * .pi)
                : CarvedBall.facing(yaw: calm * 0.34 * sin(scene.now * 0.62 + seed * 1.7), tilt: calm * 0.2 * sin(scene.now * 0.47 + seed * 2.3))
            let upright = k < 1 ? CarvedBall.rolled(SIMD3(0, 1, 0), along: way, by: along * 2 * .pi) : SIMD3(0, 1, 0)
            CarvedBall.draw(&context, strokes: letter.strokes, at: centre, radius: radius, facing: facing, upright: upright)
        }

        if writing.phase == .finished {
            let shown = WritingEase.out((scene.since(writing.phaseAt) - 0.3) / 0.4)
            var layer = context
            layer.opacity = shown
            layer.draw(Text(writing.text).font(.display).tracking(-0.6).foregroundStyle(Color.ink),
                       at: CGPoint(x: Metric.gutter, y: level + small + 18 + 10 * (1 - shown)), anchor: .topLeading)
        }
    }
}
