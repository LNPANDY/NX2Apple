import SwiftUI
import Combine
import NXCore
import NXLauncher

/// One presentation model and one set of intents in desktop and console mode.
@MainActor final class AnyConsoleDriver: ConsoleDriver {
    private let base: any ConsoleDriver
    private var subscription: AnyCancellable?
    @Published private var revision = 0
    var state: ConsoleState { base.state }
    init<D: ConsoleDriver>(_ driver: D) {
        base = driver
        subscription = driver.objectWillChange.sink { [weak self] _ in self?.revision += 1 }
    }
    func focus(_ id: String) { base.focus(id) }
    func play(_ id: String) { base.play(id) }
    func openOptions(_ id: String) { base.openOptions(id) }
    func setOption(gameID: String, setting: String, value: String) { base.setOption(gameID: gameID, setting: setting, value: value) }
    func openControllers() { base.openControllers() }
    func requestPlayer(_ player: Int) { base.requestPlayer(player) }
    func assignPlayer(controllerID: String, player: Int) { base.assignPlayer(controllerID: controllerID, player: player) }
    func requestAssignment(controllerID: String) { base.requestAssignment(controllerID: controllerID) }
    func cancelAssignment() { base.cancelAssignment() }
    func identify(controllerID: String) { base.identify(controllerID: controllerID) }
    func disconnect(controllerID: String) { base.disconnect(controllerID: controllerID) }
    func openMenu() { base.openMenu() }
    func openLibrary() { base.openLibrary() }
    func openSettings() { base.openSettings() }
    func openCloudSaves() { base.openCloudSaves() }
    func openLanguage() { base.openLanguage() }
    func confirmExit() { base.confirmExit() }
    func testRumble(gameID: String) { base.testRumble(gameID: gameID) }
    func setMod(gameID: String, name: String, on: Bool) { base.setMod(gameID: gameID, name: name, on: on) }
    func setCheatsMaster(gameID: String, on: Bool) { base.setCheatsMaster(gameID: gameID, on: on) }
    func setCheat(gameID: String, key: String, on: Bool) { base.setCheat(gameID: gameID, key: key, on: on) }
    func openAdvanced(_ gameID: String) { base.openAdvanced(gameID) }
    func askResetOptions(_ gameID: String) { base.askResetOptions(gameID) }
    func resetOptions(_ gameID: String) { base.resetOptions(gameID) }
    func openOnDesktop(_ gameID: String) { base.openOnDesktop(gameID) }
    func setPref(_ pref: ConsolePref, on: Bool) { base.setPref(pref, on: on) }
    func appUpdateAction() { base.appUpdateAction() }
    func confirmAppUpdate() { base.confirmAppUpdate() }
    func openSystemHomeSettings() { base.openSystemHomeSettings() }
    func openGameMapping(_ gameID: String) { base.openGameMapping(gameID) }
    func openGamePad(_ gameID: String) { base.openGamePad(gameID) }
    func openMapping() { base.openMapping() }
    func openMappingRow(_ button: String?) { base.openMappingRow(button) }
    func setPadMode(_ mode: PadMode) { base.setPadMode(mode) }
    func setPadSends(button: String, to output: String) { base.setPadSends(button: button, to: output) }
    func resetPadMapping() { base.resetPadMapping() }
    func setMenuSwapAB(_ on: Bool) { base.setMenuSwapAB(on) }
    func finishMapping(save: Bool) { base.finishMapping(save: save) }
    func setPadMerge(_ enabled: Bool) { base.setPadMerge(enabled) }
    func dismissToast() { base.dismissToast() }
    func back() { base.back() }
    func exitToDesktop() { base.exitToDesktop() }
    func returnFromGame() { base.returnFromGame() }
    func consumePress(controllerID: String, isBack: Bool) -> Bool { base.consumePress(controllerID: controllerID, isBack: isBack) }
    func openHomeButtonSettings() { base.openHomeButtonSettings() }
}

/// The battery drawn as the iOS status bar does: an outline with a nub and a fill exactly as wide as the level, red at 20 percent
/// or less, a bolt over it while charging, the outline alone when the level is unknown.
struct BatteryIcon: View {
    /// 0...1, nil when the controller reports none.
    let level: Double?
    var charging = false
    var height: CGFloat = 12

    /// The fill's share of the inner width: the level, clamped to 0...1 (a non-finite level counts as empty).
    static func fillFraction(_ level: Double?) -> Double {
        guard let level, level.isFinite else { return 0 }
        return min(max(level, 0), 1)
    }
    static func isLow(_ level: Double?) -> Bool { level.map { fillFraction($0) <= 0.2 } ?? false }

    /// Every rectangle of the icon, in points, snapped to the half point (whole pixels at 2x). The outline is stroked inside its
    /// frame, the fill area is that frame inset by the stroke and a 1 point gap, and the fill is that area times the level, so the
    /// fill can never leave the body.
    struct Geometry: Equatable {
        var outer: CGRect, inner: CGRect, fill: CGRect, nub: CGRect
        var outerRadius: CGFloat, innerRadius: CGFloat
        var size: CGSize
    }
    static func geometry(height: CGFloat, level: Double?) -> Geometry {
        func snap(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
        let h = snap(height), w = snap(height * 2), stroke: CGFloat = 1, gap: CGFloat = 1, nubWidth: CGFloat = 1.5
        let outer = CGRect(x: 0, y: 0, width: w, height: h)
        let inset = stroke + gap
        let inner = outer.insetBy(dx: inset, dy: inset)
        let fill = CGRect(x: inner.minX, y: inner.minY, width: snap(inner.width * fillFraction(level)), height: inner.height)
        let nubHeight = snap(h * 0.36)
        let nub = CGRect(x: w + 1, y: snap((h - nubHeight) / 2), width: nubWidth, height: nubHeight)
        let radius = snap(h * 0.3)
        return Geometry(outer: outer, inner: inner, fill: fill, nub: nub, outerRadius: radius, innerRadius: max(0, radius - inset),
                        size: CGSize(width: nub.maxX, height: h))
    }

    var body: some View {
        let g = Self.geometry(height: height, level: level)
        let line = LauncherPalette.ink(level == nil ? 0.3 : 0.55)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: g.outerRadius).strokeBorder(line, lineWidth: 1).frame(width: g.outer.width, height: g.outer.height)
            if level != nil {
                RoundedRectangle(cornerRadius: g.innerRadius)
                    .fill(Self.isLow(level) && !charging ? Color.red : (charging ? LauncherPalette.ready : LauncherPalette.ink(0.9)))
                    .frame(width: g.fill.width, height: g.fill.height).offset(x: g.fill.minX, y: g.fill.minY)
                    .animation(.easeInOut(duration: 0.6), value: g.fill.width)   // a charging level grows smoothly between reads
            }
            if charging {
                Image(systemName: "bolt.fill").font(.system(size: height * 0.62, weight: .bold)).foregroundStyle(.black.opacity(0.75))
                    .frame(width: g.outer.width, height: g.outer.height)
            }
            Capsule().fill(line).frame(width: g.nub.width, height: g.nub.height).offset(x: g.nub.minX, y: g.nub.minY)
        }
        .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// The battery as far as it is known: a level with its percentage, a bolt while charging. When the controller reports nothing usable
/// (no battery object yet, or 0 with an unknown state) nothing is drawn at all.
struct ConsoleBattery: View {
    let controller: ConsoleController
    let lang: Lang
    var compact = false
    /// The desktop's Controllers sheet sets the desktop type (DS.Font.callout), console mode keeps its own sizes.
    var font: Font? = nil
    var body: some View {
        if let percent = controller.batteryPercent {
            HStack(spacing: 5) {
                BatteryIcon(level: controller.battery, charging: controller.charging, height: compact ? 10 : 13)
                Text(String(format: L10n.string("console.batteryPercent", lang), percent))
            }
            .font(font ?? .manrope(compact ? 11 : 16, .medium))
            .foregroundStyle(BatteryIcon.isLow(controller.battery) && !controller.charging ? Color.red : LauncherPalette.ink(0.7))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: L10n.string(controller.charging ? "console.batteryCharging" : "console.batteryLevel", lang), percent))
        } else if controller.charging {
            HStack(spacing: 5) { BatteryIcon(level: nil, charging: true, height: compact ? 10 : 13) }
                .accessibilityElement(children: .ignore).accessibilityLabel(L10n.string("console.charging", lang))
        }
    }
}

struct ConsoleToastView: View {
    let toast: ConsoleToast
    var body: some View {
        HStack(spacing: 10) {
            Label(toast.message, systemImage: "gamecontroller")
            if let glyph = toast.glyph { ConsoleGlyphView(glyph: glyph, size: 20) }
        }
            .font(.manrope(17, .semibold)).padding(.horizontal, 22).padding(.vertical, 15)
            .background(LauncherPalette.surface, in: Capsule())
            .overlay(DSPill().strokeBorder(LauncherPalette.ink(0.15)))
            .foregroundStyle(LauncherPalette.accent)
            .accessibilityElement(children: .combine)
            .allowsHitTesting(false)
            .padding(20)
    }
}

@MainActor struct ConsoleControllerList<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let compact: Bool
    var scope = "console.controllers"
    /// The row that opens the button mapping. The desktop's Controllers sheet has the Controls page for that instead.
    var showsMapping = true
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var state: ConsoleState { driver.state }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private func playerLabel(_ controller: ConsoleController) -> String {
        (state.padMerge ? 1 : controller.player).map { String(format: t("console.player"), $0) } ?? t("console.unassigned")
    }
    var body: some View {
        ScrollViewReader { proxy in
            ViewThatFits(in: .vertical) {
                content   // the desktop's sheet takes the list's own height when it fits
                ScrollView(showsIndicators: false) { content.consoleScrollContent() }
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .consoleScrollFade()
            }
            .onChange(of: pad.focused) { id in
                if let id { withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    /// Players and their controllers first, what they are for on a TV, then the input switches and the ways into console mode.
    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Console.Space.xl) {
            VStack(alignment: .leading, spacing: DS.Console.Space.s) {
                ConsoleSectionHeading(title: t("console.controllers.players"), compact: compact)
                Text(t("console.controllerNote")).font(DS.Console.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ConsoleSegmentedControl(segments: (1...4).map { ("\($0)", String(format: t("console.playerShort"), $0)) },
                                        selected: (state.assigningPlayer ?? 0) - 1, scope: scope, idPrefix: "console.player.") { index in
                    driver.requestPlayer(index + 1)
                }
                .padding(.vertical, DS.Console.Space.xxs)   // room for the focus ring, so nothing is clipped at the top
                .accessibilityLabel(t("console.controllers.players"))
            }
            if let player = state.assigningPlayer {
                ConsoleNoticeCard(tone: .info, title: String(format: t("console.assignNotice.title"), player), detail: t("console.assignNotice.detail"),
                                  action: (t("console.assignNotice.cancel"), "console.controllers.cancelAssign", scope, { driver.cancelAssignment() }))
            }
            VStack(alignment: .leading, spacing: DS.Console.Space.s) {
                if state.controllers.isEmpty {
                    ConsoleGroupedList { ConsoleInfoRow(title: t("console.noControllers"), value: "") }
                }
                ForEach(state.controllers) { controller in row(controller) }
            }
            ConsoleGroupedList(title: t("console.controllers.input")) {
                mergeToggle
                if showsMapping {
                    ConsoleRowDivider()
                    menuSwapToggle   // in reach here too, not only at the top of the button mapping (#1129)
                    ConsoleRowDivider()
                    mappingEntry
                    if state.homeButtonAvailable { ConsoleRowDivider(); homeEntry }
                }
            }
            if showsMapping {   // the ways into console mode, as the desktop's Controls card has them
                ConsoleGroupedList(title: t("console.entry")) {
                    ForEach(Array(ConsolePref.onControllers.enumerated()), id: \.element) { index, pref in
                        if index > 0 { ConsoleRowDivider() }
                        prefToggle(pref)
                    }
                }
            }
        }
        .padding(.horizontal, compact ? DS.Console.Space.l : DS.Console.Space.xl).padding(.vertical, DS.Console.Space.s)
    }

    /// The shared switch keeps pointer and controller activation on the same row.
    private var mergeToggle: some View {
        ConsoleToggleListRow(id: "console.controller.merge", scope: scope, title: t("console.mergeAll"), isOn: state.padMerge) { driver.setPadMerge(!state.padMerge) }
    }

    /// The button mapping for all games, with the layout it uses now, as iOS shows it in its Controllers page.
    private var mappingEntry: some View {
        ConsoleListRow(id: "console.controller.mapping", scope: scope, title: t("console.mapping"), accessory: .value(t("controls.mode." + state.padLayout.mode.rawValue))) { driver.openMapping() }
            .accessibilityHint(t("console.menu.mappingNote"))
    }

    /// A launcher switch about controllers (ConsolePref.onControllers: start in console mode, offer it when a controller connects).
    /// Console mode only: the desktop's Controls card has the same switches.
    private func prefToggle(_ pref: ConsolePref) -> some View {
        ConsoleToggleListRow(id: "console.pref." + pref.rawValue, scope: scope, title: t(pref.titleKey), subtitle: t(pref.noteKey), isOn: state.prefs[pref]) { driver.setPref(pref, on: !state.prefs[pref]) }
    }

    /// "Quit games with the Home button": the system's setting on macOS 27 (HomeButtonSettings), opened as the desktop's Controls page does.
    private var homeEntry: some View {
        ConsoleListRow(id: "console.controller.home", scope: scope, title: t("controls.homeQuit")) { driver.openSystemHomeSettings() }
            .accessibilityHint(t("controls.homeQuitNote"))
    }

    private var menuSwapToggle: some View {
        ConsoleToggleListRow(id: "console.controller.menuSwap", scope: scope, title: t("console.mapping.menuSwap"), subtitle: t("console.mapping.menuSwapNote"), isOn: state.menuSwapAB) { driver.setMenuSwapAB(!state.menuSwapAB) }
    }

    /// A controller's card: its kind, name, player and battery, then one row of flat buttons, Disconnect as a red text button at the right.
    private func row(_ controller: ConsoleController) -> some View {
        VStack(alignment: .leading, spacing: DS.Console.Space.m) {
            HStack(spacing: DS.Console.Space.m) {
                Image(systemName: controller.kind.symbol).font(.system(size: 26)).foregroundStyle(DS.Color.symbolDefault).frame(width: 40).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(controller.name).font(DS.Console.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                    Text(t(controller.kind.labelKey) + " \u{00b7} " + playerLabel(controller) + (controller.charging ? " \u{00b7} " + t("console.charging") : ""))
                        .font(DS.Console.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                }
                Spacer(minLength: DS.Console.Space.s)
                ConsoleBattery(controller: controller, lang: lang)
            }
            HStack(spacing: DS.Console.Space.s) {
                if controller.canIdentify {
                    ConsoleFlatButton(id: "console.controller." + controller.id + ".identify", scope: scope,
                                      title: t(state.identifyingControllerID == controller.id ? "console.identifying" : "console.identify"), symbol: "wave.3.right") {
                        driver.identify(controllerID: controller.id)
                    }
                }
                ConsoleFlatButton(id: "console.controller." + controller.id + ".assign", scope: scope, title: t("console.assign"), symbol: "person.crop.circle.badge.plus") {
                    driver.requestAssignment(controllerID: controller.id)
                }
                Spacer(minLength: DS.Console.Space.s)
                ConsoleFlatButton(id: "console.controller." + controller.id + ".disconnect", scope: scope, title: t("console.disconnect"), destructive: true) {
                    driver.disconnect(controllerID: controller.id)
                }
            }
        }
        .padding(DS.Console.Space.l)
        .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Console.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Console.Radius.card).strokeBorder(DS.Color.separator))
    }
}

/// The desktop's Controllers sheet: the players, the connected controllers and the shared switch, on the sheet layout (DSSheet)
/// with the desktop's type and spacing like every other sheet. Console mode's own 10-foot list is ConsoleControllerList.
@MainActor struct ConsoleControllersSheet<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let close: () -> Void
    private let scope = "console.controllers"
    @EnvironmentObject private var pad: PadFocus
    private var state: ConsoleState { driver.state }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private func playerLabel(_ controller: ConsoleController) -> String {
        (state.padMerge ? 1 : controller.player).map { String(format: t("console.player"), $0) } ?? t("console.unassigned")
    }

    var body: some View {
        DSSheet(width: 580, title: t("console.controllers"), message: t("console.controllerNote")) {
            DSSection(t("console.controllers.players")) {
                HStack(spacing: DS.Space.xs) {
                    ForEach(1...4, id: \.self) { player in playerButton(player) }
                }
                .padding(DS.Space.s)
                if let player = state.assigningPlayer {
                    DSRowDivider()
                    DSRow(String(format: t("console.assignNotice.title"), player), detail: t("console.assignNotice.detail"), dot: DS.Color.statusInfo) {
                        Button(t("console.assignNotice.cancel")) { driver.cancelAssignment() }
                            .buttonStyle(DSRowButtonStyle())
                            .padTarget("console.controllers.cancelAssign", scope: scope, activate: { driver.cancelAssignment() })
                    }
                }
            }
            DSSection("") {
                if state.controllers.isEmpty { DSRow(t("console.noControllers")) {} }
                ForEach(Array(state.controllers.enumerated()), id: \.element.id) { index, controller in
                    if index > 0 { DSRowDivider() }
                    controllerRow(controller)
                }
            }
            DSSection(t("console.controllers.input")) {
                DSRow(t("console.mergeAll")) {
                    Toggle(t("console.mergeAll"), isOn: Binding(get: { state.padMerge }, set: { _ in driver.setPadMerge(!state.padMerge) }))
                        .labelsHidden().toggleStyle(LauncherSwitchStyle())
                        .padTarget("console.controller.merge", scope: scope, activate: { driver.setPadMerge(!state.padMerge) })
                }
            }
        } buttons: {
            DSSheetPrimaryButton(t("free.done"), action: close)
                .keyboardShortcut(.cancelAction)
                .padTarget("console.sheet.close", scope: scope, focusColor: DS.Color.accentOn, activate: close)
        }
        .padScope(scope, pad)
        .onAppear { pad.scope = scope; pad.focused = "console.player.1" }
        .overlay(alignment: .bottom) { if let toast = state.toast { ConsoleToastView(toast: toast) } }
        .background(ConsoleKeyboardInput { input in
            pad.show(default: "console.player.1")
            switch input {
            case .back: close()
            case .left: pad.horizontal(-1)
            case .right: pad.horizontal(1)
            case .up: pad.move(dx: 0, dy: -1)
            case .down: pad.move(dx: 0, dy: 1)
            case .activate: pad.activate()
            default: break
            }
        })
    }

    /// Player 1 to 4: choosing one waits for a button on the controller that takes it. The one waiting has the accent outline.
    private func playerButton(_ player: Int) -> some View {
        let waiting = state.assigningPlayer == player
        return Button { driver.requestPlayer(player) } label: {
            Text(String(format: t("console.playerShort"), player)).frame(maxWidth: .infinity)
        }
        .buttonStyle(DSSecondaryButtonStyle(accent: waiting ? DS.Color.accent : nil))
        .accessibilityLabel(String(format: t("console.player"), player))
        .accessibilityAddTraits(waiting ? .isSelected : [])
        .padTarget("console.player.\(player)", scope: scope, activate: { driver.requestPlayer(player) })
    }

    /// A controller: its kind, name, player and battery, then Identify and Assign, Disconnect at the trailing edge.
    private func controllerRow(_ controller: ConsoleController) -> some View {
        let id = "console.controller." + controller.id
        return VStack(alignment: .leading, spacing: 0) {
            DSRow(controller.name, detail: t(controller.kind.labelKey) + " \u{00b7} " + playerLabel(controller) + (controller.charging ? " \u{00b7} " + t("console.charging") : "")) {
                ConsoleBattery(controller: controller, lang: lang, font: DS.Font.callout)
            }
            HStack(spacing: DS.Space.xs) {
                if controller.canIdentify {
                    Button { driver.identify(controllerID: controller.id) } label: {
                        Label(t(state.identifyingControllerID == controller.id ? "console.identifying" : "console.identify"), systemImage: "wave.3.right")
                    }
                    .buttonStyle(DSRowButtonStyle())
                    .padTarget(id + ".identify", scope: scope, activate: { driver.identify(controllerID: controller.id) })
                }
                Button { driver.requestAssignment(controllerID: controller.id) } label: {
                    Label(t("console.assign"), systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(DSRowButtonStyle())
                .padTarget(id + ".assign", scope: scope, activate: { driver.requestAssignment(controllerID: controller.id) })
                Spacer(minLength: DS.Space.s)
                Button(t("console.disconnect")) { driver.disconnect(controllerID: controller.id) }
                    .buttonStyle(DSDestructiveButtonStyle())
                    .padTarget(id + ".disconnect", scope: scope, activate: { driver.disconnect(controllerID: controller.id) })
            }
            .padding(.leading, DS.Space.xs + DS.Control.leadingSlot + DS.Space.s).padding(.trailing, DS.Space.s).padding(.bottom, DS.Space.s)
        }
    }
}
