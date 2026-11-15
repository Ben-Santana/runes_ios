import SwiftUI

/// The pulses the band was actually sent and the gestures it heard, most recent last. The
/// edge effect draws from this, so it appears on any page when the band vibrates, and on
/// any page but home when a gesture arrives.
@MainActor
final class BandBuzzFeed: ObservableObject {
    static let shared = BandBuzzFeed()

    struct Event {
        let at: Date
        let pulse: BandPulse
        var strength: Double { pulse.strength }
        var seconds: Double { Double(pulse.duration) / 1000 }
    }

    /// How long a pulse's trace lingers after its motor stops.
    static let tail = 1.0
    @Published private(set) var events: [Event] = []
    @Published private(set) var live = false
    /// Whether gestures show on the edge. Off while the home page is in front: its ring shows them.
    var showsGestures = true
    private var quietAt = Date.distantPast
    private var watch: Task<Void, Never>?

    func sent(_ pulse: BandPulse, at date: Date = Date()) {
        let horizon = Date().addingTimeInterval(-3)
        events.removeAll { $0.at < horizon }
        events.append(Event(at: date, pulse: pulse))
        quietAt = max(quietAt, date.addingTimeInterval(Double(pulse.duration) / 1000 + Self.tail))
        live = true
        watch?.cancel()
        watch = Task {
            while !Task.isCancelled, quietAt > Date() {
                try? await Task.sleep(for: .seconds(max(0.05, quietAt.timeIntervalSinceNow)))
            }
            if !Task.isCancelled { live = false }
        }
    }

    /// A gesture arrived: the edge shows it as a short pulse, longer and stronger for a hold.
    func heard(_ gesture: BandGesture) {
        guard showsGestures else { return }
        switch gesture.kind {
        case .tap, .doubleTap: sent(BandPulse(duration: 60, amplitude: 170))
        case .swipe: sent(BandPulse(duration: 120, amplitude: 200))
        case .holdBegan: sent(BandPulse(duration: 260, amplitude: 230))
        case .holdEnded: break
        }
    }

    /// A sample for choosing a style; not a claim that the band vibrated.
    func sample() {
        let now = Date()
        for (offset, pulse) in BandBuzz.heartbeat.pulses.enumerated() {
            sent(pulse, at: now.addingTimeInterval(Double(offset) * 0.15))
        }
        sent(BandPulse(duration: 320, amplitude: 230), at: now.addingTimeInterval(0.75))
    }
}

/// Puts the edge effect in its own window above everything, so it also shows over Settings,
/// Mappings and the apps, which open as full-screen covers. The window takes no touches.
struct EdgeEffectHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Anchor() }
    func updateUIView(_ view: UIView, context: Context) {}

    private final class Anchor: UIView {
        private static var overlay: UIWindow?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Rebuilt if the app's scene is replaced, since a window belongs to one scene.
            guard let scene = window?.windowScene, Self.overlay?.windowScene !== scene else { return }
            let host = UIHostingController(rootView: EdgeEffect())
            host.view.backgroundColor = .clear
            let fresh = UIWindow(windowScene: scene)
            fresh.windowLevel = .alert + 1
            fresh.backgroundColor = .clear
            fresh.isUserInteractionEnabled = false
            fresh.rootViewController = host
            fresh.isHidden = false
            Self.overlay = fresh
        }
    }
}

/// How a band vibration shows on the screen edge.
enum EdgeStyle: String, CaseIterable {
    case threads, braid, ripples, line, off
    static let key = "edgeEffectStyle"

    var label: String {
        switch self {
        case .threads: "Threads"
        case .braid: "Braid"
        case .ripples: "Ripples"
        case .line: "Line"
        case .off: "Off"
        }
    }
}

/// The screen edge acting out a band vibration. Nothing is drawn at rest.
/// - Threads: three fine lines that drift across one another, swelling with the pulse.
/// - Braid: two lines twisted round each other, tightening as the pulse strengthens.
/// - Ripples: fine lines that leave the bezel and fade a short way in.
/// - Line: one still hairline that darkens. Reduce Motion always uses this.
struct EdgeEffect: View {
    @ObservedObject private var feed = BandBuzzFeed.shared
    @AppStorage(EdgeStyle.key) private var stored = EdgeStyle.threads.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Close to the display's corner, so the lines follow the glass.
    private static let corner = 54.0

    private var style: EdgeStyle {
        let chosen = EdgeStyle(rawValue: stored) ?? .threads
        return reduceMotion && chosen != .off ? .line : chosen
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 120, paused: !feed.live || style == .off)) { context in
            Canvas { canvas, size in
                guard feed.live, style != .off else { return }
                draw(in: &canvas, size: size, now: context.date)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 0…1: rises fast when a pulse starts, holds while it runs, then lets go slowly.
    private func energy(at now: Date) -> Double {
        feed.events.reduce(0) { most, event in
            let age = now.timeIntervalSince(event.at)
            guard age >= 0 else { return most }
            let attack = min(1, age / 0.03)
            let release = age <= event.seconds ? 1 : exp(-(age - event.seconds) / 0.22)
            return max(most, event.strength * attack * release)
        }
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, now: Date) {
        let t = now.timeIntervalSinceReferenceDate
        let level = energy(at: now)
        switch style {
        case .threads:
            guard level > 0.01 else { return }
            let swing = 3.5 * level
            // Each thread has its own two wavelengths and drift, so they keep crossing.
            let threads: [(Double, Double, Double, Double, Double, Double)] = [
                (47, 7.0, 113, 3.1, 0.0, 0.62), (61, -5.2, 89, 4.3, 2.1, 0.42), (38, 8.6, 139, -2.4, 4.4, 0.28),
            ]
            for (short, fast, long, slow, phase, ink) in threads {
                let path = Self.border(size, inset: 5 + swing) { along in
                    let breath = 0.65 + 0.35 * sin(along / 310 + t * 1.3 + phase)
                    return swing * breath * (sin(along / short + t * fast + phase) * 0.62 + sin(along / long + t * slow) * 0.38)
                }
                canvas.stroke(path, with: .color(.ink.opacity(ink * (0.35 + 0.65 * level))),
                              style: StrokeStyle(lineWidth: 0.75 + 0.5 * level, lineJoin: .round))
            }
        case .braid:
            guard level > 0.01 else { return }
            let swing = 3 * level
            for side in [1.0, -1.0] {
                let path = Self.border(size, inset: 5 + swing) { along in
                    side * swing * sin(along / (34 - 10 * level) + t * 5.5)
                }
                canvas.stroke(path, with: .color(.ink.opacity(0.3 + 0.45 * level)),
                              style: StrokeStyle(lineWidth: 0.9, lineJoin: .round))
            }
        case .ripples:
            for event in feed.events {
                // One line as the pulse starts and another every 150 ms it runs.
                for wave in 0...Int(event.seconds / 0.15) {
                    let age = (now.timeIntervalSince(event.at) - Double(wave) * 0.15) / 0.75
                    guard age >= 0, age < 1 else { continue }
                    canvas.stroke(Self.border(size, inset: 5 + age * (8 + 14 * event.strength)) { _ in 0 },
                                  with: .color(.ink.opacity((1 - age) * (1 - age) * 0.5 * event.strength)), lineWidth: 0.75)
                }
            }
        case .line:
            guard level > 0.01 else { return }
            canvas.stroke(Self.border(size, inset: 4) { _ in 0 },
                          with: .color(.ink.opacity(0.75 * level)), lineWidth: 1 + level)
        case .off:
            break
        }
    }

    /// A closed rounded rectangle `inset` points inside the screen edge, each point pushed
    /// further in or out by `wave(distance along the edge)`.
    private static func border(_ size: CGSize, inset: Double, wave: (Double) -> Double) -> Path {
        let radius = max(4, corner - inset)
        let left = inset, top = inset, right = size.width - inset, bottom = size.height - inset
        var path = Path(), along = 0.0, started = false
        func add(_ x: Double, _ y: Double, _ nx: Double, _ ny: Double) {
            let push = wave(along)
            let point = CGPoint(x: x + nx * push, y: y + ny * push)
            if started { path.addLine(to: point) } else { path.move(to: point); started = true }
        }
        func edge(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ nx: Double, _ ny: Double) {
            let length = hypot(x1 - x0, y1 - y0), steps = max(1, Int(length / 5))
            for step in 0..<steps {
                let k = Double(step) / Double(steps)
                add(x0 + (x1 - x0) * k, y0 + (y1 - y0) * k, nx, ny)
                along += length / Double(steps)
            }
        }
        func turn(_ cx: Double, _ cy: Double, from: Double) {
            let steps = max(2, Int(radius * .pi / 2 / 5))
            for step in 0..<steps {
                let a = from + .pi / 2 * Double(step) / Double(steps)
                add(cx + cos(a) * radius, cy + sin(a) * radius, -cos(a), -sin(a))
                along += radius * .pi / 2 / Double(steps)
            }
        }
        edge(left + radius, top, right - radius, top, 0, 1)
        turn(right - radius, top + radius, from: -.pi / 2)
        edge(right, top + radius, right, bottom - radius, -1, 0)
        turn(right - radius, bottom - radius, from: 0)
        edge(right - radius, bottom, left + radius, bottom, 0, -1)
        turn(left + radius, bottom - radius, from: .pi / 2)
        edge(left, bottom - radius, left, top + radius, 1, 0)
        turn(left + radius, top + radius, from: .pi)
        path.closeSubpath()
        return path
    }
}
