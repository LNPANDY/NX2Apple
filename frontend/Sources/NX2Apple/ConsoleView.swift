import SwiftUI
import Combine
import NXCore
import NXLauncher

/// Semantic inputs from a future controller adapter; the view does not discover hardware.
enum ConsoleInput: Equatable {
    case left, right, up, down, activate, back, options, menu
    /// #816: X plays the focused game at once, L and R switch a page's tabs or filters, − (View) opens the quick menu. The search's
    /// keyboard takes typed text and Delete from the Mac's keyboard.
    case play, previousTab, nextTab, quickMenu
    case typed(String), deleteBackward

    /// The launcher's controller path (Gamepad.swift) in console terms: the D-pad and left stick move, A activates, B backs out,
    /// Y opens the focused game's options, X plays it, L and R switch tabs, the menu button (+, Menu, Options) opens the console's
    /// menu and the Select-type button (−, View, Share, Create) the quick menu. The same button again closes what it opened.
    init?(_ action: LauncherGamepad.Action) {
        switch action {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .up
        case .down: self = .down
        case .a: self = .activate
        case .b: self = .back
        case .y: self = .options
        case .x: self = .play
        case .l: self = .previousTab
        case .r: self = .nextTab
        case .plus: self = .menu
        case .select: self = .quickMenu
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
                    ConsoleHomeScreen(driver: driver, lang: lang, glyphs: glyphs, size: geometry.size, compact: compact)
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
                        ConsoleQuestionLayer(driver: driver, lang: lang, compact: compact)
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
        .consoleDarkAppearance()   // the console stays dark in Light: every token resolves to its Dark value here
        .environmentObject(pad)
        .environment(\.padRingStyle, .hug)
        .background(ConsoleKeyboardInput(perform: { input in glyphs = .keyboard; handle(input) },
                                         typing: { [driver] in driver.state.presentedSheet == .search }).frame(width: 0, height: 0))
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
            case .quickMenu: ConsoleQuickMenu(driver: driver, lang: lang, compact: compact)
            case let .manage(id):
                if let game = state.games.first(where: { $0.id == id }) { ConsoleManagePanel(driver: driver, game: game, lang: lang, compact: compact) }
            case .mapping, .gamePad, .cloudSaves, .confirmExit, .confirmMapping, .confirmReset, .confirmUpdate,
                 .gamePage, .allGames, .search, .builds, .stopped, .confirmStopBuild, .confirmQuitPaused: EmptyView()   // drawn over the whole screen (fullPage, question)
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

    /// The pages over the whole screen: the cloud saves, a game's controller settings, the button mapping.
    @ViewBuilder private func fullPage(_ sheet: ConsoleSheet, compact: Bool) -> some View {
        switch sheet {
        case .cloudSaves: ConsoleCloudSavesPage(rows: state.saveRows, lang: lang, compact: compact, close: { driver.back() })
        case let .gamePad(id):
            if let game = state.games.first(where: { $0.id == id }) {
                ConsoleGamePadPage(driver: driver, game: game, lang: lang, compact: compact, editing: $editingOption)
            }
        case .mapping: ConsolePadMappingSheet(driver: driver, lang: lang, compact: compact)
        case let .gamePage(id):
            if let game = state.games.first(where: { $0.id == id }) {
                ConsoleGamePage(driver: driver, game: game, lang: lang, glyphs: glyphs, compact: compact, editing: $editingOption)
            }
        case .allGames: ConsoleAllGamesPage(driver: driver, lang: lang, glyphs: glyphs, compact: compact)
        case .search: ConsoleSearchPage(driver: driver, lang: lang, glyphs: glyphs, compact: compact)
        case .builds: ConsoleBuildsPage(driver: driver, lang: lang, compact: compact)
        default: EmptyView()
        }
    }

    /// The console's own menu, as the desktop's Settings groups things: Library (the library's switch, the cloud saves), Controllers
    /// (players, the button mapping, the ways into console mode), General (the language, the app's update), and the way back to the desktop.
    private func menu(compact: Bool) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            // #816: all games with their filters, the search and the builds, before the pages the menu had
            menuRow("console.menu.allGames", symbol: "square.grid.3x2", title: t("console.allGames"), note: t("console.menu.allGamesNote"),
                    compact: compact) { driver.openAllGames() }
            menuRow("console.menu.search", symbol: "magnifyingglass", title: t("console.search"), note: t("console.menu.searchNote"),
                    compact: compact) { driver.openSearch() }
            menuRow("console.menu.builds", symbol: "shippingbox", title: t("console.builds"), note: t("console.menu.buildsNote"),
                    value: state.builds.running ? t("console.builds.running") : nil, compact: compact) { driver.openBuilds() }
            menuRow("console.menu.library", symbol: "square.grid.2x2", title: t("console.menu.library"), note: t("console.menu.libraryNote"),
                    compact: compact) { driver.openLibrary() }
            menuRow("console.menu.controllers", symbol: "gamecontroller", title: t("console.controllers"), note: t("console.menu.controllersNote"),
                    compact: compact) { driver.openControllers() }
            menuRow("console.menu.settings", symbol: "gearshape", title: t("console.menu.settings"), note: t("console.menu.settingsNote"),
                    compact: compact) { driver.openSettings() }
            Spacer(minLength: 12)
            menuRow("console.menu.exit", symbol: "rectangle.portrait.and.arrow.right", title: t("console.menu.exit"), note: t("console.menu.exitNote"),
                    compact: compact) { driver.confirmExit() }
        }
        .padding(.horizontal, compact ? 24 : 40).padding(.bottom, compact ? 24 : 40)
        .consoleScrollContent()
        }
        .consoleScrollFade()
        .onChange(of: pad.focused) { id in
            guard let id, id.hasPrefix("console.menu.") else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) }
        }
        }
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
                        if long {
                            ConsoleHint(glyph: glyphs.hintGlyph(.activate, swapAB: state.menuSwapAB), label: t("cloudCheck.playLocal"), id: "console.cloudSave.offline",
                                        primary: true, compact: compact) { driver.chooseCloudSave(.offline) }
                        }
                        ConsoleHint(glyph: glyphs.hintGlyph(.back, swapAB: state.menuSwapAB), label: t("cloudCheck.cancel"), id: "console.cloudSave.cancel",
                                    compact: compact) { driver.back() }
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
        ConsolePrimaryButton(label: label, id: id, scope: scope, action: action)
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
        case .quickMenu: return "console.quickMenu"
        case .manage: return "console.manage"
        case .gamePage, .allGames, .search, .builds, .stopped, .confirmStopBuild, .confirmQuitPaused: return "console.menu"   // their own headers
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
        case .menu: pad.focused = "console.menu.allGames"
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
        case let .gamePage(id): pad.focused = ConsoleGamePage<Driver>.firstTarget(state.games.first { $0.id == id }, paused: id == state.pausedGameID)
        case .allGames: pad.focused = state.libraryGames.first.map { "console.lib." + $0.id } ?? "console.allGames.close"
        case .search: pad.focused = "console.key.a"
        case .builds: pad.focused = state.builds.running ? "console.builds.stop" : "console.builds.close"
        case .quickMenu: pad.focused = ConsoleQuickMenu<Driver>.firstTarget(state)
        case .manage: pad.focused = "console.manage.desktop"
        case .stopped: pad.focused = "console.stopped.again"   // the main answer: nothing is lost by playing again
        case .confirmStopBuild: pad.focused = "console.confirmStop.cancel"   // the safe choice, as leaving
        case .confirmQuitPaused: pad.focused = "console.confirmQuitPaused.cancel"   // the safe choice: the paused game keeps its progress
        case nil: pad.focused = state.exited ? "console.return" : state.focusedGame.map { "console.game." + $0.id } ?? "console.empty.desktop"
        }
    }
    private func handle(_ input: ConsoleInput) {
        if editingOption != nil, input == .back || input == .activate { editingOption = nil; return }   // A or B lets a slider go
        if state.presentedSheet == .search {   // the Mac's keyboard types into the search (#816)
            if case let .typed(text) = input { driver.typeSearch(text); return }
            if input == .deleteBackward { driver.deleteSearch(); return }
        }
        if input == .back { driver.back(); return }
        if state.exited { if input == .activate { driver.returnFromGame() }; return }
        if case let .cloudSave(long) = state.starting, state.startingGameID != nil {   // the download's wait (#957): A plays without it once it takes long
            if input == .activate && long { driver.chooseCloudSave(.offline) }
            return
        }
        guard state.startingGameID == nil else { return }
        pad.show(default: pad.focused)
        let home = state.presentedSheet == nil
        let onTile = home && pad.focused?.hasPrefix("console.game.") == true
        switch input {
        case .left, .right:
            // on the home screen left and right stay in the focused game's row (ConsoleHome.move), elsewhere the nearest target
            let step = input == .left ? -1 : 1
            if onTile, let id = state.focusedGame?.id, let next = ConsoleHome.move(from: id, dx: step, dy: 0, in: state.homeSections) {
                driver.focus(next); pad.focused = "console.game." + next
            } else { pad.horizontal(step) }
        case .up, .down:
            // from row to row at the same place, up from the first row to the top bar's Search, and back down to the focused game
            let dy = input == .up ? -1 : 1
            if onTile, let id = state.focusedGame?.id {
                if let next = ConsoleHome.move(from: id, dx: 0, dy: dy, in: state.homeSections) { driver.focus(next); pad.focused = "console.game." + next }
                else if dy < 0 { pad.focused = "console.searchButton" }
                else { pad.move(dx: 0, dy: 1) }
            } else if home, let focused = pad.focused, let id = state.focusedGame?.id,
                      dy > 0 ? ConsoleHomeScreen<Driver>.isTopBar(focused) : ConsoleHomeScreen<Driver>.hintIDs.contains(focused) {
                pad.focused = "console.game." + id
            } else { pad.move(dx: 0, dy: CGFloat(dy)) }
        case .activate: pad.activate()
        case .play: if let id = playTarget { driver.play(id) }
        case .previousTab, .nextTab:
            let step = input == .previousTab ? -1 : 1
            if case .gamePage = state.presentedSheet { driver.stepGameTab(step) }
            else if state.presentedSheet == .allGames { driver.stepLibraryFilter(step) }
        case .options:
            if case .options = state.presentedSheet { driver.back() }
            else if home, let id = state.focusedGame?.id { driver.openOptions(id) }
            else if case let .gamePage(id) = state.presentedSheet { driver.openOptions(id) }
            else if state.presentedSheet == .allGames { driver.toggleLibrarySort() }
            else if state.presentedSheet == .search { driver.deleteSearch() }
        case .menu: if state.presentedSheet == .menu { driver.back() } else if home { driver.openMenu() }
        case .quickMenu: if state.presentedSheet == .quickMenu { driver.back() } else if home { driver.openQuickMenu() }
        case .back, .typed, .deleteBackward: break
        }
    }

    /// The game X plays: the focused one on the home screen, the focused tile of all games or of the search, the page's game.
    private var playTarget: String? {
        switch state.presentedSheet {
        case nil: return state.focusedGame?.id
        case let .gamePage(id)?: return id
        case .allGames?, .search?:
            guard let focused = pad.focused else { return nil }
            for prefix in ["console.lib.", "console.result."] where focused.hasPrefix(prefix) { return String(focused.dropFirst(prefix.count)) }
            return nil
        default: return nil
        }
    }
}

