import AVFoundation

/// A soft voice made from the Premium system speech voices only: the downloaded,
/// neural ones that sound natural. It slows and lowers the voice slightly and plays it
/// through a gentle filter: sibilance and harshness taken off the top, a little warmth
/// underneath, a breath of room. Sentences get short pauses between them.
@MainActor
final class SoftVoice: ObservableObject {
    struct Option: Identifiable, Hashable {
        let id: String
        let name: String
        let quality: AVSpeechSynthesisVoiceQuality
        let language: String

    }

    /// Picked first when nothing has been chosen yet.
    private static let preferred = ["Lee", "Zoe", "Ava", "Serena", "Matilda", "Jamie"]
    private static let chosenKey = "softVoice.voice"

    @Published private(set) var options: [Option] = []
    @Published var voiceID: String? {
        didSet { UserDefaults.standard.set(voiceID, forKey: Self.chosenKey) }
    }
    @Published private(set) var speaking = false

    /// 0…1 sliders, centred on the tuning that sounded best.
    @Published var pace = 0.5
    @Published var pitch = 0.5
    @Published var softening = true

    private let synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let filter = AVAudioUnitEQ(numberOfBands: 4)
    private let room = AVAudioUnitReverb()
    // Stereo: the room effect will not take mono.
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var converter: AVAudioConverter?
    private var wired = false
    /// Bumped on every `speak`/`stop`, so buffers from an earlier phrase are dropped.
    private var generation = 0
    private var pending = 0
    private var writing = 0

    init() {
        reload()
        shapeFilter()
    }

    var chosen: Option? { options.first { $0.id == voiceID } }

    /// The saved choice while it is still installed, otherwise the best one there is.
    func reload() {
        options = Self.premiumVoices()
        let saved = voiceID ?? UserDefaults.standard.string(forKey: Self.chosenKey)
        let keep = saved.flatMap { id in options.first { $0.id == id }?.id }
        if voiceID != keep ?? options.first?.id { voiceID = keep ?? options.first?.id }
    }

    static func premiumVoices() -> [Option] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.quality == .premium && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { Option(id: $0.identifier, name: $0.name.replacingOccurrences(of: #" \(Premium\)"#, with: "", options: .regularExpression), quality: $0.quality, language: $0.language) }
            .sorted { a, b in
                if a.language.hasPrefix("en") != b.language.hasPrefix("en") { return a.language.hasPrefix("en") }
                let ra = preferred.firstIndex(of: a.name) ?? preferred.count, rb = preferred.firstIndex(of: b.name) ?? preferred.count
                if ra != rb { return ra < rb }
                if (a.language == "en-US") != (b.language == "en-US") { return a.language == "en-US" }
                return a.name < b.name
            }
    }

    func speak(_ text: String) {
        stop()
        let sentences = Self.sentences(text)
        guard !sentences.isEmpty, let voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)),
              (try? start()) != nil else { return }
        let mine = generation
        speaking = true
        writing = sentences.count
        for (index, sentence) in sentences.enumerated() {
            let utterance = AVSpeechUtterance(string: sentence)
            utterance.voice = voice
            // Slightly under the default pace and pitch: unhurried, lower, warmer.
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(0.77 + pace * 0.3)
            utterance.pitchMultiplier = Float(0.88 + pitch * 0.2)
            utterance.volume = 0.9
            let pause = index == sentences.count - 1 ? 0 : Self.pause(after: sentence)
            synthesizer.write(utterance) { [weak self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                let copy = Handoff(buffer: Self.copy(pcm))
                Task { @MainActor in self?.receive(copy.buffer, pause: pause, generation: mine) }
            }
        }
    }

    func stop() {
        generation += 1
        synthesizer.stopSpeaking(at: .immediate)
        player.stop()
        converter?.reset()
        pending = 0
        writing = 0
        if speaking { speaking = false; AudioHub.release("voice") }
    }

    /// Re-applies the filter while speaking, so the switch can be compared live.
    func shapeFilter() {
        filter.bypass = !softening
        room.bypass = !softening
    }

    // MARK: Playback

    private func start() throws {
        if !wired {
            engine.attach(player); engine.attach(filter); engine.attach(room)
            engine.connect(player, to: filter, format: format)
            engine.connect(filter, to: room, format: format)
            engine.connect(room, to: engine.mainMixerNode, format: format)
            configureFilter()
            wired = true
        }
        try AudioHub.activate("voice")
        if !engine.isRunning { try engine.start() }
        player.play()
    }

    private func configureFilter() {
        let bands = filter.bands
        // Warmth: a little body under the voice.
        bands[0].filterType = .lowShelf; bands[0].frequency = 220; bands[0].gain = 2.5
        // Boxiness out of the low mids.
        bands[1].filterType = .parametric; bands[1].frequency = 650; bands[1].bandwidth = 1.2; bands[1].gain = -1.5
        // Harshness, where synthetic voices edge.
        bands[2].filterType = .parametric; bands[2].frequency = 3_200; bands[2].bandwidth = 1.0; bands[2].gain = -2.5
        // Sibilance and air: the hiss on s and t.
        bands[3].filterType = .highShelf; bands[3].frequency = 7_000; bands[3].gain = -6
        bands.forEach { $0.bypass = false }
        filter.globalGain = 1
        room.loadFactoryPreset(.smallRoom)
        room.wetDryMix = 7
    }

    private func receive(_ buffer: AVAudioPCMBuffer?, pause: TimeInterval, generation mine: Int) {
        guard mine == generation else { return }
        guard let buffer, buffer.frameLength > 0 else {
            // A sentence is written: leave its pause, and finish once the last one plays out.
            writing -= 1
            if pause > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pause * format.sampleRate)) {
                silence.frameLength = silence.frameCapacity
                schedule(silence, generation: mine)
            }
            finishIfDone()
            return
        }
        if let converted = convert(buffer) { schedule(converted, generation: mine) }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, generation mine: Int) {
        pending += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                self.pending -= 1
                self.finishIfDone()
            }
        }
    }

    private func finishIfDone() {
        guard speaking, writing <= 0, pending <= 0 else { return }
        speaking = false
        AudioHub.release("voice")
    }

    /// Speech comes in the voice's own format, often 16-bit at 22 kHz; the filter wants float stereo at 44.1.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    /// The synthesizer may reuse its buffers once the callback returns.
    nonisolated private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            if let src = from.mData, let dst = to.mData { memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize))) }
        }
        return out
    }

    // MARK: Phrasing

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty { out.append(sentence) }
        }
        return out
    }

    private static func pause(after sentence: String) -> TimeInterval {
        sentence.hasSuffix("?") || sentence.hasSuffix("!") ? 0.32 : sentence.hasSuffix("…") ? 0.45 : 0.26
    }
}

/// A copied buffer passed once from the synthesizer's thread to the main actor.
private struct Handoff: @unchecked Sendable { let buffer: AVAudioPCMBuffer? }
