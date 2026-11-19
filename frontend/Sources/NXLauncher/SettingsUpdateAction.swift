import SwiftUI

/// A stable action footprint while an update checks, downloads or prepares.
package struct SettingsUpdateAction: View {
    let title: String
    let busy: Bool
    let prominent: Bool
    let action: () -> Void
    package init(_ title: String, busy: Bool = false, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.busy = busy; self.prominent = prominent; self.action = action
    }
    private var label: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small).accessibilityHidden(true) }
            Text(title).lineLimit(1).minimumScaleFactor(LauncherControl.minimumLabelScale)
        }.font(.manrope(13, .semibold))
    }
    package var body: some View {
        Group {
            if prominent {
                Button(action: action) { label.frame(width: LauncherControl.width, height: LauncherControl.height) }
                    .buttonStyle(LauncherActionButtonStyle())
            } else {
                Button(action: action) { label.frame(width: LauncherControl.buttonLabelWidth) }
                    .buttonStyle(LauncherSecondaryButtonStyle())
            }
        }.disabled(busy).accessibilityLabel(title)
    }
}
