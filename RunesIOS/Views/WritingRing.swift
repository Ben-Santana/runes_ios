import SwiftUI

/// The written bead drops into the front of the ring, which turns a place to make room, so
/// the word wraps round the ring as the gestures of a spell do. A finished word is turned to
/// the front to be read, then its beads fall into the middle as one, which lands with a
/// bounce and three rings on the ground.
enum WritingRing {
    private static let place = Double.pi / 4, ring = 49.0, ball = 13.0
    /// Seconds a written bead takes to fall into the ring, the ring to turn a place, and a
    /// finished word to be held up before it gathers.
    private static let fall = 0.45, turnTime = 0.55, hold = 1.1

    static func draw(_ scene: WritingScene, in context: inout GraphicsContext) {
        let writing = scene.writing, pad = scene.pad, letters = writing.letters
        let scale = scene.size.width / 250, flat = sin(RingGeometry.elevation), r = ball * scale
        let origin = CGPoint(x: scene.size.width / 2, y: pad.centre.y + pad.radius + 22 + 58 * scale)
        func iso(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
            let point = RingGeometry.project(x, y, z)
            return CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
        }
        func ground(_ x: Double, _ y: Double, _ radius: Double) -> Path {
            var circle = Path()
            circle.addLines((0..<64).map { iso(x + cos(Double($0) / 64 * 2 * .pi) * radius, y + sin(Double($0) / 64 * 2 * .pi) * radius, 6) })
            circle.closeSubpath()
            return circle
        }
        func ellipse(_ centre: CGPoint, _ rx: Double, _ ry: Double) -> Path {
            Path(ellipseIn: CGRect(x: centre.x - rx, y: centre.y - ry, width: 2 * rx, height: 2 * ry))
        }
        /// Seconds since a letter's bead landed in the ring; negative while it is still falling.
        func landed(_ letter: Writing.Letter) -> Double { scene.since(letter.at) - fall }

        // The ring has turned one place for every bead that has landed.
        var turn = letters.reduce(0) { $0 + WritingEase.back(landed($1) / turnTime) }
        var present = 0.0, gather = 0.0, carved = 1.0
        var gathered: (grown: Double, squat: Double, lift: Double)?
        var ripples: [(x: Double, y: Double, radius: Double, alpha: Double)] = []
        let front = (x: cos(place) * ring, y: sin(place) * ring)
        for letter in letters {
            // A ring spreads on the ground where each bead lands.
            let age = landed(letter) / 0.8
            if age > 0, age < 1 { ripples.append((front.x, front.y, 15 + 26 * WritingEase.out(age), (1 - age) * 0.55)) }
        }
        if writing.phase == .finished {
            let t = scene.since(writing.phaseAt), T = t - hold
            // The middle of the word comes to the front, and every bead rises to be read.
            turn -= Double(letters.count + 1) / 2 * WritingEase.inOut(t / 0.6)
            present = WritingEase.out(t / 0.15) * (1 - WritingEase.clamp(T / 0.15))
            if T >= 0 {
                let down = 0.38, land = T - down
                carved = 1 - WritingEase.clamp(T / 0.2)
                gather = WritingEase.inOut(T / 0.35)
                let grown = WritingEase.out((gather - 0.5) / 0.5)
                gathered = land < 0 ? (grown, 1 - 0.06 * WritingEase.inOut(T / down), 0)
                    : (grown, 1 + 0.16 * exp(-6 * land) * sin(18 * land) - 0.06 * exp(-10 * land), 20 * exp(-3 * land) * abs(sin(8.5 * land)))
                for (echo, strength) in [0.85, 0.6, 0.4].enumerated() {
                    let age = (land - 0.13 * Double(echo)) / 0.9
                    if age > 0, age < 1 { ripples.append((0, 0, 34 + 54 * WritingEase.out(age), (1 - age) * strength)) }
                }
            }
        }

        for ripple in ripples {
            context.stroke(ground(ripple.x, ripple.y, ripple.radius), with: .color(Color.ink.opacity(ripple.alpha)), lineWidth: 1.25)
        }

        // Each bead of the ring carries the last letter that landed on it.
        var carried = [Writing.Letter?](repeating: nil, count: 8)
        for (index, letter) in letters.enumerated() where landed(letter) >= 0 { carried[index % 8] = letter }
        func angle(_ index: Int) -> Double { place + (turn - Double(index)) * place }
        let radius = ring * (1 - gather), apart = 1 - WritingEase.clamp((gather - 0.55) / 0.4)
        let beads = (0..<8).map { index -> (index: Int, x: Double, y: Double, z: Double) in
            var z = 8 + 10 * gather
            if let letter = carried[index] {
                let age = landed(letter)
                if !scene.still { z += 9 * exp(-5.5 * age) * sin(2 * .pi * 2.6 * age) }
                z += 4 * present
            }
            return (index, cos(angle(index)) * radius, sin(angle(index)) * radius, z)
        }
        .sorted { $0.x + $0.y < $1.x + $1.y }
        let upright = SIMD3(0, cos(RingGeometry.elevation), sin(RingGeometry.elevation))

        // Shadows first, so no bead is drawn under another bead's shadow.
        for bead in beads {
            let shade = r * max(0.45, 0.8 - max(0, bead.z - 8) / 60)
            context.stroke(ellipse(iso(bead.x, bead.y, 6), shade, shade * flat), with: .color(Color.ink.opacity(0.3 * apart)), lineWidth: 1)
        }
        for bead in beads {
            let letter = carried[bead.index]
            CarvedBall.draw(&context, strokes: letter?.strokes ?? [], at: iso(bead.x, bead.y, bead.z + ball), radius: r,
                            facing: facing(angle(bead.index)), upright: upright,
                            outline: letter == nil ? 0.4 : 0.4 + 0.6 * carved, alpha: apart)
            if carved < 1, letter != nil {
                // The writing goes as the beads fall together; the bead itself stays.
                CarvedBall.draw(&context, strokes: [], at: iso(bead.x, bead.y, bead.z + ball), radius: r, outline: 0.4 + 0.6 * carved, alpha: apart * (1 - carved))
            }
        }

        // Gathered: one ball of ink where the eight were, standing on the ground as they do.
        if let gathered, gathered.grown > 0 {
            let size = r * (0.6 + 1.3 * gathered.grown) * gathered.squat
            var centre = iso(0, 0, 6)
            centre.y -= gathered.lift + size * 0.92
            let shade = size * 0.8 * max(0.45, 1 - gathered.lift / 70)
            context.stroke(ellipse(iso(0, 0, 6), shade, shade * flat), with: .color(Color.ink.opacity(0.45 * gathered.grown)), lineWidth: 1)
            context.fill(ellipse(centre, size, size), with: .color(Color.ink.opacity(gathered.grown)))
        }

        // The bead to write on, and the one on its way down.
        let last = letters.last
        switch writing.phase {
        case .read:
            // A fresh bead swells up where the last one was, once that one has landed.
            let grown = WritingEase.back((scene.since(last?.at ?? 0) - fall) / 0.4)
            CarvedBall.draw(&context, strokes: [], at: pad.centre, radius: pad.radius * grown)
        case .waiting, .writing, .unread, .finished:
            scene.drawPad(&context, at: pad.centre, radius: pad.radius)
        }
        if let last, landed(last) < 0 {
            let k = WritingEase.clamp(scene.since(last.at) / fall), seat = iso(front.x, front.y, 8 + ball)
            // It falls faster as it goes, shrinking to the ring's size and turning to face out.
            let centre = CGPoint(x: pad.centre.x + (seat.x - pad.centre.x) * WritingEase.inOut(k), y: pad.centre.y + (seat.y - pad.centre.y) * WritingEase.in(k))
            let way = SIMD3(0, 0, 1) * (1 - k) + facing(place) * k, level = SIMD3(0, 1, 0) * (1 - k) + upright * k
            CarvedBall.draw(&context, strokes: last.strokes, at: centre, radius: pad.radius + (r - pad.radius) * WritingEase.inOut(k),
                            facing: way / (way * way).sum().squareRoot(), upright: level)
        }

        if writing.phase == .finished {
            let shown = WritingEase.out((scene.since(writing.phaseAt) - hold - 0.6) / 0.4)
            var layer = context
            layer.opacity = shown
            layer.draw(Text(writing.text).font(.display).tracking(-0.6).foregroundStyle(Color.ink),
                       at: CGPoint(x: origin.x, y: origin.y + (ring * flat + 26) * scale + 10 * (1 - shown)), anchor: .top)
        }
    }

    /// Where on a bead of the ring its letter sits, as a unit vector in view space (x right,
    /// y up, z toward the eye). It leans out from the ring, tipped up to meet the eye, so the
    /// front bead shows it square on and it slides toward the edge as the bead travels, never
    /// further round than can still be read. The same lean the gesture beads give their runes.
    private static func facing(_ angle: Double) -> SIMD3<Double> {
        let e = RingGeometry.elevation, s = 0.5.squareRoot(), near = s * (cos(angle) + sin(angle))
        let outward = SIMD3(cos(e) * s * (cos(angle) - sin(angle)), cos(e) * sin(e) * (1 - near), cos(e) * cos(e) * near + sin(e) * sin(e))
        let between = outward * 0.5 + SIMD3(0, 0, 0.5)
        let out = between / (between * between).sum().squareRoot()
        let furthest = 0.9
        guard out.z < cos(furthest) else { return out }
        let across = (out.x * out.x + out.y * out.y).squareRoot()
        guard across > 1e-6 else { return SIMD3(0, 0, 1) }
        return SIMD3(out.x / across * sin(furthest), out.y / across * sin(furthest), cos(furthest))
    }
}
