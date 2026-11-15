import CoreHaptics
import UIKit

/// The band's vibrations, felt on the phone as well. Whenever the app vibrates the band, the
/// phone plays the same pulses at the same strengths while the app is in front, so a buzz
/// is felt in the hand whether or not the band is connected. iOS gives apps no haptics in
/// the background, so there the band buzzes alone.
@MainActor
final class BandEcho {
    static let shared = BandEcho()

    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?

    private init() {}

    /// Plays `pulses` on the phone, replacing a pattern still playing, as the band does.
    func play(_ pulses: [BandPulse]) {
        guard !pulses.isEmpty, UIApplication.shared.applicationState == .active,
              CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        var start = 0.0
        let events = pulses.map { pulse in
            defer { start += Double(pulse.duration + pulse.gap) / 1000 }
            return CHHapticEvent(eventType: .hapticContinuous,
                                 parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(min(pulse.amplitude, 255)) / 255),
                                              CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
                                 relativeTime: start, duration: Double(pulse.duration) / 1000)
        }
        do {
            let engine = try self.engine ?? CHHapticEngine()
            if self.engine == nil {
                engine.playsHapticsOnly = true; engine.isAutoShutdownEnabled = true
                self.engine = engine
            }
            try engine.start()
            try? player?.stop(atTime: CHHapticTimeImmediate)
            player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            // The engine is made again on the next buzz.
            engine = nil
        }
    }
}
