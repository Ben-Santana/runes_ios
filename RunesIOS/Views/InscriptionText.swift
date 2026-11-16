import SwiftUI
import UIKit

// An inscription's words as a text view that can be formatted: select some words and the menu
// over them offers bold, italic, a highlight and a colour. The formatting is kept as TextMarks
// beside the plain text, which everything else (titles, sets, sharing) goes on reading.

extension NSAttributedString.Key {
    fileprivate static let markBold = Self("runes.bold")
    fileprivate static let markItalic = Self("runes.italic")
    fileprivate static let markHighlight = Self("runes.highlight")
    fileprivate static let markColor = Self("runes.color")
}

extension TextMark.Ink {
    var title: String { rawValue.capitalized }
    var color: UIColor {
        switch self {
        case .yellow: .systemYellow
        case .orange: .systemOrange
        case .red: .systemRed
        case .pink: .systemPink
        case .purple: .systemPurple
        case .blue: .systemBlue
        case .green: .systemGreen
        }
    }
    /// Yellow words can't be read on white, so it is only a highlight.
    static let textColors: [Self] = [.red, .orange, .pink, .purple, .blue, .green]
}

@MainActor
final class InscriptionText: NSObject, ObservableObject, UITextViewDelegate {
    @Published private(set) var focused = false
    @Published private(set) var isEmpty = true
    /// Empty, or being written after starting empty: the box keeps its room until writing ends.
    @Published private(set) var roomy = true
    /// Bumped on every change, so the view is measured again.
    @Published private(set) var revision = 0
    let view = UITextView()

    private static let size: CGFloat = 19
    private var ink: UIColor { UIColor(Color.ink) }

    override init() {
        super.init()
        view.delegate = self
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityLabel = "Inscription text"
        view.typingAttributes = base
    }

    private var base: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        return [.font: Self.font(bold: false, italic: false), .foregroundColor: ink, .paragraphStyle: paragraph]
    }

    /// Geist has no italic, so italic is Geist slanted.
    private static func font(bold: Bool, italic: Bool) -> UIFont {
        var font = UIFont(name: bold ? "Geist-SemiBold" : "Geist-Regular", size: size)
            ?? .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if italic {
            let slant = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
            font = UIFont(descriptor: font.fontDescriptor.withMatrix(slant), size: size)
        }
        return UIFontMetrics(forTextStyle: .title3).scaledFont(for: font)
    }

    // MARK: In and out

    func load(_ text: String, marks: [TextMark]?) {
        let string = NSMutableAttributedString(string: text, attributes: base)
        let length = string.length
        for mark in marks ?? [] {
            let start = max(0, min(mark.start, length)), end = max(start, min(mark.start + mark.length, length))
            let range = NSRange(location: start, length: end - start)
            guard range.length > 0 else { continue }
            if mark.bold { string.addAttribute(.markBold, value: true, range: range) }
            if mark.italic { string.addAttribute(.markItalic, value: true, range: range) }
            if let ink = mark.highlight { string.addAttribute(.markHighlight, value: ink.rawValue, range: range) }
            if let ink = mark.color { string.addAttribute(.markColor, value: ink.rawValue, range: range) }
        }
        restyle(string, in: NSRange(location: 0, length: length))
        view.attributedText = string
        view.typingAttributes = base
        changed()
    }

    /// The words without the space around them, and their formatting.
    var saved: (text: String, marks: [TextMark]?) {
        let string = view.attributedText ?? NSAttributedString()
        let plain = string.string as NSString
        let first = plain.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
        guard first.location != NSNotFound else { return ("", nil) }
        let last = plain.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards)
        let kept = string.attributedSubstring(from: NSRange(location: first.location, length: NSMaxRange(last) - first.location))
        var marks: [TextMark] = []
        kept.enumerateAttributes(in: NSRange(location: 0, length: kept.length)) { attributes, range, _ in
            let mark = TextMark(start: range.location, length: range.length,
                                bold: attributes[.markBold] as? Bool ?? false,
                                italic: attributes[.markItalic] as? Bool ?? false,
                                highlight: (attributes[.markHighlight] as? String).flatMap(TextMark.Ink.init),
                                color: (attributes[.markColor] as? String).flatMap(TextMark.Ink.init))
            if mark.bold || mark.italic || mark.highlight != nil || mark.color != nil { marks.append(mark) }
        }
        return (kept.string, marks.isEmpty ? nil : marks)
    }

    func focus() { view.isEditable = true; view.becomeFirstResponder() }

    // MARK: Following the recording

    private var timeline: [(range: NSRange, at: Double)] = []
    private var timelineRevision = -1
    /// Where the said words end, while the recording plays; nil when not following.
    private var said: Int?

    /// Greys the words, then inks each as the recording reaches it. nil puts them back.
    func follow(_ time: Double?, spoken: [SpokenWord]?, duration: Double) {
        let storage = view.textStorage
        guard let time, !focused else {
            if said != nil { said = nil; recolor(NSRange(location: 0, length: storage.length), grey: false) }
            return
        }
        if timelineRevision != revision {
            timeline = SpokenWord.timeline(of: storage.string, spoken: spoken, duration: duration)
            timelineRevision = revision
        }
        // Said up to the start of the first word not yet reached, so its punctuation inks with it.
        let end = timeline.first(where: { $0.at > time })?.range.location ?? storage.length
        guard end != said else { return }
        said = end
        storage.beginEditing()
        recolor(NSRange(location: 0, length: end), grey: false)
        recolor(NSRange(location: end, length: storage.length - end), grey: true)
        storage.endEditing()
    }

    private func recolor(_ range: NSRange, grey: Bool) {
        let storage = view.textStorage
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let muted = UIColor(Color.muted)
        storage.enumerateAttribute(.markColor, in: range) { value, run, _ in
            let color = grey ? muted : (value as? String).flatMap(TextMark.Ink.init)?.color ?? ink
            storage.addAttribute(.foregroundColor, value: color, range: run)
        }
    }
    func resign() { view.resignFirstResponder() }

    // MARK: Formatting

    private func restyle(_ string: NSMutableAttributedString, in range: NSRange) {
        string.enumerateAttributes(in: range) { attributes, run, _ in
            let bold = attributes[.markBold] as? Bool ?? false, italic = attributes[.markItalic] as? Bool ?? false
            string.addAttribute(.font, value: Self.font(bold: bold, italic: italic), range: run)
            let color = (attributes[.markColor] as? String).flatMap(TextMark.Ink.init)?.color ?? ink
            string.addAttribute(.foregroundColor, value: color, range: run)
            if let highlight = (attributes[.markHighlight] as? String).flatMap(TextMark.Ink.init) {
                string.addAttribute(.backgroundColor, value: highlight.color.withAlphaComponent(0.3), range: run)
            } else {
                string.removeAttribute(.backgroundColor, range: run)
            }
        }
    }

    private func format(_ range: NSRange, _ change: (NSTextStorage) -> Void) {
        let storage = view.textStorage
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.beginEditing()
        change(storage)
        restyle(storage, in: range)
        storage.endEditing()
        changed()
    }

    private func everywhere(_ key: NSAttributedString.Key, in range: NSRange) -> Bool {
        var all = true
        view.textStorage.enumerateAttribute(key, in: range) { value, _, stop in
            if (value as? Bool) != true { all = false; stop.pointee = true }
        }
        return all
    }

    private func toggle(_ key: NSAttributedString.Key, in range: NSRange) {
        let on = !everywhere(key, in: range)
        format(range) { on ? $0.addAttribute(key, value: true, range: range) : $0.removeAttribute(key, range: range) }
    }

    private func paint(_ key: NSAttributedString.Key, _ ink: TextMark.Ink?, in range: NSRange) {
        format(range) { storage in
            if let ink { storage.addAttribute(key, value: ink.rawValue, range: range) } else { storage.removeAttribute(key, range: range) }
        }
    }

    private static func swatch(_ color: UIColor?) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { _ in
            let circle = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 16, height: 16))
            if let color { color.setFill(); circle.fill() } else { UIColor.secondaryLabel.setStroke(); circle.lineWidth = 1; circle.stroke() }
        }.withRenderingMode(.alwaysOriginal)
    }

    // MARK: UITextViewDelegate

    private func changed() {
        isEmpty = view.textStorage.length == 0
        roomy = isEmpty || (focused && roomy)
        revision &+= 1
    }

    func textViewDidChange(_ textView: UITextView) { changed() }
    func textViewDidBeginEditing(_ textView: UITextView) {
        if said != nil { said = nil; recolor(NSRange(location: 0, length: textView.textStorage.length), grey: false) }
        textView.typingAttributes[.foregroundColor] = (textView.typingAttributes[.markColor] as? String).flatMap(TextMark.Ink.init)?.color ?? ink
        focused = true; roomy = isEmpty
    }
    func textViewDidEndEditing(_ textView: UITextView) { focused = false; roomy = isEmpty }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0, textView.isEditable else { return nil }
        let bold = UIAction(title: "Bold", image: UIImage(systemName: "bold"),
                            state: everywhere(.markBold, in: range) ? .on : .off) { [weak self] _ in self?.toggle(.markBold, in: range) }
        let italic = UIAction(title: "Italic", image: UIImage(systemName: "italic"),
                              state: everywhere(.markItalic, in: range) ? .on : .off) { [weak self] _ in self?.toggle(.markItalic, in: range) }
        let highlight = UIMenu(title: "Highlight", image: UIImage(systemName: "highlighter"), children:
            TextMark.Ink.allCases.map { ink in
                UIAction(title: ink.title, image: Self.swatch(ink.color.withAlphaComponent(0.5))) { [weak self] _ in self?.paint(.markHighlight, ink, in: range) }
            } + [UIAction(title: "None", image: Self.swatch(nil)) { [weak self] _ in self?.paint(.markHighlight, nil, in: range) }])
        let color = UIMenu(title: "Text Color", image: UIImage(systemName: "paintpalette"), children:
            TextMark.Ink.textColors.map { ink in
                UIAction(title: ink.title, image: Self.swatch(ink.color)) { [weak self] _ in self?.paint(.markColor, ink, in: range) }
            } + [UIAction(title: "Default", image: Self.swatch(ink)) { [weak self] _ in self?.paint(.markColor, nil, in: range) }])
        return UIMenu(children: [UIMenu(options: .displayInline, children: [bold, italic, highlight, color])] + suggestedActions)
    }
}

/// The text view, sized to its words.
struct InscriptionTextView: UIViewRepresentable {
    @ObservedObject var model: InscriptionText
    var editable = true

    func makeUIView(context: Context) -> UITextView { model.view }

    func updateUIView(_ view: UITextView, context: Context) {
        view.isEditable = editable
        view.isSelectable = editable
        view.isUserInteractionEnabled = editable
        _ = model.revision
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}
