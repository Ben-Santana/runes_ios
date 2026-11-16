import SwiftUI

/// Plays pulses on the band's motor and keeps a short tape of what was sent and answered.
@MainActor
final class VibrationLab: ObservableObject {
    static let shared = VibrationLab()

    struct Answer {
        let at: Date
        let result: WristFeedbackResult
        let latency: TimeInterval
    }
    /// The ring's loop: which bead each pulse came from, and how long one lap takes.
    struct Loop: Equatable {
        let beads: [Int]
        let lap: Double
    }
    struct Playback: Equatable {
        let name: String
        let pulses: [BandPulse]
        let started: Date
        var loop: Loop?
        /// Planned length; the band can stretch it, since each pulse waits for the last answer.
        var milliseconds: Double { Double(pulses.milliseconds) }
    }
    struct Sent {
        let at: Date
        let pulse: BandPulse
    }

    static let tapeSeconds = 6.0
    @Published private(set) var playback: Playback?
    @Published private(set) var sent: [Sent] = []
    @Published private(set) var answers: [Answer] = []
    @Published private(set) var tapeRunning = false
    @Published private(set) var last: [BandPulse] = []

    /// Plays on the band when it is connected; the ring and tape always show it.
    func play(_ pulses: [BandPulse], name: String, onBand: Bool, loop: Loop? = nil) {
        guard !pulses.isEmpty else { return }
        if onBand { SessionController.shared.vibrate(pulses) }
        let now = Playback(name: name, pulses: pulses, started: Date(), loop: loop)
        playback = now; last = pulses
        let horizon = Date().addingTimeInterval(-Self.tapeSeconds)
        sent.removeAll { $0.at < horizon || $0.at > now.started }
        var at = now.started
        for pulse in pulses {
            sent.append(Sent(at: at, pulse: pulse))
            at.addTimeInterval(Double(pulse.span) / 1000)
        }
        tapeRunning = true
        Task {
            try? await Task.sleep(for: .milliseconds(Int(now.milliseconds) + 400))
            if playback == now { playback = nil; restTape() }
        }
    }
    func stop() {
        SessionController.shared.vibrate([])
        let now = Date()
        sent.removeAll { $0.at > now }
        playback = nil
        restTape()
    }
    /// Lets the last bars scroll off, then stops redrawing the tape.
    private func restTape() {
        Task {
            try? await Task.sleep(for: .seconds(Self.tapeSeconds))
            if playback == nil { tapeRunning = false }
        }
    }
    func answered(_ result: WristFeedbackResult, latency: TimeInterval) {
        answers.append(Answer(at: Date(), result: result, latency: latency))
        if answers.count > 64 { answers.removeFirst() }
    }
}

/// A named vibration to try, with what to notice when it is an experiment.
struct LabPattern: Identifiable {
    let id: String
    let name: String
    var note: String?
    let pulses: [BandPulse]

    var milliseconds: UInt64 { pulses.milliseconds }

    private static func p(_ duration: UInt64, _ amplitude: UInt64, _ gap: UInt64 = 0) -> BandPulse {
        BandPulse(duration: duration, amplitude: amplitude, gap: gap)
    }

    /// The band's built-in buzzes, then a few made for the lab.
    static let library: [LabPattern] =
        BandBuzz.allCases.map { LabPattern(id: $0.rawValue, name: $0.label, pulses: $0.pulses) } + [
        LabPattern(id: "purr", name: "Purr", pulses: Array(repeating: p(30, 140, 30), count: 12)),
        LabPattern(id: "wave", name: "Wave", pulses: [80, 130, 180, 230, 250, 230, 180, 130, 80].map { p(60, $0, 40) }),
        LabPattern(id: "knock", name: "Knock knock", pulses: [p(60, 245, 140), p(60, 245, 520), p(60, 245, 140), p(60, 245)]),
        LabPattern(id: "sos", name: "SOS", pulses: [p(80, 230, 120), p(80, 230, 120), p(80, 230, 320),
                                                   p(260, 230, 120), p(260, 230, 120), p(260, 230, 320),
                                                   p(80, 230, 120), p(80, 230, 120), p(80, 230)]),
        LabPattern(id: "drumroll", name: "Drumroll", pulses: Array(repeating: p(25, 200, 25), count: 14) + [p(320, 255)]),
        LabPattern(id: "countdown", name: "Countdown", pulses: [p(100, 180, 700), p(100, 200, 700), p(100, 220, 700), p(500, 255)]),
        LabPattern(id: "rain", name: "Rain", pulses: [(30, 120, 180), (25, 200, 60), (35, 150, 260), (25, 230, 90), (30, 110, 140),
                                                     (25, 210, 40), (40, 160, 300), (25, 240, 120), (30, 130, 70), (35, 190, 0)].map { p($0.0, $0.1, $0.2) }),
    ]

    /// Ladders that find the motor's limits. The big number shows each rung as it plays.
    static let experiments: [LabPattern] = [
        LabPattern(id: "strength-ladder", name: "How soft", note: "Ten equal pulses from 25 up to 250. Note the number when you first feel one.",
                   pulses: stride(from: 25, through: 250, by: 25).map { p(120, UInt64($0), 380) }),
        LabPattern(id: "length-ladder", name: "How short", note: "Full strength, from 5 ms doubling to 320 ms. Short ones feel like a tick, long ones like a hum.",
                   pulses: [5, 10, 20, 40, 80, 160, 320].map { p(UInt64($0), 240, 500) }),
        LabPattern(id: "speed-ladder", name: "How fast", note: "Ten taps with the pause shrinking from 200 ms to nothing. Where they blur together is the motor’s limit; the tape shows if the band keeps up.",
                   pulses: [200, 160, 120, 90, 70, 50, 35, 20, 10, 0].map { p(30, 230, UInt64($0)) }),
        LabPattern(id: "contrast", name: "How different", note: "Pairs that differ by less each time: 250 then 50, 150, 200, 230. The last pair you can tell apart is your useful resolution.",
                   pulses: [50, 150, 200, 230].flatMap { [p(120, 250, 200), p(120, UInt64($0), 700)] }),
    ]
}

/// Strength (0…1) and pulse index at `ms` into a pattern, with the pulses started so far.
private func level(of pulses: [BandPulse], at ms: Double) -> (amplitude: Double, index: Int?, starts: [(at: Double, strength: Double)]) {
    var start = 0.0, amplitude = 0.0, index: Int?, starts: [(at: Double, strength: Double)] = []
    for (offset, pulse) in pulses.enumerated() {
        guard start <= ms else { break }
        let strength = pulse.strength
        starts.append((start, strength))
        if ms < start + Double(pulse.span) { index = offset }
        if ms < start + Double(pulse.duration) {
            // A quick attack and release, like a motor spinning up and down.
            let into = ms - start, left = start + Double(pulse.duration) - ms
            amplitude = strength * min(1, into / 18) * min(1, left / 25 + 0.35)
        }
        start += Double(pulse.span)
    }
    return (amplitude, index, starts)
}

/// Settings → Vibration lab. The ring is the instrument: each bead is a step, lifted as high
/// as it hits. Below it, a tape of what was sent and answered, a pad for single pulses,
/// patterns to try, and ladders that find the motor's limits.
struct VibrationLabScreen: View {
    @ObservedObject private var lab = VibrationLab.shared
    @ObservedObject private var controller = SessionController.shared
    @State private var steps: [Double] = [230, 0, 150, 0, 230, 0, 150, 90]
    @State private var focus = 0
    @State private var stepLength = 160.0
    @State private var laps = 2
    @State private var selected: String?
    @State private var drawing: [CGPoint] = []
    @State private var press: PressPad.Press?
    @State private var copied = false
    @AppStorage(EdgeStyle.key) private var edgeStyle = EdgeStyle.threads.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ready: Bool { controller.snapshot.state == .streaming }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                if reduceMotion { stillNotice }
                instrument
                tape
                pad
                ledger("Patterns", LabPattern.library)
                ledger("Find the limits", LabPattern.experiments)
                draw
                edge
                keep
            }
            .padding(.horizontal, Metric.gutter).padding(.bottom, 28)
        }
        .background(Color.paper)
        .navigationTitle("Vibration lab")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func play(_ pattern: LabPattern) {
        selected = pattern.id
        lab.play(pattern.pulses, name: pattern.name, onBand: ready)
    }
    private func playLoop() {
        let loop = BandPulse.loop(steps: steps.map { UInt64($0) }, stepLength: UInt64(stepLength), laps: laps)
        selected = nil
        lab.play(loop.map(\.pulse), name: "Your loop", onBand: ready,
                 loop: VibrationLab.Loop(beads: loop.map(\.step), lap: stepLength * 8))
    }

    /// Reduce Motion replaces every movement here with a still state, which is easy to
    /// mistake for the lab not working.
    private var stillNotice: some View {
        Text("Reduce Motion is on, so nothing here moves: the beads don’t shake, the wrist doesn’t turn and every edge style is the same still line. To see the motion, turn it off in Settings → Accessibility → Motion.")
            .font(.caption).fixedSize(horizontal: false, vertical: true)
            .padding(Metric.inset).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.soft, in: RoundedRectangle(cornerRadius: Metric.panel))
            .overlay(RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.rule, lineWidth: Metric.hairline))
    }

    // MARK: The ring

    private var instrument: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .topLeading) {
                StepRing(steps: $steps, focus: $focus, playback: lab.playback, connected: ready)
                    .padding(.top, 44).padding(.leading, 20).padding(.trailing, -16)
                readout
            }
            Text(ready ? "Each bead is a step. Drag one up to hit harder; tap it to switch it off."
                       : "Connect your band to feel it. The ring and tape still show everything.")
                .font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(lab.playback == nil ? "Play loop" : "Stop") {
                    if lab.playback == nil { playLoop() } else { lab.stop() }
                }
                .buttonStyle(.primary)
                .disabled(lab.playback == nil && steps.allSatisfy { $0 == 0 })
                Button("×\(laps)") { laps = laps == 4 ? 1 : laps * 2 }
                    .buttonStyle(.secondary).frame(width: 72)
                    .accessibilityLabel("Laps").accessibilityValue("\(laps)")
            }
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Step").font(.caption).foregroundStyle(Color.muted)
                    Text("\(Int(stepLength)) ms").font(.label).monospacedDigit().contentTransition(.numericText())
                }
                .frame(width: 64, alignment: .leading)
                Ruler(value: $stepLength, range: 60...400, step: 10)
                    .accessibilityLabel("Step length")
            }
        }
    }

    /// The one oversized number: how hard, right now. While something plays it follows the
    /// motor; while you press the pad it follows your finger; otherwise it is the bead you touched.
    private var readout: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: lab.playback == nil)) { context in
            let playing = lab.playback.map { ($0, level(of: $0.pulses, at: context.date.timeIntervalSince($0.started) * 1000)) }
            let pulse = playing.flatMap { state in state.1.index.map { state.0.pulses[$0] } }
            let value = press?.strength ?? pulse.map { Int(min($0.amplitude, 255)) } ?? Int(steps[focus])
            VStack(alignment: .leading, spacing: -6) {
                Text("\(value)")
                    .font(.geist(84, .medium, relativeTo: .largeTitle)).tracking(-3).monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))
                    .animation(.standard, value: value)
                Group {
                    if press != nil { Text("Strength under your finger") }
                    else if let playing, let pulse { Text("\(playing.0.name) · \(pulse.duration) ms") }
                    else if let playing { Text(playing.0.name) }
                    else { Text("Bead \(focus + 1) of 8") }
                }
                .font(.caption).foregroundStyle(Color.muted).padding(.leading, 4)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Strength \(value) of 255")
        }
        .allowsHitTesting(false)
    }

    // MARK: Tape

    private var tape: some View {
        VStack(alignment: .leading, spacing: 10) {
            Tape(lab: lab).padding(.horizontal, -Metric.gutter)
            Text(tapeSummary).font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var tapeSummary: String {
        let recent = lab.answers.suffix(24)
        guard !recent.isEmpty else {
            return "The tape runs right to left. Bars are the pattern’s pulses; a tick under the line is the band’s answer to one."
        }
        let accepted = recent.filter { $0.result == .accepted }.count
        let average = Int(recent.map(\.latency).reduce(0, +) / Double(recent.count) * 1000)
        return "Band accepted \(accepted) of the last \(recent.count). It answers \(average) ms after a pulse is sent, on average; patterns can’t run tighter than that."
    }

    // MARK: Pad

    private var pad: some View {
        VStack(alignment: .leading, spacing: 10) {
            PressPad(press: $press) { pulse in
                selected = nil
                lab.play([pulse], name: "One pulse", onBand: ready)
            }
            Text("One pulse, two numbers. Where you press sets how hard; how long you hold sets how long, up to a second. It is sent when you let go, because a pulse can’t be stopped once sent.")
                .font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Lists

    private func ledger(_ title: String, _ patterns: [LabPattern]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title)
            VStack(spacing: 0) {
                ForEach(Array(patterns.enumerated()), id: \.element.id) { index, pattern in
                    if index > 0 { Rule() }
                    Button { play(pattern) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 14) {
                                Text(pattern.name).font(pattern.id == selected ? .label : .bodyText)
                                    .foregroundStyle(pattern.id == selected ? Color.ink : Color.muted)
                                    .frame(width: 104, alignment: .leading)
                                PulseStrip(pulses: pattern.pulses, playback: pattern.id == selected ? lab.playback : nil,
                                           axis: max(1000, Double(pattern.milliseconds)))
                                Text("\(pattern.milliseconds) ms").font(.caption).monospacedDigit().foregroundStyle(Color.muted)
                                    .frame(width: 54, alignment: .trailing)
                            }
                            if let note = pattern.note {
                                Text(note).font(.caption).foregroundStyle(Color.muted)
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(pattern.name), \(pattern.pulses.count) pulses")
                    .accessibilityAddTraits(pattern.id == selected ? .isSelected : [])
                }
            }
        }
    }

    private var draw: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Draw one")
            DrawPad(points: $drawing) {
                let pulses = BandPulse.sketch(drawing.map { (x: $0.x, y: $0.y) })
                guard !pulses.isEmpty else { return }
                selected = nil
                lab.play(pulses, name: "Your drawing", onBand: ready)
            }
            Text("Left to right is two seconds; higher is harder. Lift your finger to play it.")
                .font(.caption).foregroundStyle(Color.muted)
        }
    }

    /// How a band vibration shows on the screen edge, here and everywhere else in the app.
    private var edge: some View {
        PanelGroup("On the screen edge", caption: "When the band vibrates, the edge of the screen shows it, in every part of the app. Picking a style plays a sample; otherwise it only appears for pulses the band was sent.") {
            ChipRow(selection: $edgeStyle, options: EdgeStyle.allCases.map(\.rawValue)) { EdgeStyle(rawValue: $0)?.label ?? $0 }
                .padding(.vertical, 12)
                .onChange(of: edgeStyle) { _, _ in BandBuzzFeed.shared.sample() }
        }
    }

    /// Whatever played last, as the pulse list the rest of the app uses.
    private var keep: some View {
        PanelGroup(nil, caption: "Copies the last thing played as a list of pulses, ready to paste into a feature.") {
            ActionRow(copied ? "Copied" : "Copy last vibration", icon: copied ? .check : .clipboardCopy) {
                UIPasteboard.general.string = "[" + lab.last.map {
                    "BandPulse(duration: \($0.duration), amplitude: \($0.amplitude)\($0.gap > 0 ? ", gap: \($0.gap)" : ""))"
                }.joined(separator: ", ") + "]"
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            .disabled(lab.last.isEmpty)
        }
    }
}

/// The band's eight beads as an eight-step loop. A bead's height is how hard its step hits;
/// a bead on the floor is silent. While the loop plays, an arc sweeps the wrist and the bead
/// whose turn it is shakes; any other pattern shakes them all. Reduce Motion keeps the fills.
private struct StepRing: View {
    @Binding var steps: [Double]
    @Binding var focus: Int
    let playback: VibrationLab.Playback?
    let connected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grab: (bead: Int, from: Double, moved: Bool)?
    @State private var remembered = Array(repeating: 230.0, count: 8)
    @GestureState private var touching = false

    /// Bead 0 sits at the front; steps run clockwise from there.
    private static let rotation = Double.pi / 4
    private static let rise = 13.0

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1 / 120, paused: playback == nil)) { context in
                Canvas { canvas, size in draw(in: &canvas, size: size, now: context.date) }
            }
            .contentShape(Rectangle())
            .onChange(of: touching) { _, held in if !held { grab = nil } }
            .gesture(DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { value in
                    if grab == nil {
                        guard let bead = bead(at: value.startLocation, in: geometry.size) else { return }
                        grab = (bead, steps[bead], false); focus = bead
                    }
                    guard var held = grab else { return }
                    if abs(value.translation.height) > 6 { held.moved = true }
                    if held.moved {
                        steps[held.bead] = (min(255, max(0, held.from - value.translation.height * 1.6)) / 5).rounded() * 5
                    }
                    grab = held
                }
                .onEnded { _ in
                    defer { grab = nil }
                    guard let held = grab, !held.moved else { return }
                    if steps[held.bead] > 0 { remembered[held.bead] = steps[held.bead]; steps[held.bead] = 0 }
                    else { steps[held.bead] = remembered[held.bead] }
                })
        }
        .aspectRatio(1.55, contentMode: .fit)
        .sensoryFeedback(.selection, trigger: steps.map { Int($0 / 25) })
        .accessibilityElement()
        .accessibilityLabel("Eight-step vibration loop")
        .accessibilityValue(steps.map { $0 == 0 ? "off" : "\(Int($0))" }.joined(separator: ", "))
    }

    private static func transform(for size: CGSize) -> CGAffineTransform {
        let extent = RingGeometry.radius + 16
        let corners = [RingGeometry.project(-extent, extent, 0), RingGeometry.project(extent, -extent, 0),
                       RingGeometry.project(-extent, -extent, 0), RingGeometry.project(extent, extent, 0),
                       RingGeometry.project(-extent, -extent, rise + 20)]
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        let scale = min(size.width / (maxX - minX), size.height / (maxY - minY))
        return CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -(minX + maxX) / 2, y: -(minY + maxY) / 2)
    }
    private func lift(_ bead: Int) -> Double { steps[bead] / 255 * Self.rise }

    private func bead(at point: CGPoint, in size: CGSize) -> Int? {
        let transform = Self.transform(for: size)
        let reach = RingGeometry.ballRadius * transform.a * 1.7
        return RingGeometry.pods(rotation: Self.rotation, radius: RingGeometry.radius)
            .map { pod -> (Int, Double) in
                let body = RingGeometry.ball(pod.x, pod.y, pod.z + lift(pod.index), transform)
                return (pod.index, hypot(body.midX - point.x, body.midY - point.y))
            }
            .filter { $0.1 <= reach }.min { $0.1 < $1.1 }?.0
    }

    private static func arc(radius: Double, from: Double = 0, to: Double = 2 * .pi, around centre: (x: Double, y: Double) = (0, 0),
                            _ transform: CGAffineTransform) -> Path {
        var path = Path()
        let segments = max(2, Int(abs(to - from) / (2 * .pi) * 72))
        for step in 0...segments {
            let a = from + (to - from) * Double(step) / Double(segments)
            let point = RingGeometry.project(centre.x + cos(a) * radius, centre.y + sin(a) * radius, 6).applying(transform)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, now: Date) {
        let t = now.timeIntervalSinceReferenceDate
        let transform = Self.transform(for: size)
        let line = max(0.75, min(1.25, transform.a * 0.45))
        let ms = playback.map { now.timeIntervalSince($0.started) * 1000 } ?? -1
        let state = playback.map { level(of: $0.pulses, at: ms) }
        let amplitude = state?.amplitude ?? 0
        // Each pulse belongs to one bead: its step in a loop, otherwise the next bead round.
        func bead(for pulse: Int) -> Int { playback?.loop?.beads[pulse] ?? pulse % 8 }
        let turn = state?.index.map(bead)

        // The wrist: a faint track, the loop's sweep, and a ripple from each bead as it hits.
        canvas.stroke(Self.arc(radius: RingGeometry.radius, transform), with: .color(.rule), lineWidth: line)
        if let loop = playback?.loop, ms >= 0 {
            let lap = (ms / loop.lap).truncatingRemainder(dividingBy: 1)
            let from = Self.rotation - .pi / 8
            canvas.stroke(Self.arc(radius: RingGeometry.radius, from: from, to: from + lap * 2 * .pi, transform),
                          with: .color(.ink), style: StrokeStyle(lineWidth: line * 1.4, lineCap: .round))
        }
        if !reduceMotion, let state {
            for (pulse, (at, strength)) in state.starts.enumerated() {
                let age = (ms - at) / 800
                guard age >= 0, age < 1 else { continue }
                let angle = Double(bead(for: pulse)) * .pi / 4 + Self.rotation
                let centre = (x: cos(angle) * RingGeometry.radius, y: sin(angle) * RingGeometry.radius)
                for ring in 0..<2 {
                    let spread = max(0, age - Double(ring) * 0.18)
                    guard spread > 0 else { continue }
                    canvas.stroke(Self.arc(radius: 9 + spread * 34 * (0.5 + strength), around: centre, transform),
                                  with: .color(.ink.opacity((1 - age) * (1 - age) * 0.45 * strength)), lineWidth: line * 0.8)
                }
            }
        }

        let pods = RingGeometry.pods(rotation: Self.rotation, radius: RingGeometry.radius)
        func placed(_ pod: RingGeometry.Pod) -> (x: Double, y: Double, lift: Double, energy: Double) {
            let energy = turn == pod.index ? amplitude : 0
            guard !reduceMotion, energy > 0 else { return (pod.x, pod.y, lift(pod.index), energy) }
            let seed = Double(pod.index) * 1.7, shake = energy * 3
            return (pod.x + sin(t * 173 + seed) * shake, pod.y + cos(t * 151 + seed * 1.3) * shake,
                    lift(pod.index) + energy * (5 + 3 * sin(t * 37 + seed)), energy)
        }
        for pod in pods {
            let at = placed(pod)
            let shadow = RingGeometry.shadow(at.x, at.y, lift: at.lift, transform)
            canvas.stroke(Path(ellipseIn: shadow), with: .color(.muted.opacity(0.4 * max(0.3, 1 - at.lift / 26))), lineWidth: line * 0.7)
            // A stem from the wrist to a lit bead, so its height reads like a bar.
            if steps[pod.index] > 0 {
                var stem = Path()
                stem.move(to: RingGeometry.project(at.x, at.y, 6).applying(transform))
                stem.addLine(to: RingGeometry.project(at.x, at.y, pod.z + at.lift + RingGeometry.ballRadius).applying(transform))
                canvas.stroke(stem, with: .color(.faint), lineWidth: line * 0.7)
            }
        }
        for pod in pods {
            let at = placed(pod), on = steps[pod.index] > 0
            let body = RingGeometry.ball(at.x, at.y, pod.z + at.lift - (on ? 0 : 4), transform)
            let stroke: Color = at.energy > 0.05 || pod.index == focus ? .ink : on ? (connected ? .ink.opacity(0.7) : .muted) : .faint
            RingGeometry.drawBall(in: &canvas, body: body, stroke: stroke,
                                  lineWidth: line * (pod.index == focus ? 1.5 : 1),
                                  charge: max(at.energy, on ? steps[pod.index] / 255 * 0.5 : 0))
        }
    }
}

/// A dial of ticks that slides under a fixed mark, like a tuner.
private struct Ruler: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @State private var from: Double?
    @GestureState private var touching = false
    private static let pointsPerUnit = 0.9

    var body: some View {
        Canvas { canvas, size in
            let middle = size.width / 2
            for tick in stride(from: range.lowerBound, through: range.upperBound, by: step) {
                let x = middle + (tick - value) * Self.pointsPerUnit
                guard x >= 0, x <= size.width else { continue }
                let major = tick.truncatingRemainder(dividingBy: 50) == 0
                let fade = 1 - min(1, abs(x - middle) / middle) * 0.75
                var path = Path(); path.move(to: CGPoint(x: x, y: size.height)); path.addLine(to: CGPoint(x: x, y: size.height - (major ? 16 : 8)))
                canvas.stroke(path, with: .color((major ? Color.muted : Color.faint).opacity(fade)), lineWidth: Metric.hairline)
            }
            var mark = Path(); mark.move(to: CGPoint(x: middle, y: 0)); mark.addLine(to: CGPoint(x: middle, y: size.height))
            canvas.stroke(mark, with: .color(.ink), lineWidth: 1.5)
        }
        .frame(height: 30)
        .contentShape(Rectangle())
        .onChange(of: touching) { _, held in if !held { from = nil } }
        .gesture(DragGesture()
            .updating($touching) { _, state, _ in state = true }
            .onChanged { drag in
                let start = from ?? value; from = start
                let moved = start - drag.translation.width / Self.pointsPerUnit
                value = min(range.upperBound, max(range.lowerBound, (moved / step).rounded() * step))
            }
            .onEnded { _ in from = nil })
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityValue("\(Int(value)) milliseconds")
        .accessibilityAdjustableAction { direction in
            let next = value + (direction == .increment ? step : -step)
            value = min(range.upperBound, max(range.lowerBound, next))
        }
    }
}

/// A seismograph of the last few seconds, edge to edge: bars are pulses sent, sliding left
/// from "now" at the right edge; ticks under the line are the band's answers.
private struct Tape: View {
    @ObservedObject var lab: VibrationLab

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !lab.tapeRunning)) { context in
            Canvas { canvas, size in
                let now = context.date, floor = size.height - 14
                func x(_ date: Date) -> Double { size.width * (1 - now.timeIntervalSince(date) / VibrationLab.tapeSeconds) }
                for second in 1..<Int(VibrationLab.tapeSeconds) {
                    let at = size.width * (1 - Double(second) / VibrationLab.tapeSeconds)
                    var grid = Path(); grid.move(to: CGPoint(x: at, y: floor - 4)); grid.addLine(to: CGPoint(x: at, y: floor + 4))
                    canvas.stroke(grid, with: .color(.faint), lineWidth: Metric.hairline)
                }
                var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: floor)); baseline.addLine(to: CGPoint(x: size.width, y: floor))
                canvas.stroke(baseline, with: .color(.rule), lineWidth: Metric.hairline)
                for sent in lab.sent where sent.at <= now {
                    let left = x(sent.at)
                    let end = min(now, sent.at.addingTimeInterval(Double(sent.pulse.duration) / 1000))
                    guard x(end) > 0 else { continue }
                    let height = max(2, (floor - 4) * sent.pulse.strength)
                    canvas.fill(Path(CGRect(x: left, y: floor - height, width: max(1.5, x(end) - left), height: height)), with: .color(.ink))
                }
                for answer in lab.answers {
                    let at = x(answer.at)
                    guard at > 0 else { continue }
                    switch answer.result {
                    case .accepted:
                        var tick = Path(); tick.move(to: CGPoint(x: at, y: floor + 3)); tick.addLine(to: CGPoint(x: at, y: floor + 10))
                        canvas.stroke(tick, with: .color(.ink), lineWidth: 1.5)
                    case .rejected:
                        canvas.stroke(Path(ellipseIn: CGRect(x: at - 3, y: floor + 4, width: 6, height: 6)), with: .color(.destructive), lineWidth: 1.5)
                    case .unconfirmed:
                        canvas.stroke(Path(ellipseIn: CGRect(x: at - 3, y: floor + 4, width: 6, height: 6)), with: .color(.muted), lineWidth: 1)
                    }
                }
            }
        }
        .frame(height: 60)
        .accessibilityHidden(true)
    }
}

/// An ink slab for one pulse: where you press is how hard, how long you hold is how long.
private struct PressPad: View {
    struct Press: Equatable {
        let since: Date
        var strength: Int
    }
    @Binding var press: Press?
    let send: (BandPulse) -> Void
    @GestureState private var touching = false

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(paused: press == nil)) { context in
                ZStack(alignment: .topLeading) {
                    Color.ink
                    if let press {
                        let held = min(1, context.date.timeIntervalSince(press.since))
                        Rectangle().fill(Color.paper).frame(width: Metric.hairline)
                            .offset(x: geometry.size.width * Double(press.strength) / 255)
                        Rectangle().fill(Color.paper).frame(width: geometry.size.width * held, height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                        Text("\(Int(held * 1000)) ms").font(.display).monospacedDigit().foregroundStyle(Color.paper).padding(16)
                    } else {
                        VStack(alignment: .leading) {
                            Text("Press and hold").font(.label)
                            Spacer()
                            HStack { Text("Soft"); Spacer(); Text("Hard") }.font(.caption).opacity(0.6)
                        }
                        .foregroundStyle(Color.paper).padding(16)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metric.panel))
            .contentShape(Rectangle())
            .onChange(of: touching) { _, held in if !held { press = nil } }
            .gesture(DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { drag in
                    let strength = Int(min(255, max(40, drag.location.x / geometry.size.width * 255)))
                    if press == nil { press = Press(since: Date(), strength: strength) } else { press?.strength = strength }
                }
                .onEnded { _ in
                    guard let held = press else { return }
                    press = nil
                    let length = min(1000, max(20, Date().timeIntervalSince(held.since) * 1000))
                    send(BandPulse(duration: UInt64(length), amplitude: UInt64(held.strength)))
                })
        }
        .frame(height: 132)
        .accessibilityLabel("Pad for one pulse")
        .accessibilityHint("Press position sets strength, hold time sets length")
    }
}

/// A pattern drawn to scale; bars not yet played are faint while it plays.
private struct PulseStrip: View {
    let pulses: [BandPulse]
    let playback: VibrationLab.Playback?
    /// Milliseconds the full width stands for.
    let axis: Double

    var body: some View {
        TimelineView(.animation(paused: playback == nil)) { context in
            Canvas { canvas, size in
                let scale = size.width / max(1, axis)
                var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: size.height - 0.5)); baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                canvas.stroke(baseline, with: .color(.rule), lineWidth: Metric.hairline)
                let elapsed = playback.map { context.date.timeIntervalSince($0.started) * 1000 } ?? -1
                var start = 0.0
                for pulse in pulses {
                    let height = max(2, size.height * pulse.strength)
                    let bar = CGRect(x: start * scale, y: size.height - height, width: max(2, Double(pulse.duration) * scale), height: height)
                    canvas.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(playback == nil || elapsed >= start ? .ink : .faint))
                    start += Double(pulse.span)
                }
            }
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }
}

/// A pad for drawing a vibration: x is time across two seconds, y is strength.
private struct DrawPad: View {
    @Binding var points: [CGPoint]
    let finished: () -> Void
    @State private var drawing = false
    @GestureState private var touching = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { canvas, size in
                for level in [0.25, 0.5, 0.75] {
                    var line = Path(); line.move(to: CGPoint(x: 0, y: size.height * (1 - level))); line.addLine(to: CGPoint(x: size.width, y: size.height * (1 - level)))
                    canvas.stroke(line, with: .color(.rule), lineWidth: Metric.hairline)
                }
                guard points.count > 1 else { return }
                var stroke = Path()
                for (index, point) in points.enumerated() {
                    let at = CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
                    if index == 0 { stroke.move(to: at) } else { stroke.addLine(to: at) }
                }
                canvas.stroke(stroke, with: .color(.ink), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .contentShape(Rectangle())
            .onChange(of: touching) { _, held in if !held { drawing = false } }
            .gesture(DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { value in
                    if !drawing { drawing = true; points = [] }
                    points.append(CGPoint(x: min(1, max(0, value.location.x / size.width)),
                                          y: min(1, max(0, 1 - value.location.y / size.height))))
                }
                .onEnded { _ in drawing = false; finished() })
        }
        .frame(height: 140)
        .overlay(RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.rule, lineWidth: Metric.hairline))
        .overlay(alignment: .center) {
            if points.isEmpty { Text("Draw here").font(.caption).foregroundStyle(Color.muted).allowsHitTesting(false) }
        }
        .accessibilityLabel("Drawing pad for a vibration")
    }
}
