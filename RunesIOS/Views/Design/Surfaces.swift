import SwiftUI
import UIKit

// Pages, panels, their rows and the cards that carry one sentence and one action.
// Documentation/StyleGuide.md §6 lists every part; Views/Design/StyleGuide.swift draws them.

struct Panel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.paper, in: RoundedRectangle(cornerRadius: Metric.panel))
            .overlay(RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.rule, lineWidth: Metric.hairline))
    }
}

extension View {
    func panel() -> some View { modifier(Panel()) }
    /// A panel row: inset horizontally, at least `height` tall, tappable across its width.
    func panelRow(height: CGFloat = Metric.row) -> some View {
        self.padding(.horizontal, Metric.inset).frame(maxWidth: .infinity, minHeight: height, alignment: .leading).contentShape(Rectangle())
    }
    /// Page chrome shared by every screen.
    func page() -> some View {
        self.background(Color.paper.ignoresSafeArea())
            .foregroundStyle(Color.ink)
            .tint(Color.ink)
            .coordinateSpace(.named(Page.space))
    }
}

enum Page {
    /// The page's coordinate space, for content that draws out to its edges.
    static let space = "page"
}

/// A section label, a panel of rows, and an optional caption under it. The one grouping for
/// Settings, Advanced, Mappings and editors.
struct PanelGroup<Content: View>: View {
    let title: String?
    var caption: String?
    @ViewBuilder var content: Content
    init(_ title: String?, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.caption = caption; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SectionLabel(title).padding(.leading, 2) }
            VStack(spacing: 0) { content }.panel()
            if let caption {
                Text(caption).font(.caption).foregroundStyle(Color.muted).padding(.horizontal, 2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Small caps-free section label, as in the Mac app's panel headings.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(Color.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A hairline divider; inset to match the rows it separates.
struct Rule: View {
    var inset: CGFloat = Metric.inset
    init(inset: CGFloat = Metric.inset) { self.inset = inset }
    var body: some View {
        Rectangle().fill(Color.rule).frame(height: Metric.hairline).padding(.leading, inset).accessibilityHidden(true)
    }
}

/// The trailing mark of a row that opens something.
struct Chevron: View {
    var body: some View { LucideIcon(.chevronRight, size: 16).foregroundStyle(Color.muted) }
}

/// A key and its value on one panel row.
struct ValueRow<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value
    var height: CGFloat = Metric.row
    init(_ title: String, height: CGFloat = Metric.row, @ViewBuilder value: () -> Value) { self.title = title; self.height = height; self.value = value() }
    var body: some View {
        HStack { Text(title).font(.bodyText); Spacer(); value.font(.bodyText).foregroundStyle(Color.muted) }
            .panelRow(height: height)
            .accessibilityElement(children: .combine)
    }
}

/// A panel row that pushes a destination.
struct LinkRow<Destination: View>: View {
    let title: String
    @ViewBuilder var destination: () -> Destination
    init(_ title: String, @ViewBuilder destination: @escaping () -> Destination) { self.title = title; self.destination = destination }
    var body: some View {
        NavigationLink(destination: destination) {
            HStack { Text(title).font(.bodyText); Spacer(); Chevron() }.panelRow()
        }
        .buttonStyle(.plain)
    }
}

/// A panel row that performs an action, with an optional trailing icon.
struct ActionRow: View {
    let title: String
    var icon: Lucide?
    let action: () -> Void
    init(_ title: String, icon: Lucide? = nil, action: @escaping () -> Void) { self.title = title; self.icon = icon; self.action = action }
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.bodyText)
                Spacer()
                if let icon { LucideIcon(icon, size: 16).foregroundStyle(Color.muted) }
            }
            .panelRow()
        }
        .buttonStyle(.plain)
    }
}

/// One plain sentence and one action. Used for every problem the app can show.
struct IssueCard: View {
    let issue: SessionIssue
    let action: (SessionIssue.Action) -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle().fill(issue.isGentle ? Color.muted : Color.ink).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(issue.sentence).font(.bodyText).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(issue.actionTitle) { action(issue.action) }
                .font(.label)
                .padding(.horizontal, 12).frame(minHeight: 36)
                .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
        }
        .padding(.horizontal, Metric.inset).padding(.vertical, 12)
        .background(Color.soft, in: RoundedRectangle(cornerRadius: Metric.panel))
        .overlay(RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.rule, lineWidth: Metric.hairline))
        .accessibilityElement(children: .combine)
    }
}

/// One sentence and one action, like the home screen's issue card.
struct NoticeCard: View {
    let sentence: String
    let actionTitle: String
    let action: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle().fill(Color.ink).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(sentence).font(.bodyText).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Button(actionTitle, action: action)
                .font(.label)
                .padding(.horizontal, 12).frame(minHeight: 36)
                .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
        }
        .padding(.horizontal, Metric.inset).padding(.vertical, 12)
        .background(Color.soft, in: RoundedRectangle(cornerRadius: Metric.panel))
        .overlay(RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.rule, lineWidth: Metric.hairline))
    }
}

extension UIApplication {
    /// The window's own top safe area (status bar or island), without any navigation bar,
    /// for full-bleed screens that line their top row up with the bar.
    var windowSafeTop: CGFloat {
        connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.top ?? 0
    }
}
