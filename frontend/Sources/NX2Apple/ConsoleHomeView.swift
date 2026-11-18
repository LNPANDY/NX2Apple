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

/// The home screen (#816): the top bar (the activity, the controllers, the clock, Search and the menu), the focused game's title, and
/// its history and availability groups, each scrolling sideways. Up and down go from row to row (ConsoleView
/// handles the presses, ConsoleHome.move decides), the row in focus sits at the top of the rows' area and the next one shows under it.
@MainActor struct ConsoleHomeScreen<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let glyphs: ConsoleGlyphs
    let size: CGSize
    let compact: Bool
    var launchNamespace: Namespace.ID? = nil
    var floatingPanelChrome = false
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tileFrames: [String: CGRect] = [:]

    private var state: ConsoleState { driver.state }
    private var panelOpen: Bool { state.presentedSheet != nil }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var inset: CGFloat { compact ? 24 : 70 }
    private var tileWidth: CGFloat { compact ? size.width - inset * 2 - 16 : min(420, size.width * 0.28) }
    /// A row: its heading, the tiles with their room for the ring, and the captions.
    private var sectionHeight: CGFloat { tileWidth / 1.8 + (compact ? 92 : 104) }
    /// The pad ids of the hint strip, so up from it goes back to the focused game.
    static var hintIDs: Set<String> { ["console.open", "console.options", "console.menu", "console.quickMenuHint", "console.desktop"] }
    /// The top bar's targets: the controller chips, Search and the menu button.
    static func isTopBar(_ id: String) -> Bool { id == "console.build.activity" || id.hasPrefix("console.chip.") || id == "console.searchButton" || id == "console.menuButton" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar.padding(.horizontal, inset).padding(.top, compact ? 24 : 50)
            if state.games.isEmpty {
                empty.frame(maxWidth: .infinity, maxHeight: .infinity).blur(radius: panelOpen ? 14 : 0)
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
                .blur(radius: panelOpen ? 14 : 0)
                hintBar.blur(radius: panelOpen ? 14 : 0).padding(.horizontal, inset).padding(.bottom, compact ? 20 : 32)
            }
        }
        .animation(.easeInOut(duration: panelOpen ? (reduceMotion ? 0.1 : 0.18) : 0.08), value: panelOpen)
    }

    // MARK: Top bar

    /// One fixed-height status row: the plain clock, flexible controller chips, then
    /// Search and the menu. Its height never changes, so a controller arriving or leaving moves nothing below it.
    private var topBar: some View {
        HStack(spacing: compact ? 12 : 20) {
            ConsoleClock(time: state.time, compact: compact).hidden().accessibilityHidden(true)
            Spacer(minLength: 8)
            HStack(spacing: compact ? 12 : 20) {
                HStack(alignment: .center, spacing: compact ? 12 : 16) {
                    ConsoleControllerButton(controllers: state.controllers, merged: state.padMerge, lang: lang, compact: compact) { driver.openControllers() }
                    barButton("magnifyingglass", id: "console.searchButton", label: t("console.search")) { driver.openSearch() }
                    barButton("line.3.horizontal", id: "console.menuButton", label: t("console.menu")) { driver.openMenu() }
                }
                .fixedSize(horizontal: true, vertical: false)
            }.blur(radius: panelOpen ? 14 : 0)
        }
        .frame(height: compact ? 48 : 56)
        // The banner sits under the bar, so it never covers the controller chips, and it is drawn over the page without moving it (#1004)
        .overlay(alignment: .top) {
            if let toast = state.toast {
                ConsoleToastView(toast: toast).id(toast.id).transition(.opacity).blur(radius: panelOpen ? 14 : 0)
                    .offset(y: (compact ? 48 : 56) - 12)
            }
        }
        .zIndex(1)
    }

    private func barButton(_ symbol: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        ConsoleHeaderButton(symbol: symbol, id: id, label: label, compact: compact, action: action)
    }

    // MARK: Title

    /// A fixed-height slot: the old and the new title overlap and cross-fade in place with the Library timing, so nothing slides and the rows below
    /// never move, whatever the title's length. Availability stays on the artwork chip.
    private func title(_ game: ConsoleGame) -> some View {
        let big = compact ? 36 : min(56, size.width / 26)
        return ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: compact ? 10 : 16) {
                Text(game.title).font(.manrope(big, .bold))
                    .tracking(-1.4).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.45), radius: 12)
                    .accessibilityAddTraits(.isHeader)

            }
            .id(game.id).transition(.opacity)
        }
        .animation(LibraryHeroTransition.metadata(reduceMotion: reduceMotion), value: game.id)
        .padding(.horizontal, inset)
        .frame(height: compact ? 130 : 54 + 2.4 * big, alignment: .bottomLeading)
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
        .background(ConsoleHomeWheelView { step in moveRow(step) })
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { gesture in
            if let step = ConsoleHomePointerInput.drag(gesture.translation) { moveRow(step) }
        })
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.18), value: focusedIndex)
    }

    private func moveRow(_ step: Int) {
        guard let id = state.focusedGame?.id,
              let next = ConsoleHome.move(from: id, dx: 0, dy: step, in: state.homeSections) else { return }
        driver.focus(next)
        pad.focused = "console.game." + next
    }

    /// A caption shows only while its tile is fully inside the row, so a clipped tile never leaves a fragment of text at the margin.
    private func tileVisible(_ id: String, rowWidth: CGFloat) -> Bool {
        guard let frame = tileFrames[id] else { return true }
        return frame.minX >= -1 && frame.maxX <= rowWidth + 1
    }

    private func row(_ section: ConsoleHomeSection) -> some View {
        let games = section.gameIDs.compactMap { id in state.games.first { $0.id == id } }
        let rowWidth = size.width
        let cellWidth = tileWidth + 24
        // Align the visible stroke after the active artwork scales about its center.
        let leading = inset - 12 + (reduceMotion ? 0 : tileWidth * 0.02)
        let anchor = UnitPoint(x: leading / max(1, rowWidth - cellWidth), y: 0.5)
        let space = "console.row." + section.id
        return VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            if section.row == .continuePlaying {
                ConsoleSectionHeading(title: t(section.row.titleKey), compact: compact).padding(.horizontal, inset)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: (compact ? 22 : 28) - 16) {
                        ForEach(games) { game in tile(game, games: games, rowWidth: rowWidth, space: space) }
                    }
                    .padding(.vertical, 20)
                    .padding(.leading, leading)
                    .padding(.trailing, max(0, rowWidth - leading - cellWidth))
                }
                .coordinateSpace(name: space)
                .onPreferenceChange(ConsoleTileFramesKey.self) { frames in tileFrames.merge(frames) { _, new in new } }
                .onChange(of: state.focusedGame?.id) { id in
                    guard let id, section.gameIDs.contains(id) else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                        proxy.scrollTo(Self.rowCell(id), anchor: anchor)
                    }
                }
                .onChange(of: size.width) { _ in
                    if let id = state.focusedGame?.id, section.gameIDs.contains(id) {
                        proxy.scrollTo(Self.rowCell(id), anchor: anchor)
                    }
                }
                .onAppear { if let id = state.focusedGame?.id, section.gameIDs.contains(id) { proxy.scrollTo(Self.rowCell(id), anchor: anchor) } }
                .overlay {
                    HStack {
                        Spacer(minLength: 0)
                        edgeArrow(games, rowWidth: rowWidth, anchor: anchor, proxy: proxy)
                    }
                    .padding(.horizontal, max(4, inset - 34))
                    .padding(.bottom, 28)
                }
            }
        }
    }

    private func tile(_ game: ConsoleGame, games: [ConsoleGame], rowWidth: CGFloat, space: String) -> some View {
        let selected = state.focusedGame?.id == game.id
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
            ConsoleGameTile(game: game, selected: selected, compact: compact, lang: lang, captionVisible: tileVisible(game.id, rowWidth: rowWidth), paused: paused,
                            coverflow: true, tilt: tilt(game, games: games), rearOffset: tileWidth * 0.3, showsSelection: !pad.visible || pad.focused == "console.game." + game.id, launchNamespace: selected ? launchNamespace : nil)
                .frame(width: tileWidth)
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padTarget("console.game." + game.id, scope: "console", radius: 16, activate: open)
        .environment(\.padRingStyle, .none)
        .zIndex(selected ? 1 : 0)
        .background(GeometryReader { g in Color.clear.preference(key: ConsoleTileFramesKey.self, value: [game.id: g.frame(in: .named(space))]) })
        .accessibilityLabel(game.title + ", " + t(paused ? "console.paused" : game.status.labelKey))
        .accessibilityHint(t(paused ? "console.resumeHint" : (game.status == .ready ? "console.play" : "console.options")))
        .accessibilityAddTraits(selected ? .isSelected : [])
        // every tile carries its own 12 pt of room for the ring and the focus scale, and the scroll target is this padded
        // cell, so a scroll to the first or last tile never pushes that room out of the clip
        .padding(.horizontal, 12)
        .id(Self.rowCell(game.id))
    }

    private func tilt(_ game: ConsoleGame, games: [ConsoleGame]) -> Double {
        guard let selected = state.focusedGame?.id,
              let active = games.firstIndex(where: { $0.id == selected }),
              let index = games.firstIndex(where: { $0.id == game.id }) else { return 0 }
        return index == active ? 0 : (index < active ? 25 : -10)
    }

    @ViewBuilder private func edgeArrow(_ games: [ConsoleGame], rowWidth: CGFloat, anchor: UnitPoint, proxy: ScrollViewProxy) -> some View {
        let hidden = games.filter { game in
            guard let frame = tileFrames[game.id] else { return false }
            return frame.maxX > rowWidth + 1
        }
        if let target = hidden.first {
            let select = {
                driver.focus(target.id)
                pad.focused = "console.game." + target.id
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                    proxy.scrollTo(Self.rowCell(target.id), anchor: anchor)
                }
            }
            Button(action: select) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44)
                    .background(.black, in: Circle()).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t("library.scrollForward"))
            .padTarget("console.edge." + (games.first?.id ?? "") + ".right", scope: "console", activate: select)
        }
    }

    static func rowCell(_ id: String) -> String { "console.row." + id }

    // MARK: Hints

    private var hintBar: some View {
        let focused = state.focusedGame
        let paused = focused != nil && focused?.id == state.pausedGameID
        let primary = {
            hint(.activate, paused ? "console.resume" : (focused?.status == .ready ? "console.play" : "console.options"), "console.open", primary: true) {
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

/// Pointer input on the clipped home rows. Trackpad phases form one gesture, while a wheel notch is one step.
struct ConsoleHomePointerInput {
    private var accumulated: CGFloat = 0
    private var moved = false

    static func tapTile(_ id: String, focused: String?, focus: () -> Void, open: () -> Void) {
        focus()
        open()
    }

    static func drag(_ translation: CGSize) -> Int? {
        guard abs(translation.height) >= 24, abs(translation.height) > abs(translation.width) else { return nil }
        return translation.height < 0 ? 1 : -1
    }

    mutating func wheel(deltaY: CGFloat, deltaX: CGFloat = 0, phase: NSEvent.Phase = [], momentum: Bool = false) -> Int? {
        if phase.contains(.began) || phase.contains(.mayBegin) { accumulated = 0; moved = false }
        defer {
            if phase.contains(.ended) || phase.contains(.cancelled) { accumulated = 0; moved = false }
        }
        guard !momentum, abs(deltaY) > abs(deltaX), deltaY != 0 else { return nil }
        if phase == [] { return deltaY > 0 ? -1 : 1 }
        guard !moved else { return nil }
        accumulated += deltaY
        guard abs(accumulated) >= 18 else { return nil }
        moved = true
        return accumulated > 0 ? -1 : 1
    }
}

/// Observes scrolls within the row window without covering tiles or consuming horizontal row scrolling.
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
                          self.bounds.contains(self.convert(location, from: nil)),
                          abs(deltaY) > abs(deltaX) else { return false }
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

/// Header actions share height, outline and centered content. Text actions use a capsule.
struct ConsoleHeaderButton: View {
    let symbol: String
    let id: String
    let label: String
    let compact: Bool
    var showsLabel = false
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var focused: Bool { pad.visible && pad.focused == id }
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: compact ? 18 : 20, weight: .semibold))
                    .frame(width: 24, height: 24)
                if showsLabel { Text(label).font(.manrope(compact ? 15 : 17, .semibold)).lineLimit(1) }
            }
            .padding(.horizontal, showsLabel ? 18 : 0)
            .frame(width: showsLabel ? nil : (compact ? 48 : 52), height: compact ? 48 : 52)
            .background {
                if showsLabel { Capsule().fill(focused ? LauncherPalette.cream : .black) } else { Circle().fill(focused ? LauncherPalette.cream : .black) }
            }
            .overlay {
                if showsLabel { Capsule().strokeBorder(LauncherPalette.cream, lineWidth: 2) }
                else { Circle().strokeBorder(LauncherPalette.cream, lineWidth: 2) }
            }
            .contentShape(Capsule())
        }
        .foregroundStyle(focused ? Color.black : .white)
        .buttonStyle(.plain).accessibilityLabel(label)
        .padTarget(id, scope: "console", activate: action)
        .environment(\.padRingStyle, .none)
        .scaleEffect(focused && !reduceMotion ? 1.1 : 1)
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.16), value: focused)
    }
}
