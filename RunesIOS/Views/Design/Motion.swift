import SwiftUI

// Movement that explains: arrivals, a working state, edit mode. Each one rests under Reduce Motion.
// Documentation/StyleGuide.md §6 lists every part; Views/Design/StyleGuide.swift draws them.

struct Arrive: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .onAppear { withAnimation(.spring(duration: 0.5, bounce: 0.15).delay(0.05 * Double(index))) { shown = true } }
    }
}

extension View {
    /// Fades and rises in, staggered by `index`.
    func arrive(_ index: Int) -> some View { modifier(Arrive(index: index)) }
}

/// Fades gently in and out while something is being worked on.
struct Breathing: ViewModifier {
    let active: Bool
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.45 : 1)
            .task(id: active) {
                guard active, !reduceMotion else { dim = false; return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

extension View {
    func breathing(_ active: Bool) -> some View { modifier(Breathing(active: active)) }
}

/// Keeps a view swaying like an iOS home-screen icon in edit mode. Neighbours sway in
/// opposite directions so the row does not move as one block.
struct Jiggle: ViewModifier {
    let active: Bool
    var index: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swing = false

    private var direction: Double { index.isMultiple(of: 2) ? 1 : -1 }

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(active && !reduceMotion ? (swing ? 1.6 : -1.6) * direction : 0))
            .offset(y: active && !reduceMotion ? (swing ? -0.8 : 0.8) : 0)
            .task(id: active) {
                guard active, !reduceMotion else { withAnimation(.standard) { swing = false }; return }
                // Let the view settle before a repeating animation starts; starting one while
                // the view is still being inserted leaves a stale copy on screen.
                try? await Task.sleep(for: .milliseconds(120 + 40 * index))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.13).repeatForever(autoreverses: true)) { swing = true }
            }
    }
}

extension View {
    func jiggle(_ active: Bool, index: Int = 0) -> some View { modifier(Jiggle(active: active, index: index)) }
}
