import SwiftUI
import AppKit

// The launcher's sheets (the questions, the short tasks, the editors) on one layout: the title and the message under it (no icon,
// #1458), the content, then the button row. Flat like every other content surface,
// 32 pt at the sides and 24 pt at the top and the bottom, as high as its content. No hairline above the button row in any sheet.
// frontend/README.md, "Design tokens and components", has the table.

/// A sheet's header: the title (DS.Font.title) and its message in secondary text, leading-aligned with the content under them. No
/// sheet has an icon above its title, a confirmation neither (#1458): the title and the message name what it is about.
package struct DSSheetHeader: View {
    package init(title: String, message: String = "") {
        self.title = title; self.message = message
    }
    let title: String
    let message: String
    package var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(title).font(DS.Font.title).tracking(DS.Font.titleTracking).foregroundStyle(DS.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !message.isEmpty {
                Text(message).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DSSheetMaxHeightKey: EnvironmentKey {
    static var defaultValue: CGFloat { LauncherSheet.maxHeight(screen: NSScreen.main?.visibleFrame.height ?? 800) }
}

extension EnvironmentValues {
    /// The most a sheet may be high: the screen's visible height less a margin (720 at most). A sheet whose content is higher keeps
    /// its header and button row and scrolls the content between them. The state gallery sets it from its window size.
    package var dsSheetMaxHeight: CGFloat {
        get { self[DSSheetMaxHeightKey.self] }
        set { self[DSSheetMaxHeightKey.self] = newValue }
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

    /// The height a sheet's scrolling content gets: all of it while the sheet fits, else what is left beside the header and the
    /// buttons (`chrome`). nil before it is measured.
    package static func contentFrame(content: CGFloat, chrome: CGFloat, maxHeight: CGFloat) -> CGFloat? {
        guard content > 0 else { return nil }
        return min(content, max(120, maxHeight - chrome))   // a sliver of content at the least
    }
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

/// Single-pass synchronous layout for a three-part sheet (header, body, button row): keeps the header and button row fixed, fits
/// short content tightly, and caps tall content at `max(120, maxHeight - chrome)` without cross-frame `onGeometryChange` feedback.
package struct DSSheetStackLayout: Layout {
    package let width: CGFloat
    package let maxHeight: CGFloat

    package init(width: CGFloat, maxHeight: CGFloat) {
        self.width = width
        self.maxHeight = maxHeight
    }

    package func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? width
        guard subviews.count >= 3 else {
            let h = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }
            return CGSize(width: w, height: min(h, maxHeight))
        }
        let h0 = subviews[0].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
        let h2 = subviews[2].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
        let cap = max(120, maxHeight - h0 - h2)
        let h1 = min(subviews[1].sizeThatFits(ProposedViewSize(width: w, height: cap)).height, cap)
        return CGSize(width: w, height: h0 + h1 + h2)
    }

    package func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = bounds.width
        guard subviews.count >= 3 else {
            var y = bounds.minY
            for sub in subviews {
                let h = sub.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
                sub.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: w, height: h))
                y += h
            }
            return
        }
        let h0 = subviews[0].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
        let h2 = subviews[2].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
        let cap = max(120, maxHeight - h0 - h2)
        let h1 = min(subviews[1].sizeThatFits(ProposedViewSize(width: w, height: cap)).height, cap)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: ProposedViewSize(width: w, height: h0))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + h0), proposal: ProposedViewSize(width: w, height: h1))
        subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + h0 + h1), proposal: ProposedViewSize(width: w, height: h2))
    }
}

/// A whole sheet of the launcher: the header, the content and the button row inside the shared insets, `DS.Control.sheetWidth`
/// wide (or the width a larger sheet needs) and as high as its content, at most `dsSheetMaxHeight`: higher content scrolls
/// between the fixed header and button row, so neither is ever cut (#1458).
package struct DSSheet<Content: View, Leading: View, Buttons: View>: View {
    package init(width: CGFloat = DS.Control.sheetWidth, title: String, message: String = "",
                 @ViewBuilder content: () -> Content, @ViewBuilder leading: () -> Leading, @ViewBuilder buttons: () -> Buttons) {
        self.width = width; self.title = title; self.message = message
        self.content = content(); self.leading = leading(); self.buttons = buttons()
    }
    let width: CGFloat
    let title: String
    let message: String
    let content: Content
    let leading: Leading
    let buttons: Buttons
    @Environment(\.dsSheetMaxHeight) private var maxHeight

    package var body: some View {
        let bodyStack = VStack(alignment: .leading, spacing: DSSheetInsets.gap) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DSSheetInsets.horizontal).padding(.top, DSSheetInsets.gap)
        DSSheetStackLayout(width: width, maxHeight: maxHeight) {
            DSSheetHeader(title: title, message: message)
                .padding(.horizontal, DSSheetInsets.horizontal).padding(.top, DSSheetInsets.vertical)
            ViewThatFits(in: .vertical) {
                bodyStack.fixedSize(horizontal: false, vertical: true)
                ScrollView(.vertical) { bodyStack }
            }
            DSSheetButtonRow(leading: { leading }, buttons: { buttons })
                .padding(.horizontal, DSSheetInsets.horizontal).padding(.top, DSSheetInsets.buttons).padding(.bottom, DSSheetInsets.vertical)
        }
        .frame(width: width, alignment: .leading)
        .dsSheetSurface()
    }

}

package extension DSSheet where Leading == EmptyView {
    init(width: CGFloat = DS.Control.sheetWidth, title: String, message: String = "",
         @ViewBuilder content: () -> Content, @ViewBuilder buttons: () -> Buttons) {
        self.init(width: width, title: title, message: message, content: content, leading: { EmptyView() }, buttons: buttons)
    }
}

/// A sheet whose content scrolls (a list of games, the key bindings, the parts of a build folder): the same header, insets and
/// button row as DSSheet, the header and the buttons fixed and the content between them scrolling. It has the size it is given.
package struct DSScrollingSheet<Content: View, Leading: View, Buttons: View>: View {
    /// `scrollTarget`: the id (`.id`) the list scrolls to when it changes, the controller's focus.
    package init(width: CGFloat, height: CGFloat? = nil, title: String, message: String = "",
                 scrollTarget: String? = nil,
                 @ViewBuilder content: () -> Content, @ViewBuilder leading: () -> Leading, @ViewBuilder buttons: () -> Buttons) {
        self.width = width; self.height = height; self.title = title; self.message = message
        self.scrollTarget = scrollTarget
        self.content = content(); self.leading = leading(); self.buttons = buttons()
    }
    let width: CGFloat
    let height: CGFloat?
    let title: String
    let message: String
    let scrollTarget: String?
    let content: Content
    let leading: Leading
    let buttons: Buttons
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dsSheetMaxHeight) private var maxHeight

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSheetHeader(title: title, message: message)
                .padding(.horizontal, DSSheetInsets.horizontal).padding(.top, DSSheetInsets.vertical).padding(.bottom, DSSheetInsets.gap)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DSSheetInsets.gap) { content }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DSSheetInsets.horizontal).padding(.top, DS.Space.xxs).padding(.bottom, DSSheetInsets.gap)
                }
                .onChange(of: scrollTarget) { id in
                    if let id { withAnimation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.standard)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            DSSheetButtonRow(leading: { leading }, buttons: { buttons })
                .padding(.horizontal, DSSheetInsets.horizontal).padding(.top, DSSheetInsets.gap).padding(.bottom, DSSheetInsets.vertical)
        }
        .frame(width: width, height: height.map { min($0, maxHeight) })   // never higher than the screen (#1458)
        .dsSheetSurface()
    }
}

/// The primary button of a sheet's button row (Done, Save, Use selected): the accent, Return when `takesReturn`.
package struct DSSheetPrimaryButton: View {
    package init(_ title: String, takesReturn: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.takesReturn = takesReturn; self.action = action
    }
    let title: String
    let takesReturn: Bool
    let action: () -> Void
    package var body: some View {
        Button(action: action) { Text(title).font(DS.Font.bodyStrong).padding(.horizontal, DS.Space.m) }
            .buttonStyle(DSPrimaryButtonStyle())
            .keyboardShortcut(takesReturn ? .defaultAction : nil)
    }
}

extension View {
    /// The sheet's page: the dark background, the body font, the dark appearance and the cream tint.
    package func dsSheetSurface() -> some View {
        background(DS.Color.background).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary).launcherAppearance().tint(DS.Color.accent)
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
