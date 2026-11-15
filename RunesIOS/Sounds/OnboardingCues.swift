import UIKit

/// What setting up sounds and feels like. Each step forward plays the next note up one
/// scale with a tap, so setup climbs as it goes, and the last step lands on a chord. The
/// welcome ring's beads ring the same notes when a finger knocks them. The band connecting
/// lifts from G up to D, and the first index tap answers it: a chord home on G, a success
/// buzz on the band, and a success tap on the phone a moment after. Waiting is silent.
/// The phone and the band are given different parts. A connected band taps each step
/// forward. The phone keeps to what happens under the fingers and to the big moments, where
/// it answers the band or the band answers it, so the two are felt as a pair and not as
/// one thing twice. The wrist step has its own cues (`WristCues`).
@MainActor
final class OnboardingCues {
    static let shared = OnboardingCues()

    /// One note per bead and per step: G major pentatonic, the key of the wrist step's chord.
    static let notes = [293.66, 329.63, 392.00, 440.00, 493.88, 587.33, 659.25, 783.99]

    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let notice = UINotificationFeedbackGenerator()
    private var lastBead = Date.distantPast
    private var lastMoment = Date.distantPast

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

    /// Step `index` of `count` arrived. Going back is a light tap on the phone and no
    /// sound. A step that arrives because something just happened leaves the cue to that.
    /// The last step is the band's double buzz, then the phone's success tap.
    func step(_ index: Int, of count: Int, forward: Bool) {
        guard forward else { return light.impactOccurred(intensity: 0.5) }
        guard Date().timeIntervalSince(lastMoment) > 0.3 else { return }
        if index == count - 1 {
            ScoreAudio.shared.cue(.warm, pitch: 783.99, volume: 0.45)
            ScoreAudio.shared.cue(.bandDouble, volume: 1)
            after(0.4) { self.notice.notificationOccurred(.success) }
        } else {
            ScoreAudio.shared.cue(.kalimba, pitch: Self.notes[index % Self.notes.count], volume: 0.2)
            ScoreAudio.shared.cue(.bandTap, volume: 1)
        }
    }

    /// The band guide's card landed.
    func card() { soft.impactOccurred(intensity: 0.6) }

    /// Something went wrong and the step now says so.
    func trouble() { notice.notificationOccurred(.warning) }

    /// A band turned up in the list.
    func found() {
        lastMoment = Date()
        light.impactOccurred()
        ScoreAudio.shared.cue(.pip, pitch: 587.33, volume: 0.3)
    }

    /// The band connected and is waiting for a tap: the phone taps, and the band taps back.
    func connected() {
        lastMoment = Date()
        soft.impactOccurred()
        ScoreAudio.shared.cue(.lift, volume: 0.4)
        after(0.2) { ScoreAudio.shared.cue(.bandTap, volume: 1) }
    }

    /// The band heard a gesture, but not the one asked for.
    func heard() { light.impactOccurred(intensity: 0.6) }

    /// The index tap arrived: the band buzzes, and the phone answers.
    func passed() {
        lastMoment = Date()
        ScoreAudio.shared.cue(.resolve, volume: 0.5)
        ScoreAudio.shared.cue(.bandBuzz, volume: 1)
        after(0.25) { self.notice.notificationOccurred(.success) }
    }

    private func after(_ seconds: Double, _ play: @escaping @MainActor () -> Void) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            play()
        }
    }

    /// The wrist step's pulses on the band, for the walkthrough: the real ones only
    /// answer a real change of wrist.
    func band(_ phase: WristFeedbackPhase) {
        ScoreAudio.shared.cue(phase == .wrap ? .bandTap : .bandBuzz, volume: 1)
    }
}
