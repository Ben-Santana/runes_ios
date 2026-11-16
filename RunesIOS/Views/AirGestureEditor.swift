import SwiftUI

/// Draws or records an air gesture's shape in the space under the bead string: draw one stroke
/// with a finger, or record it with the band. Saved as the Mac's 64-point normalized path.
struct AirGestureEditor: View {
    @ObservedObject var store: MappingStore
    let initial: AirShape?
    let onSave: (AirShape) -> Void
    let onCancel: () -> Void

    /// Pad coordinates.
    private static let pad = CGSize(width: 400, height: 220)

    @State private var points: [CGPoint] = []
    @State private var message = "Draw one stroke, or record it with your band."
    @State private var latest: (q: [Double], at: Date)?
    @State private var capture: (reference: [Double], points: [AirShape.Point], end: Date, last: Date)?
    @State private var now = Date()
    @State private var padWidth: CGFloat = 400
    @State private var drawing = false
    private let clock = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var recording: Bool { capture != nil }
    private var fresh: Bool { latest.map { now.timeIntervalSince($0.at) < 0.5 } ?? false }
    private var durationMs: Int { initial?.durationMs ?? 2000 }
    private var shape: AirShape {
        AirShape(points: AirMatcher.normalize(points.map { [Double($0.x), Double($0.y)] }),
                 minSimilarity: initial?.minSimilarity ?? 75, durationMs: durationMs, name: initial?.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            padView
            Text(message).font(.caption).foregroundStyle(Color.muted)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                key(.x, "Cancel") { onCancel() }
                key(.rotateCcw, "Clear", enabled: !points.isEmpty && !recording) { points = [] }
                key(recording ? .circleDot : .circle,
                    recording ? String(format: "%.1f s", max(0, capture!.end.timeIntervalSince(now))) : "Record",
                    enabled: fresh || recording) { recording ? stop() : start() }
                key(.check, "Save", enabled: !recording && shape.isValid) { onSave(shape) }
            }
        }
        .onAppear {
            if let initial { points = display(initial.points) }
            store.onOrientation = { q in sample(q) }
        }
        .onDisappear { store.onOrientation = nil; capture = nil; latest = nil }
        .onReceive(clock) { date in
            now = date
            guard let c = capture else { return }
            if date.timeIntervalSince(c.last) > 0.5 { interrupted() } else if date >= c.end { stop() }
        }
    }

    private var padView: some View {
        Canvas { context, size in
            let scale = size.width / Self.pad.width
            var path = Path()
            for (i, p) in points.enumerated() {
                let q = CGPoint(x: p.x * scale, y: p.y * scale)
                i == 0 ? path.move(to: q) : path.addLine(to: q)
            }
            context.stroke(path, with: .color(.ink), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            if points.count > 1, let first = points.first {
                context.fill(Path(ellipseIn: CGRect(x: first.x * scale - 5, y: first.y * scale - 5, width: 10, height: 10)), with: .color(.ink))
            }
        }
        .aspectRatio(Self.pad.width / Self.pad.height, contentMode: .fit)
        .overlay {
            if points.count < 2 {
                Text("Draw the shape here").font(.bodyText).foregroundStyle(Color.faint)
            }
        }
        .background(Color.paper, in: RoundedRectangle(cornerRadius: Metric.control))
        .overlay(RoundedRectangle(cornerRadius: Metric.control)
            .strokeBorder(recording ? Color.ink : Color.rule, lineWidth: recording ? 1.5 : Metric.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Metric.control))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { value in
            guard !recording else { return }
            // Each new touch starts a new stroke.
            if !drawing { drawing = true; points = [] }
            let scale = Self.pad.width / max(1, padWidth)
            let p = CGPoint(x: min(Self.pad.width, max(0, value.location.x * scale)),
                            y: min(Self.pad.height, max(0, value.location.y * scale)))
            if points.count < 4096 { points.append(p) }
        }.onEnded { _ in drawing = false })
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { padWidth = $0 }
        .accessibilityLabel("Air gesture drawing")
    }

    private func key(_ icon: Lucide, _ label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                LucideIcon(icon, size: 16)
                Text(label).font(.caption).lineLimit(1).minimumScaleFactor(0.8).monospacedDigit()
            }
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(Color.paper, in: RoundedRectangle(cornerRadius: Metric.control))
            .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
            .opacity(enabled ? 1 : 0.3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// A saved normalized path, centered on the pad.
    private func display(_ normalized: [AirShape.Point]) -> [CGPoint] {
        AirMatcher.normalize(normalized).map { CGPoint(x: 200 + $0[0] * 190, y: 110 + $0[1] * 190) }
    }

    // MARK: Band recording

    private func sample(_ q: [Double]) {
        let norm = sqrt(q.reduce(0) { $0 + $1 * $1 })
        guard q.count == 4, q.allSatisfy(\.isFinite), norm > 1e-8 else { return }
        let unit = q.map { $0 / norm }, at = Date()
        latest = (unit, at)
        guard var c = capture else { return }
        if at.timeIntervalSince(c.last) > 0.5 { interrupted(); return }
        guard at <= c.end, c.points.count < 4096 else { return }
        c.points.append(AirMatcher.wristPoint(unit, reference: c.reference))
        c.last = at
        capture = c
        points = display(c.points)
    }
    private func start() {
        guard let q = latest, Date().timeIntervalSince(q.at) < 0.5 else { return }
        capture = (q.q, [], Date().addingTimeInterval(Double(durationMs) / 1000), Date())
        points = []
        message = "Recording. Forearm forward, elbow still: act out the shape."
    }
    private func stop() {
        guard let c = capture else { return }
        capture = nil
        if c.points.count >= AirMatcher.minimumPoints, AirMatcher.pathLength(c.points) >= AirMatcher.minimumPath {
            points = display(c.points); message = "Recorded. Save it, or record again."
        } else {
            points = []; message = "Too little motion. Move your hand through a larger shape."
        }
    }
    private func interrupted() {
        capture = nil; points = []
        message = "The band's orientation dropped out. Record again."
    }
}
