import Foundation
import FoundationModels

/// Names inscriptions and chooses their scrolls with Apple Intelligence's on-device model.
/// Nothing leaves the phone. Where the model isn't available (an older phone, Apple
/// Intelligence off, the model still downloading) Capture titles from the first words and
/// leaves inscriptions loose.
enum CaptureScribe {
    enum Status: Equatable, Sendable {
        case ready
        case notEligible
        case turnedOff
        case downloading

        var sentence: String {
            switch self {
            case .ready: "Apple Intelligence names each inscription and files it in the set it belongs to, on this phone."
            case .notEligible: "This iPhone can’t run Apple Intelligence, so inscriptions are named from their first words and you file them yourself."
            case .turnedOff: "Turn on Apple Intelligence in Settings to have inscriptions named and filed for you. Until then they’re named from their first words."
            case .downloading: "Apple Intelligence is still getting ready on this phone. Inscriptions are named from their first words until it is."
            }
        }
    }

    static var status: Status {
        switch SystemLanguageModel.default.availability {
        case .available: .ready
        case .unavailable(.deviceNotEligible): .notEligible
        case .unavailable(.appleIntelligenceNotEnabled): .turnedOff
        case .unavailable: .downloading
        }
    }

    /// What the model made of one inscription.
    struct Reading: Sendable {
        var title: String?
        /// The id of the scroll it belongs in, when one fits.
        var scroll: String?
    }

    private static let none = "None of these"

    /// A title for the words and, when `scrolls` isn't empty, the scroll they belong in.
    static func read(_ text: String, scrolls: [CaptureScroll], titling: Bool = true) async -> Reading {
        // Without the model nothing is stored: the row shows the first words until the model
        // is ready and names it properly.
        guard status == .ready, titling || !scrolls.isEmpty else { return Reading() }
        let fallback = Reading(title: titling ? CaptureRules.fallbackTitle(text) : nil)
        let words = String(text.prefix(3_000))

        var properties: [DynamicGenerationSchema.Property] = []
        if titling {
            properties.append(.init(name: "title", description: "Two to six words naming what the inscription is about, in sentence case, without quotes or a full stop.",
                                    schema: DynamicGenerationSchema(type: String.self)))
        }
        if !scrolls.isEmpty {
            properties.append(.init(name: "scroll", description: "The scroll this inscription clearly belongs in, or “\(none)” when none clearly fits.",
                                    schema: DynamicGenerationSchema(name: "ScrollName", anyOf: scrolls.map(\.name) + [none])))
        }
        let shelf = scrolls.map { $0.purpose.isEmpty ? "- \($0.name)" : "- \($0.name): \($0.purpose)" }.joined(separator: "\n")
        let instructions = """
        You are the scribe of a voice notebook. Each voice note, called an inscription, is a short spoken thought written down by speech recognition, so expect missing punctuation and misheard words.
        \(titling ? "Give it a short, specific title that says what it is about, like a note's subject line. Use the speaker's own key words. Never start with “Note about” or “Reminder”." : "")
        \(scrolls.isEmpty ? "" : "Scrolls are the owner's folders. Only choose one when the inscription plainly belongs there; otherwise choose “\(none)”.")
        """
        do {
            let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Reading", properties: properties), dependencies: [])
            let session = LanguageModelSession(instructions: instructions)
            let prompt = scrolls.isEmpty ? "Inscription:\n\(words)" : "Scrolls:\n\(shelf)\n\nInscription:\n\(words)"
            let content = try await session.respond(to: prompt, schema: schema, options: GenerationOptions(temperature: 0.2)).content
            var reading = fallback
            if titling, let raw = try? content.value(String.self, forProperty: "title"), let title = CaptureRules.cleanTitle(raw) {
                reading.title = title
            }
            if !scrolls.isEmpty, let name = try? content.value(String.self, forProperty: "scroll") {
                reading.scroll = scrolls.first { $0.name == name }?.id
            }
            return reading
        } catch {
            #if DEBUG
            NSLog("Capture scribe: %@", String(describing: error))
            #endif
            return fallback
        }
    }

    /// The rune whose meaning best suits a scroll's name and purpose.
    static func rune(for name: String, purpose: String) async -> Rune {
        let fallback = Rune.fallback(for: name)
        guard status == .ready, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return fallback }
        let runes = Rune.allCases.map { "- \($0.name): \($0.meaning)" }.joined(separator: "\n")
        do {
            let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Choice", properties: [
                .init(name: "rune", schema: DynamicGenerationSchema(name: "RuneName", anyOf: Rune.allCases.map(\.name))),
            ]), dependencies: [])
            let session = LanguageModelSession(instructions: "Choose the Elder Futhark rune whose traditional meaning best matches a notebook folder.")
            let prompt = "Runes:\n\(runes)\n\nFolder: \(name)\(purpose.isEmpty ? "" : "\nWhat goes in it: \(purpose)")"
            let content = try await session.respond(to: prompt, schema: schema, options: GenerationOptions(temperature: 0.3)).content
            let chosen = try content.value(String.self, forProperty: "rune")
            return Rune.allCases.first { $0.name == chosen } ?? fallback
        } catch {
            return fallback
        }
    }
}
