import UIKit

/// What the band guide sounds and feels like. Each plate plays its cues once as it arrives,
/// in time with its drawing, and then keeps quiet. The phone and a connected band have
/// different parts. Where the drawn band lands on the wrist, only the band taps. A drawn
/// finger touching the thumb is a click on the phone, and the band answers a moment later,
/// as the drawn band does when the signal reaches it. Button holds and charging are the
/// phone's alone. The plate about the light is silent.
@MainActor
final class GuideCues {
    static let shared = GuideCues()

    enum Cue {
        /// The band settles on the wrist.
        case lands
        /// A finger (0 index, 1 middle) taps the thumb.
        case press(finger: Int)
        /// A finger stays down on the thumb.
        case hold
        /// The band hears a press, or the start of a hold.
        case answer(held: Bool)
        /// A hold of the button, counted from 0, has run its time.
        case held(Int)
        /// A bead of the charging row fills.
        case fills(Int)
        /// The charging row is full.
        case full
    }

    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notice = UINotificationFeedbackGenerator()
    private var active = false

    private init() {}

    /// Keeps the sound engine running while the guide is in front, so no cue starts late.
    func setActive(_ on: Bool) {
        active = on
        ScoreAudio.shared.setLive(on, for: "guide")
        if on { [soft, light, rigid].forEach { $0.prepare() } }
    }

    /// Plays `score` in time: each cue falls `at` seconds after `start`. A cue whose moment
    /// has already gone by is left out.
    func play(_ score: [(at: Double, cue: Cue)], since start: Date) async {
        for (at, cue) in score.sorted(by: { $0.at < $1.at }) {
            let wait = start.addingTimeInterval(at).timeIntervalSinceNow
            guard wait > -0.15 else { continue }
            do { try await Task.sleep(for: .seconds(max(0, wait))) } catch { return }
            if active { play(cue) }
        }
    }

    private func play(_ cue: Cue) {
        let audio = ScoreAudio.shared
        switch cue {
        case .lands:
            audio.cue(.pop, pitch: 293.66, volume: 0.3)
            audio.cue(.bandTap, volume: 1)
        case .press(let finger):
            light.impactOccurred()
            audio.cue(.pip, pitch: finger == 0 ? 587.33 : 493.88, volume: 0.3)
        case .hold:
            rigid.impactOccurred(intensity: 0.8)
            audio.cue(.soft, pitch: 392, volume: 0.35)
        case .answer(let held):
            audio.cue(held ? .bandLong : .bandTap, volume: 1)
        case .held(let index):
            light.impactOccurred(intensity: min(1, 0.5 + 0.15 * Double(index)))
        case .fills(let index):
            soft.impactOccurred(intensity: 0.4)
            audio.cue(.kalimba, pitch: OnboardingCues.notes[index % OnboardingCues.notes.count], volume: 0.16)
        case .full:
            notice.notificationOccurred(.success)
            audio.cue(.resolve, volume: 0.4)
        }
    }
}
