import SwiftUI
import Combine

/// Semantic inputs from a future controller adapter; the view does not discover hardware.
enum ConsoleInput {
    case left, right, up, down, activate, back, options, controllers

    /// The launcher's controller path (Gamepad.swift) in console terms: the D-pad and left stick move, A activates, B backs out,
    /// + and X open game options, Y opens Controllers. L and R are not used.
    init?(_ action: LauncherGamepad.Action) {
        switch action {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .up
        case .down: self = .down
        case .a: self = .activate
        case .b: self = .back
        case .plus, .x: self = .options
        case .y: self = .controllers
        case .l, .r, .select: return nil   // Select does nothing in console mode (B goes back)
        }
    }
}

@MainActor struct ConsoleView<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    var lang: Lang = .initial()
    var inputs: AnyPublisher<ConsoleInput, Never> = Empty().eraseToAnyPublisher()
    /// Set by the real launcher: leaving the mode calls it instead of showing the preview's "Back on desktop" screen.
    var onExit: (() -> Void)?
    @StateObject private var pad = PadFocus()
    @StateObject private var gamepad: LauncherGamepad
    @State private var tileFrames: [String: CGRect] = [:]
    /// The glyph set follows the input used last: a controller's own buttons, or key caps after the keyboard.
    @State private var glyphs: ConsoleGlyphs

    /// `gamepad` is the one the root view owns (the controller has a single handler, so two would fight); without one the view makes its own.
    init(driver: Driver, lang: Lang = .initial(), inputs: AnyPublisher<ConsoleInput, Never> = Empty().eraseToAnyPublisher(), gamepad: LauncherGamepad? = nil, glyphs: ConsoleGlyphs? = nil, onExit: (() -> Void)? = nil) {
        self.onExit = onExit
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
                    if let sheet = state.presentedSheet {
                        Color.black.opacity(0.5).ignoresSafeArea().accessibilityHidden(true)
                        sheetContent(sheet, compact: compact)
                            .frame(width: compact ? geometry.size.width : min(700, max(520, geometry.size.width * 0.46)))
                            .frame(maxHeight: .infinity)
                            .background(LauncherPalette.background)
                            .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.10)).frame(width: 1) }
                            .transition(.opacity)
                    }
                }
            }
            .overlay(alignment: .top) {
                if let toast = state.toast { ConsoleToastView(toast: toast).id(toast.id).transition(.opacity) }
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
        .onChange(of: scope) { _ in resetFocus() }
        .onChange(of: state.exited) { exited in if exited, let onExit { onExit() } else { resetFocus() } }
        .onAppear { gamepad.capture = { [driver] id, action in driver.consumePress(controllerID: id, isBack: action == .b) }
            gamepad.perform = { [self] action in if let input = ConsoleInput(action) { glyphs = .current(); handle(input) } }; resetFocus() }
        .onDisappear { gamepad.perform = { _ in }; gamepad.capture = nil }
        .onChange(of: pad.focused) { id in
            if let id, id.hasPrefix("console.game.") { driver.focus(String(id.dropFirst("console.game.".count))) }
        }
        .animation(.easeOut(duration: 0.18), value: state.presentedSheet)
        .animation(.easeOut(duration: 0.18), value: state.toast?.id)
        .animation(.easeOut(duration: 0.22), value: state.startingGameID)
    }

    private func backdrop(size: CGSize) -> some View {
        let starting = state.startingGame != nil   // the cover fills the window, soft and darkened (a static blur: Reduce Motion changes nothing here)
        return ZStack {
            LauncherPalette.background
            if let game = state.startingGame ?? state.focusedGame {
                Group {
                    if let image = game.artwork { image.resizable().scaledToFill() }
                    else { LinearGradient(colors: ConsolePlaceholder.colors(for: game.title), startPoint: .topLeading, endPoint: .bottomTrailing) }
                }
                .frame(width: size.width, height: size.height)
                .blur(radius: starting ? 36 : 70).drawingGroup().opacity(starting ? 1 : 0.30).id(game.id).transition(.opacity)
            }
            if starting { Color.black.opacity(0.32) }   // a scrim keeps the Starting text readable on any cover
            if !starting { LinearGradient(colors: [.black.opacity(0.10), LauncherPalette.background.opacity(0.95)], startPoint: .top, endPoint: .bottom) }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.01 : 0.38), value: (state.startingGame ?? state.focusedGame)?.id)   // the art cross-fades, slowly and softly
        .clipped().ignoresSafeArea().accessibilityHidden(true)
    }

    private func home(size: CGSize, compact: Bool) -> some View {
        let inset: CGFloat = compact ? 24 : 64
        return VStack(alignment: .leading, spacing: 0) {
            topBar(compact: compact).padding(.horizontal, inset).padding(.top, compact ? 24 : 40)
            if state.games.isEmpty {
                empty(compact: compact).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: compact || size.height < 900 ? 24 : 32) {
                        if let game = state.focusedGame {
                            // A fixed-height slot: the old and the new title overlap and cross-fade in place (0.15 s), so nothing slides
                            // and the row below never moves, whatever the title's length.
                            ZStack(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: compact ? 14 : 20) {
                                Text(t("console.library")).font(.manrope(compact ? 14 : 18, .semibold))
                                    .tracking(2).foregroundStyle(LauncherPalette.cream.opacity(0.75))
                                Text(game.title).font(.manrope(compact ? 36 : min(64, size.width / 24), .bold))
                                    .tracking(-1.6).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityAddTraits(.isHeader)
                                HStack(spacing: 12) {
                                    if !game.version.isEmpty { Text(String(format: t("console.version"), game.version)).monospacedDigit().lineLimit(1)
                                        .foregroundStyle(.white.opacity(0.6)).frame(width: compact ? 116 : 150, alignment: .leading) }   // fixed, so the badges stay put
                                    ForEach(game.platforms, id: \.self) { platform in
                                        Text(t(platform.labelKey)).font(.manrope(compact ? 13 : 17, .semibold))
                                            .padding(.horizontal, 12).padding(.vertical, 5)
                                            .background(.white.opacity(0.08), in: Capsule())
                                    }
                                }
                                .font(.manrope(compact ? 14 : 18))
                            }
                            .id(game.id).transition(.opacity)
                            }
                            .animation(.easeInOut(duration: 0.12), value: game.id)
                            .padding(.horizontal, inset)
                            .frame(height: compact ? 175 : 100 + 2.4 * min(64, size.width / 24), alignment: .bottomLeading)
                        }
                        gameRow(size: size, compact: compact, inset: inset)
                    }
                    .padding(.top, compact ? 44 : size.height < 900 ? 24 : max(36, size.height * 0.065))
                    .padding(.bottom, 24)
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
            ConsoleControllerChips(controllers: state.controllers, merged: state.padMerge, lang: lang, compact: compact) { driver.openControllers() }
            Text(state.time, style: .time).font(.manrope(compact ? 17 : 22, .medium)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.65)).fixedSize()
        }
        .frame(height: compact ? 40 : 52)
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
                HStack(alignment: .top, spacing: compact ? 22 : 28) {
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
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 12)   // room for the focused tile's small scale inside the clip
            }
            .coordinateSpace(name: "console.row")
            .onPreferenceChange(ConsoleTileFramesKey.self) { tileFrames = $0 }
            .padding(.horizontal, inset - 8)   // the scroll area is the page margin, so tiles clip there and the title lines up with the first tile
            .onChange(of: state.focusedGame?.id) { id in
                // The ring moves across the visible tiles. The row scrolls only when the focused tile would leave the visible area, by
                // the least that brings it inside, and a new focus replaces the running scroll (held repeats do not queue).
                guard let id else { return }
                let tile = "console.game." + id
                guard let frame = tileFrames[id] else { proxy.scrollTo(tile, anchor: .center); return }
                let rowWidth = size.width - 2 * (inset - 8)
                let anchor: UnitPoint? = frame.minX < 8 ? .leading : (frame.maxX > rowWidth - 8 ? .trailing : nil)
                if let anchor { withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.2)) { proxy.scrollTo(tile, anchor: anchor) } }
            }
            .onAppear { if let id = state.focusedGame?.id { proxy.scrollTo("console.game." + id, anchor: .center) } }
        }
    }

    private func hintBar(compact: Bool, width: CGFloat) -> some View {
        let items = {
            Group {
                hint(.activate, "console.play", "console.play", primary: true, compact: compact) { if let id = state.focusedGame?.id { driver.play(id) } }
                hint(.options, "console.options", "console.options", compact: compact) { if let id = state.focusedGame?.id { driver.openOptions(id) } }
                hint(.controllers, "console.controllers", "console.controllers", compact: compact) { driver.openControllers() }
                hint(.back, "console.desktop", "console.desktop", compact: compact) { driver.exitToDesktop() }
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

    private func hint(_ role: ConsoleGlyphs.Role, _ key: String, _ id: String, primary: Bool = false, compact: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) { ConsoleGlyphView(glyph: glyphs.glyph(for: role), size: compact ? 20 : 24); Text(t(key)).lineLimit(1).minimumScaleFactor(0.8) }
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
                    VStack(spacing: 12) {
                        if game.visibleSettings.isEmpty { Text(t("console.noOptions")).foregroundStyle(.secondary) }
                        ForEach(game.visibleSettings) { setting in
                            optionRow(setting, game: game, compact: compact)
                        }
                    }
                    .padding(.horizontal, compact ? 24 : 40).padding(.vertical, 8)
                }
                .onChange(of: pad.focused) { id in if let id { withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) } } }
            }
            VStack(alignment: .leading, spacing: 18) {
                Text(t("console.adjustHint")).font(.manrope(compact ? 14 : 17)).foregroundStyle(.secondary)
                primaryButton(t("console.play"), id: "console.options.play", scope: "console.options") { driver.play(game.id) }
            }
            .padding(compact ? 24 : 40)
        }
    }

    private func optionRow(_ setting: LaunchSetting, game: ConsoleGame, compact: Bool) -> some View {
        let value = game.value(setting)
        let label = setting.env == "DM_RENDER_SCALE" ? "\(Int((Double(value) ?? 1) * 100))%" : ConsoleOption.label(setting, value: value, lang: lang)
        let adjust: (Int) -> Void = { step in
            if let next = ConsoleOption.stepped(setting, value: value, by: step) {
                driver.setOption(gameID: game.id, setting: setting.env, value: next)
            }
        }
        return Button { adjust(1) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(setting.label).font(.manrope(compact ? 18 : 22, .semibold))
                HStack {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                    Text(label).font(.manrope(compact ? 18 : 23, .medium)).frame(maxWidth: .infinity)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(LauncherPalette.cream)
                if !setting.note.isEmpty { Text(setting.note).font(.manrope(compact ? 14 : 17)).foregroundStyle(.secondary) }
            }
            .padding(20).frame(maxWidth: .infinity, minHeight: compact ? 100 : 112, alignment: .leading)
            .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padTarget("console.option." + setting.env, scope: "console.options", radius: 14, activate: { adjust(1) }, adjust: adjust)
        .accessibilityLabel(setting.label).accessibilityValue(label)
        .accessibilityHint(t("console.adjustHint"))
        .accessibilityAdjustableAction { direction in adjust(direction == .increment ? 1 : -1) }
    }

    private func controllers(compact: Bool) -> some View {
        ConsoleControllerList(driver: driver, lang: lang, compact: compact)
    }

    private func explanation(_ game: ConsoleGame, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(game.title).font(.manrope(compact ? 27 : 38, .bold))
            Text(t(game.status.explanationKey ?? "console.ready")).font(.manrope(compact ? 20 : 26)).foregroundStyle(.secondary)
            if case let .broken(message) = game.status { Text(message).font(.manrope(compact ? 17 : 21)).foregroundStyle(.secondary) }
            Spacer(minLength: 24)
            primaryButton(t("console.desktop"), id: "console.explanation.desktop", scope: "console.explanation") { driver.exitToDesktop() }
        }
        .padding(compact ? 24 : 40)
    }

    private func empty(compact: Bool) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "rectangle.stack").font(.system(size: compact ? 44 : 64, weight: .light)).foregroundStyle(LauncherPalette.cream.opacity(0.65)).accessibilityHidden(true)
            Text(t("console.empty")).font(.manrope(compact ? 34 : 54, .bold)).accessibilityAddTraits(.isHeader)
            Text(t("console.emptyNote")).font(.manrope(compact ? 20 : 26)).foregroundStyle(.secondary)
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
                if state.isPreview { Text(t("console.simulatedShaders")).font(.manrope(compact ? 13 : 16)).foregroundStyle(.secondary) }
            }.frame(maxWidth: compact ? 320 : 540)
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var startingLabel: String {
        switch state.starting {
        case .preparing: return t("console.startingNote")
        case let .compilingShaders(completed, total): return String(format: t("console.shadersProgress"), completed, total)
        case .opening: return t("console.openingGame")
        }
    }

    private func exitPreview(compact: Bool) -> some View {
        VStack(spacing: 24) {
            Text(t("console.desktopPreview")).font(.manrope(compact ? 30 : 48, .bold))
            Text(t("console.desktopPreviewNote")).font(.manrope(compact ? 18 : 24)).foregroundStyle(.secondary)
            primaryButton(t("console.return"), id: "console.return", scope: "console") { driver.returnFromGame() }.frame(maxWidth: 360)
        }
        .multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .padScope("console", pad)
    }

    private func primaryButton(_ label: String, id: String, scope: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.manrope(21, .bold)).foregroundStyle(LauncherPalette.background)
                .frame(maxWidth: .infinity, minHeight: 60).background(LauncherPalette.cream, in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(.plain).padTarget(id, scope: scope, radius: 32, activate: action)
    }
    private func sheetTitle(_ sheet: ConsoleSheet) -> String {
        switch sheet {
        case .controllers: return "console.controllers"
        case .options: return "console.options"
        case .explanation: return "console.explanationTitle"
        }
    }
    private func resetFocus() {
        pad.scope = scope
        pad.show(default: nil)
        switch state.presentedSheet {
        case let .options(id): pad.focused = state.games.first { $0.id == id }?.visibleSettings.first.map { "console.option." + $0.env } ?? "console.options.play"
        case .controllers: pad.focused = "console.player.\(state.assigningPlayer ?? 1)"
        case .explanation: pad.focused = "console.explanation.desktop"
        case nil: pad.focused = state.exited ? "console.return" : state.focusedGame.map { "console.game." + $0.id } ?? "console.empty.desktop"
        }
    }
    private func handle(_ input: ConsoleInput) {
        if input == .back { driver.back(); return }
        if state.exited { if input == .activate { driver.returnFromGame() }; return }
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
        case .options: if state.presentedSheet == nil, let id = state.focusedGame?.id { driver.openOptions(id) }
        case .controllers: driver.openControllers()
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
    let image: Image?
    var title = ""
    var body: some View {
        GeometryReader { geometry in
            if let image { image.resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
            else {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: ConsolePlaceholder.colors(for: title), startPoint: .topLeading, endPoint: .bottomTrailing)
                    if title.isEmpty { Image(systemName: "gamecontroller").font(.system(size: 50)).foregroundStyle(.secondary) }
                    else {
                        Text(title).font(.manrope(max(14, geometry.size.width / 11), .bold)).foregroundStyle(LauncherPalette.cream.opacity(0.9))
                            .lineLimit(3).minimumScaleFactor(0.6).padding(geometry.size.width / 18)
                    }
                }
            }
        }
    }
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
            ConsoleArtwork(image: game.artwork, title: game.title).aspectRatio(1.8, contentMode: .fit)
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
