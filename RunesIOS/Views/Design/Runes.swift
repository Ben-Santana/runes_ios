import SwiftUI

// Elder Futhark runes drawn like the icons: straight strokes in a 24 × 24 box at the icons'
// 1.5 weight, so a rune sits beside a Lucide glyph as one family. Capture's scrolls wear them.

struct RuneShape: Shape {
    let rune: Rune
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let dx = rect.midX - 12 * scale, dy = rect.midY - 12 * scale
        var path = Path()
        for stroke in rune.strokes {
            guard let first = stroke.first else { continue }
            path.move(to: CGPoint(x: dx + first.0 * scale, y: dy + first.1 * scale))
            for point in stroke.dropFirst() { path.addLine(to: CGPoint(x: dx + point.0 * scale, y: dy + point.1 * scale)) }
        }
        return path
    }
}

/// A rune at any size. The stroke thickens a little with size so a large rune still reads
/// as cut, not drawn with a pen.
struct RuneGlyph: View {
    let rune: Rune
    var size: CGFloat = 24
    /// 0...1: how much of it is cut, stroke by stroke in the order a carver would.
    var carved: CGFloat = 1

    var body: some View {
        RuneShape(rune: rune)
            .trim(from: 0, to: carved)
            .stroke(style: StrokeStyle(lineWidth: max(1.5, size / 24 * 1.5 * (size > 40 ? 0.8 : 1)), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A rune cut into view when it first appears: the one moment Capture spends on motion
/// nobody asked for. Shown whole under Reduce Motion.
struct CarvedRune: View {
    let rune: Rune
    var size: CGFloat = 72
    @State private var carved: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RuneGlyph(rune: rune, size: size, carved: reduceMotion ? 1 : carved)
            .onAppear { carve() }
            .onChange(of: rune) { _, _ in carved = 0; carve() }
    }

    private func carve() {
        guard !reduceMotion else { return }
        withAnimation(.timingCurve(0.5, 0, 0.2, 1, duration: 0.9).delay(0.15)) { carved = 1 }
    }
}
