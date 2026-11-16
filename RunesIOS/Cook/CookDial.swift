import Foundation

// The wrist as the dial of a kitchen timer: pinch the index finger and hold, turn the
// wrist, let go. The turn is estimated from the band's gyroscope the way Trace does it for
// its volume dial; it is relative and approximate, which a dial read by eye forgives.
// Foundation only (Tests/CookTests.swift).

/// Turns gyroscope samples into degrees turned about the axis the wrist first turns on.
struct WristDial {
    private(set) var engaged = false
    private var lastTime: UInt64?
    private var bias = [0.0, 0.0, 0.0]
    private var integral = [0.0, 0.0, 0.0]
    private var axis: Int?

    mutating func engage() { release(); engaged = true }
    mutating func release() { engaged = false; integral = [0, 0, 0]; axis = nil }

    /// Degrees turned since the sample before, once the turn has picked its axis.
    /// `timestamp` is the band's clock in microseconds.
    mutating func gyro(_ values: [Double], timestamp: UInt64) -> Double? {
        guard values.count >= 3 else { return nil }
        let previous = lastTime
        lastTime = timestamp
        // A gap means samples were lost; the turn in between is unknown.
        guard let previous, timestamp > previous, timestamp - previous <= 50_000 else { return nil }
        let dt = Double(timestamp - previous) / 1e6
        // The sensor's resting offset, learned while the hand is still and nothing is held.
        if !engaged, (0..<3).allSatisfy({ abs(values[$0] - bias[$0]) < 45 }) {
            for index in 0..<3 { bias[index] += (values[index] - bias[index]) * (1 - exp(-dt / 2)) }
        }
        guard engaged else { return nil }
        let delta = (0..<3).map { (values[$0] - bias[$0]) * 0.07 * dt }
        for index in 0..<3 { integral[index] += delta[index] }
        if let axis { return delta[axis] }
        // The first quarter of a degree decides which way the wrist is turning.
        guard let dominant = (0..<3).max(by: { abs(integral[$0]) < abs(integral[$1]) }), abs(integral[dominant]) >= 0.25 else { return nil }
        axis = dominant
        return integral[dominant]
    }
}

extension DialTime {
    /// A time as buzzes on the wrist, for asking how long is left without looking: a long
    /// one for every five minutes, then a tap for each minute over. Part of a minute counts as one.
    static func count(_ seconds: Int) -> [BandBuzz] {
        guard seconds > 0 else { return [] }
        let minutes = (seconds + 59) / 60
        return Array(repeating: .long, count: min(12, minutes / 5)) + Array(repeating: .tap, count: minutes % 5)
    }
}

/// Degrees of turn as time on a timer: small steps while the time is short, larger ones
/// once it is long, so a quarter turn reaches a few minutes and fine times stay settable.
struct DialTime {
    private var remainder = 0.0
    /// Degrees of turn for one step.
    static let degrees = 4.0

    static func step(at seconds: Int) -> Int { seconds < 120 ? 10 : seconds < 900 ? 30 : 60 }

    /// The time showing after a turn, a whole number of steps and never below nothing.
    mutating func turn(_ degrees: Double, from seconds: Int) -> Int {
        guard degrees.isFinite else { return seconds }
        if remainder * degrees < 0 { remainder = 0 }
        remainder += degrees
        var steps = Int((remainder / Self.degrees).rounded(.towardZero))
        remainder -= Double(steps) * Self.degrees
        var result = seconds
        while steps != 0, result < 86_400 {
            // Going down uses the step of the time just below, so 2:00 comes down to 1:50.
            let size = Self.step(at: steps > 0 ? result : result - 1)
            result = steps > 0 ? (result / size + 1) * size : max(0, (result - 1) / size * size)
            steps += steps > 0 ? -1 : 1
            if result == 0 { break }
        }
        return result
    }
}
