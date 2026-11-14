import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Native segmented choice control with explicit cream selection tint and fixed foreground contrast so SwiftUI state
/// updates never recreate segments, drop in-flight Liquid Glass animations, or invert title text colors.
struct NativeCreamSegmentedControl: View {
    let options: [SettingOption]
    let value: String
    var inline = false
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let change: (String) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.shellIgnoresPress) private var ignoresPress

    var body: some View {
        if inline {
            controlBody
                .frame(minWidth: NativeCreamSegmentedSizing.minimumWidth)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            controlBody
        }
    }

    @ViewBuilder
    private var controlBody: some View {
        #if os(iOS)
        NativeCreamSegmentedRepresentable(
            options: options,
            value: value,
            inline: inline,
            accessibilityLabel: accessibilityLabel,
            accessibilityIdentifier: accessibilityIdentifier,
            isEnabled: isEnabled,
            ignoresPress: ignoresPress,
            change: change
        )
        #else
        Picker(accessibilityLabel, selection: Binding(
            get: { value },
            set: { if !ignoresPress() { change($0) } }
        )) {
            ForEach(options) { option in
                Text(option.label).tag(option.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(ShellPalette.cream)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
        #endif
    }
}

/// Shared sizing rule for compact inline controls vs. full-width editor pickers.
enum NativeCreamSegmentedSizing {
    static let minimumWidth: CGFloat = 200
    static let fallbackHeight: CGFloat = 32

    static func measuredSize(proposal: ProposedViewSize, intrinsicSize: CGSize, inline: Bool) -> CGSize {
        let height = intrinsicSize.height > 0 ? intrinsicSize.height : fallbackHeight
        let naturalWidth = max(minimumWidth, intrinsicSize.width)
        if inline {
            if let proposedWidth = proposal.width, proposedWidth.isFinite, proposedWidth > 0 {
                return CGSize(width: min(naturalWidth, proposedWidth), height: height)
            }
            return CGSize(width: naturalWidth, height: height)
        }
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? naturalWidth
        return CGSize(width: width, height: height)
    }
}

#if os(iOS)
@MainActor
enum NativeCreamSegmentedAppearance {
    static let changeAnimationDuration: TimeInterval = 0.22

    static func selectedIndex(in options: [SettingOption], for value: String) -> Int {
        options.firstIndex(where: { $0.id == value }) ?? UISegmentedControl.noSegment
    }

    static func configureColors(_ control: UISegmentedControl) {
        control.overrideUserInterfaceStyle = .dark
        control.selectedSegmentTintColor = UIColor(ShellPalette.cream)
        control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .highlighted)
        control.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        control.setTitleTextAttributes([.foregroundColor: UIColor.black], for: [.selected, .highlighted])
        control.setTitleTextAttributes([.foregroundColor: UIColor.white.withAlphaComponent(0.45)], for: .disabled)
        control.setTitleTextAttributes([.foregroundColor: UIColor.black.withAlphaComponent(0.65)], for: [.selected, .disabled])
    }

    /// Applies option titles only when they change, and updates `selectedSegmentIndex` only when it differs from
    /// UIKit's live selection so active touch transitions are never cut off mid-flight.
    static func synchronize(
        _ control: UISegmentedControl,
        options: [SettingOption],
        appliedLabels: inout [String],
        value: String,
        isEnabled: Bool,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        animated: Bool
    ) {
        let labels = options.map(\.label)
        if appliedLabels != labels {
            UIView.performWithoutAnimation {
                control.removeAllSegments()
                for (index, label) in labels.enumerated() {
                    control.insertSegment(withTitle: label, at: index, animated: false)
                }
            }
            appliedLabels = labels
            control.invalidateIntrinsicContentSize()
        }

        let targetIndex = selectedIndex(in: options, for: value)
        if control.selectedSegmentIndex != targetIndex {
            if animated, control.window != nil, !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(
                    withDuration: changeAnimationDuration,
                    delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
                ) {
                    control.selectedSegmentIndex = targetIndex
                    control.layoutIfNeeded()
                }
            } else {
                control.selectedSegmentIndex = targetIndex
            }
        }

        if control.isEnabled != isEnabled {
            control.isEnabled = isEnabled
        }
        if control.accessibilityLabel != accessibilityLabel {
            control.accessibilityLabel = accessibilityLabel
        }
        if control.accessibilityIdentifier != accessibilityIdentifier {
            control.accessibilityIdentifier = accessibilityIdentifier
        }
    }

    static func handleValueChange(
        _ control: UISegmentedControl,
        options: [SettingOption],
        currentValue: inout String,
        ignoresPress: () -> Bool,
        change: (String) -> Void
    ) {
        if ignoresPress() {
            let restored = selectedIndex(in: options, for: currentValue)
            if control.selectedSegmentIndex != restored {
                control.selectedSegmentIndex = restored
            }
            return
        }
        let index = control.selectedSegmentIndex
        guard options.indices.contains(index) else { return }
        let nextID = options[index].id
        currentValue = nextID
        change(nextID)
    }
}

private struct NativeCreamSegmentedRepresentable: UIViewRepresentable {
    let options: [SettingOption]
    let value: String
    let inline: Bool
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let isEnabled: Bool
    let ignoresPress: () -> Bool
    let change: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(options: options, value: value, ignoresPress: ignoresPress, change: change)
    }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl()
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        NativeCreamSegmentedAppearance.configureColors(control)
        NativeCreamSegmentedAppearance.synchronize(
            control,
            options: options,
            appliedLabels: &context.coordinator.appliedLabels,
            value: value,
            isEnabled: isEnabled,
            accessibilityLabel: accessibilityLabel,
            accessibilityIdentifier: accessibilityIdentifier,
            animated: false
        )
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.options = options
        context.coordinator.value = value
        context.coordinator.ignoresPress = ignoresPress
        context.coordinator.change = change
        NativeCreamSegmentedAppearance.synchronize(
            control,
            options: options,
            appliedLabels: &context.coordinator.appliedLabels,
            value: value,
            isEnabled: isEnabled,
            accessibilityLabel: accessibilityLabel,
            accessibilityIdentifier: accessibilityIdentifier,
            animated: true
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        let effective = (intrinsic.width > 0 && intrinsic.height > 0) ? intrinsic : uiView.sizeThatFits(.zero)
        return NativeCreamSegmentedSizing.measuredSize(
            proposal: proposal,
            intrinsicSize: effective,
            inline: inline
        )
    }

    @MainActor final class Coordinator: NSObject {
        var options: [SettingOption]
        var appliedLabels: [String] = []
        var value: String
        var ignoresPress: () -> Bool
        var change: (String) -> Void

        init(
            options: [SettingOption],
            value: String,
            ignoresPress: @escaping () -> Bool,
            change: @escaping (String) -> Void
        ) {
            self.options = options
            self.value = value
            self.ignoresPress = ignoresPress
            self.change = change
        }

        @objc func changed(_ control: UISegmentedControl) {
            NativeCreamSegmentedAppearance.handleValueChange(
                control,
                options: options,
                currentValue: &value,
                ignoresPress: ignoresPress,
                change: change
            )
        }
    }
}
#endif
