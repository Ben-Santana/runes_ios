import SwiftUI

/// A board of small beads. The ones under the finger ink in as it writes, and when the
/// letter is read they empty in the order they were filled while it sets as type, in beads,
/// on the board below. The whole word is made of beads.
enum WritingBoard {
    /// How far apart the beads are, and how large.
    private static let pitch = 11.0, dot = 3.6
    /// Each letter on a board five beads wide and seven tall.
    private static let type: [Character: [String]] = [
        "a": [".....", ".....", ".###.", "....#", ".####", "#...#", ".####"],
        "b": ["#....", "#....", "#.##.", "##..#", "#...#", "#...#", "####."],
        "c": [".....", ".....", ".###.", "#....", "#....", "#...#", ".###."],
        "d": ["....#", "....#", ".##.#", "#..##", "#...#", "#...#", ".####"],
        "e": [".....", ".....", ".###.", "#...#", "#####", "#....", ".###."],
        "f": ["..##.", ".#..#", ".#...", "###..", ".#...", ".#...", ".#..."],
        "g": [".....", ".####", "#...#", "#...#", ".####", "....#", ".###."],
        "h": ["#....", "#....", "#.##.", "##..#", "#...#", "#...#", "#...#"],
        "i": ["..#..", ".....", ".##..", "..#..", "..#..", "..#..", ".###."],
        "j": ["...#.", ".....", "..##.", "...#.", "...#.", "#..#.", ".##.."],
        "k": ["#....", "#....", "#..#.", "#.#..", "##...", "#.#..", "#..#."],
        "l": [".##..", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "m": [".....", ".....", "##.#.", "#.#.#", "#.#.#", "#...#", "#...#"],
        "n": [".....", ".....", "#.##.", "##..#", "#...#", "#...#", "#...#"],
        "o": [".....", ".....", ".###.", "#...#", "#...#", "#...#", ".###."],
        "p": [".....", ".....", "####.", "#...#", "####.", "#....", "#...."],
        "q": [".....", ".....", ".##.#", "#..##", ".####", "....#", "....#"],
        "r": [".....", ".....", "#.##.", "##..#", "#....", "#....", "#...."],
        "s": [".....", ".....", ".###.", "#....", ".###.", "....#", "####."],
        "t": [".#...", ".#...", "###..", ".#...", ".#...", ".#..#", "..##."],
        "u": [".....", ".....", "#...#", "#...#", "#...#", "#..##", ".##.#"],
        "v": [".....", ".....", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
        "w": [".....", ".....", "#...#", "#...#", "#.#.#", "#.#.#", ".#.#."],
        "x": [".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
        "y": [".....", ".....", "#...#", "#...#", ".####", "....#", ".###."],
        "z": [".....", ".....", "#####", "...#.", "..#..", ".#...", "#####"],
    ]

    static func draw(_ scene: WritingScene, in canvas: inout GraphicsContext) {
        let writing = scene.writing, pad = scene.pad, lower = scene.lower
        var empty = Path(), full = Path()
        func bead(_ centre: CGPoint, inked: Bool) {
            let body = CGRect(x: centre.x - dot, y: centre.y - dot, width: dot * 2, height: dot * 2)
            if inked { full.addEllipse(in: body) } else { empty.addEllipse(in: body) }
        }

        // The pad: the strokes that are still on it ink the beads they pass over.
        var strokes: [[WritingPoint]] = []
        switch writing.phase {
        case .writing: strokes = writing.strokes
        case .read:
            if let last = writing.letters.last { strokes = LetterForms.cut(last.strokes, from: scene.arrived(last.at, over: 0.4), to: 1) }
        case .unread: strokes = LetterForms.cut(writing.strokes, from: 0, to: 1 - scene.arrived(writing.phaseAt, over: 0.4))
        case .waiting, .finished: break
        }
        let side = Int(pad.width / pitch), inset = (pad.width - Double(side) * pitch) / 2
        var inked = Set<Int>()
        for stroke in strokes {
            let length = LetterForms.length(stroke), steps = max(1, Int(length * pad.width / (pitch * 0.4)))
            for step in 0...steps {
                let point = WritingScene.place(LetterForms.point(along: stroke, at: length * Double(step) / Double(steps)), in: pad)
                let column = Int(((point.x - pad.minX - inset) / pitch).rounded(.down)), row = Int(((point.y - pad.minY - inset) / pitch).rounded(.down))
                if (0..<side).contains(column), (0..<side).contains(row) { inked.insert(row * side + column) }
            }
        }
        for row in 0..<side {
            for column in 0..<side {
                bead(CGPoint(x: pad.minX + inset + (Double(column) + 0.5) * pitch, y: pad.minY + inset + (Double(row) + 0.5) * pitch), inked: inked.contains(row * side + column))
            }
        }

        // The word, set in beads a column at a time, and a line of beads under it when it is finished.
        let columns = Int(lower.width / pitch), top = lower.minY + 6
        var set = Set<Int>()
        for (index, letter) in writing.letters.enumerated() {
            let shown = Int((scene.arrived(letter.at + 0.1, over: 0.4) * 5).rounded(.up))
            for (row, line) in (type[letter.character] ?? []).enumerated() {
                for (column, mark) in line.enumerated() where mark == "#" && column < shown { set.insert(row * columns + index * 6 + column) }
            }
        }
        if writing.phase == .finished {
            let under = Int((scene.arrived(writing.phaseAt, over: 0.5) * Double(writing.letters.count * 6 - 1)).rounded(.up))
            for column in 0..<under { set.insert(8 * columns + column) }
        }
        for row in 0..<9 {
            for column in 0..<columns {
                bead(CGPoint(x: lower.minX + (Double(column) + 0.5) * pitch, y: top + (Double(row) + 0.5) * pitch), inked: set.contains(row * columns + column))
            }
        }
        canvas.stroke(empty, with: .color(.faint), lineWidth: 0.75)
        canvas.fill(full, with: .color(.ink))
        scene.drawSentence(in: &canvas)
    }
}
