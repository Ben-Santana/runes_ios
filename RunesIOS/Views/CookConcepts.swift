#if DEBUG
import SwiftUI

// Five directions for the cooking screen, drawn to be compared. They are sketches with
// fixed data, the salmon pasta twelve minutes in, and nothing here is wired to a recipe
// or a band. Each is a different answer to the same question: three things are on the
// heat at once, what does the cook need to see?

struct CookConcept: View {
    let index: Int
    @State private var began = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSince(began)
            Group {
                switch index {
                case 1: ScoreConcept(t: t)
                case 2: ClockConcept(t: t)
                case 3: TicketConcept(t: t)
                case 4: VerbConcept(t: t)
                default: StationsConcept(t: t)
                }
            }
        }
        .page()
    }
}

private func clock(_ seconds: Double) -> String { DurationFinder.clock(Int(max(0, seconds))) }

// MARK: 1. Score

/// The recipe as a score. Each pan is a stave, each job a bar on it as long as it takes,
/// and the present is a line the bars pass under. What overlaps is seen to overlap, and
/// what must be started for everything to land together is seen coming.
private struct ScoreConcept: View {
    let t: Double
    private struct Bar { let lane: Int; let start: Double; let length: Double; let name: String }
    private let lanes = ["Air fryer", "Pot", "Skillet", "Blender"]
    private let bars = [
        Bar(lane: 0, start: 0, length: 10, name: "Salmon"), Bar(lane: 1, start: 3, length: 11, name: "Penne"),
        Bar(lane: 1, start: 11, length: 3, name: "Broccoli"), Bar(lane: 2, start: 12, length: 7, name: "Mushrooms"),
        Bar(lane: 2, start: 19, length: 3, name: "Garlic, peas"), Bar(lane: 3, start: 16, length: 2, name: "Sauce"),
        Bar(lane: 2, start: 23, length: 3, name: "Bring together"),
    ]

    var body: some View {
        let now = 12 + t * 0.35
        VStack(alignment: .leading, spacing: 0) {
            Text("Now").font(.caption).foregroundStyle(Color.muted)
            Text("Cook the mushrooms until deeply browned.").font(.geist(34, .medium, relativeTo: .title)).tracking(-0.8).padding(.top, 6)
            (Text("8 oz ").fontWeight(.medium) + Text("sliced mushrooms").foregroundStyle(Color.muted)).font(.geist(20, relativeTo: .title3)).padding(.top, 12)
            Spacer(minLength: 20)
            HStack {
                Text("\(Int(now)) min in").font(.label)
                Spacer()
                Text("lands at 26").font(.caption).foregroundStyle(Color.muted)
            }
            GeometryReader { geo in
                let scale: CGFloat = 24, anchor: CGFloat = 100, row = geo.size.height / CGFloat(lanes.count)
                ZStack(alignment: .topLeading) {
                    ForEach(lanes.indices, id: \.self) { lane in
                        Rectangle().fill(Color.rule).frame(height: Metric.hairline).offset(y: row * CGFloat(lane) + row - 1)
                    }
                    ForEach(bars.indices, id: \.self) { index in
                        let bar = bars[index]
                        let x = anchor + CGFloat(bar.start - now) * scale, width = CGFloat(bar.length) * scale
                        let done = bar.start + bar.length < now, live = bar.start <= now && !done
                        ZStack(alignment: .leading) {
                            Rectangle().fill(live ? Color.ink : Color.clear)
                            Rectangle().strokeBorder(done ? Color.faint : Color.ink, lineWidth: 1.5)
                            Text(bar.name).font(.caption).lineLimit(1).padding(.horizontal, 6)
                                .foregroundStyle(live ? Color.paper : done ? Color.faint : Color.ink)
                        }
                        .frame(width: width, height: row - 14)
                        .offset(x: x, y: row * CGFloat(bar.lane) + 6)
                    }
                    Rectangle().fill(Color.paper).frame(width: 78)
                    ForEach(lanes.indices, id: \.self) { lane in
                        Text(lanes[lane]).font(.caption).foregroundStyle(Color.muted).frame(width: 74, height: row, alignment: .leading)
                            .offset(y: row * CGFloat(lane))
                    }
                    Rectangle().fill(Color.ink).frame(width: 2).offset(x: anchor - 1)
                }
                .clipped()
            }
            .frame(height: 250)
        }
        .padding(.horizontal, Metric.gutter).padding(.top, 70).padding(.bottom, 30)
    }
}

// MARK: 2. Clock

/// One instrument. The whole cook is a single dial: a hand sweeps round, each timer is
/// an arc on its own ring that the hand eats as it comes round, and the middle says what
/// to do. Nothing scrolls and nothing stacks.
private struct ClockConcept: View {
    let t: Double
    private let timers: [(name: String, ends: Double)] = [("Boil", 14.8), ("Mushrooms", 18.2), ("Salmon", 19.5)]

    var body: some View {
        let now = 12 + t * 0.35
        VStack(spacing: 26) {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height), radius = side / 2
                ZStack {
                    Canvas { context, size in
                        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                        for tick in 0..<60 {
                            let angle = Double(tick) * .pi / 30, long = tick % 5 == 0
                            var path = Path()
                            path.move(to: CGPoint(x: centre.x + sin(angle) * (radius - (long ? 12 : 6)), y: centre.y - cos(angle) * (radius - (long ? 12 : 6))))
                            path.addLine(to: CGPoint(x: centre.x + sin(angle) * radius, y: centre.y - cos(angle) * radius))
                            context.stroke(path, with: .color(long ? Color.ink : Color.faint), lineWidth: 1)
                        }
                    }
                    ForEach(timers.indices, id: \.self) { index in
                        let inset = 26 + CGFloat(index) * 20
                        // Once round is twenty minutes: what matters is the next few, not the hour.
                        Circle().trim(from: now / 20, to: min(1, max(now, timers[index].ends) / 20))
                            .stroke(Color.ink, style: StrokeStyle(lineWidth: index == 0 ? 12 : 6, lineCap: .butt))
                            .rotationEffect(.degrees(-90)).padding(inset)
                    }
                    Rectangle().fill(Color.ink).frame(width: 2, height: radius - 8).offset(y: -(radius - 8) / 2)
                        .rotationEffect(.degrees(now * 18))
                    Circle().fill(Color.paper).frame(width: side * 0.44, height: side * 0.44)
                    VStack(spacing: 2) {
                        Text(clock((timers[0].ends - now) * 60)).font(.geist(46, .medium, relativeTo: .largeTitle)).monospacedDigit().tracking(-1.5)
                        Text(timers[0].name).font(.label)
                    }
                }
                .frame(width: side, height: side).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 360)
            VStack(alignment: .leading, spacing: 10) {
                Text("Cook the mushrooms until deeply browned.").font(.geist(26, .medium, relativeTo: .title2)).tracking(-0.6)
                HStack(spacing: 16) {
                    ForEach(timers.indices, id: \.self) { index in
                        (Text(timers[index].name + " ").foregroundStyle(Color.muted) + Text(clock((timers[index].ends - now) * 60)).fontWeight(.medium))
                            .font(.label).monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.gutter).padding(.top, 70)
    }
}

// MARK: 3. Ticket

/// The pass of a restaurant kitchen. Every step is a ticket on the rail: the ones done
/// are struck through, the one in hand is printed large with what it needs and how long
/// it has, and the ones to come hang below. Set in one width of letter, like a printer's.
private struct TicketConcept: View {
    let t: Double

    private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    private func perforation() -> some View {
        Rectangle().fill(Color.clear).frame(height: 1)
            .overlay(Rectangle().stroke(Color.ink, style: StrokeStyle(lineWidth: 1, dash: [2, 5])).frame(height: 1))
            .padding(.vertical, 12)
    }

    var body: some View {
        let left = 372 - t
        let blocks = Int((left / 420 * 14).rounded())
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SALMON PASTA").font(mono(13, .semibold))
                Spacer()
                Text("SERVES 4  12:04").font(mono(13))
            }
            perforation()
            ForEach(["01 FRY SALMON", "02 BOIL PENNE"], id: \.self) { line in
                HStack {
                    Text(line).strikethrough(true, color: Color.muted)
                    Spacer()
                    Text("ON")
                }
                .font(mono(15)).foregroundStyle(Color.muted).padding(.vertical, 3)
            }
            perforation()
            Text("03").font(mono(15, .semibold))
            Text("COOK\nMUSHROOMS").font(mono(40, .bold)).tracking(-1).lineSpacing(-2).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("8 OZ SLICED MUSHROOMS")
                Text("MED-HIGH HEAT")
                Text("UNTIL DEEPLY BROWNED")
            }
            .font(mono(15)).padding(.top, 12)
            Text(clock(left)).font(mono(64, .bold)).tracking(-3).padding(.top, 14)
            Text(String(repeating: "█", count: max(0, blocks)) + String(repeating: "░", count: max(0, 14 - blocks)))
                .font(mono(20)).lineLimit(1)
            perforation()
            ForEach(["04 BLEND SAUCE", "05 BRING TOGETHER", "06 DIVIDE"], id: \.self) { line in
                Text(line).font(mono(15)).padding(.vertical, 3)
            }
            Spacer(minLength: 0)
            HStack {
                Text("FRY 07:32").font(mono(13))
                Spacer()
                Text("BOIL 02:46").font(mono(13, .semibold))
            }
        }
        .padding(.horizontal, 28).padding(.top, 70).padding(.bottom, 34)
    }
}

// MARK: 4. Verb

/// One word. The screen is ink and holds the verb as large as the phone is wide, what it
/// is done to, and the time. Everything else is on the wrist and in the ear: this is the
/// screen for a phone propped at the far end of the counter.
private struct VerbConcept: View {
    let t: Double

    var body: some View {
        let left = 372 - t
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<6, id: \.self) { step in
                    Rectangle().fill(Color.paper.opacity(step < 2 ? 0.45 : step == 2 ? 1 : 0.2)).frame(height: step == 2 ? 4 : 2)
                }
            }
            Spacer(minLength: 0)
            Text("BROWN").font(.geist(132, .semibold, relativeTo: .largeTitle)).tracking(-7).lineLimit(1).minimumScaleFactor(0.3)
            Text("the mushrooms").font(.geist(34, relativeTo: .title)).tracking(-0.8).opacity(0.7)
            Spacer(minLength: 0)
            Text(clock(left)).font(.geist(148, .medium, relativeTo: .largeTitle)).monospacedDigit().tracking(-8).lineLimit(1).minimumScaleFactor(0.3)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.paper.opacity(0.25)).frame(height: 2)
                    Rectangle().fill(Color.paper).frame(width: geo.size.width * left / 420, height: 4)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 4)
            HStack {
                Text("then: garlic, peas, spinach").font(.label).opacity(0.7)
                Spacer()
                Text("2 more going").font(.label).opacity(0.7)
            }
            .padding(.top, 14)
        }
        .foregroundStyle(Color.paper)
        .padding(.horizontal, Metric.gutter).padding(.top, 76).padding(.bottom, 40)
        .background(Color.ink.ignoresSafeArea())
    }
}

// MARK: 5. Stations

/// The kitchen itself. The screen is a plan of the hob, the oven and the board, and each
/// thing on the go sits where it really is, with its time in the ring of its own burner.
/// The wrist points at a station to pick it; the step is a line underneath.
private struct StationsConcept: View {
    let t: Double

    private func burner(_ name: String, _ time: Double?, total: Double, pointed: Bool = false) -> some View {
        ZStack {
            Circle().strokeBorder(Color.rule, lineWidth: 1)
            if let time {
                Circle().trim(from: 0, to: max(0.01, time / total)).stroke(Color.ink, style: StrokeStyle(lineWidth: pointed ? 9 : 4, lineCap: .butt))
                    .rotationEffect(.degrees(-90)).padding(pointed ? 4.5 : 2)
                VStack(spacing: 0) {
                    Text(clock(time)).font(.geist(26, .medium, relativeTo: .title2)).monospacedDigit().tracking(-0.8)
                    Text(name).font(.caption).foregroundStyle(Color.muted)
                }
            } else {
                Circle().strokeBorder(Color.faint, style: StrokeStyle(lineWidth: 1, dash: [2, 4])).padding(16)
            }
        }
        .frame(width: 132, height: 132)
    }

    var body: some View {
        let cook = 372 - t, boil = 166 - t, fry = 452 - t
        VStack(alignment: .leading, spacing: 0) {
            Text("Cook the mushrooms until deeply browned.").font(.geist(26, .medium, relativeTo: .title2)).tracking(-0.6)
            Spacer(minLength: 16)
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    burner("", nil, total: 1)
                    burner("Pot · boil", boil, total: 660)
                }
                HStack(spacing: 14) {
                    burner("Skillet · brown", cook, total: 420, pointed: true)
                    burner("", nil, total: 1)
                }
            }
            .padding(14)
            .overlay(RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.ink, lineWidth: 1.5))
            .frame(maxWidth: .infinity)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Air fryer").font(.caption).foregroundStyle(Color.muted)
                    Text(clock(fry)).font(.geist(26, .medium, relativeTo: .title2)).monospacedDigit()
                    GeometryReader { geo in Rectangle().fill(Color.ink).frame(width: geo.size.width * fry / 600, height: 4) }.frame(height: 4)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.ink, lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Blender").font(.caption).foregroundStyle(Color.muted)
                    Text("next").font(.geist(26, .medium, relativeTo: .title2)).foregroundStyle(Color.faint)
                    Rectangle().fill(Color.rule).frame(height: 4)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.rule, lineWidth: 1))
            }
            .padding(.top, 14)
            HStack(spacing: 8) {
                LucideIcon(.hand, size: 16)
                Text("Point your wrist at a station. Pinch to start, stop or dial it.").font(.caption)
            }
            .foregroundStyle(Color.muted).padding(.top, 16)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.gutter).padding(.top, 70).padding(.bottom, 30)
    }
}
#endif
