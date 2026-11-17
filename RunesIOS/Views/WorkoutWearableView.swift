import SwiftUI

// Linking a wearable to wear along with the band: the person says they want to, picks it from
// the ones sharing heart rate nearby, and says which wrist it is on. Opened from the Workouts
// page and from Workout settings.

struct WearableSheet: View {
    @ObservedObject var store: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// True once the person has asked to link one. Nothing is searched for before that.
    @State private var finding: Bool
    @State private var unlinking = false

    init(store: WorkoutStore, finding: Bool = false) {
        self.store = store
        _finding = State(initialValue: finding)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let wearable = store.wearable { linked(wearable) }
                    else if finding { search }
                    else { offer }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
                .animation(reduceMotion ? nil : .standard, value: store.wearable)
                .animation(reduceMotion ? nil : .standard, value: finding)
            }
            .scrollBounceBehavior(.basedOnSize)
            .page()
            .navigationTitle("Wearable").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
            .confirmationDialog("Unlink this wearable?", isPresented: $unlinking, titleVisibility: .visible) {
                Button("Unlink wearable", role: .destructive) { finding = false; store.unlinkWearable() }
            } message: { Text("Workouts already saved keep their heart rate.") }
        }
        .tint(Color.ink)
        .onAppear { store.showHeart(true) }
        .onDisappear { store.stopFindingWearables(); store.showHeart(false) }
    }

    /// Before anything is linked: what it is for, and one button to go ahead.
    private var offer: some View {
        VStack(alignment: .leading, spacing: 8) {
            LucideIcon(.heart, size: 28).foregroundStyle(Color.muted)
            Text("Wear a watch with your band?").font(.heading)
            Text("Runes can read heart rate from a watch, band or strap that shares it over Bluetooth, and keep it with each workout.")
                .font(.bodyText).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            Button("Link a wearable") { finding = true; store.findWearables() }
                .buttonStyle(PrimaryButtonStyle()).padding(.top, 16)
            Note("Nothing is searched for until you choose to link one.")
        }
        .padding(.top, 16)
    }

    private var search: some View {
        Block {
            if store.heartState == .unavailable {
                NoticeCard(sentence: "Bluetooth is off or not allowed for Runes.", actionTitle: "Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .padding(.top, 12)
            } else if store.heartSensors.isEmpty {
                HStack(spacing: 12) {
                    PulseDot()
                    Text("Looking for wearables sharing heart rate").font(.bodyText).foregroundStyle(Color.muted)
                }
                .padding(.vertical, 16)
            }
            ForEach(Array(store.heartSensors.enumerated()), id: \.element.id) { index, sensor in
                if index > 0 { Hairline(inset: 0) }
                Button { store.link(sensor) } label: {
                    HStack(spacing: 12) {
                        LucideIcon(.heart, size: 18)
                        Text(sensor.name).font(.bodyText)
                        Spacer(minLength: 8)
                        Chevron()
                    }
                    .padding(.vertical, 14).contentShape(Rectangle())
                }
                .buttonStyle(PressRow())
            }
        } header: {
            Heading("Nearby", count: store.heartSensors.isEmpty ? nil : store.heartSensors.count)
        } footer: {
            Note("Turn on heart rate sharing on the wearable first, which some call broadcast; an Apple Watch cannot share this way.")
        }
    }

    @ViewBuilder private func linked(_ wearable: Wearable) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            WearableHands(band: store.bandHand, watch: wearable.wrist, choose: store.setWearableWrist)
            HairlineSegments(selection: Binding(get: { WristChoice(wearable.wrist) }, set: { store.setWearableWrist($0.wrist) }),
                             options: WristChoice.allCases, title: \.title)
            Note(wearable.placement(band: store.bandHand))
        }
        Block {
            HStack {
                Text(wearable.name).font(.bodyText)
                Spacer(minLength: 8)
                Text(reading).font(.label).foregroundStyle(Color.muted).monospacedDigit().contentTransition(.numericText())
            }
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
        } header: {
            Heading("Heart rate")
        } footer: {
            Note(store.health.on
                 ? "During a workout it is read from the wearable and saved with the workout in Apple Health."
                 : "During a workout it is read from the wearable; turn on Save to Apple Health in Workout settings to keep it.")
        }
        Button("Unlink wearable") { unlinking = true }.buttonStyle(.quiet)
    }

    private var reading: String {
        if let beats = store.heartRate { return "\(beats) bpm" }
        return store.heartState == .unavailable ? "Bluetooth is off" : "Waiting for it to share"
    }
}

/// Where the wearable is worn, as the three choices under the hands.
private enum WristChoice: Hashable, CaseIterable {
    case left, right, elsewhere
    init(_ wrist: Handedness?) { self = wrist == .left ? .left : wrist == .right ? .right : .elsewhere }
    var wrist: Handedness? { self == .left ? .left : self == .right ? .right : nil }
    var title: String {
        switch self {
        case .left: "Left wrist"
        case .right: "Right wrist"
        case .elsewhere: "Not on a wrist"
        }
    }
}

/// Both hands, as on the Choose wrist screen: the band's beads on the wrist it is set for
/// and a watch on the wrist chosen here. Touching a hand moves the watch to it.
struct WearableHands: View {
    let band: Handedness?
    let watch: Handedness?
    let choose: (Handedness?) -> Void

    var body: some View {
        WristArtwork(state: WristFrame(handBlend: band == .left ? 1 : 0), focus: band == nil ? 0 : 1)
            .overlay { GeometryReader { geometry in if let watch { mark(on: watch, width: geometry.size.width) } } }
            .overlay {
                HStack(spacing: 0) {
                    ForEach([Handedness.left, .right], id: \.self) { hand in
                        Button { choose(hand) } label: { Color.clear.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Wearable on the \(hand.rawValue) wrist")
                            .accessibilityAddTraits(watch == hand ? .isSelected : [])
                    }
                }
            }
            .overlay(alignment: .top) { letters }
            // The artwork leaves room under the hands for beads in flight, which never fly here.
            .padding(.bottom, -44)
            .sensoryFeedback(.selection, trigger: watch)
    }

    // The artwork places each hand this far from the middle, and its wrist this far down.
    private func spacing(_ width: CGFloat) -> CGFloat { min(82, width * 0.22) }
    private func centre(_ hand: Handedness, width: CGFloat) -> CGFloat {
        let lean = hand == band ? WristArtwork.focusLean * spacing(width) / WristFlow.handOffset : 0
        return width / 2 + (hand == .left ? -1 : 1) * (spacing(width) - lean)
    }
    private static let wristLine: CGFloat = 172

    /// A watch drawn in hairline across the wrist. On the band's own wrist it sits further
    /// up the arm, clear of the beads.
    private func mark(on hand: Handedness, width: CGFloat) -> some View {
        let shared = hand == band
        let across = 46 * spacing(width) / WristFlow.handOffset
        return ZStack {
            if shared {
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Rectangle().fill(Color.faint).frame(width: 1.2, height: 34).offset(x: side * across / 2, y: -14)
                }
            }
            Capsule().fill(Color.paper).frame(width: across + 4, height: 9)
            Capsule().strokeBorder(Color.ink, lineWidth: 1.2).frame(width: across + 4, height: 9)
            RoundedRectangle(cornerRadius: 5).fill(Color.paper).frame(width: 20, height: 22)
            RoundedRectangle(cornerRadius: 5).strokeBorder(Color.ink, lineWidth: 1.2).frame(width: 20, height: 22)
        }
        .position(x: centre(hand, width: width), y: Self.wristLine + (shared ? 34 : 0))
        .accessibilityHidden(true)
    }

    private var letters: some View {
        GeometryReader { geometry in
            ForEach([("L", Handedness.left), ("R", Handedness.right)], id: \.0) { letter, hand in
                Text(letter).font(.geist(28, .semibold, relativeTo: .title))
                    .foregroundStyle(watch == hand || band == hand ? Color.ink : Color.faint)
                    .position(x: centre(hand, width: geometry.size.width), y: geometry.size.height / 2)
            }
        }
        .frame(height: 40)
        .accessibilityHidden(true)
    }
}

/// The row that opens the wearable's screen: what is linked, or the offer to link one.
struct WearableRow: View {
    @ObservedObject var store: WorkoutStore
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                LucideIcon(.heart, size: 14)
                Text(title).font(.caption)
                if let beats = store.heartRate, store.wearable != nil {
                    Text("· \(beats) bpm").font(.caption).monospacedDigit().contentTransition(.numericText())
                }
            }
            .foregroundStyle(Color.muted)
            .frame(maxWidth: .infinity, minHeight: Metric.tap).contentShape(Rectangle())
        }
        .buttonStyle(.quiet)
        .accessibilityHint("Opens the wearable's settings.")
    }

    private var title: String {
        guard let wearable = store.wearable else { return "Link a wearable" }
        return wearable.wrist.map { "\(wearable.name) · \($0.rawValue) wrist" } ?? wearable.name
    }
}
