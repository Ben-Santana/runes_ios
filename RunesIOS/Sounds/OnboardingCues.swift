import UIKit

/// What setting up sounds and feels like, kept to the moments that matter. The welcome
/// ring's beads each ring their own note when a finger knocks them. The band connecting
/// lifts from G up to D, and the first index tap answers it: a chord home on G, a success
/// tap on the phone and a buzz on the band. The wrist step has its own (`WristCues`).
@MainActor
final class OnboardingCues {
    static let shared = OnboardingCues()

    /// One note per bead: G major pentatonic, the key of the wrist step's chord.
    private static let notes = [293.66, 329.63, 392.00, 440.00, 493.88, 587.33, 659.25, 783.99]

    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let notice = UINotificationFeedbackGenerator()
    private var lastBead = Date.distantPast

    private init() {}

    /// Keeps the sound engine running while setup is in front, so no cue starts late.
    func setActive(_ on: Bool) {
        ScoreAudio.shared.setLive(on, for: "onboarding")
        if on { [soft, light].forEach { $0.prepare() } }
    }

    /// A finger knocked bead `index` aside; `strength` is 0…1. A touch that moves several
    /// beads at once sounds one note, and a finger running round the ring plays a run.
    func bead(_ index: Int, strength: Double) {
        guard Date().timeIntervalSince(lastBead) > 0.09 else { return }
        lastBead = Date()
        soft.impactOccurred(intensity: 0.35 + 0.45 * strength)
        ScoreAudio.shared.cue(.kalimba, pitch: Self.notes[index % Self.notes.count], volume: 0.18 + 0.2 * strength)
    }

    /// A band turned up in the list.
    func found() {
        light.impactOccurred()
        ScoreAudio.shared.cue(.pip, pitch: 587.33, volume: 0.3)
    }

    /// The band connected and is waiting for a tap.
    func connected() {
        soft.impactOccurred()
        ScoreAudio.shared.cue(.lift, volume: 0.4)
    }

    /// The band heard a gesture, but not the one asked for.
    func heard() { light.impactOccurred(intensity: 0.6) }

    /// The index tap arrived.
    func passed() {
        notice.notificationOccurred(.success)
        ScoreAudio.shared.cue(.resolve, volume: 0.5)
        ScoreAudio.shared.cue(.bandBuzz, volume: 1)
    }

    /// The wrist step's pulses on the band, for the walkthrough: the real ones only
    /// answer a real change of wrist.
    func band(_ phase: WristFeedbackPhase) {
        ScoreAudio.shared.cue(phase == .wrap ? .bandTap : .bandBuzz, volume: 1)
    }
}
