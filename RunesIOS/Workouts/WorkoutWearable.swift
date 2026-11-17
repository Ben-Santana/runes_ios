import Foundation

// A wearable worn along with the band: which one, on which wrist, and the heart rate it shares.
// Any watch, band or strap that shares heart rate the standard Bluetooth way can be linked.
// These are plain values, checked without Bluetooth. HeartRateLink.swift does the radio work.

extension Handedness: Codable {}

/// The wearable the person chose to link. Nothing is linked, searched for or asked until they say so.
struct Wearable: Codable, Hashable, Sendable {
    /// This phone's identifier for the sensor. It means nothing on another device.
    var id: String
    var name: String
    /// The wrist it is worn on. nil for a chest strap or anything else not on a wrist.
    var wrist: Handedness?

    /// Where both are worn, in words, given the wrist the band is set for.
    func placement(band: Handedness?) -> String {
        let worn = wrist.map { "\(name) on your \($0.rawValue) wrist" } ?? "\(name), not on a wrist"
        guard let band else { return "\(worn)." }
        return "Band on your \(band.rawValue) wrist, \(worn)."
    }
}

/// A heart rate sensor found nearby while linking.
struct HeartSensor: Hashable, Identifiable, Sendable {
    var id: String
    var name: String
}

/// What the link to the wearable is doing.
enum HeartLinkState: Hashable, Sendable {
    case idle
    /// Bluetooth is off or not allowed for Runes.
    case unavailable
    case searching
    /// Waiting for the linked wearable to come into range and share.
    case waiting
    case live
}

/// One measurement from the Bluetooth Heart Rate service.
enum HeartRateReading {
    static let plausible = 30...240

    /// Beats a minute. nil when the packet is short, the sensor reports no skin contact,
    /// or the number is not a pulse.
    static func beats(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        // Bit 2 says the sensor can tell whether it touches skin, bit 1 whether it does.
        if flags & 0x04 != 0, flags & 0x02 == 0 { return nil }
        let value: Int
        if flags & 0x01 == 0 {
            guard bytes.count >= 2 else { return nil }
            value = Int(bytes[1])
        } else {
            guard bytes.count >= 3 else { return nil }
            value = Int(bytes[1]) | Int(bytes[2]) << 8
        }
        return plausible.contains(value) ? value : nil
    }
}

struct HeartSample: Hashable, Sendable {
    var at: Date
    var beats: Int
}

/// The heart rate of one workout. Sensors report about once a second; one reading every
/// few seconds is kept, which is plenty for a workout and keeps Health light.
struct HeartLog: Sendable {
    static let spacing: TimeInterval = 5
    private(set) var samples: [HeartSample] = []

    mutating func add(_ beats: Int, at date: Date) {
        if let last = samples.last, date.timeIntervalSince(last.at) < Self.spacing { return }
        samples.append(HeartSample(at: date, beats: beats))
    }

    /// The readings taken from `start` to `end`.
    func within(_ start: Date, _ end: Date) -> [HeartSample] { samples.filter { $0.at >= start && $0.at <= end } }
}

/// What the journal keeps of a workout's heart rate. The readings themselves go to Health.
struct HeartSummary: Codable, Hashable, Sendable {
    var average: Int
    var peak: Int

    /// nil without a reading.
    init?(_ samples: [HeartSample]) {
        guard let peak = samples.map(\.beats).max() else { return nil }
        self.peak = peak
        average = Int((Double(samples.reduce(0) { $0 + $1.beats }) / Double(samples.count)).rounded())
    }

    var text: String { "avg \(average) bpm" }
}
