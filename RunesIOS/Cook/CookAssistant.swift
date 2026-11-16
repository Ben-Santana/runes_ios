import AVFoundation
import FoundationModels
import UIKit

/// Hears a question, answers it from the recipe with the model on the phone, and says the
/// answer. Nothing leaves the phone: the speech models and the language model are the
/// system's own. The microphone is opened only while a question is being asked, through
/// the shared audio session, and only with Runes in front.
@MainActor
final class CookAssistant: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Phase: Equatable {
        case idle, listening
        /// The question as heard; empty until the words are known.
        case thinking(question: String)
        case answered(question: String, answer: String)
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle
    /// How loud the voice is while listening, 0 to 1.
    @Published private(set) var level: Float = 0
    /// Whether an answer is said aloud as well as shown.
    var speaks = true
    /// The recipe being cooked when the answer is worked out.
    var recipe: () -> CookSession? = { nil }

    private let recorder = CaptureRecorder()
    private let voice = AVSpeechSynthesizer()
    private var work: Task<Void, Never>?
    private var clearing: Task<Void, Never>?
    private static let clip = FileManager.default.temporaryDirectory.appendingPathComponent("cook-question.m4a")
    private static let microphone = "cook-ask", speech = "cook-voice"
    /// A question nobody ends is ended for them.
    private static let longest = 15.0

    override init() {
        super.init()
        voice.delegate = self
        recorder.onLevel = { [weak self] level in Task { @MainActor in self?.level = level } }
    }

    #if DEBUG
    /// A fixed state for screenshots and previews.
    init(preview phase: Phase) {
        super.init()
        self.phase = phase
    }
    #endif

    #if DEBUG
    /// For the recorded walkthrough.
    func show(_ phase: Phase, level: Float = 0) { self.phase = phase; self.level = level }
    #endif

    var isListening: Bool { phase == .listening }
    var isBusy: Bool { phase != .idle }

    /// Opens the microphone for a question.
    func listen() {
        guard phase != .listening else { return }
        dismiss()
        guard UIApplication.shared.applicationState == .active else { return }
        guard AudioHub.microphone == nil else { fail("Capture has the microphone. Stop it, then ask."); return }
        phase = .listening
        work = Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                fail("Runes needs the microphone to hear a question. Allow it in Settings."); return
            }
            guard phase == .listening, !Task.isCancelled else { return }
            do {
                AudioHub.setMicrophone(.phone)
                try AudioHub.activate(Self.microphone)
                try recorder.start()
                try? FileManager.default.removeItem(at: Self.clip)
                try recorder.begin(to: Self.clip, preroll: 0)
                recorder.measuresLevel = true
            } catch {
                closeMicrophone()
                fail("The microphone couldn’t be opened.")
                return
            }
            try? await Task.sleep(for: .seconds(Self.longest))
            if !Task.isCancelled, phase == .listening { finish() }
        }
    }

    /// The question is over: turns what was said into words and answers it.
    func finish() {
        guard phase == .listening else { return }
        work?.cancel()
        let clip = recorder.end()
        closeMicrophone()
        guard let clip, clip.duration > 0.5 else { phase = .idle; return }
        phase = .thinking(question: "")
        work = Task {
            let heard = ((try? await CaptureTranscriber.transcribe(clip.url)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: clip.url)
            guard !Task.isCancelled else { return }
            guard !heard.isEmpty else { fail("Runes didn’t catch that. Hold and ask again."); return }
            await answer(heard)
        }
    }

    /// Answers a question already in words.
    func ask(_ question: String) {
        dismiss()
        work = Task { await answer(question) }
    }

    /// Stops listening, thinking or speaking and clears the answer.
    func dismiss() {
        work?.cancel(); work = nil
        clearing?.cancel(); clearing = nil
        if phase == .listening { _ = recorder.end(); closeMicrophone() }
        if voice.isSpeaking { voice.stopSpeaking(at: .immediate) }
        phase = .idle
    }

    private func answer(_ question: String) async {
        guard let session = recipe() else { phase = .idle; return }
        switch RecipeModel.availability {
        case .ready: break
        case .downloading: fail("The model that answers is still downloading. Try again in a while."); return
        default: fail("Questions are answered by Apple Intelligence, which is off on this phone."); return
        }
        phase = .thinking(question: question)
        do {
            let model = LanguageModelSession(instructions: CookAsk.instructions)
            var said = ""
            for try await part in model.streamResponse(to: CookAsk.context(session) + "\n\nQuestion: " + question) {
                guard !Task.isCancelled else { return }
                said = part.content
                if !said.isEmpty { phase = .answered(question: question, answer: said) }
            }
            guard !said.isEmpty else { fail("That one couldn’t be answered. Ask it another way."); return }
            if speaks { say(said) } else { clear(after: 20) }
        } catch {
            if !Task.isCancelled { fail("That one couldn’t be answered. Ask it another way.") }
        }
    }

    private func say(_ text: String) {
        try? AudioHub.activate(Self.speech)
        voice.speak(AVSpeechUtterance(string: text))
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        clear(after: 8)
    }

    /// The answer stays up long enough to read again, then the step comes back.
    private func clear(after seconds: Double) {
        clearing?.cancel()
        clearing = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { phase = .idle }
        }
    }

    /// Says a step as it arrives, unless a question is in the way.
    func read(_ text: String) {
        guard phase == .idle else { return }
        if voice.isSpeaking { voice.stopSpeaking(at: .immediate) }
        say(text)
    }

    private func closeMicrophone() {
        recorder.measuresLevel = false
        level = 0
        recorder.stop()
        AudioHub.setMicrophone(nil)
        AudioHub.release(Self.microphone)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.spoke() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in AudioHub.release(Self.speech) }
    }
    private func spoke() {
        AudioHub.release(Self.speech)
        if case .answered = phase { clear(after: 12) }
    }
}
