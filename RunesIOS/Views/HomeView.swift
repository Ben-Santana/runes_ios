import SwiftUI

struct HomeActions {
    var connect: () -> Void = {}
    var disconnect: () -> Void = {}
    var setUp: () -> Void = {}
    var openSettings: () -> Void = {}
    var openMappings: () -> Void = {}
    var openApplications: () -> Void = {}
    var resolve: (SessionIssue.Action) -> Void = { _ in }
}

/// One large ring, its state in words, the band's facts, and the Mac link.
struct HomeView: View {
    let status: BandStatus
    var actions = HomeActions()
    @State private var confirmDisconnect = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 12)
            Button(action: ringTapped) {
                HairlineRing(phase: status.phase, gesture: status.gesture, entrance: true)
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RingButtonStyle())
            .accessibilityLabel("Band connection")
            .accessibilityValue(status.phase.title)
            .accessibilityHint(ringHint)
            .disabled(status.phase == .connecting)

            VStack(spacing: 8) {
                Text(status.phase.title).font(.display).tracking(-0.6)
                    .contentTransition(.opacity)
                if !showsIssueCard {
                    Text(status.detail).font(.bodyText).foregroundStyle(Color.muted)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                }
            }
            .padding(.horizontal, Metric.gutter)
            .accessibilityElement(children: .combine)
            .animation(.standard, value: status.phase)

            if showsIssueCard, let issue = status.issue {
                IssueCard(issue: issue, action: actions.resolve)
                    .padding(.horizontal, Metric.gutter).padding(.top, 20)
                    .transition(.opacity)
            } else if status.phase == .connecting || status.phase == .connected {
                Button("Disconnect") { confirmDisconnect = true }
                    .buttonStyle(.quiet).padding(.top, 8)
            }

            Spacer(minLength: 20)
        }
        .animation(.standard, value: status.issue)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 5)
        .onAppear { withAnimation(.entrance) { appeared = true } }
        .page()
        .confirmationDialog("Disconnect your band?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive, action: actions.disconnect)
        } message: {
            Text("Runes will stop listening for gestures until you connect again.")
        }
    }

    private var header: some View {
        HStack {
            batteryRing
            Spacer()
            IconButton(.layoutGrid, action: actions.openApplications).accessibilityLabel("Applications")
            IconButton(.hand, action: actions.openMappings).accessibilityLabel("Mappings")
            IconButton(.settings, action: actions.openSettings).accessibilityLabel("Settings")
        }
        .padding(.leading, Metric.gutter).padding(.trailing, 8).padding(.top, 4)
    }

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Band battery")
        .accessibilityValue(status.battery.map { "\($0) percent" } ?? "Unknown")
    }

    /// The issue card carries the sentence, so the line under the title steps aside.
    private var showsIssueCard: Bool {
        guard let issue = status.issue else { return false }
        return status.phase == .attention || issue.isGentle
    }

    private var ringHint: String {
        switch status.phase {
        case .notSetUp: return "Starts setup."
        case .paused: return "Connects your band."
        case .connected: return "Asks to disconnect."
        case .attention: return status.issue?.actionTitle ?? ""
        case .connecting: return ""
        }
    }

    private func ringTapped() {
        switch status.phase {
        case .notSetUp: actions.setUp()
        case .paused: actions.connect()
        case .connected: confirmDisconnect = true
        case .attention: if let issue = status.issue { actions.resolve(issue.action) } else { actions.connect() }
        case .connecting: break
        }
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
