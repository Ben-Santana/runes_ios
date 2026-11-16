import Foundation

/// The Runes applications as the Home Screen widgets know them, and the `runes://app/<id>`
/// link that opens each one. Ids match `RunesApp` in the app.
enum AppLink: String, CaseIterable, Sendable {
    case workouts, score, cook, capture, alarm, reels

    static let scheme = "runes"

    var title: String {
        switch self {
        case .workouts: "Workouts"
        case .score: "Score"
        case .cook: "Cook"
        case .capture: "Scribe"
        case .alarm: "Alarm"
        case .reels: "Reels"
        }
    }

    /// Lucide path data, the same icons the app's Applications list uses.
    var paths: [String] {
        switch self {
        case .workouts: LucideData.dumbbell
        case .score: LucideData.gamepad2
        case .cook: LucideData.chefHat
        case .capture: [
            "M11.36 7.4A6 6 0 0 1 11.36 16.6", "M15.28 4.22A11 11 0 0 1 15.28 19.78",
            "M6.25 12a1.25 1.25 0 1 0 2.5 0a1.25 1.25 0 1 0 -2.5 0Z", "M7 12a0.5 0.5 0 1 0 1 0a0.5 0.5 0 1 0 -1 0Z",
        ]
        case .alarm: LucideData.bellRing
        case .reels: LucideData.video
        }
    }

    var url: URL { URL(string: "\(Self.scheme)://app/\(rawValue)")! }

    /// Opened from the Live Activity while an alarm rings; stops it unless it can snooze.
    static let alarmFromActivity = URL(string: "\(scheme)://app/alarm?from=activity")!

    static func isFromActivity(_ url: URL) -> Bool { url.query?.contains("from=activity") == true }

    /// Opens the app at what is running in it (the workout under way, the recipe being
    /// cooked), for a tap on the Live Activity.
    var running: URL { URL(string: "\(Self.scheme)://app/\(rawValue)?screen=running")! }

    static func isRunning(_ url: URL) -> Bool { url.query?.contains("screen=running") == true }

    /// The app a `runes://app/<id>` link opens, or nil for any other link.
    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "app", let id = url.pathComponents.dropFirst().first else { return nil }
        self.init(rawValue: id)
    }
}
