import SwiftUI
import Combine
import NXCore
import NXLauncher

/// Semantic inputs from a future controller adapter; the view does not discover hardware.
enum ConsoleInput {
    case left, right, up, down, activate, back, options, menu

    /// The launcher's controller path (Gamepad.swift) in console terms: the D-pad and left stick move, A activates, B backs out,
    /// Y opens the focused game's options, the menu button (+, Menu, Options) and the Select-type button (−, View, Share,
    /// Create) the console's menu. The same button again closes what it opened. X, L and R are not used.
    init?(_ action: LauncherGamepad.Action) {
        switch action {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .up
        case .down: self = .down
        case .a: self = .activate
        case .b: self = .back
        case .y: self = .options
        case .plus, .select: self = .menu
        case .x, .l, .r: return nil
        }
    }
}

@MainActor struct ConsoleView<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    var lang: Lang = .initial()
    var inputs: AnyPublisher<ConsoleInput, Never> = Empty().eraseToAnyPublisher()
    /// Set by the real launcher: leaving the mode calls it instead of showing the preview's "Back on desktop" screen.
    var onExit: (() -> Void)?
    /// The General page's language choice: "" follows the system, else a language code (Localizer.choose). Nil: the page shows it only.
    var chooseLanguage: ((String) -> Void)?
    /// The language picked here, shown checked (Lang.saved, read when the page opens).
    @State private var languageCode = Lang.saved?.code ?? ""
    @StateObject private var pad = PadFocus()
    @StateObject private var gamepad: LauncherGamepad
    @State private var tileFrames: [String: CGRect] = [:]
    /// The glyph set follows the input used last: a controller's own buttons, or key caps after the keyboard.
    @State private var glyphs: ConsoleGlyphs
    /// Where the focus was under each open sheet, so closing one puts it back there (the menu button, the game, a menu row).
    @State private var returnFocus: [String?] = []
    @State private var sheetDepth = 0
    /// The slider A picked: only it takes left and right, until A or B lets it go or the focus moves on.
    @State private var editingOption: String?

    /// `gamepad` is the one the root view owns (the controller has a single handler, so two would fight); without one the view makes its own.
    init(driver: Driver, lang: Lang = .initial(), inputs: AnyPublisher<ConsoleInput, Never> = Empty().eraseToAnyPublisher(), gamepad: LauncherGamepad? = nil, glyphs: ConsoleGlyphs? = nil, onExit: (() -> Void)? = nil, chooseLanguage: ((String) -> Void)? = nil) {
        self.onExit = onExit
        self.chooseLanguage = chooseLanguage
        _glyphs = State(initialValue: glyphs ?? .current())
        self.driver = driver
        self.lang = lang
        self.inputs = inputs
        _gamepad = StateObject(wrappedValue: gamepad ?? LauncherGamepad())
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: ConsoleState { driver.state }
    private var scope: String { state.presentedSheet?.scope ?? "console" }
    private func t(_ key: String) -> String { L10n.string(key, lang) }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 650
            ZStack(alignment: .trailing) {
                backdrop(size: geometry.size)
                if state.exited {
                    exitPreview(compact: compact)
                } else if let game = state.startingGame {
                    starting(game, compact: compact)
                } else {
                    home(size: geometry.size, compact: compact)
                        .allowsHitTesting(state.presentedSheet == nil)
                        .accessibilityHidden(state.presentedSheet != nil)
                    // The question to leave is drawn over what it was asked from, which stays in view but takes no input.
                    let confirming = state.presentedSheet?.isQuestion == true
                    let shown = confirming ? state.sheets.dropLast().last : state.presentedSheet
                    // A panel opened over a page of its own (a game's options over the library) keeps that page under it, as the one
                    // view: the page that was shown is the page under the panel, so nothing fades out and in (a flash) at the change.
                    let under = shown.flatMap { sheet in sheet.isFullScreen ? nil : state.sheets.last { $0.isFullScreen } }
                    let page = (shown?.isFullScreen == true ? shown : nil) ?? under
                    Group {
                        if let page {
                            // a page of its own over the whole screen, not a panel at the side; without input while a panel is over it
                            fullPage(page, compact: compact)
                                .padScope(page.scope, pad)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .background(LauncherPalette.background)
                                .allowsHitTesting(under == nil).accessibilityHidden(under != nil)
                                .id(page.scope)
                                .transition(.opacity)
                        }
                        if let sheet = shown, !sheet.isFullScreen {
                            Color.black.opacity(0.5).ignoresSafeArea().accessibilityHidden(true)
                            sheetContent(sheet, compact: compact)
                                .frame(width: compact ? geometry.size.width : min(700, max(520, geometry.size.width * 0.46)))
                                .frame(maxHeight: .infinity)
                                .background(LauncherPalette.background)
                                .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.10)).frame(width: 1) }
                                .transition(.opacity)
                        }
                    }
                    .allowsHitTesting(!confirming).accessibilityHidden(confirming)
                    if confirming {
                        Color.black.opacity(0.55).ignoresSafeArea().accessibilityHidden(true).onTapGesture { driver.back() }
                        question(compact: compact)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .background(LauncherPalette.background)
        .foregroundStyle(.white)
        .font(.manrope(22))
        .tint(LauncherPalette.cream)
        .preferredColorScheme(.dark)
        .environmentObject(pad)
        .environment(\.padRingStyle, .hug)
        .background(ConsoleKeyboardInput(perform: { input in glyphs = .keyboard; handle(input) }).frame(width: 0, height: 0))
        .onReceive(inputs, perform: handle)
        .onChange(of: scope) { _ in editingOption = nil; resetFocus() }
        .onChange(of: state.exited) { exited in if exited, let onExit { onExit() } else { resetFocus() } }
        // the buttons by their printed letters (ConsoleButtons), the swap read at each press so changing it here applies at once
        .onAppear { gamepad.capture = { [driver] id, action in
                driver.consumePress(controllerID: id, isBack: ConsoleButtons.input(action, swapAB: driver.state.menuSwapAB) == .back) }
            gamepad.perform = { [self] action in
                if let input = ConsoleButtons.input(action, swapAB: driver.state.menuSwapAB) { glyphs = .current(); handle(input) } }
            resetFocus() }
        .onDisappear { gamepad.deactivate() }
        .onChange(of: pad.focused) { id in
            if let id, id.hasPrefix("console.game.") { driver.focus(String(id.dropFirst("console.game.".count))) }
            if editingOption != id { editingOption = nil }
        }
        .animation(.easeOut(duration: 0.18), value: state.presentedSheet)
        .animation(.easeOut(duration: 0.18), value: state.toast?.id)
        .animation(.easeOut(duration: 0.22), value: state.startingGameID)
    }

    private func backdrop(size: CGSize) -> some View {
        ConsoleBackdrop(game: state.startingGame ?? state.focusedGame, starting: state.startingGame != nil, size: size)
    }

    private func home(size: CGSize, compact: Bool) -> some View {
        let inset: CGFloat = compact ? 24 : 64
        return VStack(alignment: .leading, spacing: 0) {
            topBar(compact: compact).padding(.horizontal, inset).padding(.top, compact ? 24 : 40)
            if state.games.isEmpty {
                empty(compact: compact).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The title and the row sit at the bottom, above the hints, so the artwork has the screen above them. A short window scrolls.
                GeometryReader { area in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: compact || size.height < 900 ? 24 : 32) {
                        Spacer(minLength: 0)
                        if let game = state.focusedGame {
                            // A fixed-height slot: the old and the new title overlap and cross-fade in place (0.15 s), so nothing slides
                            // and the row below never moves, whatever the title's length.
                            ZStack(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: compact ? 14 : 20) {
                                Text(t("console.library")).font(.manrope(compact ? 14 : 18, .semibold))
                                    .tracking(2).foregroundStyle(LauncherPalette.cream.opacity(0.75))
                                Text(game.title).font(.manrope(compact ? 36 : min(64, size.width / 24), .bold))
                                    .tracking(-1.6).lineLimit(2).fixedSize(horizontal: false, vertical: true)
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
                            .frame(height: compact ? 175 : 100 + 2.4 * min(64, size.width / 24), alignment: .bottomLeading)
                        }
                        gameRow(size: size, compact: compact, inset: inset)
                    }
                    .padding(.top, 24).padding(.bottom, 24)
                    .frame(minHeight: area.size.height, alignment: .bottomLeading)
                }
                }
            }
            if !state.games.isEmpty { hintBar(compact: compact, width: size.width).padding(.horizontal, inset).padding(.bottom, compact ? 20 : 32) }
        }
        .padScope("console", pad)
    }

    /// One fixed-height status row: the controller chips (scrolling sideways inside their own group) to the left of the clock.
    /// Its height never changes, so a controller arriving or leaving moves nothing below it.
    private func topBar(compact: Bool) -> some View {
        HStack(spacing: compact ? 12 : 20) {
            if let activity = state.activity { ConsoleActivityChip(activity: activity, compact: compact) }
            ConsoleControllerChips(controllers: state.controllers, merged: state.padMerge, lang: lang, compact: compact) { driver.openControllers() }
            Text(state.time, style: .time).font(.manrope(compact ? 17 : 22, .medium)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.65)).fixedSize()
            // The menu, as + and − open it: drawn as a controller chip (same capsule, same height), focusable like them.
            Button { driver.openMenu() } label: {
                Image(systemName: "line.3.horizontal").font(.system(size: compact ? 12 : 17, weight: .semibold))
                    .padding(.horizontal, compact ? 10 : 14).frame(height: compact ? 30 : 40)
                    .background(.white.opacity(0.075), in: Capsule()).contentShape(Capsule())
            }
            .buttonStyle(.plain).accessibilityLabel(t("console.menu"))
            .padTarget("console.menuButton", scope: "console", radius: 24, activate: { driver.openMenu() })
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

    /// A caption shows only while its tile is fully inside the row, so a clipped tile never leaves a fragment of text at the margin.
    private func tileVisible(_ id: String, rowWidth: CGFloat) -> Bool {
        guard let frame = tileFrames[id] else { return true }
        return frame.minX >= -1 && frame.maxX <= rowWidth + 1
    }

    private func gameRow(size: CGSize, compact: Bool, inset: CGFloat) -> some View {
        let width: CGFloat = compact ? size.width - inset * 2 - 16 : min(470, size.width * 0.32)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: (compact ? 22 : 28) - 16) {
                    ForEach(state.games) { game in
                        let selected = state.focusedGame?.id == game.id
                        Button { driver.focus(game.id); driver.play(game.id) } label: {
                            ConsoleGameTile(game: game, selected: selected, compact: compact, lang: lang, captionVisible: tileVisible(game.id, rowWidth: size.width - 2 * (inset - 8)))
                                .frame(width: width)
                                .contentShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .padTarget("console.game." + game.id, scope: "console", radius: 16, activate: { driver.play(game.id) })
                        // the focus scale is applied to the button with its ring, so the ring frames the image flush at any scale
                        .scaleEffect(selected && !reduceMotion ? 1.025 : 1)
                        .animation(.easeOut(duration: 0.15), value: selected)
                        .background(GeometryReader { g in Color.clear.preference(key: ConsoleTileFramesKey.self, value: [game.id: g.frame(in: .named("console.row"))]) })
                        .accessibilityLabel(game.title + ", " + t(game.status.labelKey))
                        .accessibilityHint(t("console.playHint"))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        // every tile carries its own 8 pt of room for the ring and the focus scale, and the scroll target is this padded
                        // cell, so a scroll to the first or last tile never pushes that room out of the clip
                        .padding(.horizontal, 8)
                        .id(Self.rowCell(game.id))
                    }
                }
                .padding(.vertical, 12)
            }
            .coordinateSpace(name: "console.row")
            .onPreferenceChange(ConsoleTileFramesKey.self) { tileFrames = $0 }
            .padding(.horizontal, inset - 8)   // the scroll area is the page margin, so tiles clip there and the title lines up with the first tile
            .onChange(of: state.focusedGame?.id) { id in
                // The ring moves across the visible tiles. The row scrolls only when the focused tile would leave the visible area, by
                // the least that brings it inside, and a new focus replaces the running scroll (held repeats do not queue).
                guard let id else { return }
                guard let frame = tileFrames[id] else { proxy.scrollTo(Self.rowCell(id), anchor: .center); return }
                let rowWidth = size.width - 2 * (inset - 8)
                let anchor: UnitPoint? = frame.minX < 8 ? .leading : (frame.maxX > rowWidth - 8 ? .trailing : nil)
                if let anchor { withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.2)) { proxy.scrollTo(Self.rowCell(id), anchor: anchor) } }
            }
            .onAppear { if let id = state.focusedGame?.id { proxy.scrollTo(Self.rowCell(id), anchor: .center) } }
        }
    }

    private static func rowCell(_ id: String) -> String { "console.row." + id }

    private func hintBar(compact: Bool, width: CGFloat) -> some View {
        let items = {
            Group {
                hint(.activate, "console.play", "console.play", primary: true, compact: compact) { if let id = state.focusedGame?.id { driver.play(id) } }
                hint(.options, "console.options", "console.options", compact: compact) { if let id = state.focusedGame?.id { driver.openOptions(id) } }
                hint(.menu, "console.menu", "console.menu", compact: compact) { driver.openMenu() }
                hint(.back, "console.desktop", "console.desktop", compact: compact) { driver.confirmExit() }   // asks first, as B does
            }
        }
        return VStack(spacing: 20) {
            Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
            if compact {
                // equal pills, two by two
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) { items() }
            } else {
                // inline glyph and label, the group centered as a whole with even spacing, the active one a cream pill
                HStack(spacing: min(width * 0.12, 220)) { items() }.frame(maxWidth: .infinity)   // wide gaps, the group centered as a unit
            }
        }
    }

    /// A button and what it does. The glyph is the button that does it now (ConsoleButtons): A or B as Swap A and B in menus has it.
    private func hint(_ role: ConsoleGlyphs.Role, _ key: String, _ id: String, primary: Bool = false, compact: Bool, action: @escaping () -> Void) -> some View {
        let input: ConsoleInput = switch role { case .back: .back; case .options: .options; case .menu: .menu; default: .activate }
        let glyph = glyphs.glyph(for: role, on: ConsoleButtons.button(for: input, swapAB: state.menuSwapAB))
        return Button(action: action) {
            HStack(alignment: .center, spacing: 10) { ConsoleGlyphView(glyph: glyph, size: compact ? 20 : 24); Text(t(key)).lineLimit(1).minimumScaleFactor(0.8) }
                .font(.manrope(compact ? 15 : 20, .semibold))
                .padding(.horizontal, compact ? 12 : (primary ? 20 : 8)).frame(maxWidth: compact ? .infinity : nil, minHeight: 48)
                .foregroundStyle(primary ? LauncherPalette.background : .white.opacity(0.8))
                .background(primary ? LauncherPalette.cream : (compact ? .white.opacity(0.07) : .clear), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).padTarget(id, scope: "console", radius: 28, activate: action)
    }

    @ViewBuilder private func sheetContent(_ sheet: ConsoleSheet, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(t(sheetTitle(sheet)))
                    .font(.manrope(compact ? 28 : 36, .bold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { driver.back() } label: { Image(systemName: "xmark").font(.system(size: 20)).frame(width: 48, height: 48).contentShape(Circle()) }
                    .buttonStyle(.plain).accessibilityLabel(t("console.close"))
                    .padTarget("console.sheet.close", scope: sheet.scope, radius: 24, activate: { driver.back() })
            }
            .padding(.horizontal, compact ? 24 : 40).padding(.top, 30).padding(.bottom, 20)
            switch sheet {
            case let .options(id):
                if let game = state.games.first(where: { $0.id == id }) { options(game, compact: compact) }
            case .controllers: controllers(compact: compact)
            case let .explanation(id):
                if let game = state.games.first(where: { $0.id == id }) { explanation(game, compact: compact) }
            case .homeButtonHint: homeButtonHint(compact: compact)
            case let .cloudSave(question):   // ConsoleCloudSaveView.swift (#957)
                ConsoleCloudSaveView(question: question, lang: lang, compact: compact, choose: { driver.chooseCloudSave($0) },
                                     retry: { driver.retryCloudSave() }, cancel: { driver.back() })
            case .menu: menu(compact: compact)
            case .library: library(compact: compact)
            case .settings: settings(compact: compact)
            case .language: language(compact: compact)
            case let .advanced(id):
                if let game = state.games.first(where: { $0.id == id }) { advanced(game, compact: compact) }
            case .mapping, .gamePad, .cloudSaves, .confirmExit, .confirmMapping, .confirmReset, .confirmUpdate: EmptyView()   // drawn over the whole screen (fullPage, question)
            }
        }
        .padScope(sheet.scope, pad)
    }

    private func options(_ game: ConsoleGame, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(game.title).font(.manrope(compact ? 19 : 24, .semibold)).foregroundStyle(LauncherPalette.cream)
                .padding(.horizontal, compact ? 24 : 40).padding(.bottom, 24)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                    ConsoleGameOptionsList(driver: driver, game: game, lang: lang, compact: compact, editing: $editingOption)
                        .padding(.horizontal, compact ? 24 : 40).padding(.vertical, 8)
                    }.consoleScrollContent()
                }
                .consoleScrollFade()
                .onChange(of: pad.focused) { id in if let id { withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) } } }
            }
            VStack(alignment: .leading, spacing: 18) {
                Text(t(adjustHint(game.basicSettings))).font(.manrope(compact ? 14 : 17)).foregroundStyle(LauncherPalette.secondaryText)
                primaryButton(t("console.play"), id: "console.options.play", scope: "console.options") { driver.play(game.id) }
            }
            .padding(compact ? 24 : 40)
        }
    }

    /// A game's advanced options, as the options page scrolls them.
    private func advanced(_ game: ConsoleGame, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(game.title).font(.manrope(compact ? 19 : 24, .semibold)).foregroundStyle(LauncherPalette.cream)
                .padding(.horizontal, compact ? 24 : 40).padding(.bottom, 24)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                    ConsoleAdvancedList(driver: driver, game: game, lang: lang, compact: compact, editing: $editingOption)
                        .padding(.horizontal, compact ? 24 : 40).padding(.vertical, 8)
                    }.consoleScrollContent()
                }
                .consoleScrollFade()
                .onChange(of: pad.focused) { id in if let id { withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) } } }
            }
            Text(t(adjustHint(game.advancedSettings))).font(.manrope(compact ? 14 : 17)).foregroundStyle(LauncherPalette.secondaryText).padding(compact ? 24 : 40)
        }
    }

    /// The hint under a list of options: the slider's two-step way only where there is a slider.
    private func adjustHint(_ settings: [LaunchSetting]) -> String {
        settings.contains { $0.kind == "range" } ? "console.adjustHintSlider" : "console.adjustHint"
    }

    /// The question on top: leaving console mode, saving the button mapping's changes, resetting a game's options, the app's update.
    @ViewBuilder private func question(compact: Bool) -> some View {
        if case let .confirmReset(id) = state.presentedSheet {
            ConsoleQuestion(compact: compact, symbol: "arrow.counterclockwise", title: t("console.reset.ask"), message: t("console.reset.askBody"),
                            scope: "console.confirmReset",
                            other: (t("console.exit.cancel"), "console.confirmReset.cancel", { driver.back() }),
                            main: (t("console.reset.confirm"), "console.confirmReset.reset", { driver.resetOptions(id) }))
                .padScope("console.confirmReset", pad)
        } else if state.presentedSheet == .confirmUpdate {
            let ready = state.prefs.update == .ready
            let tag: String = {
                switch state.prefs.update { case let .available(tag), let .failed(tag, _): return tag; default: return "" }
            }()
            ConsoleQuestion(compact: compact, symbol: "arrow.down.app", title: ready ? t("console.update.restartAsk") : String(format: t("console.update.ask"), tag),
                            message: t(ready ? "console.update.restartBody" : "console.update.askBody"), scope: "console.confirmUpdate",
                            other: (t("console.exit.cancel"), "console.confirmUpdate.cancel", { driver.back() }),
                            main: (t(ready ? "app.restartNow" : "console.update.install"), "console.confirmUpdate.go", { driver.confirmAppUpdate() }))
                .padScope("console.confirmUpdate", pad)
        } else if state.presentedSheet == .confirmMapping {
            ConsoleQuestion(compact: compact, symbol: "arrow.left.arrow.right", title: t("console.mapping.saveTitle"), message: t("console.mapping.saveBody"),
                            scope: "console.confirmMapping",
                            other: (t("console.mapping.discard"), "console.confirmMapping.discard", { driver.finishMapping(save: false) }),
                            main: (t("console.mapping.save"), "console.confirmMapping.save", { driver.finishMapping(save: true) }))
                .padScope("console.confirmMapping", pad)
        } else {
            ConsoleQuestion(compact: compact, symbol: "rectangle.portrait.and.arrow.right", title: t("console.exit.title"), message: t("console.exit.body"),
                            scope: "console.confirmExit",
                            other: (t("console.exit.cancel"), "console.confirmExit.cancel", { driver.back() }),
                            main: (t("console.exit.confirm"), "console.confirmExit.leave", { driver.exitToDesktop() }))
                .padScope("console.confirmExit", pad)
        }
    }

    /// The pages over the whole screen: the cloud saves, a game's controller settings, the button mapping.
    @ViewBuilder private func fullPage(_ sheet: ConsoleSheet, compact: Bool) -> some View {
        switch sheet {
        case .cloudSaves: ConsoleCloudSavesPage(rows: state.saveRows, lang: lang, compact: compact, close: { driver.back() })
        case let .gamePad(id):
            if let game = state.games.first(where: { $0.id == id }) {
                ConsoleGamePadPage(driver: driver, game: game, lang: lang, compact: compact, editing: $editingOption)
            }
        case .mapping: ConsolePadMappingSheet(driver: driver, lang: lang, compact: compact)
        default: EmptyView()
        }
    }

    /// The console's own menu, as the desktop's Settings groups things: Library (the library's switch, the cloud saves), Controllers
    /// (players, the button mapping, the ways into console mode), General (the language, the app's update), and the way back to the desktop.
    private func menu(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            menuRow("console.menu.library", symbol: "square.grid.2x2", title: t("console.menu.library"), note: t("console.menu.libraryNote"),
                    compact: compact) { driver.openLibrary() }
            menuRow("console.menu.controllers", symbol: "gamecontroller", title: t("console.controllers"), note: t("console.menu.controllersNote"),
                    compact: compact) { driver.openControllers() }
            menuRow("console.menu.settings", symbol: "gearshape", title: t("console.menu.settings"), note: t("console.menu.settingsNote"),
                    compact: compact) { driver.openSettings() }
            Spacer(minLength: 24)
            menuRow("console.menu.exit", symbol: "rectangle.portrait.and.arrow.right", title: t("console.menu.exit"), note: t("console.menu.exitNote"),
                    compact: compact) { driver.confirmExit() }
        }
        .padding(.horizontal, compact ? 24 : 40).padding(.bottom, compact ? 24 : 40)
    }

    private func menuRow(_ id: String, scope: String = "console.menu", symbol: String, title: String, note: String, value: String? = nil, compact: Bool,
                         action: @escaping () -> Void) -> some View {
        ConsoleMenuRow(id: id, scope: scope, symbol: symbol, title: title, note: note, value: value, compact: compact, action: action)
    }

    /// "Follow the system" by its name in the launcher's language, every other language by its own name (as Settings lists them).
    private func languageName(_ code: String) -> String { code.isEmpty ? t("settings.language.system") : (Lang.find(code)?.name ?? code) }

    /// The Library page (ConsoleLibraryList): the library's switch and the cloud saves.
    private func library(compact: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                ConsoleLibraryList(driver: driver, lang: lang, compact: compact)
                    .padding(.horizontal, compact ? 24 : 40).padding(.bottom, compact ? 24 : 40)
                }.consoleScrollContent()
            }
            .consoleScrollFade()
            .onChange(of: pad.focused) { id in if let id { withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) } } }
        }
    }

    /// The General page (ConsoleSettingsList): the language, the app's update and the launcher after a game.
    private func settings(compact: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                ConsoleSettingsList(driver: driver, lang: lang, compact: compact, languageName: languageName(languageCode))
                    .padding(.horizontal, compact ? 24 : 40).padding(.bottom, compact ? 24 : 40)
                }.consoleScrollContent()
            }
            .consoleScrollFade()
            .onChange(of: pad.focused) { id in if let id { withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) } } }
        }
    }

    /// The display language as a list, the one in use checked. A picks it, the console redraws in it at once.
    private func language(compact: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("console.language.note")).font(.manrope(compact ? 15 : 18)).foregroundStyle(LauncherPalette.secondaryText)
                        .padding(.leading, 4).padding(.bottom, 6)
                    ForEach(AppCard.languageCodes, id: \.self) { code in
                        let chosen = code == languageCode
                        let pick = { languageCode = code; chooseLanguage?(code) }
                        let id = "console.language." + (code.isEmpty ? "system" : code)
                        Button(action: pick) {
                            HStack(spacing: 14) {
                                Text(languageName(code)).font(.manrope(compact ? 18 : 21, chosen ? .bold : .medium))
                                Spacer(minLength: 8)
                                if chosen { Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(LauncherPalette.cream) }
                            }
                            .padding(.horizontal, 20).frame(maxWidth: .infinity, minHeight: compact ? 56 : 62)
                            .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14)).contentShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .padTarget(id, scope: "console.language", radius: 14, activate: pick)
                        .accessibilityLabel(languageName(code)).accessibilityAddTraits(chosen ? .isSelected : [])
                        .id(id)
                    }
                }
                .padding(.horizontal, compact ? 24 : 40).padding(.bottom, compact ? 24 : 40)
                }.consoleScrollContent()
            }
            .consoleScrollFade()
            .onChange(of: pad.focused) { id in
                guard let id, id.hasPrefix("console.language.") else { return }
                withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func controllers(compact: Bool) -> some View {
        ConsoleControllerList(driver: driver, lang: lang, compact: compact)
    }

    private func explanation(_ game: ConsoleGame, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(game.title).font(.manrope(compact ? 27 : 38, .bold))
            Text(t(game.status.explanationKey ?? "console.ready")).font(.manrope(compact ? 20 : 26)).foregroundStyle(LauncherPalette.secondaryText)
            if case let .broken(message) = game.status { Text(message).font(.manrope(compact ? 17 : 21)).foregroundStyle(LauncherPalette.secondaryText) }
            Spacer(minLength: 24)
            // the build, the files or the folder are the desktop's: it opens with this game selected
            primaryButton(t("console.openOnDesktop"), id: "console.explanation.desktop", scope: "console.explanation") { driver.openOnDesktop(game.id) }
        }
        .padding(compact ? 24 : 40)
    }

    /// Shown once, after a game quit, when that game reported that the system keeps the Home button for itself (#336): what the
    /// button does in a game, why it does not now, and the way to the setting. A opens Settings, B or "Not now" closes it.
    private func homeButtonHint(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "house.circle").font(.system(size: compact ? 44 : 60, weight: .light))
                .foregroundStyle(LauncherPalette.cream).accessibilityHidden(true)
            Text(t("console.homeHint.body")).font(.manrope(compact ? 20 : 26)).fixedSize(horizontal: false, vertical: true)
            Text(t("console.homeHint.how")).font(.manrope(compact ? 17 : 21)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 24)
            // Both buttons take the sheet's full width, so their width never follows the label or the language (ConsoleButtonWidths)
            VStack(spacing: 14) {
                primaryButton(t("console.homeHint.open"), id: "console.homeHint.open", scope: "console.homeHint") { driver.openHomeButtonSettings() }
                    .background(ConsoleButtonWidths.reader("console.homeHint.open"))
                Button { driver.back() } label: {
                    Text(t("console.homeHint.later")).font(.manrope(21, .semibold)).foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8).padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, minHeight: 60).background(.white.opacity(0.08), in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.plain).padTarget("console.homeHint.later", scope: "console.homeHint", radius: 30, activate: { driver.back() })
                .background(ConsoleButtonWidths.reader("console.homeHint.later"))
            }
        }
        .padding(compact ? 24 : 40)
    }

    private func empty(compact: Bool) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "rectangle.stack").font(.system(size: compact ? 44 : 64, weight: .light)).foregroundStyle(LauncherPalette.cream.opacity(0.65)).accessibilityHidden(true)
            Text(t("console.empty")).font(.manrope(compact ? 34 : 54, .bold)).accessibilityAddTraits(.isHeader)
            Text(t("console.emptyNote")).font(.manrope(compact ? 20 : 26)).foregroundStyle(LauncherPalette.secondaryText)
            primaryButton(t("console.desktop"), id: "console.empty.desktop", scope: "console") { driver.exitToDesktop() }.frame(maxWidth: 340)
        }
        .multilineTextAlignment(.center).padding(24)
    }

    private func starting(_ game: ConsoleGame, compact: Bool) -> some View {
        VStack(spacing: 30) {
            // The only image is the blurred cover behind (backdrop). The text and the bar sit in the middle of the screen.
            Text(String(format: t("console.starting"), game.title)).font(.manrope(compact ? 30 : 48, .bold))
                .multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
            VStack(spacing: 16) {
                Text(startingLabel).font(.manrope(compact ? 17 : 22, .medium)).foregroundStyle(LauncherPalette.cream)
                if let progress = state.starting.progress {
                    LauncherProgressBar(value: progress, height: 8, tint: LauncherPalette.cream)
                        .transaction { if reduceMotion { $0.disablesAnimations = true } }
                        .accessibilityLabel(t("console.shaders"))
                        .accessibilityValue(String(format: t("console.batteryPercent"), Int(progress * 100)))
                }
                if state.isPreview { Text(t("console.simulatedShaders")).font(.manrope(compact ? 13 : 16)).foregroundStyle(LauncherPalette.secondaryText) }
                if case let .cloudSave(long) = state.starting {   // the cloud's save on its way (#957): B cancels, A plays without it once it takes long
                    if long { Text(t("cloudCheck.fetching.long")).font(.manrope(compact ? 15 : 19)).foregroundStyle(LauncherPalette.secondaryText).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
                    HStack(spacing: 24) {
                        if long { hint(.activate, "cloudCheck.playLocal", "console.cloudSave.offline", primary: true, compact: compact) { driver.chooseCloudSave(.offline) } }
                        hint(.back, "cloudCheck.cancel", "console.cloudSave.cancel", compact: compact) { driver.back() }
                    }.padding(.top, 8)
                }
            }.frame(maxWidth: compact ? 320 : 540)
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var startingLabel: String {
        switch state.starting {
        case .preparing: return t("console.startingNote")
        case let .compilingShaders(completed, total): return String(format: t("console.shadersProgress"), completed, total)
        case .opening: return t("console.openingGame")
        case .cloudSave: return t("cloudCheck.fetching.title")
        }
    }

    private func exitPreview(compact: Bool) -> some View {
        VStack(spacing: 24) {
            Text(t("console.desktopPreview")).font(.manrope(compact ? 30 : 48, .bold))
            Text(t("console.desktopPreviewNote")).font(.manrope(compact ? 18 : 24)).foregroundStyle(LauncherPalette.secondaryText)
            primaryButton(t("console.return"), id: "console.return", scope: "console") { driver.returnFromGame() }.frame(maxWidth: 360)
        }
        .multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .padScope("console", pad)
    }

    private func primaryButton(_ label: String, id: String, scope: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.manrope(21, .bold)).foregroundStyle(LauncherPalette.background)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8).padding(.horizontal, 20)   // a long label wraps or shrinks, the button keeps its width
                .frame(maxWidth: .infinity, minHeight: 60).background(LauncherPalette.cream, in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(.plain).padTarget(id, scope: scope, radius: 30, activate: action)   // half the 60 pt height: a capsule ring
    }
    private func sheetTitle(_ sheet: ConsoleSheet) -> String {
        switch sheet {
        case .controllers: return "console.controllers"
        case .options: return "console.options"
        case .explanation: return "console.explanationTitle"
        case .homeButtonHint: return "console.homeHint.title"
        case let .cloudSave(question): return question.outcome == .unreadable ? "cloudCheck.unreadable.title" : "cloudCheck.differ.title"
        case .menu: return "console.menu"
        case .mapping: return state.mappingGameID == nil ? "console.mapping" : "console.mapping.game"
        case .gamePad: return "console.gamePad"
        case .library: return "console.menu.library"
        case .settings: return "console.menu.settings"
        case .language: return "console.language.title"
        case .cloudSaves: return "console.saves.title"
        case .confirmExit: return "console.exit.title"
        case .confirmMapping: return "console.mapping.saveTitle"
        case .advanced: return "launch.advanced"
        case .confirmReset: return "console.reset.ask"
        case .confirmUpdate: return "console.update.title"
        }
    }
    private func resetFocus() {
        // A sheet opening keeps the focus it covers, a sheet closing gives it back, read before the new scope clears it.
        let depth = state.sheets.count
        var restored: String?
        if depth > sheetDepth { returnFocus.append(pad.focused) }
        while returnFocus.count > depth { restored = returnFocus.removeLast() }
        sheetDepth = depth
        pad.scope = scope
        pad.show(default: nil)
        if let restored, !state.exited { pad.focused = restored; return }   // a target gone by now falls back at the next press (PadFocus.show)
        switch state.presentedSheet {
        case let .options(id):
            let game = state.games.first { $0.id == id }
            pad.focused = game.map(ConsoleGameOptionsList<Driver>.firstTarget) ?? "console.options.play"
        case let .gamePad(id): pad.focused = state.games.first { $0.id == id }.map(ConsoleGamePadPage<Driver>.firstTarget) ?? "console.gamePad.close"
        case .controllers: pad.focused = "console.player.\(state.assigningPlayer ?? 1)"
        case .explanation: pad.focused = "console.explanation.desktop"
        case .homeButtonHint: pad.focused = "console.homeHint.open"
        case let .cloudSave(question): pad.focused = ConsoleCloudSaveView.firstFocus(question)
        case .menu: pad.focused = "console.menu.library"
        case .cloudSaves: pad.focused = ConsoleCloudSaves.sorted(state.saveRows).first.map { "console.saves.row." + $0.id } ?? "console.saves.close"   // the first row as the page sorts them
        case .library: pad.focused = ConsolePref.onLibrary.first.map { "console.pref." + $0.rawValue } ?? "console.library.saves"
        case .settings: pad.focused = "console.settings.language"
        case .language: pad.focused = "console.language." + (languageCode.isEmpty ? "system" : languageCode)
        case .confirmExit: pad.focused = "console.confirmExit.cancel"   // the safe choice: A by habit stays in console mode
        case .confirmMapping: pad.focused = "console.confirmMapping.save"
        case let .advanced(id): pad.focused = state.games.first { $0.id == id }?.advancedSettings.first.map { "console.option." + $0.env } ?? "console.sheet.close"
        case .confirmReset: pad.focused = "console.confirmReset.cancel"   // the safe choice, as leaving
        case .confirmUpdate: pad.focused = "console.confirmUpdate.cancel"   // the safe choice, as leaving
        case .mapping: pad.focused = state.mappingGameID == nil ? "console.map.menuSwap" : "console.map.swap"
        case nil: pad.focused = state.exited ? "console.return" : state.focusedGame.map { "console.game." + $0.id } ?? "console.empty.desktop"
        }
    }
    private func handle(_ input: ConsoleInput) {
        if editingOption != nil, input == .back || input == .activate { editingOption = nil; return }   // A or B lets a slider go
        if input == .back { driver.back(); return }
        if state.exited { if input == .activate { driver.returnFromGame() }; return }
        if case let .cloudSave(long) = state.starting, state.startingGameID != nil {   // the download's wait (#957): A plays without it once it takes long
            if input == .activate && long { driver.chooseCloudSave(.offline) }
            return
        }
        guard state.startingGameID == nil else { return }
        pad.show(default: pad.focused)
        switch input {
        case .left, .right:
            let step = input == .left ? -1 : 1
            if state.presentedSheet == nil, pad.focused?.hasPrefix("console.game.") == true {
                var snapshot = state; snapshot.moveFocus(step)
                if let id = snapshot.focusedGame?.id { driver.focus(id); pad.focused = "console.game." + id }
            } else { pad.horizontal(step) }
        case .up: pad.move(dx: 0, dy: -1)
        case .down: pad.move(dx: 0, dy: 1)
        case .activate: pad.activate()
        case .options:
            if case .options = state.presentedSheet { driver.back() }
            else if state.presentedSheet == nil, let id = state.focusedGame?.id { driver.openOptions(id) }
        case .menu: if state.presentedSheet == .menu { driver.back() } else if state.presentedSheet == nil { driver.openMenu() }
        case .back: break
        }
    }
}

/// Reusable 1.8:1 presentation; nil artwork uses the same quiet surface as the desktop library.
/// A cover drawn from the title alone, in the launcher's palette: a dark gradient tinted by one of its accents, and the name.
/// Nothing is loaded or bundled. The same title always gets the same colors.
enum ConsolePlaceholder {
    static func colors(for title: String) -> [Color] {
        let accents = [LauncherPalette.cream, LauncherPalette.ready, LauncherPalette.building, LauncherPalette.unbuilt]
        let seed = title.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        let accent = accents[abs(seed) % accents.count]
        return [accent.opacity(0.42), LauncherPalette.surface, LauncherPalette.background]
    }
}

struct ConsoleArtwork: View {
    let image: NSImage?
    var title = ""
    var focus = UnitPoint.center
    var body: some View {
        GeometryReader { geometry in
            if let image { ArtworkFill(image: image, focus: focus).frame(width: geometry.size.width, height: geometry.size.height) }
            else {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: ConsolePlaceholder.colors(for: title), startPoint: .topLeading, endPoint: .bottomTrailing)
                    if title.isEmpty { Image(systemName: "gamecontroller").font(.system(size: 50)).foregroundStyle(LauncherPalette.secondaryText) }
                    else {
                        Text(title).font(.manrope(max(14, geometry.size.width / 11), .bold)).foregroundStyle(LauncherPalette.cream.opacity(0.9))
                            .lineLimit(3).minimumScaleFactor(0.6).padding(geometry.size.width / 18)
                    }
                }
            }
        }
    }
}

/// The width each button of the Home button hint was drawn at, by its pad id: ConsoleTests checks that it is the same in every language.
struct ConsoleButtonWidths: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { _, new in new } }
    static func reader(_ id: String) -> some View { GeometryReader { g in Color.clear.preference(key: ConsoleButtonWidths.self, value: [id: g.size.width]) } }
}

private struct ConsoleTileFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}

struct ConsoleGameTile: View {
    let game: ConsoleGame
    let selected: Bool
    let compact: Bool
    let lang: Lang
    var captionVisible = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConsoleArtwork(image: game.artwork, title: game.title, focus: game.artworkFocus).aspectRatio(1.8, contentMode: .fit)
                .opacity(game.status == .ready ? 1 : 0.45)   // not playable on this Mac: dimmed, its status on top
                .overlay(alignment: .bottomLeading) {
                    if game.status != .ready {
                        Text(L10n.string(game.status.labelKey, lang)).font(.manrope(compact ? 14 : 18, .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(LauncherPalette.background.opacity(0.93), in: Capsule()).padding(14)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            // The focused game's name is the big title above, so its tile shows the image alone (the row is top-aligned, so
            // nothing else moves). The others keep a small, muted caption.
            if !selected {
                Text(game.title).opacity(captionVisible ? 1 : 0).font(.manrope(compact ? 14 : 17, .medium)).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 4).accessibilityHidden(true)
            }
        }
    }
}
