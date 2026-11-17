import SwiftUI

/// A bead with handwriting cut into its surface. The strokes lie on the sphere, so they bend
/// toward its edge, slide round as the bead turns and go out of sight behind it. A stroke
/// written with a finger on a bead that faces the eye is cut exactly where the finger went.
enum CarvedBall {
    /// How much of the bead's face the writing box covers, and the point of the box at its middle.
    private static let spread = 1.8, middle = WritingPoint(0.5, 0.55)

    /// Where on the face a point of the writing box lies, in radii right and down from the centre.
    static func face(_ point: WritingPoint) -> SIMD2<Double> {
        SIMD2((point.x - middle.x) * spread, (point.y - middle.y) * spread)
    }

    /// The point of the writing box under a touch, given in radii from the centre of the bead.
    static func point(under offset: SIMD2<Double>) -> WritingPoint {
        WritingPoint(middle.x + offset.x / spread, middle.y + offset.y / spread)
    }

    /// The way a bead faces after turning about the upright and about the level.
    static func facing(yaw: Double, tilt: Double) -> SIMD3<Double> {
        SIMD3(sin(yaw) * cos(tilt), sin(tilt), cos(yaw) * cos(tilt))
    }

    /// A direction after the bead has rolled `angle` across the page along `way` (x right, y up).
    /// The side facing the eye goes forward and under, and comes back over the top.
    static func rolled(_ v: SIMD3<Double>, along way: SIMD2<Double>, by angle: Double) -> SIMD3<Double> {
        let axis = SIMD3(-way.y, way.x, 0)
        let across = SIMD3(axis.y * v.z - axis.z * v.y, axis.z * v.x - axis.x * v.z, axis.x * v.y - axis.y * v.x)
        return v * cos(angle) + across * sin(angle) + axis * ((axis * v).sum() * (1 - cos(angle)))
    }

    /// Draws the bead and what is cut into it. `facing` is the direction its written side
    /// looks (x right, y up, z toward the eye), `roll` turns it in the page as it rolls, and
    /// `upright` is which way is up for the writing.
    static func draw(_ context: inout GraphicsContext, strokes: [[WritingPoint]], at centre: CGPoint, radius: Double,
                     facing n: SIMD3<Double> = SIMD3(0, 0, 1), roll: Double = 0, upright: SIMD3<Double> = SIMD3(0, 1, 0),
                     outline: Double = 1, alpha: Double = 1) {
        guard radius > 0.5 else { return }
        let body = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
        context.fill(body, with: .color(Color.paper.opacity(alpha)))
        context.stroke(body, with: .color(Color.ink.opacity(outline * alpha)), lineWidth: 1.25)
        guard !strokes.isEmpty, n.z > 0.05 else { return }

        let lean = upright - n * (upright * n).sum(), length = (lean * lean).sum().squareRoot()
        let up = length > 1e-6 ? lean / length : SIMD3(0, 1, 0)
        let right = SIMD3(up.y * n.z - up.z * n.y, up.z * n.x - up.x * n.z, up.x * n.y - up.y * n.x)
        let turn = SIMD2(cos(roll), sin(roll))
        /// A point of the writing box on the sphere, as seen: where it is drawn, or nothing when it is round the back.
        func seen(_ point: WritingPoint) -> CGPoint? {
            var flat = face(point)
            flat = SIMD2(flat.x * turn.x - flat.y * turn.y, flat.x * turn.y + flat.y * turn.x)
            let far = (flat * flat).sum().squareRoot()
            if far > 0.995 { flat *= 0.995 / far }
            let on = right * flat.x - up * flat.y + n * (1 - (flat * flat).sum()).squareRoot()
            return on.z > 0.02 ? CGPoint(x: centre.x + radius * on.x, y: centre.y - radius * on.y) : nil
        }
        var cut = Path()
        for stroke in strokes {
            guard var last = stroke.first else { continue }
            var drawing = false
            func add(_ point: WritingPoint) {
                guard let place = seen(point) else { drawing = false; return }
                if drawing { cut.addLine(to: place) } else { cut.move(to: place); cut.addLine(to: place); drawing = true }
            }
            add(last)
            for next in stroke.dropFirst() {
                // A straight stretch bends with the bead too, so it is laid down in short pieces.
                let pieces = max(1, Int(hypot(next.x - last.x, next.y - last.y) / 0.04))
                for piece in 1...pieces {
                    let t = Double(piece) / Double(pieces)
                    add(WritingPoint(last.x + (next.x - last.x) * t, last.y + (next.y - last.y) * t))
                }
                last = next
            }
        }
        context.stroke(cut, with: .color(Color.ink.opacity(0.9 * min(1, n.z * 2.5) * alpha)),
                       style: StrokeStyle(lineWidth: max(1.15, radius / 50), lineCap: .round, lineJoin: .round))
    }
}
