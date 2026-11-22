import SwiftUI

/// One notice of the launcher (LNPANDY/NX2Apple#1458): what the library and the game page tell the player outside a sheet, the
/// engine update, skipped files, a signature that runs out, a first launch that takes long. Each is a single row: a symbol in its
/// tone's colour, a title, a detail that wraps (never cut, keep it to one or two sentences), at most one action and an optional
/// dismiss. Symbol and action are centred on the title and detail, the notice grows in height. Notices sit in one slot under
/// the top bar (LauncherNoticeStack), the most serious first.
package struct LauncherNoticeItem: Identifiable {
    /// The design system's tone: one fixed symbol and its status colour each, no notice brings its own (#1458).
    package typealias Tone = DSTone
    package struct Action {
        package init(title: String, padID: String? = nil, perform: @escaping () -> Void) { self.title = title; self.padID = padID; self.perform = perform }
        package let title: String
        /// The controller's target, when a page already named it ("notice." and the notice's id otherwise).
        package let padID: String?
        package let perform: () -> Void
    }

    package init(id: String, tone: Tone, symbol: String? = nil, title: String, detail: String? = nil, busy: Bool = false,
                 action: Action? = nil, dismiss: (label: String, perform: () -> Void)? = nil) {
        self.id = id; self.tone = tone; self.symbol = tone.symbol; _ = symbol; self.title = title; self.detail = detail; self.busy = busy
        self.action = action; self.dismiss = dismiss
    }
    package let id: String
    package let tone: Tone
    package let symbol: String
    package let title: String
    package let detail: String?
    /// A spinner instead of the symbol: something is running (the engine is fetched).
    package let busy: Bool
    package let action: Action?
    package let dismiss: (label: String, perform: () -> Void)?
}

/// The calm surface of a notice: a filled rounded rectangle on the dark page, not blurred and not a coloured field.
package enum LauncherNoticeStyle {
    package static let radius: CGFloat = 12
    package static let fill = LauncherPalette.surface.opacity(0.94)
    package static let minHeight: CGFloat = 52
}

package struct LauncherNotice: View {
    /// `scope` is the controller's scope the notice's action and dismiss belong to: "main" on a page, the sheet's own in a sheet.
    package init(_ item: LauncherNoticeItem, enabled: Bool = true, scope: String = "main") {
        self.item = item; self.enabled = enabled; self.scope = scope
    }
    let item: LauncherNoticeItem
    let enabled: Bool
    let scope: String
    @EnvironmentObject private var pad: PadFocus

    package var body: some View {
        HStack(spacing: 12) {
            Group {
                if item.busy { DSSpinner(size: 15) }
                else { Image(systemName: item.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(item.tone.color) }
            }
            .frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.manrope(13.5, .semibold)).foregroundStyle(LauncherPalette.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let detail = item.detail {
                    Text(detail).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)   // wraps: important text is never cut (#1458)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action = item.action {
                Button(action.title, action: action.perform)
                    .buttonStyle(LauncherSecondaryButtonStyle(height: 30)).fixedSize()
                    .disabled(!enabled)
                    .padTarget(action.padID ?? "notice." + item.id, scope: scope, enabled: enabled, activate: action.perform)
            }
            if let dismiss = item.dismiss {
                Button(action: dismiss.perform) { Image(systemName: "xmark") }
                    .buttonStyle(LauncherIconButtonStyle(size: 28))
                    .disabled(!enabled)
                    .help(dismiss.label).accessibilityLabel(dismiss.label)
                    .accessibilityIdentifier("notice." + item.id + ".dismiss")
                    .padTarget("notice." + item.id + ".dismiss", scope: scope, radius: 14, enabled: enabled, activate: dismiss.perform)
            }
        }
        .padding(.leading, 14).padding(.trailing, item.action == nil && item.dismiss == nil ? 16 : 10).padding(.vertical, 10)
        .frame(minHeight: LauncherNoticeStyle.minHeight)
        .background(LauncherNoticeStyle.fill, in: RoundedRectangle(cornerRadius: LauncherNoticeStyle.radius))
        .overlay(RoundedRectangle(cornerRadius: LauncherNoticeStyle.radius).strokeBorder(LauncherPalette.cardBorder))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notice." + item.id)
    }
}

/// The one place notices show: under the top bar, the most serious first, at most `limit` of them stacked 8 pt apart.
package struct LauncherNoticeStack: View {
    package init(_ items: [LauncherNoticeItem], limit: Int = 3, enabled: Bool = true, scope: String = "main") {
        self.scope = scope
        self.items = Array(items.enumerated().sorted { ($0.element.tone, $0.offset) < ($1.element.tone, $1.offset) }.map(\.element).prefix(limit))
        self.enabled = enabled
    }
    let items: [LauncherNoticeItem]
    let enabled: Bool
    let scope: String
    package var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { LauncherNotice($0, enabled: enabled, scope: scope) }
            }
        }
    }
}
