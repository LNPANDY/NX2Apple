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
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title).font(DS.Font.largeTitle).tracking(DS.Font.largeTitleTracking).foregroundStyle(DS.Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if !note.isEmpty { Text(note).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary) }
        }
    }
}

private struct LauncherSectionTitleFontKey: EnvironmentKey {
    static let defaultValue: Font = DS.Font.headline
}

extension EnvironmentValues {
    package var launcherSectionTitleFont: Font {
        get { self[LauncherSectionTitleFontKey.self] }
        set { self[LauncherSectionTitleFontKey.self] = newValue }
    }
}

private struct LauncherSettingsLayoutKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    package var launcherSettingsLayout: Bool {
        get { self[LauncherSettingsLayoutKey.self] }
        set { self[LauncherSettingsLayoutKey.self] = newValue }
    }
}

/// A titled group: a label over one card of rows.
package struct CardGroup<Content: View>: View {
    @Environment(\.launcherSectionTitleFont) private var titleFont
    let label: String
    let insetTitle: Bool
    let qualifier: String
    let footnote: String
    let help: (id: String, text: String)?
    /// A status at the label's trailing edge (the build queue's "Paused"), empty for none.
    let trailing: String
    let content: Content

    package init(_ label: String, footnote: String = "", help: (id: String, text: String)? = nil, trailing: String = "", qualifier: String = "", insetTitle: Bool = false, @ViewBuilder _ content: () -> Content) {
        self.label = label
        self.insetTitle = insetTitle
        self.qualifier = qualifier
        self.footnote = footnote
        self.help = help
        self.trailing = trailing
        self.content = content()
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if !insetTitle && !label.isEmpty { heading }
            VStack(spacing: 0) {
                if insetTitle && !label.isEmpty { heading.padding(.horizontal, DS.Space.m).padding(.top, DS.Space.m) }
                content
            }
                .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(LauncherPalette.cardBorder))
            if !footnote.isEmpty {
                Text(footnote).font(DS.Font.footnote).foregroundStyle(DS.Color.textSecondary).padding(.horizontal, DS.Space.xxs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    /// One header style for every section: headline, secondary text (an inset title reads as a row title).
    private var heading: some View {
        HStack(spacing: DS.Space.xs) {
            Text(label).font(insetTitle ? DS.Font.body : titleFont)
                .foregroundStyle(insetTitle ? DS.Color.textPrimary : DS.Color.textSecondary).padding(.leading, DS.Space.xxs)
                .accessibilityAddTraits(.isHeader)
            if !qualifier.isEmpty { Text(qualifier).font(DS.Font.callout).foregroundStyle(DS.Color.textTertiary) }
            if let help { LauncherInfoHelp(id: help.id, label: label, text: help.text) }
            Spacer(minLength: DS.Space.xs)
            if !trailing.isEmpty { Text(trailing).font(DS.Font.body).foregroundStyle(DS.Color.statusWarning) }
        }
    }

}

/// One line of a card (`DSRow`): a leading slot for the status dot that every row reserves, so every title starts at one x, the
/// title (with a disclosure chevron beside it when `open` is given), one secondary line, and the trailing control column, whose
/// buttons and dropdowns share one width (`DS.Control.columnWidth`).
package struct CardRow<Trailing: View>: View {
    let title: String
    let detail: String
    let detail2: String
    let dot: Color?
    let help: String
    let open: Bool?
    let trailing: Trailing
    let info: (id: String, text: String)?
    @Environment(\.launcherSettingsLayout) private var settingsLayout

    package init(_ title: String, detail: String = "", detail2: String = "", dot: Color? = nil, help: String = "", open: Bool? = nil, info: (id: String, text: String)? = nil,
                 @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.info = info
        self.detail = detail
        self.detail2 = detail2
        self.dot = dot
        self.help = help
        self.open = open
        self.trailing = trailing()
    }

    package var body: some View {
        HStack(spacing: DS.Space.s) {
            Circle().fill(dot ?? .clear).frame(width: 7, height: 7).frame(width: DS.Control.leadingSlot)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xs) {
                    Text(title).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary).fixedSize(horizontal: false, vertical: true)
                    if let info { LauncherInfoHelp(id: info.id, label: title, text: info.text) }
                    if let open {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Color.textSecondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                if !detail.isEmpty {
                    // A path is technical text: the system's monospaced face, on one line, cut in the middle when
                    // too long. Everything else is prose in Manrope and wraps, so no word is ever cut.
                    if detail.hasPrefix("/") || detail.hasPrefix("~") {
                        Text(detail).font(DS.Font.mono).foregroundStyle(DS.Color.textSecondary)
                            .lineLimit(1).truncationMode(.middle).help(help.isEmpty ? detail : help)
                    } else {
                        Text(detail).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true).help(help.isEmpty ? detail : help)
                    }
                }
                if !detail2.isEmpty {
                    Text(detail2).font(DS.Font.mono).foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(1).truncationMode(.middle).help(detail2)
                }
            }
            Spacer(minLength: DS.Space.s)
            HStack(spacing: DS.Space.xs) { trailing }.launcherRowControls()
        }
        .padding(.leading, DS.Space.xs).padding(.trailing, DS.Space.m).padding(.vertical, DS.Space.s)
        .frame(minHeight: settingsLayout ? 60 : 52)
    }
}

package struct CardDivider: View {
    package init() {}
    package var body: some View { DS.Color.separator.frame(height: 1).padding(.leading, DS.Space.xs + DS.Control.leadingSlot + DS.Space.s) }
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
package struct LauncherPageScroll<Header: View, Content: View>: View {
    let header: Header
    let content: Content
    let memoryKey: String?
    @EnvironmentObject private var padFocus: PadFocus

    /// `memoryKey` names the scroll position this page keeps (ScrollMemory): a page with several parts gives each its own.
    /// `header` spans the full width above the content column and scrolls away with it (the build wizard's hero, #1458).
    package init(memoryKey: String? = nil, @ViewBuilder header: () -> Header, @ViewBuilder _ content: () -> Content) {
        self.header = header(); self.content = content(); self.memoryKey = memoryKey
    }

    package var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: DS.Space.xl) { content }
                        .padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.xl).padding(.bottom, DS.Space.xl + DS.Space.m)
                        .frame(maxWidth: DS.Control.contentWidth)
                        .frame(maxWidth: .infinity)
                }
                .background { if let memoryKey { ScrollMemory(key: memoryKey) } }
                .environment(\.launcherScrollTo, { id in withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .top) } })
            }
            .onChange(of: padFocus.focused) { id in   // a controller's focus on this page scrolls into view
                if let id, padFocus.scope == "main" { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
    }
}

extension LauncherPageScroll where Header == EmptyView {
    package init(memoryKey: String? = nil, @ViewBuilder _ content: () -> Content) {
        self.init(memoryKey: memoryKey, header: { EmptyView() }, content)
    }
}

/// A scrolling column whose category selector pins beneath the top bar once the heading scrolls out of view.
package struct LauncherStickyPageScroll<Heading: View, Bar: View, Content: View>: View {
    let memoryKey: String?
    @Binding var scrollRequest: String?
    let heading: Heading
    let bar: Bar
    let content: Content
    @EnvironmentObject private var padFocus: PadFocus
    @State private var headingHeight: CGFloat = 132
    @State private var viewportHeight: CGFloat = 720
    @State private var pinned = false
    @Environment(\.launcherSettingsLayout) private var settingsLayout

    package init(memoryKey: String? = nil, scrollRequest: Binding<String?> = .constant(nil),
                 @ViewBuilder heading: () -> Heading, @ViewBuilder bar: () -> Bar, @ViewBuilder content: () -> Content) {
        self.memoryKey = memoryKey
        self._scrollRequest = scrollRequest
        self.heading = heading()
        self.bar = bar()
        self.content = content()
    }

    package var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    heading
                        .padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.xl).padding(.bottom, DS.Space.l)
                        .frame(maxWidth: DS.Control.contentWidth, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .background(GeometryReader { g in
                            let h = g.size.height
                            Color.clear.onAppear {
                                if h > 0, abs(headingHeight - h) > 0.5 { DispatchQueue.main.async { headingHeight = h } }
                            }.onChange(of: h) { newH in
                                if newH > 0, abs(headingHeight - newH) > 0.5 { DispatchQueue.main.async { headingHeight = newH } }
                            }
                        })
                    Section {
                        VStack(alignment: .leading, spacing: DS.Space.xl) { content }
                            .padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.l).padding(.bottom, DS.Space.xl + DS.Space.m)
                            .frame(maxWidth: DS.Control.contentWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, minHeight: max(0, viewportHeight - 62), alignment: .top)
                    } header: {
                        VStack(spacing: 0) {
                            bar
                                .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.s)
                                .frame(maxWidth: DS.Control.contentWidth, alignment: .leading)
                                .frame(maxWidth: .infinity)
                            LauncherPalette.topBarRule.frame(height: 1).opacity(pinned ? 1 : 0)
                        }
                        .background {
                            ZStack {
                                LauncherPalette.background.opacity(pinned ? 0.94 : 0.98)
                            }
                        }
                    }
                }
                .background {
                    if let memoryKey {
                        ScrollMemory(key: memoryKey, pinnedOffset: headingHeight) { isPinned in
                            if pinned != isPinned { pinned = isPinned }
                        }
                    }
                }
                .environment(\.launcherScrollTo, { id in withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .top) } })
            }
            .background(GeometryReader { g in
                let vh = g.size.height
                Color.clear.onAppear {
                    if vh > 0, abs(viewportHeight - vh) > 0.5 { DispatchQueue.main.async { viewportHeight = vh } }
                }.onChange(of: vh) { newVH in
                    if newVH > 0, abs(viewportHeight - newVH) > 0.5 { DispatchQueue.main.async { viewportHeight = newVH } }
                }
            })
            .onChange(of: padFocus.focused) { id in
                if let id, padFocus.scope == "main" { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onChange(of: scrollRequest) { id in
                guard let id else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .top) }
                    scrollRequest = nil
                }
            }
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
    }
}

package func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}
