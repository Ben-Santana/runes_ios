import SwiftUI

struct HomeActions {
    var connect: () -> Void = {}
    var setUp: () -> Void = {}
    var openSettings: () -> Void = {}
    var openMappings: () -> Void = {}
    var openApplications: () -> Void = {}
    var resolve: (SessionIssue.Action) -> Void = { _ in }
}

/// One large ring, the band's link in the top corner, and the two places to go below.
struct HomeView: View {
    let status: BandStatus
    var actions = HomeActions()
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 12)
            Button(action: retry) {
                HairlineRing(phase: status.phase, gesture: status.gesture, entrance: true)
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RingButtonStyle())
            .accessibilityLabel("Band connection")
            .accessibilityValue(link.title)
            .accessibilityHint(link == .disconnected ? "Retries the connection." : "")
            .disabled(link != .disconnected)
            Spacer(minLength: 20)
            HStack(spacing: 12) {
                HomeCard(title: "Apps", action: actions.openApplications) { AppsMark() }
                HomeCard(title: "Gestures", action: actions.openMappings) { GesturesMark() }
            }
            .padding(.horizontal, Metric.gutter).padding(.bottom, 8)
        }
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 5)
        .onAppear { withAnimation(.entrance) { appeared = true } }
        .page()
    }

    private var link: BandLink {
        switch status.phase {
        case .connected: .connected
        case .connecting: .connecting
        default: .disconnected
        }
    }

    private var header: some View {
        HStack {
            ZStack(alignment: .leading) {
                if link == .connected {
                    batteryRing.transition(Self.swap)
                } else {
                    StatusTag(link: link, action: retry).transition(Self.swap)
                }
            }
            .animation(reduceMotion ? .standard : .spring(duration: 0.45, bounce: 0.2), value: link)
            Spacer()
            IconButton(.settings, action: actions.openSettings).accessibilityLabel("Settings")
        }
        .padding(.leading, Metric.gutter).padding(.trailing, 8).padding(.top, 4)
    }

    /// The battery and the status tag trade places in the corner with a blur and a small scale from the leading edge.
    private static let swap = AnyTransition.opacity
        .combined(with: .scale(scale: 0.85, anchor: .leading))
        .combined(with: .modifier(active: BlurOut(radius: 6), identity: BlurOut(radius: 0)))

    /// Band battery as a hairline ring followed by its percentage, at the leading edge of the header.
    private var batteryRing: some View {
        let level = status.battery.map { Double(min(max($0, 0), 100)) / 100 }
        return HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.rule, lineWidth: 2)
                Circle().trim(from: 0, to: level ?? 0)
                    .stroke(level.map { $0 <= 0.15 } == true ? Color.muted : Color.ink,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
            .animation(.standard, value: status.battery)
            Text(status.battery.map { "\($0)%" } ?? "—")
                .font(.caption).monospacedDigit().foregroundStyle(Color.muted)
                .contentTransition(.numericText())
        }
        .frame(minHeight: Metric.tap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Band battery")
        .accessibilityValue(status.battery.map { "\($0) percent" } ?? "Unknown")
    }

    /// The step that gets a disconnected band going again.
    private func retry() {
        switch status.phase {
        case .notSetUp: actions.setUp()
        case .attention: if let issue = status.issue { actions.resolve(issue.action) } else { actions.connect() }
        case .paused: actions.connect()
        case .connected, .connecting: break
        }
    }
}

private struct BlurOut: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

private enum BandLink: Equatable {
    case connected, connecting, disconnected
    var title: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .disconnected: "Disconnected"
        }
    }
}

/// The link in one word with a dot, in ink and hairline. Tapping it while disconnected retries.
private struct StatusTag: View {
    let link: BandLink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                ZStack {
                    if link == .connecting {
                        PulseDot(tint: .ink).transition(.opacity)
                    } else {
                        Circle().strokeBorder(Color.muted, lineWidth: 1.5).transition(.opacity)
                    }
                }
                .frame(width: 7, height: 7)
                Text(link.title).font(.caption).foregroundStyle(link == .connecting ? Color.ink : Color.muted)
                    .contentTransition(.interpolate)
            }
            .padding(.leading, 10).padding(.trailing, 12)
            .frame(minHeight: 28)
            .overlay(Capsule().strokeBorder(Color.rule, lineWidth: Metric.hairline))
            .frame(minHeight: Metric.tap)
            .contentShape(Rectangle())
        }
        .buttonStyle(RingButtonStyle())
        .allowsHitTesting(link == .disconnected)
        .animation(.standard, value: link)
        .accessibilityLabel("Band")
        .accessibilityValue(link.title)
        .accessibilityHint(link == .disconnected ? "Retries the connection." : "")
    }
}

/// One of the two destinations under the ring: a small bead mark, then its name.
private struct HomeCard<Mark: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder let mark: () -> Mark

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                mark().frame(height: 17, alignment: .leading).accessibilityHidden(true)
                Spacer(minLength: 28)
                Text(title).font(.heading).foregroundStyle(Color.ink)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 104)
            .panel()
            .contentShape(RoundedRectangle(cornerRadius: Metric.panel))
        }
        .buttonStyle(RingButtonStyle())
        .accessibilityLabel(title)
    }
}

/// Apps: one bead for each app, set as a small grid; the first in ink.
private struct AppsMark: View {
    var body: some View {
        Grid(horizontalSpacing: 5, verticalSpacing: 5) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        bead(row == 0 && column == 0)
                    }
                }
            }
        }
    }
    private func bead(_ lit: Bool) -> some View {
        Circle().strokeBorder(lit ? Color.ink : Color.faint, lineWidth: Metric.hairline)
            .background(Circle().fill(lit ? Color.ink : Color.clear))
            .frame(width: 6, height: 6)
    }
}

/// Gestures: three beads strung on a hairline, a combo read left to right.
private struct GesturesMark: View {
    var body: some View {
        HStack(spacing: 0) {
            bead(true)
            Rectangle().fill(Color.faint).frame(width: 12, height: Metric.hairline)
            bead(false)
            Rectangle().fill(Color.faint).frame(width: 12, height: Metric.hairline)
            bead(false)
        }
    }
    private func bead(_ lit: Bool) -> some View {
        Circle().strokeBorder(lit ? Color.ink : Color.faint, lineWidth: Metric.hairline)
            .background(Circle().fill(lit ? Color.ink : Color.clear))
            .frame(width: 6, height: 6)
    }
}

/// The ring gives under the finger slightly, without any fill or shadow.
private struct RingButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.standard, value: configuration.isPressed)
    }
}

/// The band-driven applications.
enum RunesApp: String, CaseIterable, Identifiable {
    case workouts, score, cook, capture, alarm, reels
    var id: String { rawValue }
    var title: String { switch self { case .workouts: "Workouts"; case .score: "Score"; case .cook: "Cook"; case .capture: "Scribe"; case .alarm: "Alarm"; case .reels: "Reels" } }
    var icon: Lucide { switch self { case .workouts: .dumbbell; case .score: .gamepad2; case .cook: .chefHat; case .capture: .mic; case .alarm: .bellRing; case .reels: .video } }
    var route: AppRoute { switch self { case .workouts: .workouts; case .score: .score; case .cook: .cook; case .capture: .capture; case .alarm: .alarm; case .reels: .reels } }
    /// The screens down to what is running in the app, or just its first screen when nothing is.
    @MainActor var runningPath: [AppRoute] {
        switch self {
        case .workouts: WorkoutStore.shared.run != nil ? [.workouts, .activeWorkout] : [.workouts]
        case .cook: CookStore.shared.session != nil ? [.cook, .cooking] : [.cook]
        default: [route]
        }
    }
}

/// An application's icon: a Lucide glyph, or for Scribe the voice rune.
struct AppIcon: View {
    let app: RunesApp
    var size: CGFloat = 22

    var body: some View {
        if app == .capture {
            IconStroke(path: InscriptionRune.voice.path).frame(width: size, height: size).accessibilityHidden(true)
        } else {
            LucideIcon(app.icon, size: size)
        }
    }
}
