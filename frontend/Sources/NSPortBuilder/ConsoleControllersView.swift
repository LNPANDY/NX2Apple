import SwiftUI
import Combine

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
    func identify(controllerID: String) { base.identify(controllerID: controllerID) }
    func disconnect(controllerID: String) { base.disconnect(controllerID: controllerID) }
    func setPadMerge(_ enabled: Bool) { base.setPadMerge(enabled) }
    func dismissToast() { base.dismissToast() }
    func back() { base.back() }
    func exitToDesktop() { base.exitToDesktop() }
    func returnFromGame() { base.returnFromGame() }
    func consumePress(controllerID: String, isBack: Bool) -> Bool { base.consumePress(controllerID: controllerID, isBack: isBack) }
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
        let line = Color.white.opacity(level == nil ? 0.3 : 0.55)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: g.outerRadius).strokeBorder(line, lineWidth: 1).frame(width: g.outer.width, height: g.outer.height)
            if level != nil {
                RoundedRectangle(cornerRadius: g.innerRadius)
                    .fill(Self.isLow(level) && !charging ? Color.red : (charging ? LauncherPalette.ready : Color.white.opacity(0.9)))
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
    var body: some View {
        if let percent = controller.batteryPercent {
            HStack(spacing: 5) {
                BatteryIcon(level: controller.battery, charging: controller.charging, height: compact ? 10 : 13)
                Text(String(format: L10n.string("console.batteryPercent", lang), percent))
            }
            .font(.manrope(compact ? 11 : 16, .medium))
            .foregroundStyle(BatteryIcon.isLow(controller.battery) && !controller.charging ? Color.red : .white.opacity(0.7))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: L10n.string(controller.charging ? "console.batteryCharging" : "console.batteryLevel", lang), percent))
        } else if controller.charging {
            HStack(spacing: 5) { BatteryIcon(level: nil, charging: true, height: compact ? 10 : 13) }
                .accessibilityElement(children: .ignore).accessibilityLabel(L10n.string("console.charging", lang))
        }
    }
}

/// Fixed-height strip: controller arrivals only change its horizontal content, never the library's position.
struct ConsoleControllerChips: View {
    let controllers: [ConsoleController]
    let merged: Bool
    let lang: Lang
    var compact = false
    var scope = "console"
    let openControllers: () -> Void
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var row: some View {
        HStack(spacing: 8) {
            if controllers.isEmpty {
                chip(id: "empty", label: t("console.noControllers")) {
                    Label(t("console.controllers"), systemImage: "gamecontroller")
                }
            }
            ForEach(controllers) { controller in
                chip(id: controller.id, label: controller.name + ", " + t(controller.kind.labelKey) + ", " + ((merged ? 1 : controller.player).map { String(format: t("console.player"), $0) } ?? t("console.unassigned")) + (controller.batteryPercent.map { ", " + String(format: t(controller.charging ? "console.batteryCharging" : "console.batteryLevel"), $0) } ?? "")) {
                    HStack(spacing: compact ? 5 : 8) {
                        Image(systemName: controller.kind.symbol).accessibilityHidden(true)
                        Text((merged ? 1 : controller.player).map { String(format: t("console.playerShort"), $0) } ?? "\u{2014}")   // the full "Unassigned" is in the Controllers list
                        ConsoleBattery(controller: controller, lang: lang, compact: compact)
                    }
                }
            }
        }
        .padding(5)
    }

    /// The chips take their own width (nothing is cut off) and sit at the trailing edge. Only when there are more than the row has
    /// room for does it scroll sideways.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row.fixedSize().frame(maxWidth: .infinity, alignment: .trailing)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) { row }
                    .mask(HStack(spacing: 0) { Rectangle(); LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18) })   // an overflowing row fades out instead of ending in a cut
                    .onChange(of: pad.focused) { id in
                        if let id, id.hasPrefix(scope + ".chip.") {
                            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
            }
        }
        .frame(height: compact ? 40 : 52)
    }
    private func chip<C: View>(id: String, label: String, @ViewBuilder content: () -> C) -> some View {
        Button(action: openControllers) {
            content().font(.manrope(compact ? 12 : 17, .semibold))
                .padding(.horizontal, compact ? 10 : 14).frame(height: compact ? 30 : 40)
                .background(.white.opacity(0.075), in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(t("console.controllers"))
        .padTarget(scope + ".chip." + id, scope: scope, radius: 24, activate: openControllers)
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
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
            .foregroundStyle(LauncherPalette.cream)
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
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var state: ConsoleState { driver.state }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private func playerLabel(_ controller: ConsoleController) -> String {
        (state.padMerge ? 1 : controller.player).map { String(format: t("console.player"), $0) } ?? t("console.unassigned")
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    mergeToggle
                    Text(t("console.controllerNote")).font(.manrope(compact ? 17 : 22)).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        ForEach(1...4, id: \.self) { player in
                            Button { driver.requestPlayer(player) } label: {
                                Text(String(format: t("console.playerShort"), player)).font(.manrope(compact ? 18 : 22, .bold))
                                    .frame(maxWidth: .infinity, minHeight: 56)
                                    .background(state.assigningPlayer == player ? LauncherPalette.cream : LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                                    .foregroundStyle(state.assigningPlayer == player ? LauncherPalette.background : .white)
                            }
                            .buttonStyle(.plain).accessibilityLabel(String(format: t("console.player"), player))
                            .accessibilityAddTraits(state.assigningPlayer == player ? .isSelected : [])
                            .padTarget("console.player.\(player)", scope: scope, radius: 12, activate: { driver.requestPlayer(player) })
                        }
                    }
                    if let player = state.assigningPlayer {
                        Text(String(format: t("console.pressToAssign"), player)).font(.manrope(compact ? 19 : 26, .semibold)).foregroundStyle(LauncherPalette.cream)
                    }
                    if state.controllers.isEmpty { Text(t("console.noControllers")) }
                    ForEach(state.controllers) { controller in row(controller) }
                }
                .padding(.horizontal, compact ? 24 : 40).padding(.vertical, 12)
            }
            .onChange(of: pad.focused) { id in
                if let id { withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
    /// "All controllers are player 1" as a switch with its state spelled out.
    private var mergeToggle: some View {
        let flip = { driver.setPadMerge(!state.padMerge) }
        return Button(action: flip) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(t("console.mergeAll"), systemImage: "person.2").font(.manrope(compact ? 16 : 18, .semibold))
                    Text(t(state.padMerge ? "console.on" : "console.off")).font(.manrope(compact ? 16 : 20)).foregroundStyle(state.padMerge ? LauncherPalette.cream : .secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { state.padMerge }, set: { _ in flip() })).labelsHidden().toggleStyle(LauncherSwitchStyle()).allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10)).contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padTarget("console.controller.merge", scope: scope, radius: 10, activate: flip, adjust: { _ in flip() })
        .accessibilityLabel(t("console.mergeAll")).accessibilityValue(t(state.padMerge ? "console.on" : "console.off"))
    }

    private func row(_ controller: ConsoleController) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(systemName: controller.kind.symbol).font(.system(size: compact ? 26 : 34)).frame(width: 42).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.name).font(.manrope(compact ? 18 : 23, .semibold))
                    do { Text(t(controller.kind.labelKey) + " \u{00b7} " + playerLabel(controller)).font(.manrope(compact ? 14 : 17)).foregroundStyle(.secondary) }
                    ConsoleBattery(controller: controller, lang: lang)
                    if controller.charging { Text(t("console.charging")).font(.manrope(13)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            // Three equal tiles: the icon above a label that wraps between words only (and shrinks a little rather than break a word).
            HStack(spacing: 10) {
                if controller.canIdentify { tile(id: controller.id + ".identify", label: t(state.identifyingControllerID == controller.id ? "console.identifying" : "console.identify"), symbol: "wave.3.right") { driver.identify(controllerID: controller.id) } }
                tile(id: controller.id + ".assign", label: t("console.assign"), symbol: "person.crop.circle.badge.plus") { driver.requestAssignment(controllerID: controller.id) }
                tile(id: controller.id + ".disconnect", label: t("console.disconnect"), symbol: "xmark.circle") { driver.disconnect(controllerID: controller.id) }
            }
            if state.isPreview, state.assigningPlayer != nil, state.assigningControllerID == nil || state.assigningControllerID == controller.id {
                action(id: controller.id + ".press", label: t("console.mockPress"), symbol: "hand.tap") {
                    driver.assignPlayer(controllerID: controller.id, player: state.assigningPlayer ?? 1)
                }
            }
        }
        .padding(20).background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 16))
    }
    private func tile(id: String, label: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: compact ? 20 : 24)).accessibilityHidden(true)
                Text(label).font(.manrope(compact ? 14 : 17, .semibold)).multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 88 : 96).padding(.horizontal, 6)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10)).contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padTarget("console.controller." + id, scope: scope, radius: 10, activate: perform)
        .accessibilityLabel(label)
    }
    private func action(id: String, label: String, value: String? = nil, symbol: String, adjust: ((Int) -> Void)? = nil, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(alignment: .leading, spacing: 8) {
                Label(label, systemImage: symbol).font(.manrope(compact ? 16 : 18, .semibold))
                if let value { Text(value).font(.manrope(compact ? 16 : 20)).foregroundStyle(LauncherPalette.cream) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10)).contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padTarget("console.controller." + id, scope: scope, radius: 10, activate: perform, adjust: adjust)
        .accessibilityLabel(label).accessibilityValue(value ?? "")
    }
}

@MainActor struct ConsoleControllersSheet<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let close: () -> Void
    @EnvironmentObject private var pad: PadFocus
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("console.controllers", lang)).font(.manrope(28, .bold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 48, height: 48) }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("console.close", lang))
                    .padTarget("console.sheet.close", scope: "console.controllers", radius: 24, activate: close)
            }.padding(24)
            ConsoleControllerList(driver: driver, lang: lang, compact: true)
        }
        .frame(minWidth: 360, idealWidth: 580, maxWidth: 580, minHeight: 600, idealHeight: 720, maxHeight: 720).background(LauncherPalette.background).preferredColorScheme(.dark)
        .foregroundStyle(.white).padScope("console.controllers", pad)
        .environment(\.padRingStyle, .hug)
        .onAppear { pad.scope = "console.controllers"; pad.focused = "console.controller.merge" }
        .overlay(alignment: .bottom) { if let toast = driver.state.toast { ConsoleToastView(toast: toast) } }
        .background(ConsoleKeyboardInput { input in
            pad.show(default: "console.controller.merge")
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
}
