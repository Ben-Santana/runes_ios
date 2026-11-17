import SwiftUI

/// The two places a written bead can go, to be judged side by side.
enum WritingTake: String, CaseIterable, Identifiable {
    case shelf, ring
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var line: String {
        switch self {
        case .shelf: "Each letter is cut into a bead, which rolls down to stand with the others."
        case .ring: "Each letter is cut into a bead, which drops into the ring. The ring turns to make room, and a finished word gathers into one."
        }
    }
}

/// Handwriting as a screen hears it. Pen events from any source go through the phone's own
/// reader; a reader that does its own reading, as the band's model would, calls `receive`.
@MainActor
final class WritingFeed: ObservableObject {
    @Published private(set) var writing = Writing()
    /// Called with each finished word. This is all another screen needs to take handwriting.
    var onWord: ((String) -> Void)?

    private var reader = StrokeReader()
    private var settling: Task<Void, Never>?
    private var playing: Task<Void, Never>?
    private static var clock: TimeInterval { Date().timeIntervalSinceReferenceDate }

    /// The pen came down, moved or lifted.
    func pen(_ event: WritingEvent) {
        let now = Self.clock
        for heard in reader.pen(event, at: now) { receive(heard, at: now) }
        settleLater()
    }

    func receive(_ event: WritingEvent, at now: TimeInterval) {
        writing.apply(event, at: now)
        if event == .finished { onWord?(writing.text) }
    }

    /// Reads the letter, or finishes the word, once the pen has rested long enough.
    private func settleLater() {
        settling?.cancel()
        guard let due = reader.nextTick else { return }
        settling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, due - Self.clock)))
            guard !Task.isCancelled, let self else { return }
            let now = Self.clock
            for heard in self.reader.tick(at: now) { self.receive(heard, at: now) }
            self.settleLater()
        }
    }

    func clear() {
        playing?.cancel(); settling?.cancel()
        reader = StrokeReader(); writing = Writing()
    }

    /// Writes the sample at the pace a hand would.
    func playSample() {
        clear()
        let start = Self.clock
        playing = Task { [weak self] in
            for step in WritingScript.sample {
                try? await Task.sleep(for: .seconds(max(0, start + step.at - Self.clock)))
                guard !Task.isCancelled, let self else { return }
                self.pen(step.event)
            }
        }
    }

    /// Shows the sample as it stands `seconds` in, as if it had been playing that long.
    func showSample(at seconds: TimeInterval) {
        clear()
        let start = Self.clock - seconds
        var time = 0.0
        func pass(_ events: [WritingEvent]) { for event in events { receive(event, at: start + time) } }
        for step in WritingScript.sample where step.at <= seconds {
            while time < step.at { time = min(step.at, time + 0.02); pass(reader.tick(at: start + time)) }
            pass(reader.pen(step.event, at: start + time))
        }
        while time < seconds { time = min(seconds, time + 0.02); pass(reader.tick(at: start + time)) }
    }
}

/// What a take is given to draw with: the writing, the clock, and the space.
struct WritingScene {
    let writing: Writing
    let now: TimeInterval
    /// Reduce Motion: every arrival is shown already there, and nothing drifts.
    let still: Bool
    let size: CGSize

    /// The large bead that is written on: its centre and radius. A finger on the stage is
    /// read against the same bead.
    static func pad(in size: CGSize) -> (centre: CGPoint, radius: Double) {
        let radius = min(size.width * 0.37, size.height * 0.27, 150)
        return (CGPoint(x: size.width / 2, y: radius + 14), radius)
    }
    var pad: (centre: CGPoint, radius: Double) { Self.pad(in: size) }

    /// Seconds since something happened, or long ago when motion is reduced.
    func since(_ moment: TimeInterval) -> Double { still ? 60 : now - moment }

    static func mix(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }

    /// The bead being written on, facing the eye, with what has been written so far. A
    /// letter that was not read shakes the bead, and its strokes are taken back.
    func drawPad(_ context: inout GraphicsContext, at centre: CGPoint, radius: Double) {
        var centre = centre, strokes = writing.strokes
        if writing.phase == .unread {
            let t = since(writing.phaseAt)
            if !still { centre.x += 9 * sin(t * 42) * exp(-5 * t) }
            strokes = LetterForms.cut(strokes, from: 0, to: 1 - WritingEase.inOut((t - 0.25) / 0.4))
        } else if writing.phase != .writing {
            strokes = []
        }
        CarvedBall.draw(&context, strokes: strokes, at: centre, radius: radius)
    }
}

/// Curves over 0...1; anything outside is held at the ends.
enum WritingEase {
    static func clamp(_ t: Double) -> Double { min(1, max(0, t)) }
    static func out(_ t: Double) -> Double { 1 - pow(1 - clamp(t), 3) }
    static func `in`(_ t: Double) -> Double { pow(clamp(t), 3) }
    static func inOut(_ t: Double) -> Double { let t = clamp(t); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    /// Ease out with a small overshoot.
    static func back(_ t: Double) -> Double { let t = clamp(t) - 1; return 1 + 2.4 * t * t * t + 1.4 * t * t }
}

/// The chosen take, drawn from the clock.
struct WritingStage: View {
    let take: WritingTake
    let writing: Writing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || scenePhase != .active)) { timeline in
            Canvas { context, size in
                let scene = WritingScene(writing: writing, now: timeline.date.timeIntervalSinceReferenceDate, still: reduceMotion, size: size)
                switch take {
                case .shelf: WritingShelf.draw(scene, in: &context)
                case .ring: WritingRing.draw(scene, in: &context)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Handwriting")
        .accessibilityValue([writing.text, writing.sentence].filter { !$0.isEmpty }.joined(separator: ". "))
    }
}

/// Settings, Developer, Handwriting. One idea in two takes: the letter is cut into a bead.
/// Write on the large bead with a finger, or play the sample. Nothing here reaches the band.
struct HandwritingLabScreen: View {
    @StateObject private var feed = WritingFeed()
    @AppStorage("handwriting.take") private var take = WritingTake.shelf

    init() {}

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let pad = WritingScene.pad(in: geometry.size)
                WritingStage(take: take, writing: feed.writing)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let offset = SIMD2((value.location.x - pad.centre.x) / pad.radius, (value.location.y - pad.centre.y) / pad.radius)
                            let point = CarvedBall.point(under: offset)
                            feed.pen(value.translation == .zero ? .began(point) : .moved(point))
                        }
                        .onEnded { _ in feed.pen(.lifted) })
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(feed.writing.sentence).font(.label).foregroundStyle(Color.muted)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .id(feed.writing.sentence).transition(.opacity)
                    .animation(.standard, value: feed.writing.sentence)
                HairlineSegments(selection: $take, options: WritingTake.allCases, title: \.title)
                Text(take.line).font(.caption).foregroundStyle(Color.muted)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                HStack(spacing: 12) {
                    Button("Play sample") { feed.playSample() }.buttonStyle(.secondary)
                    Button("Clear") { feed.clear() }.buttonStyle(.quiet).padding(.horizontal, 12)
                }
            }
            .padding(.horizontal, Metric.gutter).padding(.bottom, 12)
        }
        .page()
        .navigationTitle("Handwriting")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.impact(weight: .light), trigger: feed.writing.letters.count) { _, count in count > 0 }
        .sensoryFeedback(.success, trigger: feed.writing.phase) { _, phase in phase == .finished }
        .onChange(of: take) { _, _ in feed.clear() }
        .onDisappear { feed.clear() }
        #if DEBUG
        .task { await stage() }
        #endif
    }

    #if DEBUG
    /// For screenshots: "handwriting-<take>" plays the sample in that take, and
    /// "handwriting-<take>-<seconds>" shows it that many seconds in.
    private var snapshot: String?
    init(snapshot: String) { self.snapshot = snapshot }

    private func stage() async {
        guard let parts = snapshot?.split(separator: "-").dropFirst(), let chosen = parts.first.flatMap({ WritingTake(rawValue: String($0)) }) else { return }
        take = chosen
        try? await Task.sleep(for: .seconds(0.1))
        if let seconds = parts.dropFirst().first.flatMap({ Double($0) }) {
            feed.showSample(at: seconds)
        } else {
            try? await Task.sleep(for: .seconds(1))
            feed.playSample()
        }
    }
    #endif
}
