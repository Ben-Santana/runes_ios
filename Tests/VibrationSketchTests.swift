// swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift RunesIOS/Persistence/IdentityStore.swift Tests/VibrationSketchTests.swift -o /private/tmp/runes-vibration-sketch-tests && /private/tmp/runes-vibration-sketch-tests
// Checks how a finger drawing in the Vibration lab becomes band pulses. No Bluetooth.
import Foundation

@main
struct VibrationSketchTests {
    static func main() {
        precondition(BandPulse.sketch([]).isEmpty, "No drawing, no pulses")

        // A flat line across the whole pad: one pulse per slot at that strength.
        let flat = stride(from: 0.0, through: 1.0, by: 0.01).map { (x: $0, y: 0.5) }
        let steady = BandPulse.sketch(flat)
        precondition(steady.count == BandPulse.sketchSlots)
        precondition(steady.allSatisfy { $0.amplitude == 128 && $0.duration + $0.gap == UInt64(BandPulse.sketchSlot) })

        // Strength follows height, and leading silence is dropped.
        let ramp = stride(from: 0.5, through: 1.0, by: 0.01).map { (x: $0, y: ($0 - 0.5) * 2) }
        let rising = BandPulse.sketch(ramp)
        precondition(!rising.isEmpty && rising.first!.amplitude < rising.last!.amplitude, "Higher is stronger")

        // A quiet middle stretch becomes a longer pause, not a zero-strength pulse.
        let gapped = flat.filter { $0.x < 0.3 || $0.x > 0.7 }
        let split = BandPulse.sketch(gapped)
        precondition(split.allSatisfy { $0.amplitude >= BandPulse.sketchFloor })
        precondition(split.contains { $0.gap > UInt64(BandPulse.sketchSlot) }, "Silence lengthens the previous pause")
        precondition(split.count < steady.count)

        // Out-of-range touches are clamped, never wrap past 255.
        precondition(BandPulse.sketch([(x: 0.5, y: 3)]).first?.amplitude == 255)

        // The ring's eight steps: lit steps play for most of a step, unlit ones are silence.
        precondition(BandPulse.loop(steps: Array(repeating: 0, count: 8), stepLength: 100, laps: 2).isEmpty)
        let loop = BandPulse.loop(steps: [200, 0, 0, 100, 0, 0, 0, 0], stepLength: 100, laps: 2)
        precondition(loop.map(\.step) == [0, 3, 0, 3], "Each pulse remembers its bead")
        precondition(loop.map(\.pulse.amplitude) == [200, 100, 200, 100])
        precondition(loop[0].pulse.duration == 60 && loop[0].pulse.gap == 240, "Two unlit steps lengthen the pause")
        precondition(loop[0].pulse.duration + loop[0].pulse.gap + loop[1].pulse.duration + loop[1].pulse.gap == 800, "A lap is eight steps long")
        precondition(BandPulse.loop(steps: [999], stepLength: 100, laps: 1).first?.pulse.amplitude == 255)
        print("Vibration sketch checks passed: empty, steady, rising, gaps, clamping and ring loops.")
    }
}
