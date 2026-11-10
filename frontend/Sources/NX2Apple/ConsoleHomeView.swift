import SwiftUI
import NXCore
import NXLauncher

/// A button and what it does, as the hint strip and the pages show it: the glyph of the button that does it now, its label, and the
/// cream pill for the main one. Also a pad target, so the mouse and the focus reach it.
struct ConsoleHint: View {
    let glyph: ConsoleGlyphs.Glyph
    let label: String
    let id: String
    var scope = "console"
    var primary = false
    let compact: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) { ConsoleGlyphView(glyph: glyph, size: compact ? 20 : 24); Text(label).lineLimit(1).minimumScaleFactor(0.8) }
                .font(.manrope(compact ? 15 : 20, .semibold))
                .padding(.horizontal, compact ? 12 : (primary ? 20 : 8)).frame(maxWidth: compact ? .infinity : nil, minHeight: 48)
                .foregroundStyle(primary ? LauncherPalette.background : .white.opacity(0.8))
                .background(primary ? LauncherPalette.cream : (compact ? .white.opacity(0.07) : .clear), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).padTarget(id, scope: scope, radius: 28, activate: action)
    }
}

struct ConsoleTileFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}

/// The home screen (#816): the top bar (the activity, the controllers, the clock, Search and the menu), the focused game's title, and
/// its rows, Continue playing, Ready to play and Needs attention, each scrolling sideways. Up and down go from row to row (ConsoleView
/// handles the presses, ConsoleHome.move decides), the row in focus sits at the top of the rows' area and the next one shows under it.
@MainActor struct ConsoleHomeScreen<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let glyphs: ConsoleGlyphs
    let size: CGSize
    let compact: Bool
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tileFrames: [String: CGRect] = [:]

    private var state: ConsoleState { driver.state }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var inset: CGFloat { compact ? 24 : 64 }
    private var tileWidth: CGFloat { compact ? size.width - inset * 2 - 16 : min(420, size.width * 0.28) }
    /// A row: its heading, the tiles with their room for the ring, and the captions.
    private var sectionHeight: CGFloat { tileWidth / 1.8 + (compact ? 92 : 104) }
    /// The pad ids of the hint strip, so up from it goes back to the focused game.
    static var hintIDs: Set<String> { ["console.open", "console.play", "console.options", "console.menu", "console.quickMenuHint", "console.desktop"] }
    /// The top bar's targets: the controller chips, Search and the menu button.
    static func isTopBar(_ id: String) -> Bool { id.hasPrefix("console.chip.") || id == "console.searchButton" || id == "console.menuButton" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar.padding(.horizontal, inset).padding(.top, compact ? 24 : 40)
            if state.games.isEmpty {
                empty.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The title and the rows sit at the bottom, above the hints, so the artwork has the screen above them. A short window scrolls.
                GeometryReader { area in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: compact || size.height < 900 ? 16 : 24) {
                            Spacer(minLength: 0)
                            if let game = state.focusedGame { title(game) }
                            rows
                        }
                        .padding(.top, 24).padding(.bottom, 16)
                        .frame(minHeight: area.size.height, alignment: .bottomLeading)
                    }
                }
                hintBar.padding(.horizontal, inset).padding(.bottom, compact ? 20 : 32)
            }
        }
        .padScope("console", pad)
    }

    // MARK: Top bar

    /// One fixed-height status row: the controller chips (scrolling sideways inside their own group) to the left of the clock, then
    /// Search and the menu. Its height never changes, so a controller arriving or leaving moves nothing below it.
    private var topBar: some View {
        HStack(spacing: compact ? 12 : 20) {
            if let activity = state.activity { ConsoleActivityChip(activity: activity, compact: compact) }
            ConsoleControllerChips(controllers: state.controllers, merged: state.padMerge, lang: lang, compact: compact) { driver.openControllers() }
            Text(state.time, style: .time).font(.manrope(compact ? 17 : 22, .medium)).monospacedDigit()
                .foregroundStyle(.white).fixedSize()
                .padding(.horizontal, compact ? 10 : 14).frame(height: compact ? 30 : 40)
                .consoleBarFill()
            barButton("magnifyingglass", id: "console.searchButton", label: t("console.search")) { driver.openSearch() }
            // The menu, as + opens it: drawn as a controller chip (same capsule, same height), focusable like them.
            barButton("line.3.horizontal", id: "console.menuButton", label: t("console.menu")) { driver.openMenu() }
        }
        .frame(height: compact ? 40 : 52)
        // The banner sits under the bar, so it never covers the controller chips, and it is drawn over the page without moving it (#1004)
        .overlay(alignment: .top) {
            if let toast = state.toast {
                ConsoleToastView(toast: toast).id(toast.id).transition(.opacity)
                    .offset(y: (compact ? 40 : 52) - 12)
            }
        }
        .zIndex(1)
    }

    private func barButton(_ symbol: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: compact ? 12 : 17, weight: .semibold))
                .padding(.horizontal, compact ? 10 : 14).frame(height: compact ? 30 : 40)
                .consoleBarFill().contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
        .padTarget(id, scope: "console", radius: 24, activate: action)
    }

    // MARK: Title

    /// A fixed-height slot: the old and the new title overlap and cross-fade in place (0.12 s), so nothing slides and the rows below
    /// never move, whatever the title's length. Above it, what the game is: paused, its status, or when it was last played.
    private func title(_ game: ConsoleGame) -> some View {
        let big = compact ? 36 : min(56, size.width / 26)
        return ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: compact ? 10 : 16) {
                Text(eyebrow(game)).font(.manrope(compact ? 14 : 18, .semibold))
                    .tracking(2).foregroundStyle(LauncherPalette.cream.opacity(0.75)).lineLimit(1)
                Text(game.title).font(.manrope(big, .bold))
                    .tracking(-1.4).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.45), radius: 12)
                    .accessibilityAddTraits(.isHeader)
                if !game.version.isEmpty {
                    Text(String(format: t("console.version"), game.version)).monospacedDigit().lineLimit(1)
                        .font(.manrope(compact ? 14 : 18)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .id(game.id).transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.12), value: game.id)
        .padding(.horizontal, inset)
        .frame(height: compact ? 160 : 86 + 2.4 * big, alignment: .bottomLeading)
    }

    private func eyebrow(_ game: ConsoleGame) -> String {
        if game.id == state.pausedGameID { return t("console.paused").uppercased() }
        if game.status != .ready { return t(game.status.labelKey).uppercased() }
        // ready, but in Needs attention: why it is there (built with other tools than the engine has now)
        if game.olderTools, game.lastPlayed == nil { return (t("console.ready") + " \u{00b7} " + t("library.olderTools")).uppercased() }
        if let date = game.lastPlayed { return String(format: t("console.lastPlayedOn"), ConsoleTimes.relative(date, now: state.time, lang: lang)).uppercased() }
        return t("console.ready").uppercased()
    }

    // MARK: Rows

    /// The focused row at the top of the rows' area and the start of the next one under it. The rows above it are not drawn, so the
    /// layout never depends on a scroll position: up and down change which row leads, with a short fade.
    private var rows: some View {
        let sections = state.homeSections
        let focusedIndex = sections.firstIndex { $0.gameIDs.contains(state.focusedGame?.id ?? "") } ?? 0
        // the row in focus and the start of the next one: more would push the title off a 1080 p screen
        let height = sectionHeight + (sections.count > focusedIndex + 1 ? (compact ? 40 : 64) : 0)
        return VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            ForEach(sections.dropFirst(focusedIndex)) { section in row(section).transition(.opacity) }
        }
        .fixedSize(horizontal: false, vertical: true)   // each row at its own height: the area clips the next one, it never squeezes a tile
        .frame(height: height, alignment: .top)
        .clipped()
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.18), value: focusedIndex)
    }

    /// A caption shows only while its tile is fully inside the row, so a clipped tile never leaves a fragment of text at the margin.
    private func tileVisible(_ id: String, rowWidth: CGFloat) -> Bool {
        guard let frame = tileFrames[id] else { return true }
        return frame.minX >= -1 && frame.maxX <= rowWidth + 1
    }

    private func row(_ section: ConsoleHomeSection) -> some View {
        let games = section.gameIDs.compactMap { id in state.games.first { $0.id == id } }
        let rowWidth = size.width - 2 * (inset - 8)
        let space = "console.row." + section.id
        return VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            ConsoleSectionHeading(title: t(section.row.titleKey), compact: compact).padding(.horizontal, inset)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: (compact ? 22 : 28) - 16) {
                        ForEach(games) { game in tile(game, rowWidth: rowWidth, space: space) }
                    }
                    .padding(.vertical, 12)
                }
                .coordinateSpace(name: space)
                .onPreferenceChange(ConsoleTileFramesKey.self) { frames in tileFrames.merge(frames) { _, new in new } }
                .padding(.horizontal, inset - 8)   // the scroll area is the page margin, so tiles clip there and the title lines up with the first tile
                .onChange(of: state.focusedGame?.id) { id in
                    // The ring moves across the visible tiles. The row scrolls only when the focused tile would leave the visible area, by
                    // the least that brings it inside, and a new focus replaces the running scroll (held repeats do not queue).
                    guard let id, section.gameIDs.contains(id) else { return }
                    guard let frame = tileFrames[id] else { proxy.scrollTo(Self.rowCell(id), anchor: .center); return }
                    let anchor: UnitPoint? = frame.minX < 8 ? .leading : (frame.maxX > rowWidth - 8 ? .trailing : nil)
                    if let anchor { withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.2)) { proxy.scrollTo(Self.rowCell(id), anchor: anchor) } }
                }
                .onAppear { if let id = state.focusedGame?.id, section.gameIDs.contains(id) { proxy.scrollTo(Self.rowCell(id), anchor: .center) } }
            }
        }
    }

    private func tile(_ game: ConsoleGame, rowWidth: CGFloat, space: String) -> some View {
        let selected = state.focusedGame?.id == game.id
        let paused = game.id == state.pausedGameID
        let open = { driver.focus(game.id); paused ? driver.resume(game.id) : driver.openGamePage(game.id) }
        return Button(action: open) {
            ConsoleGameTile(game: game, selected: selected, compact: compact, lang: lang, captionVisible: tileVisible(game.id, rowWidth: rowWidth), paused: paused)
                .frame(width: tileWidth)
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padTarget("console.game." + game.id, scope: "console", radius: 16, activate: open)
        // the focus scale is applied to the button with its ring, so the ring frames the image flush at any scale
        .scaleEffect(selected && !reduceMotion ? 1.025 : 1)
        .animation(.easeOut(duration: 0.15), value: selected)
        .background(GeometryReader { g in Color.clear.preference(key: ConsoleTileFramesKey.self, value: [game.id: g.frame(in: .named(space))]) })
        .accessibilityLabel(game.title + ", " + t(paused ? "console.paused" : game.status.labelKey))
        .accessibilityHint(t(paused ? "console.resumeHint" : "console.openHint"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        // every tile carries its own 8 pt of room for the ring and the focus scale, and the scroll target is this padded
        // cell, so a scroll to the first or last tile never pushes that room out of the clip
        .padding(.horizontal, 8)
        .id(Self.rowCell(game.id))
    }

    static func rowCell(_ id: String) -> String { "console.row." + id }

    // MARK: Hints

    private var hintBar: some View {
        let focused = state.focusedGame
        let paused = focused != nil && focused?.id == state.pausedGameID
        let items = {
            Group {
                hint(.activate, paused ? "console.resume" : "console.open", "console.open", primary: true) {
                    if let id = focused?.id { paused ? driver.resume(id) : driver.openGamePage(id) }
                }
                if !paused { hint(.play, "console.play", "console.play") { if let id = focused?.id { driver.play(id) } } }
                hint(.options, "console.options", "console.options") { if let id = focused?.id { driver.openOptions(id) } }
                hint(.menu, "console.menu", "console.menu") { driver.openMenu() }
                hint(.quickMenu, "console.quickMenu", "console.quickMenuHint") { driver.openQuickMenu() }
                hint(.back, "console.desktop", "console.desktop") { driver.confirmExit() }   // asks first, as B does
            }
        }
        return VStack(spacing: 20) {
            Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
            if compact {
                // equal pills, two by two
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) { items() }
            } else {
                // inline glyph and label, the group centered as a whole with even spacing, the active one a cream pill
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: min(size.width * 0.08, 160)) { items() }
                    HStack(spacing: 16) { items() }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func hint(_ role: ConsoleGlyphs.Role, _ key: String, _ id: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        ConsoleHint(glyph: glyphs.hintGlyph(role, swapAB: state.menuSwapAB), label: t(key), id: id, primary: primary, compact: compact, action: action)
    }

    // MARK: Empty

    private var empty: some View {
        VStack(spacing: 24) {
            Image(systemName: "rectangle.stack").font(.system(size: compact ? 44 : 64, weight: .light)).foregroundStyle(LauncherPalette.cream.opacity(0.65)).accessibilityHidden(true)
            Text(t("console.empty")).font(.manrope(compact ? 34 : 54, .bold)).accessibilityAddTraits(.isHeader)
            Text(t("console.emptyNote")).font(.manrope(compact ? 20 : 26)).foregroundStyle(LauncherPalette.secondaryText)
            ConsolePrimaryButton(label: t("console.desktop"), id: "console.empty.desktop", scope: "console") { driver.exitToDesktop() }.frame(maxWidth: 340)
        }
        .multilineTextAlignment(.center).padding(24)
    }
}

/// The cream capsule of console mode's main actions: 60 pt high, the label wraps or shrinks, the button keeps its width.
struct ConsolePrimaryButton: View {
    let label: String
    let id: String
    let scope: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.manrope(21, .bold)).foregroundStyle(LauncherPalette.background)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8).padding(.horizontal, 20)   // a long label wraps or shrinks, the button keeps its width
                .frame(maxWidth: .infinity, minHeight: 60).background(LauncherPalette.cream, in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(.plain).padTarget(id, scope: scope, radius: 30, activate: action)   // half the 60 pt height: a capsule ring
    }
}

/// Times as console mode says them, in the launcher's language, not the Mac's.
enum ConsoleTimes {
    static func locale(_ lang: Lang) -> Locale { Locale(identifier: lang.locales.first ?? lang.code) }
    static func relative(_ date: Date, now: Date, lang: Lang) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = locale(lang)
        f.unitsStyle = .full
        return f.localizedString(for: min(date, now), relativeTo: now)
    }
    static func absolute(_ date: Date, lang: Lang) -> String {
        let f = DateFormatter()
        f.locale = locale(lang)
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
    /// Play time in hours and minutes ("2 hr, 5 min"), at least a minute once anything was played.
    static func duration(_ seconds: Double, lang: Lang) -> String {
        let f = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale(lang)
        f.calendar = calendar
        f.unitsStyle = .short
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        return f.string(from: max(seconds, 60)) ?? ""
    }
}

/// The top bar's capsules (the controllers, the clock, Search, the menu): a dark fill with a hairline, so white text keeps at least
/// 4.5:1 on any art, together with the backdrop's top scrim (ConsoleBackdrop.scrimHeight).
extension View {
    func consoleBarFill() -> some View {
        background(Color.black.opacity(ConsoleBarFill.opacity), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

enum ConsoleBarFill {
    /// Black at this share over pure white, under the scrim's 0.32 at the bar's middle, gives white text about 7:1, and 4.9:1 with
    /// no scrim at all.
    static let opacity = 0.55
}
