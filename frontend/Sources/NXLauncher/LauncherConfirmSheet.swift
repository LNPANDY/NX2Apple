import SwiftUI

/// A question before an action that cannot be undone or changes several things at once, on the sheet layout (DSSheet): the icon of
/// what it is about, the title, the thing it is about in secondary text, an optional card, a note, then Cancel and the action.
/// Escape cancels and Return presses Cancel, so Return never confirms by accident. A removing action is the red destructive button.
package struct LauncherConfirmSheet<Content: View>: View {
    let subject: DSSheetSubject?
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

    package init(subject: DSSheetSubject? = nil, title: String, subtitle: String, note: String, cancelTitle: String, confirmTitle: String,
                 destructive: Bool = false, scope: String, cancel: @escaping () -> Void, confirm: @escaping () -> Void,
                 @ViewBuilder content: () -> Content) {
        self.subject = subject
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

    package static var width: CGFloat { DS.Control.sheetWidth }

    package var body: some View {
        DSSheet(subject: subject, title: title, message: subtitle) {
            content
            if !note.isEmpty {
                Text(note).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        } buttons: {
            DSSheetConfirmButtons(cancelTitle: cancelTitle, confirmTitle: confirmTitle, role: destructive ? .destructive : .primary,
                                  scope: scope, cancel: cancel, confirm: confirm)
        }
        .padScope(scope, pad)
    }
}

package extension LauncherConfirmSheet where Content == EmptyView {
    init(subject: DSSheetSubject? = nil, title: String, subtitle: String, note: String, cancelTitle: String, confirmTitle: String,
         destructive: Bool = false, scope: String, cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.init(subject: subject, title: title, subtitle: subtitle, note: note, cancelTitle: cancelTitle, confirmTitle: confirmTitle,
                  destructive: destructive, scope: scope, cancel: cancel, confirm: confirm) { EmptyView() }
    }
}
