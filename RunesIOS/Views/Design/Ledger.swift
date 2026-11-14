import SwiftUI

// Open lists: hairlines between rows, a heading that runs to the trailing edge, no boxes.
// Documentation/StyleGuide.md §6 lists every part; Views/Design/StyleGuide.swift draws them.

/// Header, rows and footer stacked tight, so the page's spacing doesn't reach the rows.
struct Block<Content: View, Header: View, Footer: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var header: Header
    @ViewBuilder var footer: Footer
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { header; content; footer }
    }
}

extension Block where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.content = content(); self.header = header(); self.footer = EmptyView()
    }
}

struct Heading: View {
    let title: String
    var count: Int?
    init(_ title: String, count: Int? = nil) { self.title = title; self.count = count }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.label)
            if let count { Text("\(count)").font(.caption).foregroundStyle(Color.muted).monospacedDigit().contentTransition(.numericText()) }
            Rectangle().fill(Color.rule).frame(height: Metric.hairline).padding(.leading, 4).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] - 4 }
        }
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A full-width rule that draws in from the leading edge.
struct Hairline: View {
    var inset: CGFloat = 0
    var delay: Double = 0
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Rectangle().fill(Color.rule).frame(height: Metric.hairline)
            .scaleEffect(x: drawn || reduceMotion ? 1 : 0, anchor: .leading)
            .padding(.leading, inset)
            .onAppear { withAnimation(.easeOut(duration: 0.6).delay(delay)) { drawn = true } }
            .accessibilityHidden(true)
    }
}

struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
    }
}

struct AddRow: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().strokeBorder(Color.muted, style: StrokeStyle(lineWidth: Metric.hairline, dash: [2, 3]))
                    LucideIcon(.plus, size: 14)
                }
                .frame(width: 28, height: 28)
                Text(title).font(.bodyText)
                Spacer()
            }
            .padding(.vertical, 16).contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
    }
}

/// Text options over one hairline, with an ink underline that slides to the selection.
struct HairlineSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: KeyPath<Value, String>
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(options, id: \.self) { option in
                    let on = option == selection
                    Button { withAnimation(.spring(duration: 0.4, bounce: 0.25)) { selection = option } } label: {
                        VStack(spacing: 10) {
                            Text(option[keyPath: title]).font(.label).foregroundStyle(on ? Color.ink : Color.muted)
                            ZStack {
                                Color.clear.frame(height: 1.5)
                                if on { Capsule().fill(Color.ink).frame(height: 1.5).matchedGeometryEffect(id: "bar", in: ns) }
                            }
                        }
                        .frame(maxWidth: .infinity).padding(.top, 10).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Rectangle().fill(Color.rule).frame(height: Metric.hairline)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}
