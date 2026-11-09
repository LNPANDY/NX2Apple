import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Reuses the keyboard/controller editor with persistence scoped to this game's bundle domain.
@MainActor struct GameControllerMappingView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: ControllerMappingStore
    @StateObject private var layout: ControlLayout
    private let game: LibraryGame
    private let globalControls: ControlLayout?
    private var savingEnabled: Bool { game.controllerSavingEnabled(environment: game.launchOptions) }

    init(game: LibraryGame, globalControls: ControlLayout? = nil) {
        self.game = game
        self.globalControls = globalControls
        let preferences = game.controllerPreferences()
        if savingEnabledFor(game) { _ = preferences.launchControls(globalControls?.environment ?? [:]) }
        let store = ControllerMappingStore(preferences: preferences, canSave: {
            game.controllerSavingEnabled(environment: game.launchOptions)
        })
        _store = StateObject(wrappedValue: store)
        _layout = StateObject(wrappedValue: ControlLayout(keyMap: store.keyMap, padMap: store.padMap) { env, value in
            guard game.controllerSavingEnabled(environment: game.launchOptions) else { return }
            store.setMap(env, value: value)
        })
    }

    var body: some View {
        Group {
            if savingEnabled {
                ControlsView(layout: layout, gameName: game.displayName(loc.lang), mappingStore: store, copyGlobal: globalControls.map { global in
                    { copy(global.environment) }
                })
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    Text(game.displayName(loc.lang)).font(.manrope(26, .heavy))
                    Text(loc.t("controls.savingDisabled")).font(.manrope(14))
                    Button(loc.t("launch.done")) { dismiss() }.buttonStyle(LauncherSecondaryButtonStyle())
                        .padTarget("controls.done", scope: "controls") { dismiss() }
                }.padding(30).frame(width: 600, height: 300).background(LauncherPalette.background)
                    .padScope("controls", focus).launcherAppearance()
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }

    private func refresh() {
        guard savingEnabled else { return }
        store.refresh()
        layout.load(keyMap: store.keyMap, padMap: store.padMap)
    }
    private func copy(_ environment: [String: String]) {
        guard savingEnabled else { return }
        store.copyStandardMaps(environment)
        layout.load(keyMap: store.keyMap, padMap: store.padMap)
    }
}

private func savingEnabledFor(_ game: LibraryGame) -> Bool { game.controllerSavingEnabled(environment: game.launchOptions) }

struct SteamControllerSection: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject var store: ControllerMappingStore
    private let extras = ["L4", "R4", "L5", "R5", "leftPad", "rightPad", "Guide", "QuickAccess"]
    private var targets: [(value: String, label: String)] {
        [("-1", loc.t("controls.none"))] + ControllerMap.buttons.enumerated().map { (String($0.offset), loc.t("controls.fn." + $0.element)) } + [("63", loc.t("controls.fn.Shake"))]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(loc.t("controls.steam.title")).font(.manrope(15, .semibold)).foregroundStyle(LauncherPalette.secondaryText)
                Spacer()
                Button(loc.t("controls.steam.reset")) { store.resetSteam() }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .padTarget("steam.reset", scope: "controls") { store.resetSteam() }
            }
            VStack(spacing: 0) {
                ForEach(Array(extras.enumerated()), id: \.offset) { index, name in
                    line(loc.t("controls.steam." + name), id: name, adjust: { by in
                        let values = targets.map(\.value)
                        let at = values.firstIndex(of: String(store.steam.buttons[index + 16] ?? -1)) ?? 0
                        store.setButton(index + 16, target: Int(values[(at + by + values.count) % values.count]) ?? -1)
                    }) {
                        LauncherDropdown(options: targets, selection: String(store.steam.buttons[index + 16] ?? -1),
                                         label: loc.t("controls.steam." + name), fill: true) { store.setButton(index + 16, target: Int($0) ?? -1) }
                    }
                    Divider().opacity(0.2).padding(.leading, 18)
                }
                ForEach(0..<2, id: \.self) { index in
                    line(loc.t(index == 0 ? "controls.steam.leftMode" : "controls.steam.rightMode"), id: "mode\(index)",
                         adjust: { store.setPad(index, mode: (store.steam.pads[index] + $0 + 5) % 5) }) {
                        LauncherDropdown(options: (0...4).map { (value: String($0), label: loc.t("controls.steam.mode.\($0)")) },
                                         selection: String(store.steam.pads[index]), label: loc.t("controls.steam.title"), fill: true) { store.setPad(index, mode: Int($0) ?? 0) }
                    }
                    Divider().opacity(0.2).padding(.leading, 18)
                }
                line(loc.t("controls.steam.gyro"), id: "gyro", activate: { store.setGyro(!store.steam.gyro) },
                     adjust: { _ in store.setGyro(!store.steam.gyro) }) {
                    Toggle("", isOn: Binding(get: { store.steam.gyro }, set: { store.setGyro($0) }))
                        .labelsHidden().toggleStyle(LauncherSwitchStyle())
                }
            }
            .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
        }
    }
    private func line<Trailing: View>(_ title: String, id: String, activate: (() -> Void)? = nil, adjust: ((Int) -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.manrope(13, .medium))
            Spacer(minLength: 8)
            trailing().frame(width: 168, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 4).frame(minHeight: 34)
        .padTarget("steam." + id, scope: "controls", radius: 10, activate: activate, adjust: adjust)
    }
}


/// A fixed-footer observer so every mapping section reports persistence failures immediately.
struct ControllerMappingStatus: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject var store: ControllerMappingStore
    var body: some View {
        let message = loc.t(store.saveFailed ? "controls.saveFailed" : "controls.gameApplied")
        Text(message).font(.manrope(12)).foregroundStyle(store.saveFailed ? Color.orange : Color.secondary).lineLimit(2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message)
            .accessibilityIdentifier("controllerMapping.status")
    }
}
