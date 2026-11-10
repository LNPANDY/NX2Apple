import SwiftUI
import NXCore
import NXLauncher

/// The tiles of all games or of the search's results: A opens a game's page (Resume for the paused one), X plays it (ConsoleView's
/// playTarget reads the pad id's prefix).
@MainActor private struct ConsoleGridTile<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let game: ConsoleGame
    let prefix: String
    let scope: String
    let width: CGFloat
    let lang: Lang
    let compact: Bool
    @EnvironmentObject private var pad: PadFocus
    private func t(_ key: String) -> String { L10n.string(key, lang) }

    var body: some View {
        let paused = driver.state.pausedGameID == game.id
        let open = { paused ? driver.resume(game.id) : driver.openGamePage(game.id) }
        let selected = pad.visible && pad.focused == prefix + game.id
        Button(action: open) {
            ConsoleGameTile(game: game, selected: selected, compact: compact, lang: lang, paused: paused, alwaysCaptioned: true)
                .frame(width: width).contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padTarget(prefix + game.id, scope: scope, radius: 16, activate: open)
        .accessibilityLabel(game.title + ", " + t(paused ? "console.paused" : game.status.labelKey))
        .accessibilityHint(t(paused ? "console.resumeHint" : "console.openHint"))
        .id(prefix + game.id)
    }
}

/// All games (#816, from the menu): every game of the library as tiles, the filters on L and R (All, Ready on Mac, Not built, Needs
/// game data), the order on Y (Recently played or Name, the desktop's own sort and its saved choice) and the way to the search.
@MainActor struct ConsoleAllGamesPage<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let glyphs: ConsoleGlyphs
    let compact: Bool
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var scope: String { "console.allGames" }
    private var state: ConsoleState { driver.state }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var inset: CGFloat { compact ? 24 : 64 }

    var body: some View {
        let games = state.libraryGames
        VStack(alignment: .leading, spacing: 0) {
            ConsolePageHeader(title: t("console.allGames"), subtitle: Self.count(games.count, lang: lang), compact: compact,
                              closeLabel: t("console.close"), closeID: "console.allGames.close", scope: Self.scope) { driver.back() }
            bar.padding(.horizontal, inset).padding(.bottom, compact ? 16 : 24)
            GeometryReader { area in
                let width = Self.tileWidth(area.size.width - 2 * inset, compact: compact)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            if games.isEmpty {
                                Text(t("console.allGames.empty")).font(.manrope(compact ? 17 : 21)).foregroundStyle(LauncherPalette.secondaryText)
                                    .padding(.top, 24)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width + 40), spacing: 12, alignment: .topLeading)],
                                          alignment: .leading, spacing: compact ? 16 : 24) {
                                    ForEach(games) { game in
                                        ConsoleGridTile(driver: driver, game: game, prefix: "console.lib.", scope: Self.scope, width: width, lang: lang, compact: compact)
                                            .padding(8)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, inset - 8).padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .consoleScrollContent()
                    }
                    .consoleScrollFade()
                    .onChange(of: pad.focused) { id in
                        guard let id, id.hasPrefix("console.lib.") else { return }
                        withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            hints.padding(.horizontal, inset).padding(.bottom, compact ? 20 : 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LauncherPalette.background)
        .onChange(of: state.libraryFilter) { _ in focusFirst() }
        .onChange(of: state.librarySort) { _ in focusFirst() }
    }

    /// Four tiles a row on a wide screen, fewer on a narrow one, never wider than the home screen's.
    static func tileWidth(_ available: CGFloat, compact: Bool) -> CGFloat {
        if compact { return max(available - 16, 160) }
        let columns = max(2, min(5, Int(available / 340)))
        return min(400, (available - CGFloat(columns) * 28) / CGFloat(columns))
    }

    /// "1 game", "12 games".
    static func count(_ n: Int, lang: Lang) -> String {
        n == 1 ? L10n.string("console.allGames.one", lang) : String(format: L10n.string("console.allGames.count", lang), n)
    }

    private func focusFirst() { pad.focused = state.libraryGames.first.map { "console.lib." + $0.id } ?? "console.allGames.close" }

    /// The filters between L and R, the chosen one cream, then the order (Y) and Search.
    private var bar: some View {
        HStack(spacing: compact ? 8 : 12) {
            ConsoleGlyphView(glyph: glyphs.hintGlyph(.previousTab, swapAB: state.menuSwapAB), size: compact ? 20 : 24).foregroundStyle(.white.opacity(0.7))
            ForEach(ConsoleLibraryFilter.allCases, id: \.self) { filter in
                let on = filter == state.libraryFilter
                let index = { (f: ConsoleLibraryFilter) in ConsoleLibraryFilter.allCases.firstIndex(of: f) ?? 0 }
                Button { driver.stepLibraryFilter(index(filter) - index(state.libraryFilter)) } label: {
                    Text(t(filter.titleKey)).font(.manrope(compact ? 14 : 17, .semibold)).lineLimit(1)
                        .foregroundStyle(on ? LauncherPalette.background : .white.opacity(0.8))
                        .padding(.horizontal, compact ? 12 : 18).frame(height: compact ? 34 : 42)
                        .background(on ? LauncherPalette.cream : .white.opacity(0.075), in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.plain).accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
            ConsoleGlyphView(glyph: glyphs.hintGlyph(.nextTab, swapAB: state.menuSwapAB), size: compact ? 20 : 24).foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 8)
            if !compact {
                Button { driver.openSearch() } label: {
                    Label(t("console.search"), systemImage: "magnifyingglass").font(.manrope(17, .semibold))
                        .padding(.horizontal, 16).frame(height: 42).background(.white.opacity(0.075), in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.plain).padTarget("console.allGames.search", scope: Self.scope, radius: 21, activate: { driver.openSearch() })
            }
        }
    }

    private var hints: some View {
        let sort = String(format: t("console.sortBy"), t(state.librarySort.labelKey))
        return HStack(spacing: compact ? 12 : 32) {
            ConsoleHint(glyph: glyphs.hintGlyph(.options, swapAB: state.menuSwapAB), label: sort, id: "console.allGames.sort", scope: Self.scope,
                        compact: compact) { driver.toggleLibrarySort() }
            ConsoleHint(glyph: glyphs.hintGlyph(.play, swapAB: state.menuSwapAB), label: t("console.play"), id: "console.allGames.play", scope: Self.scope,
                        compact: compact) { if let id = focusedGameID { driver.play(id) } }
            Spacer(minLength: 0)
            ConsoleHint(glyph: glyphs.hintGlyph(.back, swapAB: state.menuSwapAB), label: t("console.back"), id: "console.allGames.back", scope: Self.scope,
                        compact: compact) { driver.back() }
        }
    }

    private var focusedGameID: String? {
        guard let id = pad.focused, id.hasPrefix("console.lib.") else { return nil }
        return String(id.dropFirst("console.lib.".count))
    }
}

/// The search (#816) with an on-screen keyboard a controller can type on: letters, digits, space, Delete and Done (which goes to the
/// results). The Mac's keyboard types into it too (ConsoleKeyboardInput). It finds a game by any name it answers to, as the desktop's
/// search does (LibraryGame.matches: the shown name, the player's, each language's, the title ID).
@MainActor struct ConsoleSearchPage<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let glyphs: ConsoleGlyphs
    let compact: Bool
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var scope: String { "console.search" }
    static var keyRows: [[String]] { ConsoleKeyboard.rows }
    private var state: ConsoleState { driver.state }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var inset: CGFloat { compact ? 24 : 64 }
    private var keySize: CGSize { compact ? CGSize(width: 30, height: 44) : CGSize(width: 64, height: 56) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsolePageHeader(title: t("console.search"), note: t("console.search.note"), compact: compact, closeLabel: t("console.close"),
                              closeID: "console.search.close", scope: Self.scope) { driver.back() }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: compact ? 18 : 28) {
                        field
                        keyboard
                        results
                    }
                    .padding(.horizontal, inset).padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .consoleScrollContent()
                }
                .consoleScrollFade()
                .onChange(of: pad.focused) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            hints.padding(.horizontal, inset).padding(.bottom, compact ? 20 : 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LauncherPalette.background)
    }

    /// X plays the result in focus, B deletes a letter while there is one and goes back once the field is empty.
    private var hints: some View {
        HStack(spacing: compact ? 12 : 32) {
            ConsoleHint(glyph: glyphs.hintGlyph(.play, swapAB: state.menuSwapAB), label: t("console.play"), id: "console.search.hint.play", scope: Self.scope,
                        compact: compact) {
                if let id = pad.focused, id.hasPrefix("console.result.") { driver.play(String(id.dropFirst("console.result.".count))) }
            }
            Spacer(minLength: 0)
            ConsoleHint(glyph: glyphs.hintGlyph(.back, swapAB: state.menuSwapAB), label: t(ConsoleSearchBack.labelKey(state.searchText)),
                        id: "console.search.hint.back", scope: Self.scope, compact: compact) {
                state.searchText.isEmpty ? driver.back() : driver.deleteSearch()
            }
        }
    }

    /// What was typed, with a caret, or the placeholder.
    private var field: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass").font(.system(size: compact ? 18 : 22, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                .accessibilityHidden(true)
            HStack(spacing: 2) {
                Text(state.searchText.isEmpty ? t("console.search.placeholder") : state.searchText)
                    .font(.manrope(compact ? 20 : 26, .semibold)).lineLimit(1).truncationMode(.head)
                    .foregroundStyle(state.searchText.isEmpty ? LauncherPalette.secondaryText : .white)
                // the caret: a cream bar, not a typed character that could read as a letter
                if !state.searchText.isEmpty { Rectangle().fill(LauncherPalette.cream).frame(width: 2, height: compact ? 22 : 28).accessibilityHidden(true) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).frame(maxWidth: 12 * keySize.width, minHeight: compact ? 52 : 64, alignment: .leading)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t("console.search")).accessibilityValue(state.searchText)
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.keyRows, id: \.self) { row in
                HStack(spacing: 8) { ForEach(row, id: \.self) { key in self.key(key, label: key.uppercased()) { driver.typeSearch(key) } } }
            }
            HStack(spacing: 8) {
                key("space", label: t("console.key.space"), width: 4 * keySize.width + 24) { driver.typeSearch(" ") }
                key("delete", label: t("console.key.delete"), symbol: "delete.left", width: 2 * keySize.width + 8) { driver.deleteSearch() }
                key("done", label: t("console.key.done"), width: 2 * keySize.width + 8, primary: true) {
                    pad.focused = state.searchResults.first.map { "console.result." + $0 } ?? "console.search.close"
                }
            }
        }
    }

    private func key(_ id: String, label: String, symbol: String? = nil, width: CGFloat? = nil, primary: Bool = false, action: @escaping () -> Void) -> some View {
        ConsoleKeyButton(id: "console.key." + id, scope: Self.scope, label: label, symbol: symbol, size: keySize, width: width, primary: primary,
                         compact: compact, action: action)
    }

    @ViewBuilder private var results: some View {
        let games = state.searchGames
        VStack(alignment: .leading, spacing: 12) {
            if !state.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                ConsoleSectionHeading(title: games.isEmpty ? t("console.search.none") : ConsoleAllGamesPage<Driver>.count(games.count, lang: lang), compact: compact)
            }
            if !games.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(games) { game in
                            ConsoleGridTile(driver: driver, game: game, prefix: "console.result.", scope: Self.scope, width: compact ? 220 : 300, lang: lang, compact: compact)
                                .padding(8)
                        }
                    }
                }
                .padding(.horizontal, -8)
            }
        }
    }
}

/// The on-screen keyboard's keys, row by row (Latin letters and digits: a title ID and most games' names, the player's own and
/// other languages' included, can be typed with them).
enum ConsoleKeyboard {
    static let rows: [[String]] = [Array("1234567890"), Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")].map { $0.map(String.init) }
}
