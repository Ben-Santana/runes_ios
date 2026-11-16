import SwiftUI

// What Cook prints. The step is a ticket off a kitchen printer, in one width of letter,
// a sentence at a time, under the loop of beads (CookBeadLoop.swift). The finished cook
// is a receipt: what was made, each step and where it was done, how long it took.

func ticketFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

/// A line of dashes, where a ticket would tear.
struct Perforation: View {
    var body: some View {
        Rectangle().fill(Color.clear).frame(height: 1)
            .overlay(Rectangle().stroke(Color.ink, style: StrokeStyle(lineWidth: 1, dash: [2, 5])).frame(height: 1))
            .accessibilityHidden(true)
    }
}

// MARK: The ticket

/// The step as a ticket off the printer: its number and where it happens, its sentences
/// as a row of beads, one sentence in capitals, the amounts it calls for, and what
/// follows. A new sentence feeds out from under the tear line.
struct Ticket: View {
    let session: CookSession
    let plan: StationPlan
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let beats = session.beats, index = session.beatIndex, sentence = beats[index]
        let uses = Ingredients.uses(in: sentence, of: session.recipe.ingredients).map(\.text)
        let spot = plan.spot(step: session.step)
        VStack(alignment: .leading, spacing: 0) {
            Perforation()
            HStack(spacing: 10) {
                Text(String(format: "%02d/%02d", session.step + 1, session.count))
                Text(spot.vessel.uppercased())
                Spacer()
                if beats.count > 1 { SentenceBeads(count: beats.count, index: index) }
            }
            .font(ticketFont(13, .semibold)).padding(.top, 12)
            VStack(alignment: .leading, spacing: 10) {
                TicketSetting(sentence: sentence)
                if !uses.isEmpty {
                    VStack(alignment: .leading, spacing: 2) { ForEach(uses.prefix(3), id: \.self) { Text($0.uppercased()) } }
                        .font(ticketFont(15))
                }
            }
            .padding(.top, 10)
            .id("\(session.step).\(index)")
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            Spacer(minLength: 10)
            Perforation()
            HStack(spacing: 10) {
                Text(session.isLast && index == beats.count - 1 ? "LAST" : "NEXT")
                if index < beats.count - 1 {
                    Text(beats[index + 1].uppercased()).lineLimit(1)
                } else if !session.isLast {
                    Text(String(format: "%02d", session.step + 2) + " " + plan.spot(step: session.step + 1).vessel.uppercased()).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(ticketFont(13)).foregroundStyle(Color.muted).padding(.top, 10)
        }
        .padding(.horizontal, Metric.gutter + 4)
        .clipped()
        .animation(reduceMotion ? nil : .entrance, value: index)
        .animation(reduceMotion ? nil : .entrance, value: session.step)
        .accessibilityElement(children: .combine)
    }
}

/// A sentence of a step set the way a poster is: the word that says what to do, as large
/// as the ticket is wide, and the rest under it with each time printed white on ink and
/// each heat underlined, so both are found again at a glance from the stove.
struct TicketSetting: View {
    let sentence: String

    /// The opening word, and "air fry" as the one thing it is.
    private var parts: (head: String, rest: String) {
        let words = sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first else { return ("", "") }
        let take = words.count > 1 && first.lowercased() == "air" && words[1].lowercased().hasPrefix("fry") ? 2 : 1
        let head = words.prefix(take).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;:."))
        return (head, words.dropFirst(take).joined(separator: " "))
    }

    private func marked(_ rest: String) -> AttributedString {
        var text = AttributedString(rest)
        for heat in StepDetails.heat(in: rest) {
            if let range = Range(heat, in: text) { text[range].underlineStyle = Text.LineStyle(pattern: .solid, color: Color.ink) }
        }
        for time in DurationFinder.find(in: rest) {
            guard let range = Range(NSRange(location: time.location, length: time.length), in: text) else { continue }
            text[range].backgroundColor = Color.ink
            text[range].foregroundColor = Color.paper
        }
        return text
    }

    var body: some View {
        let parts = parts
        VStack(alignment: .leading, spacing: 2) {
            // One width of letter, so the size that fills the line follows from the count.
            Text(parts.head.uppercased())
                .font(ticketFont(min(76, 520 / CGFloat(max(4, parts.head.count))), .black)).tracking(-2)
                .lineLimit(1).minimumScaleFactor(0.4)
            if !parts.rest.isEmpty {
                Text(marked(parts.rest)).textCase(.uppercase)
                    .font(ticketFont(parts.rest.count < 70 ? 21 : parts.rest.count < 120 ? 18 : 16, .bold)).lineSpacing(3)
                    .minimumScaleFactor(0.75).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sentence)
    }
}

// MARK: The receipt

/// The cook, printed: what was made, each step and where it was done, how long it took,
/// and the notes to keep. It is what the finished screen shows in this look.
struct CookReceipt: View {
    let session: CookSession
    /// When the cook ended; now, while it is on the finished screen.
    var ended = Date()
    /// Nil for a receipt from the past, which is only read.
    let addNote: (() -> Void)?
    @State private var bow: BandGesture?

    var body: some View {
        let plan = StationPlan(steps: session.recipe.steps)
        let minutes = max(1, Int(ended.timeIntervalSince(session.started) / 60))
        VStack(alignment: .leading, spacing: 0) {
            // The ring of beads signs the receipt, and takes a bow when it is printed.
            HairlineRing(phase: .connected, gesture: bow).frame(height: 150).frame(maxWidth: .infinity)
                .padding(.bottom, 6).accessibilityHidden(true)
                .onAppear { bow = BandGesture(id: 1, kind: .doubleTap, finger: 2, at: Date()) }
            Text(session.recipe.title.uppercased()).font(ticketFont(22, .bold)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(session.started.formatted(date: .abbreviated, time: .shortened).uppercased())
                Spacer()
                Text((session.recipe.yield ?? "").uppercased())
            }
            .font(ticketFont(13)).padding(.top, 6)
            Perforation().padding(.vertical, 12)
            ForEach(Array(session.recipe.steps.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 8) {
                    Text(String(format: "%02d", index + 1))
                    Text(plan.spot(step: index).vessel.uppercased())
                    Text(String(repeating: ".", count: 40)).lineLimit(1).foregroundStyle(Color.faint)
                    Text("DONE").fixedSize()
                }
                .font(ticketFont(15)).padding(.vertical, 3)
            }
            Perforation().padding(.vertical, 12)
            HStack {
                Text("TOTAL")
                Spacer()
                Text("\(minutes) MIN")
            }
            .font(ticketFont(22, .bold))
            if let notes = session.recipe.notes, !notes.isEmpty {
                Perforation().padding(.vertical, 12)
                ForEach(notes, id: \.self) { Text("* " + $0.uppercased()).font(ticketFont(13)).padding(.vertical, 2).fixedSize(horizontal: false, vertical: true) }
            }
            Perforation().padding(.vertical, 12)
            if let addNote {
                Button(action: addNote) { Text("+ ADD A NOTE FOR NEXT TIME").font(ticketFont(13, .semibold)).frame(minHeight: Metric.tap) }
                    .buttonStyle(PressRow())
            }
            // A bar code, because a receipt has one: the same recipe always prints the same.
            Canvas { context, size in
                var seed = UInt64(truncatingIfNeeded: session.recipe.title.hashValue) | 1, x: CGFloat = 0
                while x < size.width {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let width = CGFloat(1 + (seed >> 60) % 3)
                    context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(Color.ink))
                    x += width + CGFloat(1 + (seed >> 56) % 4)
                }
            }
            .frame(height: 44).padding(.top, 8).accessibilityHidden(true)
            Text("ENJOY.").font(ticketFont(13, .semibold)).frame(maxWidth: .infinity).padding(.top, 10)
        }
        .padding(.horizontal, Metric.gutter + 4).padding(.vertical, 20)
    }
}
