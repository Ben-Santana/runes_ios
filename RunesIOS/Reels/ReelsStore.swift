import Foundation

// Reels: Instagram's Reels page in a web view, moved through from the band. Instagram
// has no API for its Reels feed and iOS lets no app touch another app, so the page is
// instagram.com in Runes, signed in once, and each command is a short script run in it
// (`ReelsScript`). The band's gestures are Reels' only while its screen can be seen:
// a web view doesn't play with the phone locked, so then they go back to mappings.

/// What the band can do on the Reels screen.
enum ReelsCommand: String, Codable, CaseIterable, Identifiable, Sendable {
    case next, previous, pause, like, mute

    var id: String { rawValue }
    var title: String {
        switch self {
        case .next: "Next reel"
        case .previous: "Previous reel"
        case .pause: "Pause or play"
        case .like: "Like"
        case .mute: "Sound on or off"
        }
    }
    var detail: String {
        switch self {
        case .next: "Scrolls to the next reel."
        case .previous: "Scrolls back to the one before."
        case .pause: "Pauses the reel on screen, and plays it again."
        case .like: "Likes the reel on screen, or unlikes it."
        case .mute: "Turns the reel’s sound on or off."
        }
    }
}

/// Which gesture or combo does what on the Reels screen.
struct ReelsControls: Codable, Hashable, Sendable {
    var triggers: [ReelsCommand: CommandTrigger]

    /// Up and down scroll, as a thumb would on the screen. A watching hand is still, so
    /// the index finger's tap pauses; liking takes a double tap so it never happens by itself.
    static let standard = ReelsControls(triggers: [
        .next: .gesture(.swipeUp), .previous: .gesture(.swipeDown), .pause: .gesture(.tapIndex),
        .like: .gesture(.doubleTapMiddle), .mute: .gesture(.holdMiddle),
    ])
    private static let mappingPrefix = "reels:"

    /// Finger gestures and swipes. Motion and air steps would need the band's motion
    /// streams for as long as the screen is open.
    static let singleChoices = GestureKind.motions
    static func comboChoices(after steps: [ComboStep]) -> [GestureKind] {
        ComboRules.allowedNext(after: steps).filter { !$0.isMotion && !$0.isAir }
    }
    static var rules: TriggerRules { .gestureOrCombo(singleChoices, next: comboChoices, allowsNone: true) }

    func trigger(for command: ReelsCommand) -> CommandTrigger? { triggers[command] }
    func gesture(for command: ReelsCommand) -> GestureKind? { triggers[command]?.gesture }
    /// Assigns a trigger; a command that already had it takes this command's old one.
    mutating func setTrigger(_ trigger: CommandTrigger?, for command: ReelsCommand) { triggers.assign(trigger, to: command) }

    var reserved: Set<GestureKind> { triggers.reserved }
    var mappings: [Mapping] { triggers.mappings(prefix: Self.mappingPrefix) }
    func command(forMapping id: String) -> ReelsCommand? { triggers.command(forMapping: id, prefix: Self.mappingPrefix) }

    init(triggers: [ReelsCommand: CommandTrigger]) { self.triggers = triggers }
    private enum Keys: String, CodingKey { case triggers }
    init(from decoder: Decoder) throws {
        triggers = Dictionary(saved: try decoder.container(keyedBy: Keys.self).decode([String: CommandTrigger].self, forKey: .triggers))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(triggers.saved, forKey: .triggers)
    }
}

/// The gestures and the screen. The web view itself belongs to `ReelsScreen`, which
/// runs the commands this store decides on (`onCommand`).
@MainActor
final class ReelsStore: ObservableObject {
    static let shared = ReelsStore()
    private static let key = "runes.reels.v1"

    @Published private(set) var controls: ReelsControls { didSet { configureDecider() } }

    /// True while the Reels screen is in front with the app active; only then are the
    /// gestures Reels'.
    var onScreen = false { didSet { if onScreen != oldValue { onReserve?(reservedNow) } } }
    /// Told which gestures Reels holds.
    var onReserve: ((Set<GestureKind>) -> Void)? { didSet { onReserve?(reservedNow) } }
    /// Runs a command in the web view. Set by the screen while it is shown.
    var onCommand: ((ReelsCommand) -> Void)?

    private let decider = TriggerDecider()
    private var reservedNow: Set<GestureKind> { onScreen ? controls.reserved : [] }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(ReelsControls.self, from: data) { controls = saved } else { controls = .standard }
        decider.onFire = { [weak self] id in
            guard let self, let command = self.controls.command(forMapping: id) else { return }
            self.perform(command)
        }
        configureDecider()
    }

    private func configureDecider() { decider.configure(controls.mappings) }

    func setTrigger(_ trigger: CommandTrigger?, for command: ReelsCommand) {
        controls.setTrigger(trigger, for: command)
        if let data = try? JSONEncoder().encode(controls) { UserDefaults.standard.set(data, forKey: Self.key) }
        onReserve?(reservedNow)
    }

    func perform(_ command: ReelsCommand) { onCommand?(command) }

    /// Takes a band gesture that is one of Reels' while its screen is in front.
    /// Returns false to let mappings handle it.
    func consume(_ gesture: BandGesture) -> Bool {
        guard onScreen, let kind = GestureKind(gesture), reservedNow.contains(kind) else { return false }
        decider.receive(kind)
        return true
    }
}

/// The scripts run in the page. Instagram's markup has no stable ids, so they work from
/// what every reel has: a `<video>`, the scrolling list it sits in, and a like button
/// labelled "Like" or "Unlike".
enum ReelsScript {
    static let reelsURL = URL(string: "https://www.instagram.com/reels/")!

    /// Instagram serves its full mobile site only to something that looks like Safari.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// Added to every page before its own scripts run. Instagram starts each reel muted
    /// and leaves a reel that is slow to load sitting paused, so this keeps the reel in
    /// the middle of the screen playing with sound, the others quiet, and the next one
    /// loading. `away` is true until the screen says it is being watched.
    static let keeper = """
    (() => {
      if (window.__runes) return;
      const state = window.__runes = { sound: true, held: false, away: true, current: null, touch: -1e9, toggled: -1, last: -1, stuck: 0, bar: 0 };
      const muted = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'muted');
      const quiet = (v, on) => { if (muted.get.call(v) !== on) muted.set.call(v, on); };
      const touched = () => performance.now() - state.touch < 500;

      // The page mutes a reel whenever it starts one. Only a write that follows a touch,
      // which is its own sound button, changes the sound.
      Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
        configurable: true, enumerable: true,
        get() { return muted.get.call(this); },
        set(value) {
          if (touched() && state.toggled !== state.touch) { state.toggled = state.touch; state.sound = !state.sound; }
          muted.set.call(this, !state.sound);
        },
      });

      const shown = () => [...document.querySelectorAll('video')].filter(v => { const r = v.getBoundingClientRect(); return r.width > 0 && r.height > 0; });
      const find = () => {
        let best = null, nearest = Infinity;
        for (const v of shown()) {
          const r = v.getBoundingClientRect();
          if (r.bottom <= 0 || r.top >= innerHeight) continue;
          const d = Math.abs((r.top + r.bottom) / 2 - innerHeight / 2);
          if (d < nearest) { nearest = d; best = v; }
        }
        return best;
      };
      // Instagram's tab bar sits under the list of reels and the page sizes each reel to
      // what is left. Its height goes to the app, which hangs that much of the page off
      // the bottom of the screen, so the reel has all of it. Not while a sheet such as
      // comments is up, which needs the page's real bottom edge.
      const bar = best => {
        let height = 0, list = null;
        const on = best && location.pathname.startsWith('/reels') && !document.querySelector('[role="dialog"]');
        for (let e = on && best.parentElement; e; e = e.parentElement) {
          const c = getComputedStyle(e);
          if (c.position === 'fixed' && (c.overflowY === 'scroll' || c.overflowY === 'auto')) { list = e; break; }
        }
        if (list) for (const e of document.querySelectorAll('body div, body nav')) {
          if (e.contains(list) || list.contains(e) || e.querySelectorAll('a').length < 4) continue;
          const r = e.getBoundingClientRect();
          if (getComputedStyle(e).position === 'fixed' && r.height > 0 && r.height < 120 && r.bottom >= innerHeight - 1) { height = Math.round(r.height); break; }
        }
        if (height === state.bar) return;
        state.bar = height;
        try { webkit.messageHandlers.runes.postMessage(height); } catch (e) {}
      };
      const tick = () => {
        const videos = shown(), best = find();
        bar(best);
        if (best !== state.current) { state.current = best; state.held = false; state.stuck = 0; state.last = -1; }
        for (const v of videos) {
          quiet(v, !state.sound);
          if (!state.sound) continue;
          if (v.volume === 0) v.volume = 1;
        }
        if (state.away) { videos.forEach(v => { if (!v.paused) v.pause(); }); return; }
        if (!best) return;
        for (const v of videos) if (v !== best && !v.paused) v.pause();
        const below = videos.filter(v => v.getBoundingClientRect().top > best.getBoundingClientRect().top + 1)
          .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top)[0];
        for (const v of [best, below]) if (v && v.preload !== 'auto') v.preload = 'auto';
        if (state.held || document.hidden) return;
        if (best.paused) { if (!best.ended) best.play().catch(() => {}); return; }
        // Playing but going nowhere: ask for the file again from where it stopped.
        state.stuck = best.currentTime === state.last ? state.stuck + 1 : 0;
        state.last = best.currentTime;
        if (state.stuck >= 16 && best.readyState < 3 && best.currentSrc && !best.currentSrc.startsWith('blob:')) {
          const at = best.currentTime;
          state.stuck = 0;
          best.load();
          best.addEventListener('loadedmetadata', () => { best.currentTime = at; }, { once: true });
          best.play().catch(() => {});
        }
      };
      state.find = find; state.shown = shown; state.tick = tick;

      // Taps only: a swipe to the next reel is not a press of anything.
      addEventListener('click', e => { if (e.isTrusted) state.touch = performance.now(); }, true);
      // A reel the watcher paused by hand stays paused until they play it or move on.
      document.addEventListener('pause', e => { if (e.target === state.current && touched()) state.held = true; }, true);
      document.addEventListener('play', e => {
        if (e.target instanceof HTMLMediaElement) quiet(e.target, !state.sound);
        if (e.target === state.current) state.held = false;
      }, true);
      let settle;
      addEventListener('scroll', () => { clearTimeout(settle); settle = setTimeout(tick, 120); }, true);
      setInterval(tick, 300);
    })();
    """

    static func source(for command: ReelsCommand) -> String {
        let body: String
        switch command {
        case .next, .previous:
            // To the reel after or before this one; where the page hasn't made it yet,
            // one screen, which is what the list snaps to.
            let forward = command == .next
            body = """
            const top = v => v.getBoundingClientRect().top;
            const here = top(current);
            const others = runes.shown().filter(v => \(forward ? "top(v) > here + 1" : "top(v) < here - 1")).sort((a, b) => \(forward ? "top(a) - top(b)" : "top(b) - top(a)"));
            if (others[0]) { others[0].scrollIntoView({ behavior: 'smooth', block: 'center' }); return; }
            let list = document.scrollingElement;
            for (let e = current.parentElement; e; e = e.parentElement) {
              const y = getComputedStyle(e).overflowY;
              if ((y === 'auto' || y === 'scroll') && e.scrollHeight > e.clientHeight + 10) { list = e; break; }
            }
            list.scrollBy({ top: \(forward ? "" : "-")list.clientHeight, behavior: 'smooth' });
            """
        case .pause:
            body = """
            runes.held = !current.paused;
            if (current.paused) current.play().catch(() => {}); else current.pause();
            """
        case .mute:
            body = """
            runes.sound = !runes.sound;
            runes.tick();
            """
        case .like:
            // The nearest like button above the reel's own video: walk out from it until
            // an ancestor holds one.
            body = """
            for (let e = current.parentElement; e; e = e.parentElement) {
              const icon = e.querySelector('svg[aria-label="Like"], svg[aria-label="Unlike"]');
              if (!icon) continue;
              (icon.closest('[role="button"], button') || icon.parentElement).click();
              return;
            }
            """
        }
        return "(() => {\nconst runes = window.__runes;\nconst current = runes && runes.find();\nif (!current) return;\n\(body)\n})(); 0"
    }

    /// Run as the screen comes and goes, so reels play only while they are watched.
    static func watching(_ on: Bool) -> String {
        "if (window.__runes) { window.__runes.away = \(on ? "false" : "true"); window.__runes.tick(); } 0"
    }
}
