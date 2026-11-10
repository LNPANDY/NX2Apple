import SwiftUI

/// A 560 pt question before an action that cannot be undone or changes several things at once: a title, the thing it is about in
/// secondary text, an optional card, a note, then Cancel and the action. Cancel has the focus and answers Escape, so Return never
/// confirms by accident. The action is drawn in red when it removes something.
package struct LauncherConfirmSheet<Content: View>: View {
    let title: String
    let subtitle: String
    let note: String
    let cancelTitle: String
    let confirmTitle: String
    let destructive: Bool
    let scope: String
    let cancel: () -> Void
    let confirm: () -> Void
    let content: Content
    @EnvironmentObject private var pad: PadFocus
    @FocusState private var cancelFocused: Bool

    package init(title: String, subtitle: String, note: String, cancelTitle: String, confirmTitle: String, destructive: Bool = false,
                 scope: String, cancel: @escaping () -> Void, confirm: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.note = note
        self.cancelTitle = cancelTitle
        self.confirmTitle = confirmTitle
        self.destructive = destructive
        self.scope = scope
        self.cancel = cancel
        self.confirm = confirm
        self.content = content()
    }

    package static var width: CGFloat { 560 }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.manrope(26, .heavy)).tracking(-0.6).fixedSize(horizontal: false, vertical: true)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 18)
            content
            if !note.isEmpty {
                Text(note).font(.manrope(12.5)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32).padding(.top, 12)
            }
            Divider().opacity(0.3).padding(.top, 20)
            HStack(spacing: 12) {
                Spacer(minLength: 8)
                Button(cancelTitle, action: cancel)
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction).focused($cancelFocused)
                    .padTarget(scope + ".cancel", scope: scope, activate: cancel)
                Button(confirmTitle, action: confirm)
                    .buttonStyle(LauncherSecondaryButtonStyle(accent: destructive ? LauncherPalette.danger : nil))
                    .padTarget(scope + ".confirm", scope: scope, activate: confirm)
            }
            .padding(.horizontal, 30).padding(.vertical, 16)
        }
        .padScope(scope, pad)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .launcherAppearance()
        .tint(LauncherPalette.accent)
        .onAppear { cancelFocused = true }
    }
}

package extension LauncherConfirmSheet where Content == EmptyView {
    init(title: String, subtitle: String, note: String, cancelTitle: String, confirmTitle: String, destructive: Bool = false,
         scope: String, cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, note: note, cancelTitle: cancelTitle, confirmTitle: confirmTitle, destructive: destructive,
                  scope: scope, cancel: cancel, confirm: confirm) { EmptyView() }
    }
}
