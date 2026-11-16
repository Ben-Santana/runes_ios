import Foundation

/// A point of a stroke in the unit writing box: across from the left, and down from the top.
struct WritingPoint: Equatable, Sendable {
    var x: Double, y: Double
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// What anything that reads handwriting tells the screen, in the order it happens. A reader
/// that follows the pen sends the pen events and then what it made of them. A reader that
/// only hears letters, as the band's own model would, sends `read` alone.
enum WritingEvent: Equatable, Sendable {
    /// The pen came down.
    case began(WritingPoint)
    /// The pen moved while down.
    case moved(WritingPoint)
    /// The pen lifted.
    case lifted
    /// The best reading of the letter still being written, and how sure the reader is, 0 to 1.
    case guessed(Character, sure: Double)
    /// The letter was read.
    case read(Character, sure: Double)
    /// What was written could not be read as a letter.
    case unread
    /// The last letter was taken back.
    case erased
    /// The word is finished.
    case finished
}

/// Where a piece of writing stands, for a screen to draw. Every change carries the time it
/// happened, so a screen can play each arrival once from the clock alone.
struct Writing: Equatable, Sendable {
    enum Phase: Sendable { case waiting, writing, read, unread, finished }

    struct Letter: Equatable, Sendable {
        var character: Character
        var sure: Double
        /// The strokes it was written with.
        var strokes: [[WritingPoint]]
        /// When it was read.
        var at: TimeInterval
    }

    private(set) var phase = Phase.waiting
    private(set) var phaseAt: TimeInterval = 0
    /// The phase the letter being written began from.
    private(set) var before = Phase.waiting
    /// The strokes of the letter being written. After a letter is not read they stay until
    /// the next one begins, so a screen can take them away.
    private(set) var strokes: [[WritingPoint]] = []
    private(set) var penDown = false
    private(set) var guess: Character?
    private(set) var sure = 0.0
    private(set) var letters: [Letter] = []

    var text: String { String(letters.map(\.character)) }

    /// One sentence for the phase, for the screen and for VoiceOver.
    var sentence: String {
        switch phase {
        case .waiting: "Write a letter."
        case .writing: guess.map { "Reading \($0)." } ?? "Writing."
        case .read: letters.last.map { "Read \($0.character)." } ?? ""
        case .unread: "Not read. Write it again."
        case .finished: "Written."
        }
    }

    mutating func apply(_ event: WritingEvent, at now: TimeInterval) {
        switch event {
        case .began(let point):
            if phase != .writing {
                // A new word starts on a clean page.
                if phase == .finished { letters = [] }
                before = phase == .finished ? .waiting : phase
                strokes = []; guess = nil; sure = 0
                enter(.writing, at: now)
            }
            strokes.append([point]); penDown = true
        case .moved(let point):
            guard penDown, !strokes.isEmpty else { return }
            strokes[strokes.count - 1].append(point)
        case .lifted:
            penDown = false
        case .guessed(let character, let sure):
            guard phase == .writing else { return }
            guess = character; self.sure = sure
        case .read(let character, let sure):
            if phase == .finished { letters = [] }
            // A reader that only hears letters has no strokes to give, so the letter is
            // kept in the app's own hand.
            let written = phase == .writing && !strokes.isEmpty ? strokes : LetterForms.strokes(for: character)
            letters.append(Letter(character: character, sure: sure, strokes: written, at: now))
            strokes = []; penDown = false; guess = character; self.sure = sure
            enter(.read, at: now)
        case .unread:
            // How sure the reader had been stays, so a screen can show it fall away.
            penDown = false
            enter(.unread, at: now)
        case .erased:
            guard !letters.isEmpty else { return }
            letters.removeLast(); strokes = []; penDown = false; guess = nil; sure = 0
            enter(letters.isEmpty ? .waiting : .read, at: now)
        case .finished:
            guard !letters.isEmpty else { return }
            strokes = []; penDown = false
            enter(.finished, at: now)
        }
    }

    private mutating func enter(_ next: Phase, at now: TimeInterval) { phase = next; phaseAt = now }
}
