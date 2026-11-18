// Offline checks of how the band's own handwriting is read. No Bluetooth, no network.
// swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift RunesIOS/Persistence/IdentityStore.swift RunesIOS/Protocol/BandWriting.swift Tests/BandWritingTests.swift -o /private/tmp/runes-band-writing-tests && /private/tmp/runes-band-writing-tests
// The cases are the public band-core project's own. See THIRD_PARTY_NOTICES.md.
import Foundation

@main
struct BandWritingTests {
    static func row(_ best: Int, _ score: Float = 5) -> [Float] {
        var scores = [Float](repeating: 0, count: BandWriting.symbols)
        scores[best] = score
        return scores
    }

    static func main() throws {
        // The symbols, in the order the band's model scores them.
        precondition(BandWriting.symbol(0) == "a" && BandWriting.symbol(25) == "z" && BandWriting.symbol(26) == "A" && BandWriting.symbol(52) == "0")
        precondition(BandWriting.symbol(62) == "!" && BandWriting.symbol(93) == "~" && BandWriting.symbol(87) == "^" && BandWriting.symbol(88) == "_")
        precondition(BandWriting.symbol(96) == "▁" && BandWriting.symbol(94) == "⌫" && BandWriting.symbol(99) == "·")

        // Repeats merge, and a blank between two of the same letter keeps them apart.
        var decoder = BandWriting.Decoder()
        for index in [7, 7, BandWriting.blank, 4, 11, 11, BandWriting.blank, 11, 14, BandWriting.blank, BandWriting.blank] { decoder.push(row(index)) }
        precondition(decoder.symbols == "hello" && decoder.text == "hello" && decoder.rows == 11)
        // A pause between letters is noted and is not text.
        decoder = BandWriting.Decoder()
        for index in [0, BandWriting.pause, 1] { decoder.push(row(index)) }
        precondition(decoder.symbols == "ab" && decoder.text == "ab")

        // A symbol is judged on its surest row.
        decoder = BandWriting.Decoder()
        for scores in [row(4, 0.3), row(4, 4), row(4, 1), row(BandWriting.blank), row(7, 2), row(0, 1)] { decoder.push(scores) }
        precondition(decoder.finished == [BandWriting.Written(index: 4, margin: 4), BandWriting.Written(index: 7, margin: 2)])
        // An "o" read as o, O and 0 by turns is one sure o, though each row is split.
        var o = [Float](repeating: 0, count: BandWriting.symbols)
        o[14] = 3; o[40] = 2.8; o[BandWriting.zero] = 2.9
        decoder = BandWriting.Decoder()
        for scores in [o, row(40, 3), o, row(BandWriting.blank)] { decoder.push(scores) }
        precondition(decoder.finished.count == 1 && BandWriting.group(decoder.finished[0].index) == 14 && decoder.finished[0].margin >= 2.9)

        // The blank needs a clear lead: one point ahead of "a" loses after its handicap.
        var close = [Float](repeating: 0, count: BandWriting.symbols)
        close[BandWriting.blank] = 3; close[0] = 2
        precondition(BandWriting.best(close).index == 0)
        close[BandWriting.blank] = 4
        precondition(BandWriting.best(close).index == BandWriting.blank)

        // Ordinary text: spaces either way the band writes them, a delete, a new line, and
        // the two gesture symbols left out.
        decoder = BandWriting.Decoder()
        for index in [7, BandWriting.blank, 8, BandWriting.blank, BandWriting.underscore, BandWriting.blank, 23, BandWriting.blank, BandWriting.backspace, BandWriting.blank,
                      24, BandWriting.blank, BandWriting.space, BandWriting.blank, 98, BandWriting.blank, 14, BandWriting.blank, BandWriting.newline, BandWriting.blank] { decoder.push(row(index)) }
        precondition(decoder.text == "hi y o\n", decoder.text.debugDescription)
        // A row that is too short is ignored.
        precondition(decoder.push([1, 2, 3]) == nil)

        // The numbers in a message: little endian, four bytes each, a ragged end dropped.
        var bytes = Data()
        for value: Float in [1.5, -2, 0.25] { withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
        precondition(BandWriting.scores(bytes) == [1.5, -2, 0.25] && BandWriting.scores(bytes + Data([1, 2])) == [1.5, -2, 0.25] && BandWriting.scores(Data()).isEmpty)

        // The settings sent to the band, byte for byte: handwriting state with standby off, and
        // the usual state with the band's own standby time put back.
        precondition(BandWriting.state(on: true, standby: 30) == Data([0x30, 0x04, 0x68, 0x00, 0xa8, 0x01, 0x00]))
        precondition(BandWriting.state(on: false, standby: 30) == Data([0x30, 0x02, 0xa8, 0x01, 0x1e]))
        precondition(BandWriting.state(on: false, standby: nil) == Data([0x30, 0x02]))
        // The standby time in the settings the band reports.
        let settings = PB.field(1, 9) + PB.field(2, 1) + PB.field(6, PB.field(11, 3) + PB.field(21, 30) + PB.field(22, 60))
        precondition(BandWriting.standby(settings) == 30 && BandWriting.standby(PB.field(2, 1)) == nil)
        print("BandWritingTests passed")
    }
}
