import SwiftUI

/// The looks being tried for the handwriting screen. One is to be kept and the rest removed,
/// with this picker.
enum WritingLook: String, CaseIterable, Identifiable {
    case eight, trail, staves, tally, strand, board

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var line: String {
        switch self {
        case .eight: "The eight beads leave the ring and stand as each letter."
        case .trail: "The beads follow your finger as a string, and your own hand is kept."
        case .staves: "Each letter is cut as its rune, with the letter under it."
        case .tally: "The ring counts how sure the reader is, a bead at a time."
        case .strand: "A bead for each letter on a string, which closes into the band."
        case .board: "A board of beads that ink in under your finger and set as type."
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

/// What a look is given to draw with: the writing, the clock, and the space.
struct WritingScene {
    let writing: Writing
    let now: TimeInterval
    /// Reduce Motion: every arrival is shown already there.
    let still: Bool
    let size: CGSize

    /// The square the pen writes in. A finger on the stage is read against the same square.
    static func pad(in size: CGSize) -> CGRect {
        let side = min(size.width - 2 * Metric.gutter, size.height - 176, 330)
        return CGRect(x: (size.width - side) / 2, y: 8, width: side, height: side)
    }
    var pad: CGRect { Self.pad(in: size) }
    /// The space under the pad, inside the page gutters.
    var lower: CGRect {
        CGRect(x: Metric.gutter, y: pad.maxY + 12, width: size.width - 2 * Metric.gutter, height: max(0, size.height - pad.maxY - 12))
    }

    /// How far along something that began at `start` is, `over` seconds later: 0 to 1, eased
    /// at both ends, and never past 1.
    func arrived(_ start: TimeInterval, over: Double) -> Double {
        guard !still else { return 1 }
        let x = min(1, max(0, (now - start) / over))
        return x * x * (3 - 2 * x)
    }

    static func place(_ point: WritingPoint, in box: CGRect) -> CGPoint {
        CGPoint(x: box.minX + point.x * box.width, y: box.minY + point.y * box.height)
    }

    static func path(_ strokes: [[WritingPoint]], in box: CGRect) -> Path {
        var path = Path()
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            path.move(to: place(first, in: box))
            // A touch that never moved still leaves a mark.
            if stroke.count == 1 { path.addLine(to: place(first, in: box)) }
            for point in stroke.dropFirst() { path.addLine(to: place(point, in: box)) }
        }
        return path
    }

    static func mix(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }

    /// A bead as the ring draws it: paper, a hairline, and ink that grows from its middle.
    static func bead(_ canvas: inout GraphicsContext, at centre: CGPoint, radius: Double, inked: Double = 0, stroke: Color = .ink.opacity(0.75)) {
        let body = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        canvas.fill(Path(ellipseIn: body), with: .color(.paper))
        if inked > 0.01 {
            let inset = radius * (1 - min(1, inked))
            canvas.fill(Path(ellipseIn: body.insetBy(dx: inset, dy: inset)), with: .color(.ink))
        }
        canvas.stroke(Path(ellipseIn: body), with: .color(stroke), lineWidth: 1)
    }

    /// Where the eight beads sit as the ring, seen from the home screen's angle. A bead's
    /// angle is 0 at the right and a quarter turn at the front, nearest the viewer.
    static func ringSeat(_ angle: Double, centre: CGPoint, scale: Double) -> CGPoint {
        CGPoint(x: centre.x + cos(angle) * RingGeometry.radius * scale,
                y: centre.y + sin(angle) * RingGeometry.radius * scale * sin(RingGeometry.elevation))
    }
    static func ring(centre: CGPoint, scale: Double) -> [CGPoint] {
        (0..<8).map { ringSeat(Double($0) * .pi / 4, centre: centre, scale: scale) }
    }

    /// Draws text uncovered from its leading edge as `shown` goes from 0 to 1, and gives
    /// back the space it takes.
    @discardableResult
    func write(_ text: Text, at point: CGPoint, anchor: UnitPoint = .topLeading, shown: Double = 1, in canvas: inout GraphicsContext) -> CGRect {
        let resolved = canvas.resolve(text), size = resolved.measure(in: self.size)
        let frame = CGRect(x: point.x - size.width * anchor.x, y: point.y - size.height * anchor.y, width: size.width, height: size.height)
        guard shown > 0.001 else { return frame }
        var layer = canvas
        if shown < 0.999 { layer.clip(to: Path(CGRect(x: frame.minX, y: frame.minY, width: frame.width * shown, height: frame.height))) }
        layer.draw(resolved, at: point, anchor: anchor)
        return frame
    }

    /// The sentence for the phase, at the foot of the stage.
    func drawSentence(in canvas: inout GraphicsContext) {
        write(Text(writing.sentence).font(.caption).foregroundStyle(Color.muted), at: CGPoint(x: lower.minX, y: size.height - 6), anchor: .bottomLeading, in: &canvas)
    }

    /// The word so far in display type standing on a rule, which is drawn across in ink
    /// when the word is finished.
    func drawWord(top: Double, in canvas: inout GraphicsContext) {
        let word = write(Text(writing.text.isEmpty ? " " : writing.text).font(.display).tracking(-0.6).foregroundStyle(Color.ink),
                         at: CGPoint(x: lower.minX, y: top), in: &canvas)
        var rule = Path()
        rule.move(to: CGPoint(x: lower.minX, y: word.maxY + 8)); rule.addLine(to: CGPoint(x: lower.maxX, y: word.maxY + 8))
        canvas.stroke(rule, with: .color(.rule), lineWidth: Metric.hairline)
        if writing.phase == .finished {
            canvas.stroke(rule.trimmedPath(from: 0, to: arrived(writing.phaseAt, over: 0.5)), with: .color(.ink), lineWidth: Metric.hairline)
        }
    }

    static let hairline = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
}

/// The chosen look, drawn from the clock.
struct WritingStage: View {
    let look: WritingLook
    let writing: Writing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || scenePhase != .active)) { context in
            Canvas { canvas, size in
                let scene = WritingScene(writing: writing, now: context.date.timeIntervalSinceReferenceDate, still: reduceMotion, size: size)
                switch look {
                case .eight: WritingEight.draw(scene, in: &canvas)
                case .trail: WritingTrail.draw(scene, in: &canvas)
                case .staves: WritingStaves.draw(scene, in: &canvas)
                case .tally: WritingTally.draw(scene, in: &canvas)
                case .strand: WritingStrand.draw(scene, in: &canvas)
                case .board: WritingBoard.draw(scene, in: &canvas)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Handwriting")
        .accessibilityValue([writing.text, writing.sentence].filter { !$0.isEmpty }.joined(separator: ". "))
    }
}

/// Settings, Band tests, Handwriting. The looks for the handwriting screen, to be judged in
/// place: write on the stage with a finger, or play the sample. Nothing here reaches the band.
struct HandwritingLabScreen: View {
    @StateObject private var feed = WritingFeed()
    @AppStorage("handwriting.look") private var look = WritingLook.eight

    init() {}

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let pad = WritingScene.pad(in: geometry.size)
                WritingStage(look: look, writing: feed.writing)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let point = WritingPoint((value.location.x - pad.minX) / pad.width, (value.location.y - pad.minY) / pad.height)
                            feed.pen(value.translation == .zero ? .began(point) : .moved(point))
                        }
                        .onEnded { _ in feed.pen(.lifted) })
            }
            VStack(alignment: .leading, spacing: 10) {
                ChipRow(selection: $look, options: WritingLook.allCases) { $0.title }
                    .padding(.horizontal, -Metric.inset)
                Text(look.line).font(.caption).foregroundStyle(Color.muted)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
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
        .sensoryFeedback(.selection, trigger: feed.writing.letters.count)
        .onDisappear { feed.clear() }
        #if DEBUG
        .task { await stage() }
        #endif
    }

    #if DEBUG
    /// For screenshots: "handwriting-<look>" plays the sample in that look, and
    /// "handwriting-<look>-<seconds>" shows it that many seconds in.
    private var snapshot: String?
    init(snapshot: String) { self.snapshot = snapshot }

    private func stage() async {
        guard let parts = snapshot?.split(separator: "-").dropFirst(), let chosen = parts.first.flatMap({ WritingLook(rawValue: String($0)) }) else { return }
        look = chosen
        if let seconds = parts.dropFirst().first.flatMap({ Double($0) }) {
            feed.showSample(at: seconds)
        } else {
            try? await Task.sleep(for: .seconds(1))
            feed.playSample()
        }
    }
    #endif
}
