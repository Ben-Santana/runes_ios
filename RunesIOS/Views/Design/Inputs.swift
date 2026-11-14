import SwiftUI
import UIKit

// Editing in the app's own parts: sheets, choices, chips, switches and fields.
// Documentation/StyleGuide.md §6 lists every part; Views/Design/StyleGuide.swift draws them.

/// A small editing sheet: inline title, Cancel, and one confirming action. Content scrolls only
/// when it must.
struct FormSheet<Content: View>: View {
    let title: String
    var done = "Done"
    var canSave = true
    let save: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    init(_ title: String, done: String = "Done", canSave: Bool = true, save: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.done = done; self.canSave = canSave; self.save = save; self.content = content
    }
    var body: some View {
        NavigationStack {
            ScrollView { content().padding(Metric.gutter) }
                .scrollBounceBehavior(.basedOnSize)
                .page()
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.label) }
                    ToolbarItem(placement: .confirmationAction) { Button(done) { save(); dismiss() }.font(.label).disabled(!canSave) }
                }
        }
        .tint(Color.ink)
    }
}

/// Options as panel rows, the chosen one checked. Inline in a form, or inside `ChoiceSheet`.
struct ChoiceList<Value: Hashable, Label: View>: View {
    let options: [Value]
    let selected: Value?
    @ViewBuilder let label: (Value) -> Label
    let choose: (Value) -> Void
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                let on = option == selected
                if index > 0 { Rule() }
                Button { choose(option) } label: {
                    HStack(spacing: 12) {
                        label(option)
                        Spacer(minLength: 8)
                        LucideIcon(.check, size: 16).opacity(on ? 1 : 0).scaleEffect(on ? 1 : 0.6)
                    }
                    .panelRow(height: Metric.rowTall)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .panel()
        .animation(.standard, value: selected)
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// A medium sheet that asks one question with a list of answers; choosing one closes it.
struct ChoiceSheet<Value: Hashable, Label: View>: View {
    let title: String
    let options: [Value]
    let selected: Value?
    var caption: String? = nil
    @ViewBuilder let label: (Value) -> Label
    let choose: (Value) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ChoiceList(options: options, selected: selected, label: label) { choose($0); dismiss() }
                    if let caption { Text(caption).font(.caption).foregroundStyle(Color.muted).padding(.horizontal, 2) }
                }
                .padding(Metric.gutter)
            }
            .scrollBounceBehavior(.basedOnSize)
            .page()
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.label) } }
        }
        .tint(Color.ink)
        .presentationDetents([.medium, .large])
    }
}

/// Discrete values as a scrolling row of pills, the chosen one in ink; it scrolls to the selection.
struct ChipRow<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        let on = option == selection
                        Button { withAnimation(.standard) { selection = option; reader.scrollTo(option, anchor: .center) } } label: {
                            Text(title(option)).font(.label).monospacedDigit().lineLimit(1)
                                .foregroundStyle(on ? Color.paper : Color.ink)
                                .padding(.horizontal, 12).frame(minHeight: 36)
                                .background(on ? Color.ink : Color.paper, in: RoundedRectangle(cornerRadius: Metric.control))
                                .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: on ? 0 : Metric.hairline))
                        }
                        .buttonStyle(.plain)
                        .id(option)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Metric.inset).padding(.vertical, 1)
            }
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: Metric.inset)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: Metric.inset)
                }
            )
            .onAppear { reader.scrollTo(selection, anchor: .center) }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// A one-line title field in display type, underlined by a rule that wakes with focus.
struct TitleField: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(prompt, text: $text).font(.display).focused(focus).submitLabel(.done)
            FocusRule(active: focus.wrappedValue)
        }
    }
}

/// An underline that darkens and thickens from the centre while its field is focused.
struct FocusRule: View {
    let active: Bool
    var body: some View {
        ZStack {
            Rectangle().fill(Color.rule).frame(height: Metric.hairline)
            Rectangle().fill(Color.ink).frame(height: 1.5).scaleEffect(x: active ? 1 : 0, anchor: .center)
        }
        .animation(.spring(duration: 0.4, bounce: 0.1), value: active)
    }
}

/// A switch in ink and hairline: an outline with an open knob when off, filled with the
/// knob in paper when on, so it reads in both appearances.
struct HairlineSwitch: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .center, spacing: 16) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Color.ink : Color.clear)
                    Capsule().strokeBorder(configuration.isOn ? Color.ink : Color.faint, lineWidth: Metric.hairline)
                    Circle().fill(configuration.isOn ? Color.paper : Color.clear)
                        .overlay(Circle().strokeBorder(configuration.isOn ? Color.clear : Color.ink, lineWidth: Metric.hairline))
                        .frame(width: 22, height: 22).padding(4)
                }
                .frame(width: 52, height: 30)
                .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// A small hairline chip showing a number and its unit. Tapping it shows + above and − below and
/// opens the keyboard to type the number; tapping elsewhere or Done puts it away.
struct NumberChip: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var decimals = false
    let unit: String
    /// Shown instead of the number when it is zero, such as "No weight".
    var zeroText: String? = nil
    let label: String

    @FocusState private var focused: Bool
    @State private var text = ""
    static let width: CGFloat = 92

    var body: some View {
        VStack(spacing: 6) {
            if focused { stepButton(plus: true).transition(.move(edge: .bottom).combined(with: .opacity)) }
            ZStack {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    TextField("", text: $text)
                        .keyboardType(decimals ? .decimalPad : .numberPad)
                        .focused($focused)
                        .font(.geist(17, .medium, relativeTo: .body)).monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                    Text(unit).font(.caption).foregroundStyle(Color.muted)
                }
                .opacity(focused ? 1 : 0)
                if !focused {
                    display.allowsHitTesting(false)
                }
            }
            .frame(width: Self.width, height: 38)
            .background(RoundedRectangle(cornerRadius: Metric.control).fill(focused ? Color.soft : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(focused ? Color.ink : Color.rule, lineWidth: Metric.hairline))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            if focused { stepButton(plus: false).transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .animation(.spring(duration: 0.3, bounce: 0.2), value: focused)
        .onAppear { text = format(value) }
        .onChange(of: focused) { _, now in
            if now { text = value == 0 && zeroText != nil ? "" : format(value) } else { commit() }
        }
        .onChange(of: text) { _, typed in
            guard focused, let number = parse(typed) else { return }
            value = clamp(number)
        }
        .onChange(of: value) { _, new in if !focused { text = format(new) } }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value == 0 ? (zeroText ?? "0") : "\(format(value)) \(unit)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = clamp(value + step)
            case .decrement: value = clamp(value - step)
            @unknown default: break
            }
        }
    }

    @ViewBuilder private var display: some View {
        if value == 0, let zeroText {
            Text(zeroText).font(.caption).foregroundStyle(Color.muted)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(format(value)).font(.geist(17, .medium, relativeTo: .body)).monospacedDigit()
                    .contentTransition(.numericText(value: value))
                Text(unit).font(.caption).foregroundStyle(Color.muted)
            }
            .animation(.standard, value: value)
        }
    }

    private func stepButton(plus: Bool) -> some View {
        let enabled = plus ? value < range.upperBound : value > range.lowerBound
        return Button {
            value = clamp(value + (plus ? step : -step))
            text = format(value)
        } label: {
            ZStack {
                Rectangle().frame(width: 12, height: 1.4)
                if plus { Rectangle().frame(width: 1.4, height: 12) }
            }
            .frame(width: Self.width, height: 34)
            .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(Ripple())
        .buttonRepeatBehavior(.enabled)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(plus ? "More" : "Less")
    }

    private func clamp(_ v: Double) -> Double {
        let snapped = decimals ? (v * 10).rounded() / 10 : v.rounded()
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
    private func parse(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }
    private func commit() {
        if let number = parse(text) { value = clamp(number) }
        text = format(value)
    }
    private func format(_ v: Double) -> String {
        decimals && v.rounded() != v ? String(format: "%.1f", v) : String(Int(v))
    }
}

extension NumberChip {
    /// For a whole-number setting such as sets or reps.
    init(int: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, unit: String, label: String) {
        self.init(value: Binding(get: { Double(int.wrappedValue) }, set: { int.wrappedValue = Int($0) }),
                  range: Double(range.lowerBound)...Double(range.upperBound), step: Double(step), unit: unit, label: label)
    }
    /// For an optional weight, where zero means none.
    init(weight: Binding<Double?>, unit: WeightUnit) {
        self.init(value: Binding(get: { weight.wrappedValue ?? 0 }, set: { weight.wrappedValue = $0 > 0 ? $0 : nil }),
                  range: WorkoutItem.weightRange, step: unit.step, decimals: true, unit: unit.title, zeroText: "No weight", label: "Weight")
    }
}

/// Hides the keyboard: the Done button above it.
@MainActor func endEditing() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
