import SwiftUI
import NXCore
import NXLauncher

/// A row that opens a page: its symbol, title, what it is for, the value it has now, and a chevron. A opens it.
struct ConsoleMenuRow: View {
    let id: String
    let scope: String
    let symbol: String
    let title: String
    let note: String
    var value: String?
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: symbol).font(.system(size: compact ? 22 : 28)).frame(width: 40).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.manrope(compact ? 19 : 23, .semibold))
                    if !note.isEmpty { Text(note).font(.manrope(compact ? 14 : 17)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                if let value { Text(value).font(.manrope(compact ? 15 : 18, .semibold)).foregroundStyle(LauncherPalette.cream).lineLimit(1) }
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.4)).accessibilityHidden(true)
            }
            .padding(20).frame(maxWidth: .infinity, minHeight: compact ? 84 : 96, alignment: .leading)
            .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padTarget(id, scope: scope, radius: 14, activate: action)
        .accessibilityLabel(title).accessibilityValue(value ?? "").accessibilityHint(note)
        .id(id)
    }
}

/// One setting with a few values side by side, the chosen one cream (the mapping page's layout segments): each segment is a pad
/// target, so left and right move the focus between them and A picks the one in focus. No `adjust` on the segments: with it, left
/// and right changed the value under a focus that stayed put, and the next A put the focused value back.
struct ConsoleChoiceRow: View {
    let id: String
    let scope: String
    let title: String
    var note = ""
    /// Each value's key and label, in order.
    let choices: [(String, String)]
    let chosen: String
    let compact: Bool
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.manrope(compact ? 17 : 20, .semibold)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { ForEach(choices, id: \.0) { choice in segment(choice.0, label: choice.1) } }
            if !note.isEmpty { Text(note).font(.manrope(compact ? 13 : 15)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 20).padding(.vertical, compact ? 14 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .id(id)
    }

    private func segment(_ key: String, label: String) -> some View {
        let isChosen = key == chosen
        let choose = { pick(key) }
        return Button(action: choose) {
            Text(label).font(.manrope(compact ? 14 : 16, isChosen ? .bold : .semibold))
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.75)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: compact ? 44 : 50)
                .foregroundStyle(isChosen ? LauncherPalette.background : .white.opacity(0.85))
                .background(isChosen ? LauncherPalette.cream : .white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(isChosen ? 0 : 0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + ", " + label)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .padTarget(id + "." + key, scope: scope, radius: 10, activate: choose)
        .id(id + "." + key)
    }
}

/// A switch on a row of its own: its name, what it does under it, the switch at the right. A (or left and right) flips it. A row that
/// cannot be switched (a mod that changes the game's code) is dimmed and says why, and takes no focus.
struct ConsoleSwitchRow: View {
    let id: String
    let scope: String
    let title: String
    var note = ""
    let isOn: Bool
    var enabled = true
    let compact: Bool
    let flip: () -> Void

    var body: some View {
        let row = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Text(title).font(.manrope(compact ? 17 : 20, .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                ConsoleSwitch(isOn: isOn, compact: compact)
            }
            if !note.isEmpty { Text(note).font(.manrope(compact ? 13 : 15)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 20).padding(.vertical, compact ? 14 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title).accessibilityHint(note)
        .accessibilityValue(isOn ? "1" : "0")
        .id(id)
        if enabled {
            row.onTapGesture(perform: flip)
                .accessibilityAddTraits(.isButton).accessibilityAction { flip() }
                .padTarget(id, scope: scope, radius: 14, activate: flip, adjust: { _ in flip() })
        } else {
            row
        }
    }
}

/// The scrolling part of a game's options page: its common options, its controller settings, its advanced options (a page of their
/// own), its mods and cheats (switched here, put in place on the desktop), where its cloud save stands, and Reset to defaults.
@MainActor struct ConsoleGameOptionsList<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let game: ConsoleGame
    let lang: Lang
    let compact: Bool
    @Binding var editing: String?
    static var scope: String { "console.options" }
    private var scope: String { Self.scope }
    private func t(_ key: String) -> String { L10n.string(key, lang) }

    /// Where the focus starts on the page.
    static func firstTarget(_ game: ConsoleGame) -> String {
        if let first = game.basicSettings.first { return "console.option." + first.env }
        if game.hasControllerSettings { return "console.options.gamePad" }
        if !game.advancedSettings.isEmpty { return "console.options.advanced" }
        return "console.options.play"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if game.optionSettings.isEmpty && !game.hasControllerSettings && game.mods.isEmpty && game.cheats == nil {
                Text(t("console.noOptions")).foregroundStyle(LauncherPalette.secondaryText)
            }
            ForEach(game.basicSettings) { setting in
                consoleOptionRow(setting, game: game, driver: driver, lang: lang, compact: compact, scope: scope, editing: $editing)
                    .id("console.option." + setting.env)
            }
            if game.hasControllerSettings {
                ConsoleMenuRow(id: "console.options.gamePad", scope: scope, symbol: "gamecontroller", title: t("console.gamePad"),
                               note: t("console.gamePad.note"), compact: compact) { driver.openGamePad(game.id) }
            }
            if !game.advancedSettings.isEmpty {
                ConsoleMenuRow(id: "console.options.advanced", scope: scope, symbol: "slider.horizontal.3", title: t("launch.advanced"),
                               note: t("console.advanced.note"), value: String(format: t("launch.advancedCount"), game.advancedSettings.count),
                               compact: compact) { driver.openAdvanced(game.id) }
            }
            mods
            ConsoleCheatsSection(driver: driver, game: game, lang: lang, compact: compact, scope: scope)
            if let save = game.save { saveCard(save) }
            if game.canReset {
                ConsoleMenuRow(id: "console.options.reset", scope: scope, symbol: "arrow.counterclockwise", title: t("console.reset.title"),
                               note: t("console.reset.note"), compact: compact) { driver.askResetOptions(game.id) }
            }
        }
    }

    // MARK: Mods

    @ViewBuilder private var mods: some View {
        if !game.mods.isEmpty {
            ConsoleSectionHeading(title: t("launch.mods"), compact: compact).padding(.top, 14)
            Text(t("launch.modsNote")).font(.manrope(compact ? 13 : 15)).foregroundStyle(LauncherPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            ForEach(game.mods) { mod in
                ConsoleSwitchRow(id: "console.mod." + mod.name, scope: scope, title: mod.name, note: mod.usable ? "" : t("launch.modCode"),
                                 isOn: mod.on, enabled: mod.usable, compact: compact) {
                    driver.setMod(gameID: game.id, name: mod.name, on: !mod.on)
                }
            }
        }
    }

    // MARK: Cloud save

    /// Where the game's cloud save stands, read only: the folder is chosen on the desktop.
    private func saveCard(_ row: ConsoleSaveRow) -> some View {
        HStack(spacing: 16) {
            Image(systemName: row.status.symbol).font(.system(size: compact ? 22 : 26, weight: .medium)).foregroundStyle(row.status.tint)
                .frame(width: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(t(ConsoleCloudSaves.menuKey)).font(.manrope(compact ? 17 : 20, .semibold))
                Text(t(row.status.key)).font(.manrope(compact ? 13 : 15)).foregroundStyle(row.status == .synced ? LauncherPalette.cream : row.status.tint)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20).padding(.vertical, compact ? 14 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPalette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))   // read only: quieter than the rows the focus can land on
        .padding(.top, 14)
        .accessibilityElement(children: .combine)
    }
}

/// A game's advanced options, as the desktop's Advanced settings: the same rows, the same scroll and slider rules.
@MainActor struct ConsoleAdvancedList<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let game: ConsoleGame
    let lang: Lang
    let compact: Bool
    @Binding var editing: String?
    static var scope: String { "console.advanced" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(game.advancedSettings) { setting in
                consoleOptionRow(setting, game: game, driver: driver, lang: lang, compact: compact, scope: Self.scope, editing: $editing)
                    .id("console.option." + setting.env)
            }
        }
    }
}

/// The Library page: the library's switch (only built games), and the ways to the cloud saves page and the supported games.
@MainActor struct ConsoleLibraryList<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let compact: Bool
    static var scope: String { "console.library" }
    private var scope: String { Self.scope }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var prefs: ConsolePrefs { driver.state.prefs }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ConsolePref.onLibrary, id: \.self) { pref in
                ConsoleSwitchRow(id: "console.pref." + pref.rawValue, scope: scope, title: t(pref.titleKey), note: t(pref.noteKey),
                                 isOn: prefs[pref], compact: compact) { driver.setPref(pref, on: !prefs[pref]) }
            }
            ConsoleMenuRow(id: "console.library.saves", scope: scope, symbol: "icloud", title: t(ConsoleCloudSaves.menuKey),
                           note: t(ConsoleCloudSaves.menuNoteKey), compact: compact) { driver.openCloudSaves() }
            ConsoleMenuRow(id: "console.library.supported", scope: scope, symbol: "list.bullet.rectangle", title: t("supported.title"),
                           note: t("console.supported.menuNote"), compact: compact) { driver.openSupportedGames() }
        }
    }
}

/// The Settings page: the display language (a page of its own), the app's update, and the launcher's switch for after a game quits.
@MainActor struct ConsoleSettingsList<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let compact: Bool
    let languageName: String
    static var scope: String { "console.settings" }
    private var scope: String { Self.scope }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var prefs: ConsolePrefs { driver.state.prefs }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConsoleMenuRow(id: "console.settings.language", scope: scope, symbol: "globe", title: t("console.language.title"),
                           note: t("console.language.note"), value: languageName, compact: compact) { driver.openLanguage() }
            ConsoleMenuRow(id: "console.settings.update", scope: scope, symbol: "arrow.down.app", title: t("console.update.title"),
                           note: updateNote, value: updateValue, compact: compact) { driver.appUpdateAction() }
            ForEach(ConsolePref.onSettings, id: \.self) { pref in
                ConsoleSwitchRow(id: "console.pref." + pref.rawValue, scope: scope, title: t(pref.titleKey), note: t(pref.noteKey),
                                 isOn: prefs[pref], compact: compact) { driver.setPref(pref, on: !prefs[pref]) }
            }
        }
    }

    private var updateValue: String {
        switch prefs.update {
        case .upToDate: return t("console.update.check")
        case .checking: return t("console.update.checking")
        case let .available(tag): return String(format: t("app.updateBtn"), tag)
        case let .downloading(percent): return percent.map { "\($0)%" } ?? t("console.update.checking")
        case .ready: return t("app.restartNow")
        case .cannotInstall: return t("console.update.onDesktop")
        case .waitingForBuild: return t("console.update.waiting")
        case .failed: return t("console.update.retry")
        }
    }

    private var updateNote: String {
        let version = String(format: t("app.version"), prefs.appVersion)
        switch prefs.update {
        case .cannotInstall(let tag): return version + " \u{00b7} " + String(format: t("console.update.cannotInstall"), tag)
        case .waitingForBuild: return version + " \u{00b7} " + t("console.update.waitingNote")
        case .failed(_, let reason): return version + " \u{00b7} " + reason   // why the last try failed
        default: return prefs.updateStatus.isEmpty ? version : version + " \u{00b7} " + prefs.updateStatus   // downloading, ready, or why an install failed
        }
    }
}

/// A game's cheats for the build it has (CheatFiles, imported on the desktop): the switch for all of them and one per cheat, or why
/// there are none. On its options page and on its page's Cheats tab (#816).
@MainActor struct ConsoleCheatsSection<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let game: ConsoleGame
    let lang: Lang
    let compact: Bool
    let scope: String
    private func t(_ key: String) -> String { L10n.string(key, lang) }

    @ViewBuilder var body: some View {
        if let cheats = game.cheats, cheats.note == nil || !cheats.items.isEmpty {
            ConsoleSectionHeading(title: t("cheats.title"), compact: compact).padding(.top, 14)
            ConsoleSwitchRow(id: "console.cheats.master", scope: scope, title: t("cheats.master"), isOn: cheats.masterOn, compact: compact) {
                driver.setCheatsMaster(gameID: game.id, on: !cheats.masterOn)
            }
            ForEach(cheats.items) { cheat in
                switch cheat.kind {
                case .label:
                    Text(cheat.name).font(.manrope(compact ? 14 : 16, .semibold)).foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 4).padding(.top, 6)
                case .alwaysOn:
                    HStack {
                        Text(cheat.name).font(.manrope(compact ? 17 : 20, .semibold))
                        Spacer(minLength: 8)
                        Text(t("cheats.alwaysOn")).font(.manrope(compact ? 14 : 16, .semibold)).foregroundStyle(LauncherPalette.cream)
                    }
                    .padding(.horizontal, 20).padding(.vertical, compact ? 14 : 16)
                    .background(LauncherPalette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                case .cheat:
                    ConsoleSwitchRow(id: "console.cheat." + cheat.key, scope: scope, title: cheat.name, isOn: cheat.on, enabled: cheats.masterOn,
                                     compact: compact) { driver.setCheat(gameID: game.id, key: cheat.key, on: !cheat.on) }
                }
            }
        } else if let note = game.cheats?.note, game.status == .ready {
            ConsoleSectionHeading(title: t("cheats.title"), compact: compact).padding(.top, 14)
            Text(note).font(.manrope(compact ? 14 : 16)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

}
