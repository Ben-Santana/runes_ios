import Foundation

/// The band's own handwriting. In its handwriting state the band runs its handwriting model
/// on the wrist's signals and sends a row of scores many times a second, one score for each
/// symbol it knows. This reads those rows into symbols the way the Meta app does, as the
/// public band-core project worked it out: the best symbol of each row, repeats merged, the
/// blank dropped.
enum BandWriting {
    /// Scores in one row. The last is the blank, which stands for nothing being written.
    static let symbols = 100, blank = 99
    /// Sent while the writing pauses. It is kept apart from the text.
    static let pause = 87
    static let zero = 52, underscore = 88, space = 96, backspace = 94, newline = 95
    /// Added to the blank's score before choosing, as the Meta app's decoder is set up: ln 0.2.
    private static let blankBias: Float = -1.609_438
    private static let plain = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    /// What each score stands for, as the band's model lists them.
    static func symbol(_ index: Int) -> String {
        switch index {
        case 0..<94: return String(plain[index])
        case backspace: return "⌫"
        case newline: return "⏎"
        case space: return "▁"
        case 97: return "↑"
        case 98: return "🤏"
        default: return "·"
        }
    }

    /// The little endian numbers in one message from the band's model.
    static func scores(_ bytes: Data) -> [Float] {
        stride(from: 0, to: bytes.count - bytes.count % 4, by: 4).map { offset in
            Float(bitPattern: UInt32(bytes.octet(offset)) | UInt32(bytes.octet(offset + 1)) << 8 | UInt32(bytes.octet(offset + 2)) << 16 | UInt32(bytes.octet(offset + 3)) << 24)
        }
    }

    private static func biased(_ row: [Float], _ index: Int) -> Float { index == blank ? row[index] + blankBias : row[index] }

    /// The best symbol in a row, and how far it leads the next best.
    static func best(_ row: [Float]) -> (index: Int, margin: Float) {
        var first = (index: blank, score: -Float.infinity), second = -Float.infinity
        for index in 0..<min(row.count, symbols) {
            let score = biased(row, index)
            if score > first.score { second = first.score; first = (index, score) }
            else if score > second { second = score }
        }
        return (first.index, first.score - second)
    }

    /// Symbols that are one thing as written: a letter and its capital, o with 0, and the two spaces.
    static func group(_ index: Int) -> Int {
        switch index {
        case 26..<52: return index - 26
        case zero: return 14
        case underscore: return space
        default: return index
        }
    }

    /// How far the best score in a symbol's group leads the best outside it. An "o" the band
    /// cannot tell from "O" or "0" is still a sure "o".
    static func groupMargin(_ row: [Float], _ index: Int) -> Float {
        var inside = -Float.infinity, outside = -Float.infinity
        for other in 0..<min(row.count, symbols) {
            if group(other) == group(index) { inside = max(inside, biased(row, other)) } else { outside = max(outside, biased(row, other)) }
        }
        return inside - outside
    }

    /// One symbol the band wrote, at the row that was surest of it.
    struct Written: Equatable {
        let index: Int
        let margin: Float
    }

    /// Reads rows as they arrive into symbols and text.
    struct Decoder {
        private var last: Int?
        /// The symbol whose rows are still arriving.
        private var run: Written?
        /// Symbols whose rows have ended, each judged on its surest row. A symbol's first row is
        /// often unsure, and rows that swap between one letter's forms are one symbol.
        private(set) var finished: [Written] = []
        /// The symbols so far, as the band's model spells them.
        private(set) var symbols = ""
        private(set) var rows = 0

        /// One row of scores. Returns the symbol it begins, if it begins one.
        @discardableResult
        mutating func push(_ row: [Float]) -> Int? {
            guard row.count >= BandWriting.symbols else { return nil }
            rows += 1
            let (index, _) = BandWriting.best(row)
            let begins = index != BandWriting.blank && last != index
            let sure = index == BandWriting.blank ? 0 : BandWriting.groupMargin(row, index)
            if let current = run, index != BandWriting.blank, BandWriting.group(current.index) == BandWriting.group(index) {
                if sure > current.margin { run = Written(index: index, margin: sure) }
            } else {
                if let current = run { finished.append(current) }
                run = index == BandWriting.blank ? nil : Written(index: index, margin: sure)
            }
            last = index
            guard begins else { return nil }
            if index != BandWriting.pause { symbols += BandWriting.symbol(index) }
            return index
        }

        /// The finished symbols as ordinary text: a drawn space or underscore is a space, the
        /// delete symbol removes a character, and pauses and the two gesture symbols are left out.
        var text: String {
            var text = ""
            for written in finished + [run].compactMap({ $0 }) {
                switch written.index {
                case BandWriting.pause, 97, 98: continue
                case BandWriting.backspace: if !text.isEmpty { text.removeLast() }
                case BandWriting.newline: text += "\n"
                case BandWriting.space, BandWriting.underscore: text += " "
                default: text += BandWriting.symbol(written.index)
                }
            }
            return text
        }
    }

    /// The setting that puts the band in its handwriting state with standby off, as the Meta
    /// app does, or back in its usual state. `standby` is the band's own standby time to put back.
    static func state(on: Bool, standby: UInt64?) -> Data {
        if on { return PB.field(6, 4) + PB.field(13, 0) + PB.field(21, 0) }
        return PB.field(6, 2) + (standby.map { PB.field(21, $0) } ?? Data())
    }

    /// The band's standby time in seconds, from the settings it reports.
    static func standby(_ payload: Data) -> UInt64? {
        guard let config = try? Fields(Fields(payload).bytes(6)) else { return nil }
        return try? config.integer(21)
    }
}
