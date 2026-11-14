import SwiftUI
import CoreBluetooth

enum OnboardingStep: Int, CaseIterable {
    case welcome, bluetooth, pairing, pick, signIn, test, wrist, done
}

/// Plain values describing what onboarding can show right now.
struct OnboardingContext: Equatable {
    enum Access: Equatable { case notAsked, allowed, denied }
    var bluetooth: Access = .notAsked
    var devices: [BandDevice] = []
    var searching = false
    var systemPicker = false
    /// Signing in, linking or connecting.
    var working = false
    var workingText = "Linking your band…"
    var issue: SessionIssue?
    var phase: BandPhase = .notSetUp
    var gesture: BandGesture?
    var heard: String?
    var testPassed = false
    var canSetUpBandAgain = false
    var selectedBand: UUID?
    var handSetting = HandSetting()
    var canChangeHand = false

    static func == (a: Self, b: Self) -> Bool {
        a.bluetooth == b.bluetooth && a.devices.map(\.id) == b.devices.map(\.id) && a.searching == b.searching
            && a.working == b.working && a.issue == b.issue && a.phase == b.phase && a.gesture?.id == b.gesture?.id
            && a.heard == b.heard && a.testPassed == b.testPassed && a.systemPicker == b.systemPicker
            && a.canSetUpBandAgain == b.canSetUpBandAgain
            && a.selectedBand == b.selectedBand && a.handSetting == b.handSetting && a.canChangeHand == b.canChangeHand
    }
}

struct OnboardingActions {
    var next: () -> Void = {}
    var back: () -> Void = {}
    var allowBluetooth: () -> Void = {}
    var openSettings: () -> Void = {}
    var search: () -> Void = {}
    var choose: (BandDevice) -> Void = { _ in }
    var chooseWithSystem: () -> Void = {}
    var signIn: () -> Void = {}
    var useMac: () -> Void = {}
    var resolve: (SessionIssue.Action) -> Void = { _ in }
    var finish: () -> Void = {}
    var setUpBandAgain: (UUID) -> Void = { _ in }
    var setHand: (Handedness) -> Void = { _ in }
    var wristFeedback: (WristFeedbackPhase, Handedness, UUID) -> Void = { _, _, _ in }
    var cancelWristFeedback: (UUID) -> Void = { _ in }
}

struct OnboardingView: View {
    let step: OnboardingStep
    let context: OnboardingContext
    var actions = OnboardingActions()
    @State private var showingGuide = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 0) {
                    if step == .wrist {
                        WristView(setting: context.handSetting, connected: context.canChangeHand, band: context.selectedBand,
                                  choose: actions.setHand, feedback: actions.wristFeedback,
                                  cancelFeedback: actions.cancelWristFeedback, layout: .embedded)
                            .padding(.bottom, 20)
                    } else {
                        HairlineRing(phase: ringPhase, gesture: context.gesture, emphasis: emphasis, emphasisLight: step == .pairing, playful: step == .welcome)
                            .frame(maxWidth: 300).padding(.top, 8).padding(.bottom, 12)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title).font(.display).tracking(-0.6).fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(message).font(.bodyText).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    content.padding(.top, 20)
                }
                .padding(.horizontal, Metric.gutter)
                .id(step)
                .transition(.opacity)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer.padding(.horizontal, Metric.gutter).padding(.bottom, 12)
            if step == .pairing || (step == .test && !context.testPassed) {
                GuideDrawer { showingGuide = true }
            }
        }
        .animation(.standard, value: step)
        .animation(.standard, value: context)
        .page()
        .sheet(isPresented: $showingGuide) { BandGuideSheet() }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            if step != .welcome && step != .done {
                IconButton(.chevronLeft, action: actions.back).accessibilityLabel("Back")
            } else {
                Color.clear.frame(width: Metric.tap, height: Metric.tap)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { s in
                    Capsule().fill(s.rawValue <= step.rawValue ? Color.ink : Color.rule)
                        .frame(width: s == step ? 16 : 6, height: 6)
                }
            }
            .accessibilityElement().accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
            Spacer()
            Color.clear.frame(width: Metric.tap, height: Metric.tap)
        }
        .padding(.horizontal, 8).frame(height: 52)
    }

    private var ringPhase: BandPhase {
        switch step {
        case .welcome, .bluetooth, .pairing: return .notSetUp
        case .pick: return context.searching ? .connecting : .notSetUp
        case .signIn: return context.working ? .connecting : (context.issue != nil ? .attention : .notSetUp)
        case .test: return context.phase == .connected ? .connected : .connecting
        case .wrist, .done: return .connected
        }
    }

    private var emphasis: Int? {
        switch step {
        case .pairing: return 1
        case .test where !context.testPassed && context.phase == .connected: return 1
        default: return nil
        }
    }

    // MARK: Copy


    private var title: String {
        switch step {
        case .welcome: return "Runes"
        case .bluetooth: return "Allow Bluetooth"
        case .pairing: return "Put your band in pairing mode"
        case .pick: return "Choose your band"
        case .signIn: return "Sign in with Meta"
        case .test:
            if context.testPassed { return "Got it" }
            if context.phase == .connected { return "Tap your index finger" }
            return context.issue == nil ? "Connecting to your band" : "Not connected yet"
        case .wrist: return "Choose wrist"
        case .done: return "You’re all set"
        }
    }

    private var message: String {
        switch step {
        case .welcome:
            return "Use your Meta Neural Band with iPhone. Set it up once and it stays connected, even when your phone is locked."
        case .bluetooth:
            return context.bluetooth == .denied
                ? "Bluetooth is turned off for Runes. Allow it in Settings to continue."
                : "Runes uses Bluetooth to talk to your band and to keep the connection when your phone is locked."
        case .pairing:
            return "Hold the band’s button for 3 seconds until its light flashes white, then keep the band close to your phone."
        case .pick:
            return context.systemPicker ? "Your iPhone will show bands nearby." : "Bands nearby appear below."
        case .signIn:
            return "Signing in links this phone to your band."
        case .test:
            if context.testPassed { return "Your band is talking to your phone." }
            if context.phase != .connected {
                return context.issue == nil ? "Keep the band on your wrist and close to your phone. This takes a few seconds."
                                            : "Runes keeps trying while you sort this out."
            }
            return context.heard.map { "Heard “\($0.lowercased())”. Try your index finger." }
                ?? "Your band is connected. Tap your index finger to your thumb, once, to check it’s listening."
        case .wrist:
            return context.canChangeHand
                ? "Tap the hand you wear your band on."
                : "Connect your band to set its wrist. You can also do this later in Settings."
        case .done:
            return "Runes stays connected in the background. You can close the app; it reconnects by itself when the band is nearby."
        }
    }

    // MARK: Step content

    @ViewBuilder private var content: some View {
        switch step {
        case .pick: pickList
        case .signIn: signInContent
        case .test, .wrist, .done, .welcome, .bluetooth, .pairing:
            if let issue = context.issue, step == .test {
                VStack(spacing: 12) {
                    IssueCard(issue: issue, action: actions.resolve)
                    if issue == .notRecognised {
                        BandSetupAgainAction(band: context.selectedBand, enabled: context.canSetUpBandAgain, action: actions.setUpBandAgain).panel()
                    }
                }
            }
        }
    }

    @ViewBuilder private var pickList: some View {
        if !context.systemPicker {
            VStack(spacing: 0) {
                if context.devices.isEmpty {
                    HStack(spacing: 10) {
                        if context.searching { ProgressView().controlSize(.small) }
                        Text(context.searching ? "Searching…" : "No bands found.").font(.bodyText).foregroundStyle(Color.muted)
                        Spacer()
                    }
                    .padding(.horizontal, Metric.inset).frame(minHeight: Metric.rowTall)
                }
                ForEach(Array(context.devices.enumerated()), id: \.element.id) { offset, device in
                    if offset > 0 { Rule() }
                    Button { actions.choose(device) } label: {
                        HStack {
                            Text(device.name).font(.bodyText)
                            Spacer()
                            Text(nearness(device.rssi)).font(.caption).foregroundStyle(Color.muted)
                            Chevron()
                        }
                        .panelRow(height: Metric.rowTall)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Chooses this band.")
                }
            }
            .panel()
        }
    }

    private func nearness(_ rssi: Int?) -> String {
        guard let rssi else { return "" }
        return rssi > -55 ? "Very close" : rssi > -75 ? "Nearby" : "Far"
    }

    @ViewBuilder private var signInContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text("!").font(.label).frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Color.ink, lineWidth: Metric.hairline))
                    .accessibilityHidden(true)
                Text("This may disconnect your band from other devices, like your Mac. They may need to be set up again afterwards.")
                    .font(.bodyText).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Metric.inset).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.soft, in: RoundedRectangle(cornerRadius: Metric.panel))
            .overlay(RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.rule, lineWidth: Metric.hairline))
            .accessibilityElement(children: .combine)
            if context.working {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(context.workingText).font(.bodyText).foregroundStyle(Color.muted)
                }.padding(.top, 4)
            } else if let issue = context.issue {
                IssueCard(issue: issue, action: actions.resolve)
            }
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        VStack(spacing: 4) {
            switch step {
            case .welcome:
                Button("Get started", action: actions.next).buttonStyle(.primary)
            case .bluetooth:
                if context.bluetooth == .denied {
                    Button("Open Settings", action: actions.openSettings).buttonStyle(.primary)
                } else {
                    Button("Allow Bluetooth", action: actions.allowBluetooth).buttonStyle(.primary)
                }
            case .pairing:
                Button("My band is in pairing mode", action: actions.next).buttonStyle(.primary)
            case .pick:
                if context.systemPicker {
                    Button("Choose band", action: actions.chooseWithSystem).buttonStyle(.primary)
                } else {
                    Button(context.searching ? "Searching…" : "Search again", action: actions.search)
                        .buttonStyle(.secondary).disabled(context.searching)
                }
            case .signIn:
                Button("Sign in with Meta", action: actions.signIn).buttonStyle(.primary).disabled(context.working)
                Button("Use my Mac’s setup instead", action: actions.useMac).buttonStyle(.quiet).disabled(context.working)
            case .test:
                if context.testPassed {
                    Button("Continue", action: actions.next).buttonStyle(.primary)
                } else {
                    Button("Skip", action: actions.next).buttonStyle(.quiet)
                }
            case .wrist:
                Button("Continue", action: actions.next).buttonStyle(.primary)
            case .done:
                Button("Done", action: actions.finish).buttonStyle(.primary)
            }
        }
    }
}

/// The optional band guide, as the lip of a drawer across the foot of the screen, with three
/// beads for a handle. It rises into view a moment after the step arrives; the beads hop once,
/// one after another, and then keep still.
private struct GuideDrawer: View {
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tucked = true
    @State private var hopping: Int?

    var body: some View {
        let lip = UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16)
        Button(action: open) {
            VStack(spacing: 8) {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { bead in
                        Circle().fill(Color.soft).overlay(Circle().strokeBorder(Color.ink.opacity(0.75), lineWidth: Metric.hairline))
                            .frame(width: 8, height: 8).offset(y: hopping == bead ? -5 : 0)
                    }
                }
                Text("Band guide").font(.label)
            }
            .padding(.top, 12).padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            // The drawer carries on below and past the sides of the screen, so only its lip shows.
            .background { lip.fill(Color.soft).overlay(lip.strokeBorder(Color.faint, lineWidth: Metric.hairline)).padding(.bottom, -120).padding(.horizontal, -1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(y: tucked ? 80 : 0)
        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { if $0.translation.height < -16 { open() } })
        .accessibilityHint("How to wear and use your band")
        .task {
            guard !reduceMotion else { tucked = false; return }
            try? await Task.sleep(for: .seconds(0.25))
            withAnimation(.entrance) { tucked = false }
            try? await Task.sleep(for: .seconds(1.1))
            for bead in 0..<3 {
                withAnimation(.standard) { hopping = bead }
                try? await Task.sleep(for: .seconds(0.13))
            }
            withAnimation(.standard) { hopping = nil }
        }
    }
}

/// Drives `OnboardingView` from the live session.
struct OnboardingFlow: View {
    @ObservedObject var controller: SessionController
    var finished: () -> Void
    @State private var step: OnboardingStep = .welcome
    @State private var heard: String?
    @State private var passed = false
    @State private var testStartID = 0
    @State private var scanningMac = false

    private var snapshot: SessionSnapshot { controller.snapshot }

    var body: some View {
        OnboardingView(step: step, context: context, actions: actions)
            .onChange(of: controller.bluetoothAuthorization) { _, value in
                if step == .bluetooth, value == .allowedAlways { advance(to: .pairing) }
            }
            .onChange(of: snapshot.state) { _, state in
                if step == .signIn, state == .streaming { startTest() }
            }
            .onChange(of: snapshot.lastGesture?.id) { _, _ in listen() }
            .sheet(isPresented: $scanningMac) {
                IdentityScanner(title: "Scan the code on your Mac") { text in
                    if let id = snapshot.selected { controller.importIdentityQR(text, for: id) }
                }
            }
    }

    private var context: OnboardingContext {
        let auth = controller.bluetoothAuthorization
        let working = controller.isSigningIn || (snapshot.wantsConnection && snapshot.state != .streaming && snapshot.issue == nil)
        return OnboardingContext(
            bluetooth: auth == .allowedAlways ? .allowed : (auth == .notDetermined ? .notAsked : .denied),
            devices: snapshot.devices, searching: snapshot.state == .scanning,
            systemPicker: AccessoryPicker.isEnabled,
            working: working,
            workingText: controller.isSigningIn ? "Waiting for Meta sign-in…" : "Linking your band…",
            issue: step == .signIn && controller.uiError != nil ? .signInFailed : snapshot.issue,
            phase: BandStatus(snapshot, setupComplete: true, relayStatus: nil).phase,
            gesture: snapshot.lastGesture, heard: heard, testPassed: passed,
            canSetUpBandAgain: controller.canSetUpBandAgain, selectedBand: snapshot.selected,
            handSetting: snapshot.handSetting,
            canChangeHand: snapshot.state == .streaming)
    }

    private var actions: OnboardingActions {
        OnboardingActions(
            next: next, back: back,
            allowBluetooth: {
                controller.startBluetooth()
                if controller.bluetoothAuthorization == .allowedAlways { advance(to: .pairing) }
            },
            openSettings: { controller.perform(.openSettings) },
            search: controller.scan,
            choose: { device in controller.select(device); afterPick() },
            chooseWithSystem: {
                Task {
                    let image = ImageRenderer(content: HairlineRing(phase: .connected).frame(width: 360, height: 288).background(Color.white)).uiImage ?? UIImage()
                    if let id = try? await AccessoryPicker.shared.pick(image: image) { controller.select(id: id); afterPick() }
                }
            },
            signIn: { controller.uiError = nil; controller.enroll() },
            useMac: { scanningMac = true },
            resolve: { action in
                if action == .retrySignIn { controller.uiError = nil; controller.enroll() } else { controller.perform(action) }
            },
            finish: { controller.completeSetup(); finished() },
            setUpBandAgain: controller.setUpBandAgain,
            setHand: controller.setHand,
            wristFeedback: controller.wristFeedback, cancelWristFeedback: controller.cancelWristFeedback)
    }

    private func advance(to next: OnboardingStep) {
        step = next
        if next == .pick, !AccessoryPicker.isEnabled { controller.scan() }
    }

    private func next() {
        switch step {
        case .welcome:
            advance(to: controller.bluetoothAuthorization == .allowedAlways ? .pairing : .bluetooth)
        case .bluetooth: advance(to: .pairing)
        case .pairing: advance(to: .pick)
        case .pick: afterPick()
        case .signIn: startTest()
        case .test: advance(to: snapshot.state == .streaming ? .wrist : .done)
        case .wrist: advance(to: .done)
        case .done: break
        }
    }

    private func back() {
        controller.stopScan()
        switch step {
        case .bluetooth: step = .welcome
        case .pairing: step = controller.bluetoothAuthorization == .allowedAlways ? .welcome : .bluetooth
        case .pick: step = .pairing
        case .signIn: controller.cancelSignIn(); advance(to: .pick)
        case .test: controller.disconnect(); advance(to: .pick)
        case .wrist: step = .test
        default: break
        }
    }

    /// A band that already has a saved setup on this phone connects without signing in.
    private func afterPick() {
        controller.stopScan()
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            if controller.canConnectWithoutSignIn { controller.connect(); startTest() } else { step = .signIn }
        }
    }

    private func startTest() {
        testStartID = snapshot.lastGesture?.id ?? 0; heard = nil; passed = false
        step = .test
    }

    private func listen() {
        guard step == .test, !passed, let gesture = snapshot.lastGesture, gesture.id > testStartID, gesture.kind != .holdEnded else { return }
        if gesture.finger == 2, gesture.kind == .tap || gesture.kind == .doubleTap { passed = true } else { heard = gesture.title }
    }
}
