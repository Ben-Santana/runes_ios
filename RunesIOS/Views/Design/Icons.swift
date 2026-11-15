import SwiftUI
import UIKit

// The Mac app's icons: Lucide (LucideData.swift) and its hand-drawn finger variants
// (runes_mac/src/MotionSettings.tsx, FingerIcon). Drawn from the same path
// data at the same 1.5 stroke in a 24×24 box, so they match the Mac exactly.

enum Lucide: String, CaseIterable, Sendable {
    case arrowLeft, arrowRight, arrowUp, arrowDown, rotate3d, move3d
    case house, briefcase, codeXml, music, gamepad2, camera, penTool, globe, star, heart, monitor, headphones
    case earth, layers, appWindow, list, bell, clipboardCopy, vibrate, hourglass
    case plus, chevronRight, chevronDown, check, x, clock3, workflow, hand, ellipsis, play, trash2, pencil, circle, circleDot, spline, copy
    case dumbbell, layoutGrid, skipForward, rotateCcw, square
    case settings, audioWaveform, calendarDays, bookOpen, search, timer, flame, trendingUp, activity
    case chevronLeft, chevronUp, qrCode, share, minus, info
    case mic, chefHat, pause, link, clipboardPaste, bellRing, listChecks, ear, trophy, video

    var paths: [String] {
        switch self {
        case .arrowLeft: LucideData.arrowLeft
        case .arrowRight: LucideData.arrowRight
        case .arrowUp: LucideData.arrowUp
        case .arrowDown: LucideData.arrowDown
        case .rotate3d: LucideData.rotate3d
        case .move3d: LucideData.move3d
        case .house: LucideData.house
        case .briefcase: LucideData.briefcase
        case .codeXml: LucideData.codeXml
        case .music: LucideData.music
        case .gamepad2: LucideData.gamepad2
        case .camera: LucideData.camera
        case .penTool: LucideData.penTool
        case .globe: LucideData.globe
        case .star: LucideData.star
        case .heart: LucideData.heart
        case .monitor: LucideData.monitor
        case .headphones: LucideData.headphones
        case .earth: LucideData.earth
        case .layers: LucideData.layers
        case .appWindow: LucideData.appWindow
        case .list: LucideData.list
        case .bell: LucideData.bell
        case .clipboardCopy: LucideData.clipboardCopy
        case .vibrate: LucideData.vibrate
        case .hourglass: LucideData.hourglass
        case .plus: LucideData.plus
        case .chevronRight: LucideData.chevronRight
        case .chevronDown: LucideData.chevronDown
        case .check: LucideData.check
        case .x: LucideData.x
        case .clock3: LucideData.clock3
        case .workflow: LucideData.workflow
        case .hand: LucideData.hand
        case .ellipsis: LucideData.ellipsis
        case .play: LucideData.play
        case .trash2: LucideData.trash2
        case .pencil: LucideData.pencil
        case .circle: LucideData.circle
        case .circleDot: LucideData.circleDot
        case .spline: LucideData.spline
        case .copy: LucideData.copy
        case .dumbbell: LucideData.dumbbell
        case .layoutGrid: LucideData.layoutGrid
        case .skipForward: LucideData.skipForward
        case .rotateCcw: LucideData.rotateCcw
        case .square: LucideData.square
        case .settings: LucideData.settings
        case .audioWaveform: LucideData.audioWaveform
        case .calendarDays: LucideData.calendarDays
        case .bookOpen: LucideData.bookOpen
        case .search: LucideData.search
        case .timer: LucideData.timer
        case .flame: LucideData.flame
        case .trendingUp: LucideData.trendingUp
        case .activity: LucideData.activity
        case .chevronLeft: LucideData.chevronLeft
        case .chevronUp: LucideData.chevronUp
        case .qrCode: LucideData.qrCode
        case .share: LucideData.share
        case .minus: LucideData.minus
        case .info: LucideData.info
        case .mic: LucideData.mic
        case .chefHat: LucideData.chefHat
        case .pause: LucideData.pause
        case .link: LucideData.link
        case .clipboardPaste: LucideData.clipboardPaste
        case .bellRing: LucideData.bellRing
        case .listChecks: LucideData.listChecks
        case .ear: LucideData.ear
        case .trophy: LucideData.trophy
        case .video: LucideData.video
        }
    }
    /// Each Lucide element is its own SVG path, so a leading relative "m" starts from the origin.
    var path: Path {
        var combined = Path()
        for d in paths { combined.addPath(SVGPath.cached(d)) }
        return combined
    }

    /// Template image for places SwiftUI only accepts an `Image`, such as menu items.
    @MainActor func image(size: CGFloat = 20) -> Image {
        Image(uiImage: IconImages.render(key: "\(rawValue)-\(size)", size: CGSize(width: size, height: size)) {
            LucideIcon(self, size: size)
        })
    }
}

/// A Lucide icon at the Mac's stroke. `lineWidth` is in the icon's 24-unit box.
struct LucideIcon: View {
    let path: Path
    var size: CGFloat = 20
    var lineWidth: CGFloat = 1.5
    init(_ icon: Lucide, size: CGFloat = 20, lineWidth: CGFloat = 1.5) { self.init(path: icon.path, size: size, lineWidth: lineWidth) }
    /// A profile icon by its Mac key (ProfileIcon.swift).
    init(profile key: String, size: CGFloat = 20, lineWidth: CGFloat = 1.5) { self.init(path: ProfileIcon.path(key), size: size, lineWidth: lineWidth) }
    init(path: Path, size: CGFloat = 20, lineWidth: CGFloat = 1.5) { self.path = path; self.size = size; self.lineWidth = lineWidth }
    var body: some View {
        IconStroke(path: path, lineWidth: lineWidth)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Strokes 24×24 path data scaled into the frame.
struct IconStroke: View {
    let path: Path
    var lineWidth: CGFloat = 1.5
    var box = CGSize(width: 24, height: 24)
    var fill = false
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / box.width, size.height / box.height)
            let shaped = path.applying(CGAffineTransform(scaleX: scale, y: scale))
            if fill { context.fill(shaped, with: .foreground) }
            context.stroke(shaped, with: .foreground, style: StrokeStyle(lineWidth: lineWidth * scale, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: Finger icon (Mac FingerIcon)

/// The brand hand with the index or middle finger raised. Hold fills it; a release keeps the
/// fill in the palm only, the hold draining away; a double tap adds a second outline behind;
/// a tap shows the knuckle ticks.
struct FingerIcon: View {
    enum Finger { case index, middle }
    let finger: Finger
    var hold = false
    var release = false
    var double = false
    var size: CGFloat = 20

    private static let indexOutline = "M6 14V4a2 2 0 0 1 4 0v6a2 2 0 0 1 4 0v1a2 2 0 0 1 4 0v2a2 2 0 0 1 4 0v1a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15Z"
    private static let middleOutline = "M6 14v-3a2 2 0 0 1 4 0V3a2 2 0 0 1 4 0v8a2 2 0 0 1 4 0v2a2 2 0 0 1 4 0v1a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15Z"
    private static let indexTicks = "M10 10v2m4-1v2m4 0v1"
    private static let middleTicks = "M10 11v2m4-2v2m4 0v1"

    var body: some View {
        let outline = SVGPath.cached(finger == .index ? Self.indexOutline : Self.middleOutline)
        let ticks = SVGPath.cached(finger == .index ? Self.indexTicks : Self.middleTicks)
        let box = CGSize(width: double ? 28 : 24, height: 24)
        Canvas { context, size in
            let scale = min(size.width / box.width, size.height / box.height)
            let t = CGAffineTransform(scaleX: scale, y: scale)
            let style = StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round, lineJoin: .round)
            let front = outline.applying(t)
            if double {
                // The second outline sits 4 units right, cut away wherever the front hand is.
                let back = outline.applying(CGAffineTransform(translationX: 4, y: 0).concatenating(t))
                context.drawLayer { inner in
                    inner.stroke(back, with: .foreground, style: style)
                    inner.blendMode = .destinationOut
                    inner.fill(front, with: .color(.black))
                    inner.stroke(front, with: .color(.black), style: StrokeStyle(lineWidth: 3.5 * scale, lineCap: .round, lineJoin: .round))
                }
            }
            if hold { context.fill(front, with: .foreground) }
            if release {
                var palm = context
                palm.clip(to: Path(CGRect(x: 0, y: 14.5 * scale, width: size.width, height: size.height)))
                palm.fill(front, with: .foreground)
            }
            context.stroke(front, with: .foreground, style: style)
            if !hold, !release { context.stroke(ticks.applying(t), with: .foreground, style: style) }
        }
        .frame(width: double ? size * 28 / 24 : size, height: size)
        .accessibilityHidden(true)
    }
}

/// The hand: what a gesture asks of you. Fingers for taps, holds and releases; arrows for
/// swipes; Rotate3D and Move3D for motion. Shown where a gesture is taught or chosen; where
/// one is recorded or written into a sequence, its rune (`RuneIcon`) stands for it.
struct GestureIcon: View {
    let gesture: GestureKind
    var size: CGFloat = 20
    var body: some View {
        switch gesture {
        case .tapIndex: FingerIcon(finger: .index, size: size)
        case .tapMiddle: FingerIcon(finger: .middle, size: size)
        case .releaseIndex: FingerIcon(finger: .index, release: true, size: size)
        case .releaseMiddle: FingerIcon(finger: .middle, release: true, size: size)
        case .doubleTapIndex: FingerIcon(finger: .index, double: true, size: size)
        case .doubleTapMiddle: FingerIcon(finger: .middle, double: true, size: size)
        case .holdIndex: FingerIcon(finger: .index, hold: true, size: size)
        case .holdMiddle: FingerIcon(finger: .middle, hold: true, size: size)
        case .swipeUp: LucideIcon(.arrowUp, size: size, lineWidth: 1.4)
        case .swipeDown: LucideIcon(.arrowDown, size: size, lineWidth: 1.4)
        case .swipeLeft: LucideIcon(.arrowLeft, size: size, lineWidth: 1.4)
        case .swipeRight: LucideIcon(.arrowRight, size: size, lineWidth: 1.4)
        case .rotation: LucideIcon(.rotate3d, size: size, lineWidth: 1.4)
        case .movement: LucideIcon(.move3d, size: size, lineWidth: 1.4)
        case .air: LucideIcon(.spline, size: size, lineWidth: 1.4)
        }
    }
    @MainActor static func image(_ gesture: GestureKind, size: CGFloat = 20) -> Image {
        Image(uiImage: IconImages.render(key: "gesture-\(gesture.rawValue)-\(size)", size: CGSize(width: size * 28 / 24, height: size)) {
            GestureIcon(gesture: gesture, size: size)
        })
    }
}

// MARK: Gesture runes

/// The Runes glyphs for gestures (Documentation/rune-icons), in the icons' 24-unit box at their
/// 1.5 stroke. A stave is a finger, with a shorter one beside it for the middle finger; a bead
/// is a touch; a ring is a touch that lasts; an arc is anything that moves.
enum GestureRune {
    /// `fall` runs a release from the hold's ring at the head of the stave (0) to its foot (1).
    static func path(_ gesture: GestureKind, fall: CGFloat = 1) -> Path {
        let middle = gesture.finger == "middle", x: CGFloat = middle ? 15.5 : 12
        var path = Path()
        func line(_ x: CGFloat, _ from: CGFloat, _ to: CGFloat) {
            path.move(to: CGPoint(x: x, y: from)); path.addLine(to: CGPoint(x: x, y: to))
        }
        func bead(_ y: CGFloat) {
            // Two stroked circles make a solid dot, so every rune stays stroke-only.
            for r in [1.25, 0.5] as [CGFloat] { path.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
        }
        func ringed(at y: CGFloat) {
            if y - 3 > 4 { line(x, 4, y - 3) }
            path.addEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
            if y + 3 < 20 { line(x, y + 3, 20) }
        }
        if middle { line(8.5, 9, 20) }
        switch gesture {
        case .tapIndex, .tapMiddle: line(x, 4, 20); bead(12)
        case .doubleTapIndex, .doubleTapMiddle: line(x, 4, 20); bead(8.5); bead(15.5)
        case .holdIndex, .holdMiddle: ringed(at: 7)
        case .releaseIndex, .releaseMiddle: ringed(at: 7 + 10 * min(1, max(0, fall)))
        case .swipeUp: return SVGPath.cached("M12 20V4M6 8A6.5 6.5 0 0 1 18 8")
        case .swipeDown: return SVGPath.cached("M12 4V20M6 16A6.5 6.5 0 0 0 18 16")
        case .swipeLeft: return SVGPath.cached("M20 12H4M8 6A6.5 6.5 0 0 0 8 18")
        case .swipeRight: return SVGPath.cached("M4 12H20M16 6A6.5 6.5 0 0 1 16 18")
        case .rotation: return SVGPath.cached("M12 5A7 7 0 1 1 5 12M3.75 12a1.25 1.25 0 1 0 2.5 0a1.25 1.25 0 1 0-2.5 0ZM4.5 12a.5.5 0 1 0 1 0a.5.5 0 1 0-1 0Z")
        case .movement: return SVGPath.cached("M12 13.5V5M12 13.5L5 17.5M12 13.5L19 17.5M10.75 13.5a1.25 1.25 0 1 0 2.5 0a1.25 1.25 0 1 0-2.5 0ZM11.5 13.5a.5.5 0 1 0 1 0a.5.5 0 1 0-1 0Z")
        case .air: return SVGPath.cached("M4 16C9 16 15.5 12.5 15.5 8.5A3.5 3.5 0 0 0 8.5 8.5C8.5 12.5 13.5 16 17.5 16M17.75 16a1.25 1.25 0 1 0 2.5 0a1.25 1.25 0 1 0-2.5 0ZM18.5 16a.5.5 0 1 0 1 0a.5.5 0 1 0-1 0Z")
        }
        return path
    }
}

/// A gesture's rune as an icon.
struct RuneIcon: View {
    let gesture: GestureKind
    var size: CGFloat = 20
    var body: some View {
        IconStroke(path: GestureRune.path(gesture)).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// A combo step written as a rune, plus the axis (and direction) for motion.
struct RuneStep: View {
    let step: ComboStep
    var size: CGFloat = 20
    var body: some View {
        HStack(spacing: 2) {
            RuneIcon(gesture: step.gesture, size: size)
            if let axis = step.axis {
                Text(axis.rawValue.uppercased() + (step.gesture == .rotation ? (step.direction ?? .any).arrow : ""))
                    .font(.geist(max(10, size * 0.5), .medium, relativeTo: .caption2)).opacity(0.6)
            }
        }
        .accessibilityElement().accessibilityLabel(step.name)
    }
}

/// Renders icon views into cached template images for menus.
@MainActor enum IconImages {
    private static var cache: [String: UIImage] = [:]
    static func render<V: View>(key: String, size: CGSize, _ view: () -> V) -> UIImage {
        if let image = cache[key] { return image }
        let renderer = ImageRenderer(content: view().foregroundStyle(.black).frame(width: size.width, height: size.height))
        renderer.scale = UIScreen.main.scale
        let image = (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysTemplate)
        cache[key] = image
        return image
    }
}

