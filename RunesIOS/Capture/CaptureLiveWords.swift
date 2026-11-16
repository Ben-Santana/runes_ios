import AVFoundation
import Speech

/// The words of a recording as it is made, for the Live Activity. Only a preview: the
/// inscription's words are made from the finished file afterwards. Runs only when the
/// on-device model is already installed, so a recording never waits on a download.
///
/// Sound arrives on the audio thread and is converted on `queue`.
final class CaptureLiveWords: @unchecked Sendable {
    /// The words so far, on the main thread, each time they change.
    var onWords: (@MainActor (String) -> Void)?

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "capture.live-words")
    // Guarded by `lock`.
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    private var waiting: [AVAudioPCMBuffer] = []
    private var running = false

    private var analyzer: SpeechAnalyzer?
    private var results: Task<Void, Never>?

    @MainActor func start(locale: Locale = .current) {
        lock.withLock { running = true; waiting = [] }
        Task { @MainActor in
            do { try await open(locale) } catch { stop() }
        }
    }

    @MainActor private func open(_ locale: Locale) async throws {
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return stop() }
        let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        guard await AssetInventory.status(forModules: [module]) == .installed,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
              lock.withLock({ running }) else { return stop() }
        let analyzer = SpeechAnalyzer(modules: [module])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        results = Task { @MainActor [weak self] in
            var said = AttributedString(), saying = AttributedString()
            do {
                for try await result in module.results {
                    if result.isFinal { said += result.text; saying = AttributedString() } else { saying = result.text }
                    let words = String((said + saying).characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.onWords?(words)
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
        let backlog: [AVAudioPCMBuffer] = lock.withLock {
            guard running else { return [] }
            input = continuation; target = format
            defer { waiting = [] }
            return waiting
        }
        guard lock.withLock({ running }) else { continuation.finish(); return }
        backlog.forEach(feed)
    }

    /// A buffer of the recording, mono float at the microphone's rate. Called on the audio thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        let ready: Bool = lock.withLock {
            guard running else { return false }
            if input == nil {
                // Up to ten seconds while the model opens.
                if waiting.count < 250 { waiting.append(buffer) }
                return false
            }
            return true
        }
        guard ready else { return }
        queue.async { [weak self] in self?.convert(buffer) }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let input, let target else { return }
            if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: target) }
            guard let converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var given = false
            var failure: NSError?
            converter.convert(to: output, error: &failure) { _, state in
                if given { state.pointee = .noDataNow; return nil }
                given = true
                state.pointee = .haveData
                return buffer
            }
            if failure == nil, output.frameLength > 0 { input.yield(AnalyzerInput(buffer: output)) }
        }
    }

    @MainActor func stop() {
        let continuation: AsyncStream<AnalyzerInput>.Continuation? = lock.withLock {
            defer { input = nil; converter = nil; target = nil; waiting = []; running = false }
            return input
        }
        continuation?.finish()
        results?.cancel(); results = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
    }
}
