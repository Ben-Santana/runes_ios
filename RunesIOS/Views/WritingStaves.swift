import SwiftUI

/// Each letter is cut as its rune. The hand's line is quiet; the rune is cut large over it
/// and again on the band below, where the word stands as an inscription with its letters
/// under it. One bead is the point of the chisel.
enum WritingStaves {
    private static let stave = [(12.0, 3.0), (12.0, 21.0)], left = [(9.0, 3.0), (9.0, 21.0)]
    /// The Elder Futhark rune that stands for each letter, drawn in the icons' 24 box as the
    /// app's other runes are. The alphabet has letters the runes do not, so a few share.
    private static let runes: [Character: [[(Double, Double)]]] = {
        let kenaz = [[(15.5, 5.0), (8.5, 12.0), (15.5, 19.0)]], gebo = [[(7.0, 4.0), (17.0, 20.0)], [(17.0, 4.0), (7.0, 20.0)]]
        let jera = [[(11.0, 4.0), (6.5, 9.0), (11.0, 14.0)], [(13.0, 10.0), (17.5, 15.0), (13.0, 20.0)]]
        let wunjo = [left, [(9.0, 3.0), (15.5, 7.5), (9.0, 12.0)]]
        return [
            "a": [left, [(9, 3), (16, 8)], [(9, 9), (16, 14)]],
            "b": [[(8, 3), (8, 21)], [(8, 3), (15.5, 7.5), (8, 12), (15.5, 16.5), (8, 21)]],
            "c": kenaz, "k": kenaz, "q": kenaz,
            "d": [[(6, 4), (18, 20), (18, 4), (6, 20), (6, 4)]],
            "e": [[(7, 21), (7, 3), (12, 9), (17, 3), (17, 21)]],
            "f": [left, [(9, 10), (16, 4)], [(9, 15), (16, 9)]],
            "g": gebo, "x": gebo,
            "h": [[(8, 3), (8, 21)], [(16, 3), (16, 21)], [(8, 9), (16, 15)]],
            "i": [stave],
            "j": jera, "y": jera,
            "l": [left, [(9, 3), (15.5, 9.5)]],
            "m": [[(7, 3), (7, 21)], [(17, 3), (17, 21)], [(7, 3), (17, 11)], [(17, 3), (7, 11)]],
            "n": [stave, [(8, 9), (16, 14)]],
            "o": [[(7, 20), (16.5, 10), (12, 3.5), (7.5, 10), (17, 20)]],
            "p": [[(8, 3), (8, 21)], [(8, 3), (12.5, 8), (17, 4)], [(8, 21), (12.5, 16), (17, 20)]],
            "r": [[(8, 21), (8, 3), (15.5, 7.5), (8, 12), (15.5, 21)]],
            "s": [[(15, 3), (8.5, 10.5), (15.5, 13.5), (9, 21)]],
            "t": [stave, [(7, 8.5), (12, 3), (17, 8.5)]],
            "u": [[(8, 21), (8, 3), (16, 9), (16, 21)]],
            "v": wunjo, "w": wunjo,
            "z": [stave, [(12, 11), (7, 4.5)], [(12, 11), (17, 4.5)]],
        ]
    }()

    /// A letter's rune in a square, a stroke after another in the order a carver would cut them.
    private static func rune(_ character: Character, in box: CGRect) -> Path {
        var path = Path()
        for stroke in runes[character] ?? [] {
            path.addLines(stroke.map { CGPoint(x: box.minX + $0.0 / 24 * box.width, y: box.minY + $0.1 / 24 * box.height) })
        }
        return path
    }

    static func draw(_ scene: WritingScene, in canvas: inout GraphicsContext) {
        let writing = scene.writing, pad = scene.pad, lower = scene.lower
        let quiet = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        let cut = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        let large = pad.insetBy(dx: pad.width * 0.2, dy: pad.height * 0.2)
        let last = writing.letters.last

        switch writing.phase {
        case .waiting: break
        case .writing:
            // The rune before is taken away as the next letter is begun.
            if writing.before == .read, let last {
                canvas.stroke(rune(last.character, in: large).trimmedPath(from: 0, to: 1 - scene.arrived(writing.phaseAt, over: 0.2)), with: .color(.ink), style: cut)
            }
            canvas.stroke(WritingScene.path(writing.strokes, in: pad), with: .color(.muted), style: quiet)
        case .read:
            guard let last else { break }
            canvas.stroke(WritingScene.path(last.strokes, in: pad).trimmedPath(from: scene.arrived(last.at, over: 0.35), to: 1), with: .color(.muted), style: quiet)
            canvas.stroke(rune(last.character, in: large).trimmedPath(from: 0, to: scene.arrived(last.at, over: 0.7)), with: .color(.ink), style: cut)
        case .unread:
            canvas.stroke(WritingScene.path(writing.strokes, in: pad).trimmedPath(from: 0, to: 1 - scene.arrived(writing.phaseAt, over: 0.4)), with: .color(.muted), style: quiet)
        case .finished:
            if let last { canvas.stroke(rune(last.character, in: large), with: .color(.ink), style: cut) }
        }

        // The band: two rules with the runes between them and the letters under.
        let top = lower.minY + 4, height = 56.0, cell = 42.0
        var rules = Path()
        for y in [top, top + height] { rules.move(to: CGPoint(x: lower.minX, y: y)); rules.addLine(to: CGPoint(x: lower.maxX, y: y)) }
        canvas.stroke(rules, with: .color(.rule), lineWidth: Metric.hairline)
        func slot(_ index: Int) -> CGRect { CGRect(x: lower.minX + 4 + Double(index) * cell, y: top + (height - 36) / 2, width: 36, height: 36) }
        var chisel = CGPoint(x: slot(writing.letters.count).midX, y: top + height / 2), cutting = false
        for (index, letter) in writing.letters.enumerated() {
            let k = scene.arrived(letter.at, over: 0.7)
            let carved = rune(letter.character, in: slot(index)).trimmedPath(from: 0, to: k)
            canvas.stroke(carved, with: .color(.ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            if k < 1, let tip = carved.currentPoint { chisel = tip; cutting = true }
            scene.write(Text(String(letter.character)).font(.label).foregroundStyle(Color.muted),
                        at: CGPoint(x: slot(index).midX, y: top + height + 8), anchor: .top, shown: k, in: &canvas)
        }
        if writing.phase == .finished {
            let k = scene.arrived(writing.phaseAt, over: 0.5)
            canvas.stroke(rules.trimmedPath(from: 0, to: k), with: .color(.ink), lineWidth: Metric.hairline)
            scene.write(Text(writing.text).font(.display).tracking(-0.6).foregroundStyle(Color.ink), at: CGPoint(x: lower.minX, y: top + height + 34), shown: k, in: &canvas)
        } else {
            WritingScene.bead(&canvas, at: chisel, radius: 4.5, inked: cutting || writing.penDown ? 1 : 0)
        }
        scene.drawSentence(in: &canvas)
    }
}
