import AppKit
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
        .buttonStyle(.plain).padTarget(id, scope: scope, radius: primary ? nil : 8, focusColor: primary ? LauncherPalette.onCream : nil, activate: action)
    }
}

struct ConsoleTileFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}

struct ConsoleClock: View {
    static func fontSize(compact: Bool) -> CGFloat { compact ? 34 : 44 }
    let time: Date
    let compact: Bool
    var body: some View {
        Text(time, style: .time).font(.manrope(compact ? 34 : 44, .medium)).monospacedDigit()
            .foregroundStyle(.white).fixedSize()
    }
}

/// How the console home moves when another game is focused: light and short, with the values the home had before the launcher
/// redesign (e6c789659, before #1458 brought the Library's timing and the row's slide). The new title fades in while the old one goes
/// at once, so two titles never overlap. The art cross-fades softly. The row and the focused tile move gently. Nothing blurs.
enum ConsoleHomeMotion {
    /// The title: the new one fades in, the old one is gone in the same frame. The same under Reduce Motion, a fade moves nothing.
    static let title: Animation = .easeInOut(duration: 0.12)
    static let titleTransition: AnyTransition = .asymmetric(insertion: .opacity, removal: .identity)
    /// Another game's art cross-fades with the old one. Under Reduce Motion it switches at once.
    static func artwork(reduceMotion: Bool) -> Animation { .easeInOut(duration: reduceMotion ? 0.01 : 0.38) }
    static let artworkTransition: AnyTransition = .opacity
    /// The same game's large image arriving later replaces its cover.
    static func heroArrival(reduceMotion: Bool) -> Animation { .easeInOut(duration: reduceMotion ? 0.01 : 0.25) }
    /// The row moving to the next tile: a short ease, none under Reduce Motion.
    static func row(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .easeOut(duration: 0.2) }
    /// A tile's focus ring and scale: the home row's quick ease (`coverflow`), the grid's (all games, the search) a little longer.
    static func tileFocus(coverflow: Bool, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: coverflow ? 0.15 : 0.22)
    }
}

/// The home screen (#816): the top bar (the activity, the controllers, the clock, Search and the menu), the focused game's title, and
/// one row of every game with All games as its last tile, as a PlayStation 5 home (#1458). Left and right walk the row (ConsoleView
/// handles the presses, ConsoleHome.move decides), up goes to the top bar and down from it back to the same tile.
@MainActor struct ConsoleHomeScreen<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let glyphs: ConsoleGlyphs
    let size: CGSize
    let compact: Bool
    var launchNamespace: Namespace.ID? = nil
    var floatingPanelChrome = false
    /// Whether the top bar shows the build indicator (ConsoleView decides: something builds or just finished, not expired).
    var showBuild = false
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: ConsoleState { driver.state }
    private var panelOpen: Bool { state.presentedSheet != nil }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var inset: CGFloat { compact ? 24 : 70 }
    private var tileWidth: CGFloat { compact ? size.width - inset * 2 - 16 : min(420, size.width * 0.28) }
    /// The pad id of the row's last tile, All games.
    static var allGamesPad: String { ConsoleHome.allGamesID }
    /// The pad ids of the hint strip, so up from it goes back to the focused game.
    static var hintIDs: Set<String> { ["console.open", "console.options", "console.menu", "console.quickMenuHint", "console.desktop"] }
    /// The top bar's targets: the controller chips, Search and the menu button.
    static func isTopBar(_ id: String) -> Bool { id == "console.build.activity" || id.hasPrefix("console.chip.") || id == "console.searchButton" || id == "console.menuButton" }
    /// A tile of the home row: a game or All games.
    static func isRowTile(_ id: String) -> Bool { id.hasPrefix("console.game.") || id == allGamesPad }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar.padding(.horizontal, inset).padding(.top, compact ? 24 : 50)
            if state.games.isEmpty {
                empty.frame(maxWidth: .infinity, maxHeight: .infinity).blur(radius: panelOpen ? 14 : 0)
            } else {
                // The title and the row sit at the bottom, above the hints, so the artwork has the screen above them. A short window
                // scrolls, so the top bar never moves.
                GeometryReader { area in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: compact || size.height < 900 ? 16 : 24) {
                            Spacer(minLength: 0)
                            if let game = state.focusedGame { title(game) }
                            homeRow
                        }
                        .padding(.top, 24).padding(.bottom, 16)
                        .frame(minHeight: area.size.height, alignment: .bottomLeading)
                    }
                }
                .blur(radius: panelOpen ? 14 : 0)
                hintBar.blur(radius: panelOpen ? 14 : 0).padding(.horizontal, inset).padding(.bottom, compact ? 20 : 32)
            }
        }
        .dsAnimation(.easeInOut(duration: panelOpen ? (reduceMotion ? 0.1 : 0.18) : 0.08), value: panelOpen)
    }

    // MARK: Top bar

    /// One fixed-height status row: the plain clock, flexible controller chips, then
    /// Search and the menu. Its height never changes, so a controller arriving or leaving moves nothing below it.
    private var topBar: some View {
        HStack(spacing: compact ? 12 : 20) {
            ConsoleClock(time: state.time, compact: compact)
            if showBuild, let row = state.builds.indicatorRow {
                ConsoleBuildIndicator(builds: state.builds, row: row, lang: lang) { driver.openBuilds() }
                    .padTarget(ConsoleBuildIndicator.id, scope: "console", enabled: !panelOpen, activate: { driver.openBuilds() })
                    .environment(\.padRingStyle, .none)
                    .transition(.opacity)
            }
            // the players drop out first when the window is too narrow for all of it: nothing overflows the bar
            ViewThatFits(in: .horizontal) {
                cluster(players: true)
                cluster(players: false)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: compact ? 48 : 56)
        .dsAnimation(reduceMotion ? nil : .easeOut(duration: DS.Motion.standard), value: showBuild)
        // The banner sits under the bar, so it never covers the controller chips, and it is drawn over the page without moving it (#1004)
        .overlay(alignment: .top) {
            if let toast = state.toast {
                ConsoleToastView(toast: toast).id(toast.id).transition(.opacity).blur(radius: panelOpen ? 14 : 0)
                    .offset(y: (compact ? 48 : 56) - 12)
            }
        }
        .zIndex(1)
    }

    private func cluster(players: Bool) -> some View {
        HStack(alignment: .center, spacing: compact ? 12 : 16) {
            ConsoleControllerButton(controllers: state.controllers, merged: state.padMerge, lang: lang, compact: compact, showsPlayers: players) { driver.openControllers() }
            barButton("magnifyingglass", id: "console.searchButton", label: t("console.search")) { driver.openSearch() }
            barButton("line.3.horizontal", id: "console.menuButton", label: t("console.menu")) { driver.openMenu() }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func barButton(_ symbol: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        ConsoleHeaderButton(symbol: symbol, id: id, label: label, compact: compact, action: action)
    }

    // MARK: Title

    /// A fixed-height slot, so the rows below never move, whatever the title's length. Another game's title fades in quickly and the
    /// old one goes at once, so two titles of different lengths never show at the same time (ConsoleHomeMotion). No blur, no slide.
    /// Availability stays on the artwork chip.
    private func title(_ game: ConsoleGame) -> some View {
        ZStack(alignment: .bottomLeading) {
            Text(game.title).font(compact ? DS.Console.Font.title : DS.Console.Font.largeTitle)
                .tracking(DS.Console.Font.largeTitleTracking).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(DS.Color.textPrimary)
                .shadow(color: .black.opacity(0.45), radius: 12)
                .accessibilityAddTraits(.isHeader)
                .id(game.id).transition(ConsoleHomeMotion.titleTransition)
        }
        .dsAnimation(ConsoleHomeMotion.title, value: game.id)
        .padding(.horizontal, inset)
        .frame(height: titleHeight, alignment: .bottomLeading)
    }

    private var titleHeight: CGFloat { compact ? 130 : 54 + 2.4 * DS.Console.Font.largeTitleSize }

    // MARK: Row

    private var cellWidth: CGFloat { tileWidth + 24 }   // a tile with its 12 pt of room for the ring and the focus scale on each side
    private var cellSpacing: CGFloat { (compact ? 22 : 28) - 16 }
    /// The row's focus: All games while the pad is on it, else the focused game.
    private var rowFocus: String? { pad.focused == Self.allGamesPad ? ConsoleHome.allGamesID : state.focusedGame?.id }
    /// The focused tile's place in the row (All games after the games).
    private var rowIndex: Int { rowFocus.flatMap { (state.homeOrder + [ConsoleHome.allGamesID]).firstIndex(of: $0) } ?? 0 }

    /// The one row: the focused tile stands whole at the row's leading edge, the tiles already passed fan behind it, the next ones
    /// follow. The row moves by an offset from the focused tile's place, never by a scroll position, so the focused tile is whole
    /// from the first frame on, in the app and in a capture (#1458).
    private var homeRow: some View {
        let games = state.homeOrder.compactMap { id in state.games.first { $0.id == id } }
        let index = rowIndex
        let leading = inset - 12 + (reduceMotion ? 0 : tileWidth * 0.02)
        let step = cellWidth + cellSpacing
        return HStack(alignment: .top, spacing: cellSpacing) {
            ForEach(Array(games.enumerated()), id: \.element.id) { place, game in
                tile(game, place: place - index, captionVisible: place >= index && leading + CGFloat(place - index) * step + cellWidth <= size.width + 1)
            }
            allGamesTile(captionVisible: leading + CGFloat(games.count - index) * step + cellWidth <= size.width + 1)
        }
        .fixedSize()
        .padding(.vertical, 20)
        .padding(.leading, leading)
        .offset(x: -CGFloat(index) * step)
        .frame(width: size.width, alignment: .leading)
        .clipped()
        .dsAnimation(ConsoleHomeMotion.row(reduceMotion: reduceMotion), value: index)   // the row moves to the next tile with a short ease
        .background(ConsoleHomeWheelView { step in moveRow(step) })
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { gesture in
            if let step = ConsoleHomePointerInput.drag(gesture.translation) { moveRow(step) }
        })
        .overlay(alignment: .trailing) {
            if leading + CGFloat(games.count - index) * step + cellWidth > size.width + 1 {   // a tile is beyond the edge
                Button { moveRow(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44)
                        .background(.black, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t("library.scrollForward"))
                .padTarget("console.edge.home.right", scope: "console", activate: { moveRow(1) })
                .padding(.trailing, max(4, inset - 34)).padding(.bottom, 28)
            }
        }
    }

    /// One step left or right through the row (a wheel notch, a swipe, the edge arrow), stopping at its ends.
    private func moveRow(_ step: Int) {
        guard let focus = rowFocus, let next = ConsoleHome.move(from: focus, by: step, in: state.homeOrder) else { return }
        if next == ConsoleHome.allGamesID { pad.focused = Self.allGamesPad; return }
        driver.focus(next)
        pad.focused = "console.game." + next
    }

    /// `place`: the tile's place from the focused one, negative for a tile already passed.
    private func tile(_ game: ConsoleGame, place: Int, captionVisible: Bool) -> some View {
        let selected = state.focusedGame?.id == game.id && rowFocus == game.id
        let paused = game.id == state.pausedGameID
        let open = {
            driver.focus(game.id)
            if paused { driver.resume(game.id) }
            else if game.status == .ready { driver.play(game.id) }
            else { driver.openOptions(game.id) }
        }
        return Button {
            ConsoleHomePointerInput.tapTile(game.id, focused: state.focusedGame?.id, focus: {
                driver.focus(game.id); pad.focused = "console.game." + game.id
            }, open: open)
        } label: {
            ConsoleGameTile(game: game, selected: selected, compact: compact, lang: lang, captionVisible: captionVisible, paused: paused,
                            coverflow: true, tilt: place < 0 ? 25 : (place == 0 ? 0 : -10), rearOffset: tileWidth * 0.3,
                            showsSelection: !pad.visible || pad.focused == "console.game." + game.id, launchNamespace: selected ? launchNamespace : nil)
                .frame(width: tileWidth)
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padTarget("console.game." + game.id, scope: "console", radius: 16, activate: open)
        .environment(\.padRingStyle, .none)
        .zIndex(selected ? 1 : 0)
        .accessibilityLabel(game.title + ", " + t(paused ? "console.paused" : game.status.labelKey))
        .accessibilityHint(t(paused ? "console.resumeHint" : (game.status == .ready ? "console.play" : "console.options")))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padding(.horizontal, 12)   // the tile's room for the ring and the focus scale
        .id(Self.rowCell(game.id))
    }

    /// The row's last tile: All games, so the whole library stays one press away.
    private func allGamesTile(captionVisible: Bool) -> some View {
        let selected = rowFocus == ConsoleHome.allGamesID
        let open = { driver.openAllGames() }
        return Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    DS.Color.surfaceRaised
                    Image(systemName: "square.grid.2x2").font(.system(size: compact ? 34 : 44, weight: .light)).foregroundStyle(DS.Color.symbolDefault)
                }
                .aspectRatio(1.8, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.Console.Radius.art))
                .overlay(RoundedRectangle(cornerRadius: DS.Console.Radius.art).strokeBorder(selected ? DS.Color.accent : DS.Color.separator,
                                                                                        lineWidth: selected ? DS.Console.Control.focusRing : 1))
                .scaleEffect(selected && !reduceMotion ? DS.Console.Scale.focus : 1)
                .dsAnimation(ConsoleHomeMotion.tileFocus(coverflow: true, reduceMotion: reduceMotion), value: selected)
                Text(t("console.allGames")).opacity(captionVisible ? 1 : 0)
                    .font(DS.Console.Font.callout).lineLimit(1)
                    .foregroundStyle(selected ? DS.Color.textPrimary : DS.Color.textSecondary)
                    .padding(.horizontal, DS.Space.xxs).accessibilityHidden(true)
            }
            .frame(width: tileWidth)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padTarget(Self.allGamesPad, scope: "console", radius: 16, activate: open)
        .environment(\.padRingStyle, .none)
        .zIndex(selected ? 1 : 0)
        .accessibilityLabel(t("console.allGames"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padding(.horizontal, 12)
    }

    static func rowCell(_ id: String) -> String { "console.row." + id }

    // MARK: Hints

    private var hintBar: some View {
        let focused = state.focusedGame
        let paused = focused != nil && focused?.id == state.pausedGameID
        let onAllGames = pad.focused == Self.allGamesPad
        let primary = {
            hint(.activate, onAllGames ? "console.allGames" : (paused ? "console.resume" : (focused?.status == .ready ? "console.play" : "console.options")),
                 "console.open", primary: true) {
                if onAllGames { driver.openAllGames(); return }   // A on the row's last tile opens All games
                if let id = focused?.id { paused ? driver.resume(id) : (focused?.status == .ready ? driver.play(id) : driver.openOptions(id)) }
            }
        }
        let secondary = {
            Group {
                hint(.options, "console.options", "console.options") { if let id = focused?.id { driver.openOptions(id) } }
                hint(.menu, "console.menu", "console.menu") { driver.openMenu() }
                hint(.quickMenu, "console.quickMenu", "console.quickMenuHint") { driver.openQuickMenu() }
            }
        }
        let back = { hint(.back, "console.desktop", "console.desktop") { driver.confirmExit() } }
        return VStack(spacing: 20) {
            Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
            if compact {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                    primary(); secondary(); back()
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        primary().fixedSize()
                        Spacer(minLength: 16)
                        hint(.options, "console.options", "console.options") { if let id = focused?.id { driver.openOptions(id) } }.fixedSize()
                        Spacer(minLength: 16)
                        hint(.menu, "console.menu", "console.menu") { driver.openMenu() }.fixedSize()
                        Spacer(minLength: 16)
                        hint(.quickMenu, "console.quickMenu", "console.quickMenuHint") { driver.openQuickMenu() }.fixedSize()
                        Spacer(minLength: 16)
                        back().fixedSize()
                    }
                    VStack(spacing: 12) {
                        HStack { primary(); Spacer(minLength: 16); back() }
                        HStack(spacing: 16) { secondary(); Spacer(minLength: 0) }
                    }
                }
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

/// Pointer input on the home row: a wheel or a swipe on either axis is one step through the row. Trackpad phases form one gesture,
/// while a wheel notch is one step.
struct ConsoleHomePointerInput {
    private var accumulated: CGFloat = 0
    private var moved = false

    static func tapTile(_ id: String, focused: String?, focus: () -> Void, open: () -> Void) {
        focus()
        open()
    }

    static func drag(_ translation: CGSize) -> Int? {
        let along = abs(translation.height) > abs(translation.width) ? translation.height : translation.width
        guard abs(along) >= 24 else { return nil }
        return along < 0 ? 1 : -1
    }

    mutating func wheel(deltaY: CGFloat, deltaX: CGFloat = 0, phase: NSEvent.Phase = [], momentum: Bool = false) -> Int? {
        if phase.contains(.began) || phase.contains(.mayBegin) { accumulated = 0; moved = false }
        defer {
            if phase.contains(.ended) || phase.contains(.cancelled) { accumulated = 0; moved = false }
        }
        let delta = abs(deltaY) >= abs(deltaX) ? deltaY : deltaX
        guard !momentum, delta != 0 else { return nil }
        if phase == [] { return delta > 0 ? -1 : 1 }
        guard !moved else { return nil }
        accumulated += delta
        guard abs(accumulated) >= 18 else { return nil }
        moved = true
        return accumulated > 0 ? -1 : 1
    }
}

/// Observes scrolls over the home row without covering its tiles: each becomes a step through the row.
private struct ConsoleHomeWheelView: NSViewRepresentable {
    let move: (Int) -> Void

    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ view: WheelView, context: Context) { view.move = move }

    final class WheelView: NSView {
        var move: ((Int) -> Void)?
        private var monitor: Any?
        private var input = ConsoleHomePointerInput()

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.viewWillMove(toWindow: newWindow)
            guard newWindow != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let windowNumber = event.windowNumber, location = event.locationInWindow
                let deltaY = event.scrollingDeltaY, deltaX = event.scrollingDeltaX
                let phase = event.phase, momentum = event.momentumPhase != []
                let handled = MainActor.assumeIsolated { [weak self] in
                    guard let self, self.window?.windowNumber == windowNumber,
                          self.bounds.contains(self.convert(location, from: nil)) else { return false }
                    if let step = self.input.wheel(deltaY: deltaY, deltaX: deltaX, phase: phase, momentum: momentum) { self.move?(step) }
                    return true
                }
                return handled ? nil : event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
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
        .buttonStyle(.plain).padTarget(id, scope: scope, focusColor: LauncherPalette.onCream, activate: action)
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

