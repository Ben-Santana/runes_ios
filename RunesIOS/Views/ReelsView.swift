import SwiftUI
import WebKit

// Reels: instagram.com's Reels page, edge to edge, moved through from the band. The page
// keeps its sign-in in the app's own website data, so Instagram asks once. Touch works as
// it does in Safari; the band's gestures run `ReelsScript` in the page.

struct ReelsScreen: View {
    @ObservedObject var store: ReelsStore
    @State private var showSettings = false
    @State private var appeared = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var web = ReelsWeb.shared

    var body: some View {
        ReelsWebView(web: web)
            // Instagram's tab bar hangs off the bottom, so the reel has the whole screen.
            .padding(.bottom, -web.tabBar)
            .ignoresSafeArea()
            .background(Color.black.ignoresSafeArea())
            .overlay(alignment: .top) { controls }
            .toolbar(.hidden, for: .navigationBar)
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .sheet(isPresented: $showSettings) { ReelsSettingsScreen(store: store, signOut: web.signOut) }
            // Watching, not touching: the screen must not dim between reels.
            .onAppear {
                appeared = true
                UIApplication.shared.isIdleTimerDisabled = true
                store.onCommand = { ReelsWeb.shared.run($0) }
                update()
            }
            .onDisappear {
                appeared = false
                UIApplication.shared.isIdleTimerDisabled = false
                store.onCommand = nil
                update()
            }
            .onChange(of: scenePhase) { update() }
            .onChange(of: showSettings) { update() }
    }

    /// The gestures are Reels' while its screen is in front; reels play while it is also
    /// not under its settings.
    private func update() {
        let front = appeared && scenePhase == .active
        store.onScreen = front
        web.watching = front && !showSettings
    }

    /// The page fills the screen, so the bar's buttons sit over it.
    private var controls: some View {
        HStack(spacing: 0) {
            IconButton(.chevronLeft, size: 22) { dismiss() }.accessibilityLabel("Back")
            Spacer()
            IconButton(.rotateCcw, size: 18) { web.goToReels() }.accessibilityLabel("Back to Reels")
            IconButton(.settings, size: 19) { showSettings = true }.accessibilityLabel("Reels settings")
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        .padding(.horizontal, 6)
    }
}

/// Owns the web view. One for the app's life, so the page is loaded before the screen
/// opens and is where it was left on the way back.
@MainActor
final class ReelsWeb: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let shared = ReelsWeb()
    private static let openedKey = "runes.reels.opened"

    let view: WKWebView
    /// How tall the page says Instagram's tab bar under the reels is; none off the Reels page.
    @Published private(set) var tabBar: CGFloat = 0
    /// Whether the screen is in front. Reels play only then.
    var watching = false {
        didSet {
            guard watching != oldValue else { return }
            if watching { UserDefaults.standard.set(true, forKey: Self.openedKey) }
            view.evaluateJavaScript(ReelsScript.watching(watching))
        }
    }

    /// Loads the page ahead of the screen, for someone who has used Reels before.
    static func warmUp() {
        if UserDefaults.standard.bool(forKey: openedKey) { _ = shared }
    }

    private override init() {
        let configuration = WKWebViewConfiguration()
        // Reels play in the page, with sound, without a tap first.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(
            WKUserScript(source: ReelsScript.keeper, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = ReelsScript.userAgent
        #if DEBUG
        // Safari → Develop can inspect the page when a script stops finding the reel.
        view.isInspectable = true
        #endif
        view.allowsBackForwardNavigationGestures = true
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        // The page lays itself out to the screen's edges and keeps clear of the island itself.
        view.scrollView.contentInsetAdjustmentBehavior = .never
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        configuration.userContentController.add(self, name: "runes")
        goToReels()
    }

    func run(_ command: ReelsCommand) { view.evaluateJavaScript(ReelsScript.source(for: command)) }

    func goToReels() { view.load(URLRequest(url: ReelsScript.reelsURL)) }

    /// Forgets Instagram's sign-in and anything else it stored, then shows its sign-in page.
    func signOut() {
        let store = view.configuration.websiteDataStore
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            let instagram = records.filter { $0.displayName.contains("instagram") || $0.displayName.contains("facebook") }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: instagram) { self?.goToReels() }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let height = message.body as? Double, (0...120).contains(height) { tabBar = height }
    }

    /// A new page starts as not watched; tell it if it is.

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tabBar = 0
        if watching { webView.evaluateJavaScript(ReelsScript.watching(true)) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if watching { webView.evaluateJavaScript(ReelsScript.watching(true)) }
    }

    /// iOS ends a page's process when memory is short, which leaves it blank.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView.url == nil { goToReels() } else { webView.reload() }
    }

    /// Links that would open a new window open here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    /// Instagram and its Facebook sign-in stay in the page; any other link opens in Safari.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url, let host = url.host?.lowercased() else { return .allow }
        let kept = ["instagram.com", "facebook.com", "fbcdn.net", "cdninstagram.com"]
        if kept.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return .allow }
        await UIApplication.shared.open(url)
        return .cancel
    }
}

private struct ReelsWebView: UIViewRepresentable {
    let web: ReelsWeb
    func makeUIView(context: Context) -> WKWebView { web.view }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct ReelsSettingsScreen: View {
    @ObservedObject var store: ReelsStore
    var signOut: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var choosing: ReelsCommand?
    @State private var signingOut = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    Block {
                        ForEach(Array(ReelsCommand.allCases.enumerated()), id: \.element) { index, command in
                            if index > 0 { Hairline(delay: 0.04 * Double(index)) }
                            TriggerRow(title: command.title, detail: command.detail,
                                       steps: store.controls.trigger(for: command)?.steps) { choosing = command }
                        }
                    } header: {
                        Heading("Gestures")
                    } footer: {
                        Note("A gesture or a spell each. While Reels is on screen they move through reels, and mappings that use their gestures are off. With the phone locked or Reels closed, your mappings have them again.")
                    }
                    Note("Reels is Instagram’s own website, signed in inside Runes. Runes sees nothing of your account; the gestures only scroll and press its buttons. If Instagram changes its page, a gesture may stop finding the reel until Runes is updated.")
                    Button("Sign out of Instagram") { signingOut = true }.buttonStyle(.quiet)
                        .confirmationDialog("Sign out of Instagram?", isPresented: $signingOut, titleVisibility: .visible) {
                            Button("Sign out", role: .destructive) { signOut(); dismiss() }
                        } message: { Text("Instagram forgets this phone, and asks you to sign in next time.") }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
            }
            .page()
            .navigationTitle("Reels settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
            .sheet(item: $choosing) { command in
                let current = store.controls.trigger(for: command)
                let others = ReelsCommand.allCases.filter { $0 != command }
                TriggerSheet(title: command.title, caption: command.detail, rules: ReelsControls.rules,
                             steps: current?.steps ?? [], intervalMs: current?.intervalMs ?? ComboRules.defaultTime,
                             taken: Set(others.compactMap(store.controls.gesture)),
                             feed: RunesIOSApp.snapshotName == nil ? .shared : nil,
                             note: { steps in
                    others.first { store.controls.trigger(for: $0)?.steps == steps }.map { "\($0.title) uses this; they’ll swap." }
                }, save: { steps, interval in
                    store.setTrigger(steps.isEmpty ? nil : CommandTrigger(steps: steps, intervalMs: interval), for: command)
                })
            }
        }
        .tint(Color.ink)
    }
}
