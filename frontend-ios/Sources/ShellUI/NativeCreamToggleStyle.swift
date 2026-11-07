import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A system switch with the app's cream track and a contrasting thumb only while on.
struct NativeCreamToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(iOS)
        HStack(spacing: 16) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            NativeCreamSwitch(isOn: configuration.$isOn).fixedSize()
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
        #else
        Toggle(isOn: configuration.$isOn) { configuration.label }
            .toggleStyle(.switch).tint(ShellPalette.cream)
        #endif
    }
}

#if os(iOS)
private struct NativeCreamSwitch: UIViewRepresentable {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.shellIgnoresPress) private var ignoresPress

    func makeUIView(context: Context) -> UISwitch {
        let control = UISwitch()
        control.onTintColor = UIColor(ShellPalette.cream)
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISwitch, context: Context) {
        context.coordinator.isOn = $isOn
        context.coordinator.ignoresPress = ignoresPress
        control.setOn(isOn, animated: false)
        control.thumbTintColor = isOn ? .black : nil
        control.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(isOn: $isOn, ignoresPress: ignoresPress) }

    @MainActor final class Coordinator: NSObject {
        var isOn: Binding<Bool>
        var ignoresPress: () -> Bool
        init(isOn: Binding<Bool>, ignoresPress: @escaping () -> Bool) {
            self.isOn = isOn
            self.ignoresPress = ignoresPress
        }
        @objc func changed(_ control: UISwitch) {
            guard !ignoresPress() else { control.setOn(isOn.wrappedValue, animated: false); return }
            control.thumbTintColor = control.isOn ? .black : nil
            isOn.wrappedValue = control.isOn
        }
    }
}
#endif
