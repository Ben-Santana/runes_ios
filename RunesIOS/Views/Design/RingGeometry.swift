import SwiftUI

/// Beads at play: each sits on a soft spring about its place and is pushed away from a finger
/// while one is down, so however they are touched the motion stays continuous.
final class BeadPlay {
    private(set) var offset: [SIMD2<Double>]
    private var speed: [SIMD2<Double>]
    /// Where a finger is, how fast it is moving, and whether it has only just landed.
    var finger: SIMD2<Double>?, fingerSpeed = 0.0, landed = false
    private var last: Date?

    init(beads: Int = 8) { offset = Array(repeating: .zero, count: beads); speed = offset }

    static func length(_ vector: SIMD2<Double>) -> Double { (vector * vector).sum().squareRoot() }

    /// Follows a touch as it lands and moves.
    func touch(_ value: DragGesture.Value) {
        finger = SIMD2(value.location.x, value.location.y)
        fingerSpeed = hypot(value.velocity.width, value.velocity.height)
        if value.translation == .zero { landed = true }
    }

    /// Moves the beads on to `now`, given where each rests, in a view `width` points wide.
    func step(to now: Date, rest: [SIMD2<Double>], width: Double) {
        defer { last = now; landed = false }
        guard let last else { return }
        let dt = min(1.0 / 30, max(0, now.timeIntervalSince(last)))
        for index in offset.indices {
            var pull = -90 * offset[index] - 14 * speed[index]
            if let finger {
                let away = rest[index] + offset[index] - finger, distance = Self.length(away)
                let push = away / (distance + 6) * exp(-pow(distance / (width * 0.24), 2))
                // A faster finger pushes harder, and one that has just landed gives a kick.
                pull += push * 2300 * (0.5 + min(1, fingerSpeed / 800))
                if landed { speed[index] += push * 230 }
            }
            speed[index] += pull * dt
            offset[index] += speed[index] * dt
        }
    }
}

enum RingGeometry {
    static let radius = 49.0
    static let ballRadius = 12.0
    static let elevation = 0.5

    struct Pod {
        let index: Int
        let x: Double
        let y: Double
        let z: Double
    }

    static func project(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        let s = 1 / 2.0.squareRoot()
        return CGPoint(x: (x - y) * s, y: (x + y) * s * sin(elevation) - z * cos(elevation))
    }

    static func pods(rotation: Double, radius: Double) -> [Pod] {
        (0..<8).map { i in
            let a = Double(i) * .pi / 4 + rotation
            return Pod(index: i, x: cos(a) * radius, y: sin(a) * radius, z: 8 + cos(a) * 3)
        }
        .sorted { ($0.x + $0.y) < ($1.x + $1.y) }
    }

    static func ball(_ x: Double, _ y: Double, _ z: Double, _ transform: CGAffineTransform) -> CGRect {
        let center = project(x, y, z + ballRadius).applying(transform)
        let r = ballRadius * transform.a
        return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    static func shadow(_ x: Double, _ y: Double, lift: Double, _ transform: CGAffineTransform) -> CGRect {
        let center = project(x, y, 6).applying(transform)
        let r = ballRadius * transform.a * max(0.45, 0.8 - lift / 60)
        return CGRect(x: center.x - r, y: center.y - r * sin(elevation), width: r * 2, height: r * 2 * sin(elevation))
    }

    static func drawBall(in canvas: inout GraphicsContext, body: CGRect, stroke: Color, lineWidth: Double, charge: Double) {
        canvas.fill(Path(ellipseIn: body), with: .color(.paper))
        canvas.stroke(Path(ellipseIn: body), with: .color(stroke), lineWidth: lineWidth)
        let dot = body.insetBy(dx: body.width * 0.34, dy: body.height * 0.34).offsetBy(dx: 0, dy: -body.height * 0.06)
        if charge > 0.01 { canvas.fill(Path(ellipseIn: dot), with: .color(.ink.opacity(charge))) }
    }
}
