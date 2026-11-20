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
            if busy { DSSpinner().accessibilityHidden(true) }   // in the button's foreground
            Text(title).lineLimit(1).minimumScaleFactor(LauncherControl.minimumLabelScale)
        }.font(DS.Font.bodyStrong)
    }
    package var body: some View {
        Group {
            if prominent {
                Button(action: action) { label.frame(width: LauncherControl.buttonLabelWidth) }
                    .buttonStyle(LauncherActionButtonStyle())
            } else {
                Button(action: action) { label.frame(width: LauncherControl.buttonLabelWidth) }
                    .buttonStyle(LauncherSecondaryButtonStyle())
            }
        }.disabled(busy).accessibilityLabel(title)
        .launcherRowControls()   // a row's control: the column's width in every state, prominent or not
    }
}
