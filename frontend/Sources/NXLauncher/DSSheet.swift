import SwiftUI
import AppKit

// The launcher's sheets (the questions, the short tasks, the editors) on one layout: what the sheet is about as an icon at the top
// leading corner, the title and the message under it, the content, then the button row. Flat like every other content surface,
// 32 pt at the sides and 24 pt at the top and the bottom, as high as its content. No hairline above the button row in any sheet.
// frontend/README.md, "Design tokens and components", has the table.

/// What a sheet is about, drawn above its title as a macOS alert shows the icon of the app or document it asks about. A sheet about
/// nothing that has an icon has no subject: no symbol stands in for one.
package enum DSSheetSubject {
    /// A game's square icon. nil while it has none: a quiet tile with a controller, the size of the icon.
    case game(NSImage?)
    /// The launcher itself: an app update, the app's uninstall.
    case app
}

/// The subject's icon: `DS.Control.sheetIcon` square with the card radius and a hairline, the app's own icon unclipped.
package struct DSSheetIcon: View {
    package init(_ subject: DSSheetSubject) { self.subject = subject }
    let subject: DSSheetSubject
    package var body: some View {
        Group {
            switch subject {
            case .game(let image?):
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                    .frame(width: DS.Control.sheetIcon, height: DS.Control.sheetIcon)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.separator))
            case .game(nil):
                Image(systemName: "gamecontroller.fill").font(.system(size: 22)).foregroundStyle(DS.Color.symbolDefault)
                    .frame(width: DS.Control.sheetIcon, height: DS.Control.sheetIcon)
                    .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.separator))
            case .app:
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().interpolation(.high)
                    .frame(width: DS.Control.sheetIcon, height: DS.Control.sheetIcon)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A sheet's header: the subject's icon, then the title (DS.Font.title) and its message in secondary text, all leading-aligned with
/// the content under them.
package struct DSSheetHeader: View {
    package init(subject: DSSheetSubject? = nil, title: String, message: String = "") {
        self.subject = subject; self.title = title; self.message = message
    }
    let subject: DSSheetSubject?
    let title: String
    let message: String
    package var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if let subject { DSSheetIcon(subject) }
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(DS.Font.title).tracking(DS.Font.titleTracking).foregroundStyle(DS.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if !message.isEmpty {
                    Text(message).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The paddings every sheet shares.
package enum DSSheetInsets {
    package static let horizontal = DS.Space.xl
    package static let vertical = DS.Space.l
    /// Between the header and the content, and between the content's blocks.
    package static let gap = DS.Space.m
    /// Above the button row.
    package static let buttons = DS.Space.l
}

/// The button row of a sheet: an optional leading view (a status, a secondary action like Reset), then the buttons on the trailing
/// side, Cancel left of the primary.
package struct DSSheetButtonRow<Leading: View, Buttons: View>: View {
    package init(@ViewBuilder leading: () -> Leading, @ViewBuilder buttons: () -> Buttons) { self.leading = leading(); self.buttons = buttons() }
    let leading: Leading
    let buttons: Buttons
    package var body: some View {
        HStack(spacing: DS.Space.s) {
            leading
            Spacer(minLength: DS.Space.xs)
            buttons
        }
    }
}

package extension DSSheetButtonRow where Leading == EmptyView {
    init(@ViewBuilder buttons: () -> Buttons) { self.init(leading: { EmptyView() }, buttons: buttons) }
}

/// A whole sheet of the launcher: the header, the content and the button row inside the shared insets, `DS.Control.sheetWidth`
/// wide (or the width a larger sheet needs) and as high as its content.
package struct DSSheet<Content: View, Leading: View, Buttons: View>: View {
    package init(width: CGFloat = DS.Control.sheetWidth, subject: DSSheetSubject? = nil, title: String, message: String = "",
                 @ViewBuilder content: () -> Content, @ViewBuilder leading: () -> Leading, @ViewBuilder buttons: () -> Buttons) {
        self.width = width; self.subject = subject; self.title = title; self.message = message
        self.content = content(); self.leading = leading(); self.buttons = buttons()
    }
    let width: CGFloat
    let subject: DSSheetSubject?
    let title: String
    let message: String
    let content: Content
    let leading: Leading
    let buttons: Buttons

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSheetHeader(subject: subject, title: title, message: message)
            VStack(alignment: .leading, spacing: DSSheetInsets.gap) { content }
                .padding(.top, DSSheetInsets.gap)
            DSSheetButtonRow(leading: { leading }, buttons: { buttons }).padding(.top, DSSheetInsets.buttons)
        }
        .padding(.horizontal, DSSheetInsets.horizontal).padding(.vertical, DSSheetInsets.vertical)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .dsSheetSurface()
    }
}

package extension DSSheet where Leading == EmptyView {
    init(width: CGFloat = DS.Control.sheetWidth, subject: DSSheetSubject? = nil, title: String, message: String = "",
         @ViewBuilder content: () -> Content, @ViewBuilder buttons: () -> Buttons) {
        self.init(width: width, subject: subject, title: title, message: message, content: content, leading: { EmptyView() }, buttons: buttons)
    }
}

extension View {
    /// The sheet's page: the dark background, the body font, the dark appearance and the cream tint.
    package func dsSheetSurface() -> some View {
        background(DS.Color.background).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary).launcherAppearance().tint(DS.Color.accent)
    }
}

/// The button that removes something (Delete game, Discard, Remove): the deep red fill with a white label, flat as every control in a
/// sheet. Never the Return key's button: `DSSheetKeys` gives Return to Cancel in a sheet that has one.
package struct DSDestructiveButtonStyle: ButtonStyle {
    package init() {}
    package func makeBody(configuration: Configuration) -> some View { DSDestructiveButton(configuration: configuration) }
}

private struct DSDestructiveButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    var body: some View {
        configuration.label
            .font(DS.Font.bodyStrong)
            .lineLimit(1)
            .foregroundStyle(enabled ? DS.Color.sheetDestructiveOn : DS.Color.textTertiary)
            .padding(.horizontal, DS.Space.m)
            .frame(height: DS.Control.height)
            .background(enabled ? DS.Color.sheetDestructive : DS.Color.surfaceRaised, in: Capsule())
            .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.18 : hovered && enabled ? 0.08 : 0)))
            .contentShape(Capsule())
            .onHover { hovered = $0 }
            .launcherHover()
    }
}

/// The keys of a sheet's buttons (Apple HIG, "Alerts"): Escape is always Cancel, and Return goes to the primary action only when
/// it is safe. A destructive action never takes Return: in its sheet Return is Cancel, the default button.
package enum DSSheetKeys {
    package enum Role: Equatable { case primary, destructive }
    package enum Target: Equatable { case cancel, confirm }
    /// The button Return presses: `confirm` only for a primary action that asked for it.
    package static func returnKey(role: Role, confirmTakesReturn: Bool) -> Target {
        role == .primary && confirmTakesReturn ? .confirm : .cancel
    }
}

/// Cancel and the sheet's action, right-aligned, Cancel first. Escape cancels. Return presses Cancel unless the action is a
/// primary one that takes it (`DSSheetKeys`). Cancel has the controller's focus when the sheet opens.
package struct DSSheetConfirmButtons: View {
    package init(cancelTitle: String, confirmTitle: String, role: DSSheetKeys.Role = .primary, confirmTakesReturn: Bool = false,
                 enabled: Bool = true, scope: String, cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.cancelTitle = cancelTitle; self.confirmTitle = confirmTitle; self.role = role; self.confirmTakesReturn = confirmTakesReturn
        self.enabled = enabled; self.scope = scope; self.cancel = cancel; self.confirm = confirm
    }
    let cancelTitle: String
    let confirmTitle: String
    let role: DSSheetKeys.Role
    let confirmTakesReturn: Bool
    let enabled: Bool
    let scope: String
    let cancel: () -> Void
    let confirm: () -> Void
    @EnvironmentObject private var pad: PadFocus

    private var returnKey: DSSheetKeys.Target { DSSheetKeys.returnKey(role: role, confirmTakesReturn: confirmTakesReturn) }

    package var body: some View {
        HStack(spacing: DS.Space.s) {
            Button(cancelTitle, action: cancel)
                .buttonStyle(DSSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padTarget(scope + ".cancel", scope: scope, activate: cancel)
            confirmButton
                .disabled(!enabled)
                .padTarget(scope + ".confirm", scope: scope, enabled: enabled, activate: confirm)
        }
        // Return on Cancel too when the action may not take it (a hidden twin of Cancel holds the default shortcut)
        .background { if returnKey == .cancel { Button("", action: cancel).keyboardShortcut(.defaultAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true) } }
        .onAppear { pad.scope = scope; pad.focused = scope + ".cancel" }
    }

    @ViewBuilder private var confirmButton: some View {
        switch role {
        case .destructive:
            Button(confirmTitle, action: confirm).buttonStyle(DSDestructiveButtonStyle())
        case .primary:
            Button(action: confirm) { Text(confirmTitle).font(DS.Font.bodyStrong).padding(.horizontal, DS.Space.m) }
                .buttonStyle(DSPrimaryButtonStyle())
                .keyboardShortcut(returnKey == .confirm ? .defaultAction : nil)
        }
    }
}

/// A file or folder in a sheet: one line of mono callout, cut in the middle so the name stays, the whole path in the tooltip.
package struct DSPathText: View {
    package init(_ path: String) { self.path = path }
    let path: String
    package var body: some View {
        Text(path).font(DS.Font.mono).foregroundStyle(DS.Color.textSecondary).lineLimit(1).truncationMode(.middle)
            .help(path).accessibilityLabel(path)
    }
}
