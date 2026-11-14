import SwiftUI

/// The Mac app's "Hairline" band, simplified: eight hairline balls looping around the wrist,
/// on the same isometric camera as public/hairline/band.js (azimuth 45°, elevation 0.5 rad,
/// radius 49). A faint shadow on the wrist plane shows how high each ball is lifted.
///
/// States: faint at rest (not set up), a lift travelling round (connecting), ink with a
/// slow breath (connected), muted with the front pod sunk (needs attention).
///
/// Gestures, one reaction each:
/// - Tap: a damped shockwave from the pod under that finger, the ring kicks outward and
///   two hairline ripples spread over the wrist plane.
/// - Double tap: two stacked shockwaves and a flash of the contact pads.
/// - Hold: the ring levitates and charges (pads fill with ink, a wave orbits, an arc sweeps
///   the wrist plane); on release the pods drop with a bounce and a wide ripple.
/// - Swipe left/right: the ring spins one pod-step that way with a motion trail.
/// - Swipe up/down: a wave rolls front-to-back, or the pods sink back-to-front.
/// Reduce Motion: no movement; gestures flash the ring and a hold fills the pads.
struct HairlineRing: View {
    var phase: BandPhase
    /// The latest physical gesture; the ring reacts once per new `id`.
    var gesture: BandGesture? = nil
    /// Draw one pod raised and in ink, to point at it (onboarding).
    var emphasis: Int? = nil
    /// Play the entrance once: a dot opens into the front pod and the rest unfold from it.
    var entrance = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var effects: [Effect] = []
    @State private var hold: Hold?
    @State private var previous: BandPhase?
    @State private var phaseChangedAt = Date.distantPast
    /// When the pods start to unfold; the dot opens just before it.
    @State private var unfoldsAt: Date?

    private struct Effect: Equatable {
        enum Kind: Equatable { case tap, doubleTap, release, swipe(SwipeDirection) }
        let kind: Kind
        let origin: Int
        let start: Date
        var strength = 1.0
        var duration: Double {
            switch kind { case .tap: 1.2; case .doubleTap: 1.5; case .release: 1.2; case .swipe: 1.0 }
        }
    }
    private struct Hold: Equatable { let start: Date; var end: Date?; let origin: Int }

    private static let blend = 0.45
    private static let longestHold: TimeInterval = 12
    private static let dotOpens = 0.5
    private static let unfold = 0.8

    var body: some View {
        // The canvas is wider than the ring's own frame, so ripples run to the page edges.
        Color.clear
            .aspectRatio(1.25, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let size = proxy.size, bleed = Self.bleed(proxy)
                    TimelineView(.animation(minimumInterval: 1 / 120, paused: !isAnimating)) { context in
                        Canvas { canvas, _ in
                            canvas.translateBy(x: bleed.width, y: bleed.height)
                            draw(in: &canvas, size: size, reach: size.width / 2 + bleed.width, now: context.date)
                        }
                    }
                    .frame(width: size.width + 2 * bleed.width, height: size.height + 2 * bleed.height)
                    .position(x: size.width / 2, y: size.height / 2)
                    .allowsHitTesting(false)
                }
            }
        .onAppear(perform: enter)
        .onChange(of: gesture?.id) { _, _ in if let gesture { react(to: gesture) } }
        .onChange(of: phase) { old, _ in
            previous = old; phaseChangedAt = Date()
            Task { try? await Task.sleep(for: .seconds(Self.blend)); previous = nil }
        }
        .accessibilityHidden(true)
    }

    /// How far the canvas extends past the ring on each side: to the farther page edge.
    private static func bleed(_ proxy: GeometryProxy) -> CGSize {
        guard let page = proxy.bounds(of: .named(Page.space)) else { return .zero }
        let side = max(0, -page.minX, page.maxX - proxy.size.width)
        return CGSize(width: side, height: side * 0.6)
    }

    private func enter() {
        guard entrance, !reduceMotion, unfoldsAt == nil else { return }
        let start = Date().addingTimeInterval(Self.dotOpens)
        unfoldsAt = start
        add(Effect(kind: .tap, origin: Self.front, start: start, strength: 1.25))
    }

    private var isAnimating: Bool {
        if !effects.isEmpty || hold != nil { return true }
        if reduceMotion { return false }
        return phase == .connecting || phase == .connected || previous != nil || emphasis != nil
    }

    // MARK: Reacting

    /// The pod under each finger: index at the front, middle beside it, thumb opposite.
    private static func origin(for finger: UInt64) -> Int {
        switch finger { case 3: return 2; case 1: return 0; default: return front }
    }

    private func react(to gesture: BandGesture) {
        let now = Date(), origin = Self.origin(for: gesture.finger)
        switch gesture.kind {
        case .tap: add(Effect(kind: .tap, origin: origin, start: now))
        case .doubleTap: add(Effect(kind: .doubleTap, origin: origin, start: now))
        case .swipe(let direction): add(Effect(kind: .swipe(direction), origin: origin, start: now))
        case .holdBegan:
            let started = Hold(start: now, end: nil, origin: origin)
            hold = started
            Task {
                // A lost link can swallow the release; never hover forever.
                try? await Task.sleep(for: .seconds(Self.longestHold))
                if hold == started { end(hold: now.addingTimeInterval(Self.longestHold)) }
            }
        case .holdEnded:
            end(hold: now)
        }
    }

    private func end(hold at: Date) {
        guard var current = hold, current.end == nil else { return }
        current.end = at; hold = current
        add(Effect(kind: .release, origin: current.origin, start: at))
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            if hold == current { hold = nil }
        }
    }

    private func add(_ effect: Effect) {
        effects.append(effect)
        Task {
            try? await Task.sleep(for: .seconds(effect.start.timeIntervalSinceNow + effect.duration))
            effects.removeAll { $0 == effect }
        }
    }

    // MARK: Geometry

    private static let radius = RingGeometry.radius
    /// The pod nearest the viewer.
    private static let front = 1
    private static let elevation = RingGeometry.elevation

    private static func project(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        RingGeometry.project(x, y, z)
    }

    private static func polygon(_ points: [CGPoint], _ transform: CGAffineTransform, closed: Bool = true) -> Path {
        var path = Path(); path.addLines(points.map { $0.applying(transform) }); if closed { path.closeSubpath() }; return path
    }

    private static func circle(radius: Double, z: Double, from: Double = 0, to: Double = 2 * .pi, _ transform: CGAffineTransform) -> Path {
        let steps = max(8, Int(72 * (to - from) / (2 * .pi)))
        let points = (0...steps).map { i -> CGPoint in
            let a = from + (to - from) * Double(i) / Double(steps)
            return project(cos(a) * radius, sin(a) * radius, z)
        }
        return polygon(points, transform, closed: to - from >= 2 * .pi - 0.001)
    }

    private static func steps(_ a: Int, _ b: Int) -> Double { Double(min(abs(a - b), 8 - abs(a - b))) }
    private static func easeInOut(_ x: Double) -> Double { let k = min(1, max(0, x)); return k < 0.5 ? 4 * k * k * k : 1 - pow(-2 * k + 2, 3) / 2 }
    /// A damped bounce that starts upward: 0 at τ=0, peaks near 0.1 s, settles by ~0.8 s.
    private static func bounce(_ tau: Double, frequency: Double = 2.6, decay: Double = 5.5) -> Double {
        tau <= 0 ? 0 : exp(-decay * tau) * sin(2 * .pi * frequency * tau)
    }

    // MARK: Motion

    private func stateLift(_ phase: BandPhase, index: Int, angle: Double, t: Double) -> Double {
        var value = 0.0
        switch phase {
        case .connecting where !reduceMotion:
            let head = t.truncatingRemainder(dividingBy: 2.4) / 2.4 * 2 * .pi
            value = 9 * pow(max(0, cos(angle - head)), 6)
        case .connecting:
            value = index.isMultiple(of: 2) ? 3 : 0
        case .connected where !reduceMotion:
            value = 1.2 * (1 + sin(t * 2 * .pi / 5 + angle)) / 2
        case .attention:
            value = index == Self.front ? -4 : 0
        default: break
        }
        if index == emphasis { value = reduceMotion ? 10 : 8 + 2 * sin(t * 2 * .pi / 1.6) }
        return value
    }

    /// How charged the hold is, 0…1, including its fall after release.
    private func holdLevel(at now: Date) -> Double {
        guard let hold else { return 0 }
        let held = (hold.end ?? now).timeIntervalSince(hold.start)
        let charged = 1 - exp(-4 * max(0, held))
        guard let end = hold.end else { return charged }
        return charged * exp(-9 * max(0, now.timeIntervalSince(end)))
    }

    private struct Frame {
        var rotation = 0.0
        var trail: Double?
        var radiusKick = 0.0
        var lift = [Double](repeating: 0, count: 8)
        var glow = [Double](repeating: 0, count: 8)
        var flash = 0.0
        var ripples: [(radius: Double, alpha: Double, width: Double)] = []
        var arc: (sweep: Double, alpha: Double)?
        /// The entrance: how far the pods have unfolded, and how visible the late ones are.
        var open = 1.0
        var arrive = 1.0
    }

    /// `reach` is the distance from the ring's centre to the page edge, in ring units.
    private func frame(at now: Date, reach: Double) -> Frame {
        var f = Frame()
        let t = now.timeIntervalSinceReferenceDate
        var live = 1.0
        if let unfoldsAt {
            let tau = now.timeIntervalSince(unfoldsAt)
            let k = min(1, max(0, tau / Self.unfold))
            f.open = k >= 1 ? 1 : 1 - pow(2, -10 * k)
            f.arrive = min(1, max(0, tau / 0.2))
            live = min(1, max(0, tau / 0.45))
        }
        for i in 0..<8 {
            let angle = Double(i) * .pi / 4
            var value = stateLift(phase, index: i, angle: angle, t: t)
            if let previous, !reduceMotion {
                let k = min(1, now.timeIntervalSince(phaseChangedAt) / Self.blend)
                let eased = 1 - pow(1 - k, 3)
                value = stateLift(previous, index: i, angle: angle, t: t) * (1 - eased) + value * eased
            }
            f.lift[i] = value * live
        }

        // Hold: levitate, orbit and charge.
        let level = holdLevel(at: now)
        if level > 0.001 {
            for i in 0..<8 {
                let angle = Double(i) * .pi / 4
                f.glow[i] = max(f.glow[i], 0.85 * level)
                if !reduceMotion { f.lift[i] += 11 * level + 2.5 * level * sin(2 * angle - t * 5) }
            }
            if let hold, !reduceMotion {
                let held = (hold.end ?? now).timeIntervalSince(hold.start)
                let fade = hold.end.map { max(0, 1 - now.timeIntervalSince($0) / 0.3) } ?? 1
                // The charge arc starts under the holding finger and closes in 1.2 s.
                f.arc = (sweep: min(1, held / 1.2) * 2 * .pi, alpha: 0.6 * fade)
            }
        }

        for effect in effects {
            let tau = now.timeIntervalSince(effect.start)
            guard tau >= 0, tau < effect.duration else { continue }
            if reduceMotion { f.flash = max(f.flash, tau < 0.35 ? 1 : 0); continue }
            switch effect.kind {
            case .tap, .doubleTap:
                let double = effect.kind == .doubleTap
                for (k, delay, part) in double ? [(0, 0.0, 0.8), (1, 0.13, 1.2)] : [(0, 0.0, 1.0)] {
                    let local = tau - delay, strength = part * effect.strength
                    guard local > 0 else { continue }
                    for i in 0..<8 {
                        let d = Self.steps(i, effect.origin)
                        f.lift[i] += 9 * strength * Self.bounce(local - d * 0.045)
                    }
                    f.radiusKick += 5 * strength * exp(-8 * local) * (1 - exp(-40 * local))
                    for echo in 0..<2 {
                        let r = local - Double(echo) * 0.12
                        guard r > 0, r < 0.9 else { continue }
                        let p = 1 - pow(1 - r / 0.9, 2)
                        f.ripples.append((radius: 58 + (max(100, reach * 1.1) - 58) * p, alpha: (1 - r / 0.9) * (echo == 0 ? 0.55 : 0.3) * strength, width: k == 1 ? 1.3 : 1))
                    }
                }
                if double {
                    let pads = tau < 0.13 ? 0 : max(0, 1 - (tau - 0.13) / 0.45)
                    for i in 0..<8 { f.glow[i] = max(f.glow[i], 0.9 * pads) }
                }
            case .release:
                for i in 0..<8 { f.lift[i] += -4 * Self.bounce(tau - Self.steps(i, effect.origin) * 0.02, frequency: 2.2, decay: 4.5) }
                if tau < 1.0 {
                    let p = 1 - pow(1 - tau, 3)
                    f.ripples.append((radius: 56 + (max(116, reach * 1.15) - 56) * p, alpha: 0.5 * (1 - tau), width: 1.2))
                }
            case .swipe(let direction):
                let p = min(1, tau / 0.55)
                switch direction {
                case .left, .right:
                    // Increasing angle moves the front pod left on screen.
                    let sign = direction == .left ? 1.0 : -1.0
                    let eased = Self.easeInOut(p)
                    f.rotation += sign * .pi / 4 * eased
                    let lagged = Self.easeInOut(max(0, (tau - 0.07) / 0.55))
                    if p < 1 { f.trail = sign * .pi / 4 * lagged }
                    for i in 0..<8 { f.lift[i] += 5 * sin(.pi * eased) }
                case .up, .down:
                    for i in 0..<8 {
                        let angle = Double(i) * .pi / 4
                        let depth = sin(angle + .pi / 4)   // +1 front, −1 back
                        let up = direction == .up
                        let wave = up ? 1.5 - 3 * p : -1.5 + 3 * p
                        let shape = exp(-pow(depth - wave, 2) / 0.22) * (1 - 0.4 * p)
                        f.lift[i] += (up ? 11 : -7) * shape
                    }
                }
            }
        }
        return f
    }

    // MARK: Drawing

    private func draw(in canvas: inout GraphicsContext, size: CGSize, reach: Double, now: Date) {
        if entrance, !reduceMotion, unfoldsAt == nil { return }
        // Fit the resting ring, with headroom for lifts and ripples.
        let extent = Self.radius + 13
        let corners = [Self.project(-extent, extent, 0), Self.project(extent, -extent, 0),
                       Self.project(-extent, -extent, 0), Self.project(extent, extent, 0),
                       Self.project(-extent, -extent, 34)]
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        let scale = min(size.width / (maxX - minX), size.height / (maxY - minY)) * 0.9
        let transform = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -(minX + maxX) / 2, y: -(minY + maxY) / 2)
        let line = max(0.75, min(1.25, scale * 0.45))

        if let unfoldsAt, now < unfoldsAt {
            drawDot(in: &canvas, progress: 1 + now.timeIntervalSince(unfoldsAt) / Self.dotOpens, transform, line)
            return
        }
        let f = frame(at: now, reach: reach / scale)

        // The wrist plane, behind the pods.
        for ripple in f.ripples {
            canvas.stroke(Self.circle(radius: ripple.radius, z: 6, transform), with: .color(.ink.opacity(ripple.alpha)), lineWidth: line * ripple.width)
        }
        if let arc = f.arc, let hold {
            let start = Double(hold.origin) * .pi / 4
            canvas.stroke(Self.circle(radius: 74, z: 6, from: start, to: start + arc.sweep, transform),
                          with: .color(.ink.opacity(arc.alpha)), style: StrokeStyle(lineWidth: line * 1.2, lineCap: .round))
            canvas.stroke(Self.circle(radius: 74, z: 6, transform), with: .color(.ink.opacity(arc.alpha * 0.18)), lineWidth: line)
        }

        // Motion trail for a spin: faint pods where the ring just was.
        if let trail = f.trail {
            for pod in pods(rotation: trail, radius: Self.radius, open: f.open) {
                let ghost = ball(pod.x, pod.y, pod.z + f.lift[pod.index] * 0.6, transform)
                canvas.stroke(Path(ellipseIn: ghost), with: .color(.ink.opacity(0.18)), lineWidth: line * 0.8)
            }
        }

        let radius = Self.radius + f.radiusKick
        let placed = pods(rotation: f.rotation, radius: radius, open: f.open)
        // Shadows first, so no ball is drawn under another ball's shadow.
        for pod in placed {
            let lift = max(0, f.lift[pod.index])
            let shadow = Self.shadow(pod.x, pod.y, lift: lift, transform)
            canvas.stroke(Path(ellipseIn: shadow), with: .color(strokeColor.opacity(0.35 * f.arrive * max(0.25, 1 - lift / 20))), lineWidth: line * 0.7)
        }
        for pod in placed {
            let shown = pod.index == Self.front ? 1 : f.arrive
            guard shown > 0 else { continue }
            var canvas = canvas
            canvas.opacity = shown
            let lift = f.lift[pod.index], glow = f.glow[pod.index]
            let emphasised = pod.index == emphasis || (phase == .attention && pod.index == Self.front)
            let energised = f.flash > 0 || emphasised || lift > 4 || glow > 0.2
            let stroke: Color = energised ? .ink : strokeColor
            let body = ball(pod.x, pod.y, pod.z + lift, transform)
            RingGeometry.drawBall(in: &canvas, body: body, stroke: stroke, lineWidth: line,
                                  charge: max(glow, f.flash * 0.7))
        }
    }

    /// A small ink dot swells into the front pod, its fill thinning to a hairline.
    private func drawDot(in canvas: inout GraphicsContext, progress: Double, _ transform: CGAffineTransform, _ line: Double) {
        guard let pod = pods(rotation: 0, radius: Self.radius, open: 0).first(where: { $0.index == Self.front }) else { return }
        let k = Self.easeInOut(progress), full = ball(pod.x, pod.y, pod.z, transform)
        let inset = full.width / 2 * (1 - (0.16 + 0.84 * k))
        let body = Path(ellipseIn: full.insetBy(dx: inset, dy: inset))
        let shown = min(1, max(0, progress / 0.25))
        canvas.fill(body, with: .color(.ink.opacity(shown * (1 - min(1, max(0, (k - 0.3) / 0.5))))))
        canvas.stroke(body, with: .color(strokeColor.opacity(shown * min(1, k * 5))), lineWidth: line)
    }

    private func ball(_ x: Double, _ y: Double, _ z: Double, _ transform: CGAffineTransform) -> CGRect {
        RingGeometry.ball(x, y, z, transform)
    }

    private static func shadow(_ x: Double, _ y: Double, lift: Double, _ transform: CGAffineTransform) -> CGRect {
        RingGeometry.shadow(x, y, lift: lift, transform)
    }

    private func pods(rotation: Double, radius: Double, open: Double = 1) -> [RingGeometry.Pod] {
        RingGeometry.pods(rotation: rotation, radius: radius, open: open, from: Self.front)
    }

    private var strokeColor: Color {
        switch phase {
        case .notSetUp: return .faint
        case .connected: return .ink.opacity(0.7)
        default: return .muted.opacity(0.75)
        }
    }
}
