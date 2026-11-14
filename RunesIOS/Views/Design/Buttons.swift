import SwiftUI

// Buttons and press styles. One primary per screen; icons sit in a 44 pt target.
// Documentation/StyleGuide.md §6 lists every part; Views/Design/StyleGuide.swift draws them.

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label)
            .foregroundStyle(Color.paper)
            .frame(maxWidth: .infinity, minHeight: Metric.row)
            .padding(.horizontal, 16)
            .background(Color.ink.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: Metric.control))
            .opacity(enabled ? 1 : 0.45)
            .animation(.standard, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label)
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity, minHeight: Metric.row)
            .padding(.horizontal, 16)
            .background(configuration.isPressed ? Color.soft : Color.paper, in: RoundedRectangle(cornerRadius: Metric.control))
            .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(selected ? Color.ink : Color.rule, lineWidth: Metric.hairline))
            .opacity(enabled ? 1 : 0.45)
            .animation(.standard, value: configuration.isPressed)
    }
}

/// Text-only action, for secondary choices under a primary button.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label)
            .foregroundStyle(Color.muted)
            .frame(minHeight: Metric.tap)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.standard, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle { static var primary: PrimaryButtonStyle { .init() } }
extension ButtonStyle where Self == SecondaryButtonStyle { static var secondary: SecondaryButtonStyle { .init() } }
extension ButtonStyle where Self == QuietButtonStyle { static var quiet: QuietButtonStyle { .init() } }

/// A Lucide icon in a 44 × 44 target, for headers and toolbars. Label it where you use it.
struct IconButton: View {
    let icon: Lucide
    var size: CGFloat = 20
    let action: () -> Void
    init(_ icon: Lucide, size: CGFloat = 20, action: @escaping () -> Void) { self.icon = icon; self.size = size; self.action = action }
    var body: some View {
        Button(action: action) {
            LucideIcon(icon, size: size).frame(width: Metric.tap, height: Metric.tap).contentShape(Rectangle())
        }
    }
}

/// The leading back chevron for a full-screen cover's root (Settings, Mappings, Applications),
/// so closing it looks like going back from any pushed screen.
struct BackToolbarItem: ToolbarContent {
    let action: () -> Void
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: action) { Image(systemName: "chevron.backward").font(.system(size: 17, weight: .semibold)) }
                .accessibilityLabel("Back")
        }
    }
}

struct RoundAction: View {
    let icon: Lucide
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().strokeBorder(Color.rule, lineWidth: Metric.hairline)
                    LucideIcon(icon, size: 18)
                }
                .frame(width: 52, height: 52)
                Text(label).font(.caption).foregroundStyle(Color.muted)
            }
        }
        .buttonStyle(Ripple())
        .opacity(enabled ? 1 : 0.3)
    }
}

/// The main run action: a filled or hairline capsule.
struct CapsuleAction: ButtonStyle {
    let filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label)
            .foregroundStyle(filled ? Color.paper : Color.ink)
            .frame(maxWidth: .infinity, minHeight: Metric.rowTall)
            .background(Capsule().fill(filled ? Color.ink : Color.clear))
            .overlay(Capsule().strokeBorder(Color.ink, lineWidth: Metric.hairline))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .padding(.bottom, 20)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

/// Rows dim slightly when pressed; no fill.
struct PressRow: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.standard, value: configuration.isPressed)
    }
}

/// Round hairline buttons shrink and send a ring outward when pressed.
struct Ripple: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .background(
                Circle().stroke(Color.ink, lineWidth: Metric.hairline)
                    .scaleEffect(configuration.isPressed ? 1.25 : 1)
                    .opacity(configuration.isPressed ? 0.35 : 0)
            )
            .animation(.spring(duration: 0.3, bounce: 0.45), value: configuration.isPressed)
    }
}
