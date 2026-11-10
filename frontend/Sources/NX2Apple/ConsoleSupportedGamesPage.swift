import SwiftUI
import NXCore
import NXLauncher

/// The supported games in console mode (#301), from the menu's Library page: the same list as the desktop's Supported games sheet
/// (SupportedGamesSheet), with the search's on-screen keyboard so a controller can type. A row opens its notes with A. A game the
/// player owns says so, and its notes offer the way to its page. Only the profile's own words, no download. Each row shows the game's
/// cover, the library's own (SupportedCovers), fetched while the row is on screen.
@MainActor struct ConsoleSupportedGamesPage<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let glyphs: ConsoleGlyphs
    let compact: Bool
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: String?
    @StateObject private var covers: SupportedCovers
    @State private var viewport: CGFloat = 0   // the scroll view's height: which rows are on screen

    init(driver: Driver, lang: Lang, glyphs: ConsoleGlyphs, compact: Bool) {
        self.driver = driver
        self.lang = lang
        self.glyphs = glyphs
        self.compact = compact
        _covers = StateObject(wrappedValue: driver.supportedCovers(maxPixel: Int(2 * Self.coverSize(compact: compact).width)))
    }

    /// The cover slot, 16:9, about as tall as the row's two lines of text.
    static func coverSize(compact: Bool) -> CGSize { compact ? CGSize(width: 80, height: 45) : CGSize(width: 96, height: 54) }
    private static var space: String { "console.supported.scroll" }

    static var scope: String { "console.supported" }
    static var firstTarget: String { "console.supported.key.a" }
    private var state: ConsoleState { driver.state }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var inset: CGFloat { compact ? 24 : 64 }
    private var keySize: CGSize { compact ? CGSize(width: 30, height: 44) : CGSize(width: 64, height: 56) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsolePageHeader(title: t("supported.title"), note: t("console.supported.note"), compact: compact, closeLabel: t("console.close"),
                              closeID: "console.supported.close", scope: Self.scope) { driver.back() }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: compact ? 18 : 28) {
                        field
                        keyboard
                        list
                    }
                    .padding(.horizontal, inset).padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .consoleScrollContent()
                }
                .coordinateSpace(name: Self.space)
                .background(GeometryReader { box in
                    Color.clear.onAppear { viewport = box.size.height }.onChange(of: box.size.height) { viewport = $0 }
                })
                .consoleScrollFade()
                .onChange(of: pad.focused) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            HStack {
                Spacer(minLength: 0)
                ConsoleHint(glyph: glyphs.hintGlyph(.back, swapAB: state.menuSwapAB), label: t(ConsoleSearchBack.labelKey(state.supportedText)),
                            id: "console.supported.hint.back", scope: Self.scope, compact: compact) {
                    state.supportedText.isEmpty ? driver.back() : driver.deleteSupported()
                }
            }
            .padding(.horizontal, inset).padding(.bottom, compact ? 20 : 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LauncherPalette.background)
        .onChange(of: state.supportedText) { _ in expanded = nil }
        .onDisappear { covers.stop() }
    }

    private var field: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass").font(.system(size: compact ? 18 : 22, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                .accessibilityHidden(true)
            HStack(spacing: 2) {
                Text(state.supportedText.isEmpty ? t("supported.search") : state.supportedText)
                    .font(.manrope(compact ? 20 : 26, .semibold)).lineLimit(1).truncationMode(.head)
                    .foregroundStyle(state.supportedText.isEmpty ? LauncherPalette.secondaryText : .white)
                if !state.supportedText.isEmpty { Rectangle().fill(LauncherPalette.cream).frame(width: 2, height: compact ? 22 : 28).accessibilityHidden(true) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).frame(maxWidth: 12 * keySize.width, minHeight: compact ? 52 : 64, alignment: .leading)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t("supported.search")).accessibilityValue(state.supportedText)
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ConsoleKeyboard.rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { key in
                        ConsoleKeyButton(id: "console.supported.key." + key, scope: Self.scope, label: key.uppercased(), size: keySize, compact: compact) {
                            driver.typeSupported(key)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                ConsoleKeyButton(id: "console.supported.key.space", scope: Self.scope, label: t("console.key.space"), size: keySize,
                                 width: 4 * keySize.width + 24, compact: compact) { driver.typeSupported(" ") }
                ConsoleKeyButton(id: "console.supported.key.delete", scope: Self.scope, label: t("console.key.delete"), symbol: "delete.left", size: keySize,
                                 width: 2 * keySize.width + 8, compact: compact) { driver.deleteSupported() }
                ConsoleKeyButton(id: "console.supported.key.done", scope: Self.scope, label: t("console.key.done"), size: keySize,
                                 width: 2 * keySize.width + 8, primary: true, compact: compact) {
                    pad.focused = state.supportedShown.first.map { "console.supported.row." + $0.titleID } ?? "console.supported.close"
                }
            }
        }
    }

    @ViewBuilder private var list: some View {
        let games = state.supportedShown
        VStack(alignment: .leading, spacing: 12) {
            ConsoleSectionHeading(title: games.isEmpty ? t("supported.none") : String(format: t("supported.count"), games.count), compact: compact)
            ForEach(games) { game in row(game) }
        }
    }

    private func cover(_ game: SupportedGame) -> some View {
        let size = Self.coverSize(compact: compact)
        return ZStack {
            LauncherPalette.background.opacity(0.5)
            if let image = covers.image(game.titleID) { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "gamecontroller").font(.system(size: compact ? 16 : 19, weight: .light)).foregroundStyle(LauncherPalette.secondaryText) }
        }
        .frame(width: size.width, height: size.height).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
    }

    private func detail(_ game: SupportedGame) -> String {
        var parts: [String] = []
        if game.edition == .switch2 { parts.append(t("switch2.badge")) }
        parts.append(game.version.map { String(format: t("supported.version"), $0) } ?? t("supported.noVersion"))
        return parts.joined(separator: " · ")
    }

    private func row(_ game: SupportedGame) -> some View {
        let id = "console.supported.row." + game.titleID
        let open = expanded == game.titleID
        let owned = state.ownedGameID(game)
        let toggle = { expanded = open ? nil : game.titleID }
        return VStack(alignment: .leading, spacing: 14) {
            Button(action: toggle) {
                HStack(spacing: 18) {
                    cover(game)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.name).font(.manrope(compact ? 19 : 23, .semibold)).lineLimit(2)
                        Text(detail(game)).font(.manrope(compact ? 14 : 17)).foregroundStyle(LauncherPalette.secondaryText)
                    }
                    Spacer(minLength: 8)
                    if owned != nil {
                        Text(t("supported.owned")).font(.manrope(compact ? 14 : 17, .semibold)).foregroundStyle(LauncherPalette.ready).lineLimit(1)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(.degrees(open ? 90 : 0)).accessibilityHidden(true)
                }
                .padding(20).frame(maxWidth: .infinity, minHeight: compact ? 72 : 84, alignment: .leading)
                .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padTarget(id, scope: Self.scope, radius: 14, activate: toggle)
            .accessibilityLabel(game.name).accessibilityValue(detail(game))
            .accessibilityHint(t(open ? "supported.hideNotes" : "supported.showNotes"))
            .modifier(OnScreen(space: Self.space, height: viewport) { shown in
                if shown { covers.appear(game.titleID) } else { covers.disappear(game.titleID) }
            })
            .id(id)
            if open {
                VStack(alignment: .leading, spacing: 14) {
                    Text(game.notes.isEmpty ? t("supported.noNotes") : game.notes).font(.manrope(compact ? 15 : 18))
                        .foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                    if let owned {
                        let openID = "console.supported.open." + game.titleID
                        Button { driver.openGamePage(owned) } label: {
                            Text(t("console.supported.open")).font(.manrope(compact ? 16 : 19, .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 22).frame(height: compact ? 44 : 52)
                                .background(.white.opacity(0.075), in: Capsule()).contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padTarget(openID, scope: Self.scope, radius: 26) { driver.openGamePage(owned) }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 6)
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: open)
    }
}

/// Calls `change` when the view comes within the scroll view named `space` (`height` tall, one view's height of margin), and again
/// when it leaves. The page's rows are not lazy (the controller's focus needs every row's frame), so `onAppear` would fire for all.
private struct OnScreen: ViewModifier {
    let space: String
    let height: CGFloat
    let change: (Bool) -> Void
    @State private var shown = false

    func body(content: Content) -> some View {
        content.background(GeometryReader { box in
            let frame = box.frame(in: .named(space))
            Color.clear
                .onAppear { update(frame) }
                .onChange(of: [frame.minY, frame.maxY, height]) { _ in update(frame) }
        })
        .onDisappear { if shown { shown = false; change(false) } }
    }

    private func update(_ frame: CGRect) {
        let visible = height > 0 && frame.maxY > -frame.height && frame.minY < height + frame.height
        guard visible != shown else { return }
        shown = visible
        change(visible)
    }
}

/// One key of console mode's on-screen keyboard (the search and the supported games): a letter, or a wider key with its name or symbol.
struct ConsoleKeyButton: View {
    let id: String
    let scope: String
    let label: String
    var symbol: String?
    let size: CGSize
    var width: CGFloat?
    var primary = false
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: compact ? 16 : 20, weight: .semibold)) }
                else { Text(label).font(.manrope(compact ? 16 : 21, .semibold)).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .foregroundStyle(primary ? LauncherPalette.background : .white)
            .frame(width: width ?? size.width, height: size.height)
            .background(primary ? LauncherPalette.cream : LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).accessibilityLabel(label)
        .padTarget(id, scope: scope, radius: 10, activate: action)
        .id(id)
    }
}
