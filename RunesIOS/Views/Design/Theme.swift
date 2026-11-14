import SwiftUI
import UIKit

// The Mac app's look: monochrome, Geist, hairline rules, 6 px controls, 8 px panels,
// no shadows at rest, 200 ms transitions. Light and dark are the same six tokens, inverted.
// This file holds the tokens; the parts built from them are its neighbours in Views/Design.
// The full guide is Documentation/StyleGuide.md; its live form is Views/Design/StyleGuide.swift.

extension Color {
    private static func token(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
    /// Page background.
    static let paper = token(0xFFFFFF, 0x0B0B0C)
    /// Text and primary marks.
    static let ink = token(0x191919, 0xEDEDED)
    /// Secondary text. 5.6:1 on white, 6.4:1 on the dark page.
    static let muted = token(0x696969, 0x8E8E8E)
    /// Hairline rules and panel borders.
    static let rule = token(0xE8E8E8, 0x262628)
    /// Quiet fills: pressed rows, segmented backgrounds.
    static let soft = token(0xFAFAFA, 0x141416)
    /// Resting electrode strokes on the ring.
    static let faint = token(0xC9C9C9, 0x55555A)
    /// The one colour: a destructive control that is about to remove something.
    static let destructive = Color(uiColor: .systemRed)
}

/// Which appearance Runes wears: the phone's, or one chosen in Settings.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: "Automatic"; case .light: "Light"; case .dark: "Dark" } }
    var style: UIUserInterfaceStyle { switch self { case .system: .unspecified; case .light: .light; case .dark: .dark } }

    static var chosen: Appearance {
        UserDefaults.standard.string(forKey: Preferences.appearance).flatMap(Appearance.init) ?? .system
    }

    /// Sets it on the windows rather than on a view, so sheets, covers and alerts follow, and
    /// Automatic goes back to following the phone.
    @MainActor func apply(to scene: UIScene? = nil) {
        let scenes = scene.map { [$0] } ?? Array(UIApplication.shared.connectedScenes)
        for window in scenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
            window.overrideUserInterfaceStyle = style
        }
    }
}

extension View {
    /// Keeps the app's windows in the chosen appearance. Applied once, at the root.
    func followsChosenAppearance() -> some View { modifier(ChosenAppearance()) }
}

private struct ChosenAppearance: ViewModifier {
    @AppStorage(Preferences.appearance) private var appearance = Appearance.system
    func body(content: Content) -> some View {
        content.onChange(of: appearance, initial: true) { _, chosen in chosen.apply() }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Geist, bundled under the SIL Open Font License (Resources/Fonts/OFL.txt).
/// Every style scales with Dynamic Type through its `relativeTo` text style.
extension Font {
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let name = switch weight {
        case .medium: "Geist-Medium"
        case .semibold, .bold, .heavy, .black: "Geist-SemiBold"
        default: "Geist-Regular"
        }
        return .custom(name, size: size, relativeTo: style)
    }
    static let display = geist(28, .medium, relativeTo: .largeTitle)
    static let heading = geist(20, .medium, relativeTo: .title3)
    static let bodyText = geist(15, relativeTo: .body)
    static let label = geist(14, .medium, relativeTo: .subheadline)
    static let caption = geist(12, relativeTo: .caption)
    /// Raw values and request bodies only.
    static let code = Font.system(.footnote, design: .monospaced)
}

extension Animation {
    /// Control and state transitions.
    static let standard = Animation.easeOut(duration: 0.2)
    /// Screen content arriving.
    static let entrance = Animation.easeOut(duration: 0.35)
    /// Press feedback on round and capsule controls.
    static let lively = Animation.spring(duration: 0.3, bounce: 0.3)
}

/// See Documentation/StyleGuide.md §4.
enum Metric {
    static let hairline: CGFloat = 1
    /// Step chips and tiny badges.
    static let chip: CGFloat = 4
    /// Buttons, segments, pills.
    static let control: CGFloat = 6
    /// Panels, cards, tiles.
    static let panel: CGFloat = 8
    /// Page side padding.
    static let gutter: CGFloat = 20
    /// Horizontal padding inside a panel row.
    static let inset: CGFloat = 14
    /// Key/value detail rows.
    static let rowDense: CGFloat = 44
    /// Standard rows and buttons.
    static let row: CGFloat = 48
    /// Rows with a two-line label or an icon.
    static let rowTall: CGFloat = 52
    /// Minimum hit target; icon buttons are tap × tap.
    static let tap: CGFloat = 44
}
