import SwiftUI

/// Up to three applications pinned to the bottom of the home screen, in order, plus the
/// app waiting to take a slot when all three are full.
@MainActor
final class PinStore: ObservableObject {
    static let shared = PinStore()
    static let capacity = 3
    private static let key = "home.pinnedApps"

    @Published private(set) var pinned: [RunesApp] {
        didSet { UserDefaults.standard.set(pinned.map(\.rawValue).joined(separator: ","), forKey: Self.key) }
    }
    /// Set when the user pinned a fourth app; the home screen asks which pin it replaces.
    @Published var pending: RunesApp?

    init(pinned: [RunesApp]? = nil) {
        if let pinned {
            self.pinned = pinned
        } else {
            let raw = UserDefaults.standard.string(forKey: Self.key) ?? ""
            var seen: [RunesApp] = []
            for id in raw.split(separator: ",") {
                if let app = RunesApp(rawValue: String(id)), !seen.contains(app) { seen.append(app) }
            }
            self.pinned = Array(seen.prefix(Self.capacity))
        }
        #if DEBUG
        // Screenshots: RUNES_PENDING_PIN=<app id> opens the replace prompt straight away.
        if let id = ProcessInfo.processInfo.environment["RUNES_PENDING_PIN"], let app = RunesApp(rawValue: id) { pending = app }
        #endif
    }

    var isFull: Bool { pinned.count >= Self.capacity }
    func isPinned(_ app: RunesApp) -> Bool { pinned.contains(app) }

    /// Pins the app if there is room; otherwise remembers it so the home screen can ask.
    /// Returns true when it was pinned straight away.
    @discardableResult
    func pin(_ app: RunesApp) -> Bool {
        guard !isPinned(app) else { return true }
        if isFull { pending = app; return false }
        pinned.append(app)
        return true
    }

    func unpin(_ app: RunesApp) {
        pinned.removeAll { $0 == app }
    }

    /// Puts the pending app where `old` was.
    func replace(_ old: RunesApp) {
        guard let new = pending, let index = pinned.firstIndex(of: old) else { pending = nil; return }
        pinned[index] = new
        pending = nil
    }

    func cancelPending() { pending = nil }
}
