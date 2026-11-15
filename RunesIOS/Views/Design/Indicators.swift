import SwiftUI

// Small marks that show state or progress in ink and hairline.
// Documentation/StyleGuide.md §6 lists every part; Views/Design/StyleGuide.swift draws them.

struct GestureChip: View {
    let gesture: GestureKind?
    var body: some View {
        HStack(spacing: 6) {
            if let gesture {
                GestureIcon.image(gesture, size: 16)
                Text(gesture.name).font(.label)
            } else {
                Text("None").font(.label).foregroundStyle(Color.muted)
            }
        }
        .padding(.horizontal, 10).frame(minHeight: 30)
        .overlay(Capsule().strokeBorder(Color.rule, lineWidth: Metric.hairline))
        .id(gesture)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .animation(.standard, value: gesture)
    }
}

struct PulseDot: View {
    var tint: Color = .ink
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(tint, lineWidth: Metric.hairline)
                .scaleEffect(pulse ? 2.6 : 1).opacity(pulse ? 0 : 0.8)
                // Only the ring repeats; a repeating animation on the whole dot would carry any move it makes.
                .animation(reduceMotion ? nil : .easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
            Circle().fill(tint)
        }
        .frame(width: 7, height: 7)
        .onAppear { if !reduceMotion { pulse = true } }
        .accessibilityHidden(true)
    }
}

/// A dot circling a hairline circle, for an app that's running.
struct OrbitDot: View {
    let radius: CGFloat
    @State private var turn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle().fill(Color.ink).frame(width: 4, height: 4)
            .offset(y: -radius)
            .rotationEffect(.degrees(turn ? 360 : 0))
            .onAppear { if !reduceMotion { withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { turn = true } } }
    }
}

struct RepBar: View {
    let reps: Int
    let target: Int
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.rule).frame(height: Metric.hairline)
                Rectangle().fill(Color.ink).frame(width: geo.size.width * min(1, CGFloat(reps) / CGFloat(max(1, target))), height: 1.5)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 8)
    }
}

/// Every step as a hairline segment: done in ink, the current one in ink too, the rest faint.
struct StepProgress: View {
    let count: Int
    let step: Int
    var finished = false
    var height: CGFloat = 2

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(1, count), id: \.self) { index in
                Capsule().fill(index <= step || finished ? Color.ink : Color.rule)
                    .opacity(index == step && !finished ? 1 : index < step || finished ? 0.45 : 1)
                    .frame(height: height)
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.15), value: step)
        .animation(.standard, value: finished)
        .accessibilityHidden(true)
    }
}

/// A hairline circle that fills clockwise as the time runs out.
struct TimerRing: View {
    let progress: Double
    var lineWidth: CGFloat = 1.5
    var body: some View {
        ZStack {
            Circle().stroke(Color.rule, lineWidth: Metric.hairline)
            Circle().trim(from: 0, to: min(1, max(0.01, progress)))
                .stroke(Color.ink, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: progress)
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

/// A hairline line through the points, the last one marked.
struct Sparkline: View {
    let points: [Double]
    var body: some View {
        GeometryReader { geo in
            let low = points.min() ?? 0, high = points.max() ?? 1
            let span = max(high - low, 1e-9)
            let xy: [CGPoint] = points.enumerated().map { i, v in
                CGPoint(x: points.count > 1 ? geo.size.width * CGFloat(i) / CGFloat(points.count - 1) : geo.size.width,
                        y: high == low ? geo.size.height / 2 : geo.size.height * (1 - CGFloat((v - low) / span)))
            }
            ZStack {
                Path { p in
                    guard let first = xy.first else { return }
                    p.move(to: first); for pt in xy.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(Color.ink, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                if let last = xy.last { Circle().fill(Color.ink).frame(width: 5, height: 5).position(last) }
            }
        }
        .accessibilityHidden(true)
    }
}
