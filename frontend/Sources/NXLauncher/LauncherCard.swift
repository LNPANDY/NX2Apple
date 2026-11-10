import SwiftUI
import AppKit
import NXCore
import NXModel

// The pieces every card of the Builds and Settings pages is made of: a titled group, a row, a divider, a disclosure row.
// They are the library's and the launch options' look (LNPANDY/NX2Apple#387, step 8).

extension StepState {
    package var color: Color {
        switch self {
        case .pending: return .gray
        case .running: return .yellow
        case .done: return .green
        case .failed: return .red
        }
    }
}

/// The big title of a page with a note under it.
package struct CardPageHeading: View {
    let title: String
    let note: String

    package init(_ title: String, note: String) {
        self.title = title
        self.note = note
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.manrope(44, .heavy)).tracking(-1.3)
            Text(note).font(.manrope(15)).foregroundStyle(LauncherPalette.secondaryText)
        }
    }
}

/// A titled group: a small tracked label over one card of rows.
package struct CardGroup<Content: View>: View {
    let label: String
    let footnote: String
    /// A status at the label's trailing edge (the build queue's "Paused"), empty for none.
    let trailing: String
    let content: Content

    package init(_ label: String, footnote: String = "", trailing: String = "", @ViewBuilder _ content: () -> Content) {
        self.label = label
        self.footnote = footnote
        self.trailing = trailing
        self.content = content()
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label).font(.manrope(15, .semibold)).foregroundStyle(LauncherPalette.secondaryText).padding(.leading, 2)
                Spacer(minLength: 8)
                if !trailing.isEmpty { Text(trailing).font(.manrope(13, .semibold)).foregroundStyle(LauncherPalette.building) }
            }
            VStack(spacing: 0) { content }
                .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
            if !footnote.isEmpty {
                Text(footnote).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText).padding(.leading, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One line of a card: a status dot (its place kept when there is none, so every title starts on one line),
/// the title (with a disclosure chevron beside it when `open` is given), a secondary detail, and its controls.
/// Its buttons and dropdowns are all LauncherControl.width wide, so they line up in one column across the cards.
package struct CardRow<Trailing: View>: View {
    let title: String
    let detail: String
    let detail2: String
    let dot: Color?
    let help: String
    let open: Bool?
    let trailing: Trailing

    package init(_ title: String, detail: String = "", detail2: String = "", dot: Color? = nil, help: String = "", open: Bool? = nil,
                 @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.detail2 = detail2
        self.dot = dot
        self.help = help
        self.open = open
        self.trailing = trailing()
    }

    package var body: some View {
        HStack(spacing: 12) {
            Circle().fill(dot ?? .clear).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.manrope(14)).fixedSize(horizontal: false, vertical: true)
                    if let open {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(LauncherPalette.secondaryText)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                if !detail.isEmpty {
                    // A path is technical text: the system's monospaced face, on one line, cut in the middle when
                    // too long. Everything else is prose in Manrope and wraps, so no word is ever cut.
                    if detail.hasPrefix("/") || detail.hasPrefix("~") {
                        Text(detail).font(.mono(12)).foregroundStyle(LauncherPalette.secondaryText)
                            .lineLimit(1).truncationMode(.middle).help(help.isEmpty ? detail : help)
                    } else {
                        Text(detail).font(.manrope(12.5)).foregroundStyle(LauncherPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true).help(help.isEmpty ? detail : help)
                    }
                }
                if !detail2.isEmpty {
                    Text(detail2).font(.mono(12)).foregroundStyle(LauncherPalette.secondaryText)
                        .lineLimit(1).truncationMode(.middle).help(detail2)
                }
            }
            Spacer(minLength: 12)
            trailing.launcherRowControls()
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .frame(minHeight: 52)
    }
}

package struct CardDivider: View {
    package init() {}
    package var body: some View { Divider().opacity(0.25).padding(.leading, 18) }
}

/// A row that opens the rows under it.
package struct CardDisclosure: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let detail: String
    let isOpen: Bool
    let toggle: () -> Void

    package init(_ title: String, detail: String = "", isOpen: Bool, toggle: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.isOpen = isOpen
        self.toggle = toggle
    }

    package var body: some View {
        Button(action: { withAnimation(LauncherMotion.animation(.easeInOut(duration: 0.18), reduceMotion: reduceMotion)) { toggle() } }) {
            CardRow(title, detail: detail, open: isOpen) { EmptyView() }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The scrolling column of a page of cards. A controller's focus on one of its `set.` targets scrolls into view.
package struct LauncherPageScroll<Content: View>: View {
    let content: Content
    let memoryKey: String?
    @EnvironmentObject private var padFocus: PadFocus

    /// `memoryKey` names the scroll position this page keeps (ScrollMemory): a page with several parts gives each its own.
    package init(memoryKey: String? = nil, @ViewBuilder _ content: () -> Content) { self.content = content(); self.memoryKey = memoryKey }

    package var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 34) { content }
                    .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 48)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                    .background { if let memoryKey { ScrollMemory(key: memoryKey) } }
                    .environment(\.launcherScrollTo, { id in withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .top) } })
            }
            .onChange(of: padFocus.focused) { id in   // a controller's focus on this page scrolls into view
                if let id, id.hasPrefix("set.") { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
    }
}

package func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}
