import SwiftUI
import NXCore
import NXLauncher

/// A row that opens a page, on a card of its own: its title, what it is for, the value it has now, and a chevron. A opens it. The
/// symbol is kept for VoiceOver's sake only: console rows draw no leading glyph tiles.
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
        ConsoleListRow(id: id, scope: scope, title: title, subtitle: note, accessory: value.map { .value($0) } ?? .chevron, action: action)
            .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Console.Radius.row))
            .overlay(RoundedRectangle(cornerRadius: DS.Console.Radius.row).strokeBorder(DS.Color.separator))
            .accessibilityValue(value ?? "")
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
                .background(isChosen ? LauncherPalette.cream : .white.opacity(0.055), in: Capsule())
                .overlay(DSPill().strokeBorder(.white.opacity(isChosen ? 0 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + ", " + label)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .padTarget(id + "." + key, scope: scope, activate: choose)
        .id(id + "." + key)
    }
}

/// A switch on a card of its own: its name, what it does under it, the switch at the right. A (or left and right) flips it. A row that
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
        ConsoleToggleListRow(id: id, scope: scope, title: title, subtitle: note, isOn: isOn, enabled: enabled, flip: flip)
            .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Console.Radius.row))
            .overlay(RoundedRectangle(cornerRadius: DS.Console.Radius.row).strokeBorder(DS.Color.separator))
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
    @State private var showsDetails = false
    static var scope: String { "console.options" }
    private var scope: String { Self.scope }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var buildRunning: Bool { driver.state.builds.running }

    /// Where the focus starts on the page.
    static func firstTarget(_ game: ConsoleGame) -> String {
        if game.status == .needsBuild { return "console.options.build" }
        if let first = game.basicSettings.first { return "console.option." + first.env }
        if game.hasControllerSettings { return "console.options.gamePad" }
        if !game.advancedSettings.isEmpty { return "console.options.advanced" }
        return "console.options.details"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Console.Space.xl) {
            if game.optionSettings.isEmpty && !game.hasControllerSettings && game.mods.isEmpty && game.cheats == nil {
                Text(t("console.noOptions")).font(DS.Console.Font.body).foregroundStyle(DS.Color.textSecondary)
            }
            if game.status != .ready, let key = game.status.explanationKey {
                ConsoleNoticeCard(tone: .warning, title: t(key))
            } else if game.olderTools {
                ConsoleNoticeCard(tone: .warning, title: t("library.olderToolsHelp"))
            }
            if game.status == .needsBuild {
                ConsoleGroupedList(title: t("console.tab.build")) {
                    ConsoleListRow(id: "console.options.build", scope: scope, title: t(buildRunning ? "queue.add" : "console.build"),
                                   subtitle: t(buildRunning ? "console.gamePage.queueNote" : "console.gamePage.buildNote")) {
                        driver.buildGame(game.id, queueOnly: buildRunning)
                    }
                }
            }
            if !game.basicSettings.isEmpty {
                ConsoleGroupedList(title: t("console.options.launch")) {
                    ForEach(Array(game.basicSettings.enumerated()), id: \.element.id) { index, setting in
                        if index > 0 { ConsoleRowDivider() }
                        consoleOptionRow(setting, game: game, driver: driver, lang: lang, compact: compact, scope: scope, editing: $editing)
                    }
                }
            }
            mods
            ConsoleCheatsSection(driver: driver, game: game, lang: lang, compact: compact, scope: scope)
            ConsoleGroupedList(title: t("console.options.more")) {
                ConsoleListRow(id: "console.options.details", scope: scope, title: t("console.options.information"),
                               accessory: .expanded(showsDetails)) { showsDetails.toggle() }
                if showsDetails { details }
                if game.hasControllerSettings {
                    ConsoleRowDivider()
                    ConsoleListRow(id: "console.options.gamePad", scope: scope, title: t("console.gamePad"), subtitle: t("console.gamePad.note")) { driver.openGamePad(game.id) }
                }
                if !game.advancedSettings.isEmpty {
                    ConsoleRowDivider()
                    ConsoleListRow(id: "console.options.advanced", scope: scope, title: t("launch.advanced"),
                                   accessory: .value(String(format: t("launch.advancedCount"), game.advancedSettings.count))) { driver.openAdvanced(game.id) }
                }
                ConsoleRowDivider()
                ConsoleListRow(id: "console.options.saves", scope: scope, title: t("console.menu.saves"),
                               accessory: game.save.map { .value(t($0.status.key)) } ?? .chevron) { driver.openCloudSaves() }
                ConsoleRowDivider()
                ConsoleListRow(id: "console.options.manage", scope: scope, title: t("console.manage"), subtitle: t("console.manage.note")) { driver.openManage(game.id) }
                if game.canReset {
                    ConsoleRowDivider()
                    ConsoleListRow(id: "console.options.reset", scope: scope, title: t("console.reset.title")) { driver.askResetOptions(game.id) }
                }
            }
        }
    }

    /// Game information, opened under its row: facts that take no focus.
    @ViewBuilder private var details: some View {
        let facts: [(String, String)] = [
            (t("console.lastPlayed"), game.lastPlayed.map { ConsoleTimes.relative($0, now: driver.state.time, lang: lang) } ?? t("console.notPlayed")),
            (t("console.playTime"), game.playSeconds > 0 ? ConsoleTimes.duration(game.playSeconds, lang: lang) : t("console.notPlayed")),
            (t("console.gamePage.lastSave"), game.lastSave.map { ConsoleTimes.absolute($0, lang: lang) } ?? t("console.stopped.noSave")),
            (t("console.gamePage.version"), game.version.isEmpty ? t("console.gamePage.unknown") : game.version),
            (t("console.gamePage.platforms"), game.platforms.map { t($0.labelKey) }.joined(separator: ", ")),
            (t("console.gamePage.status"), t(game.status.labelKey)),
        ]
        ForEach(facts, id: \.0) { fact in
            ConsoleRowDivider()
            ConsoleInfoRow(title: fact.0, value: fact.1)
        }
    }

    // MARK: Mods

    @ViewBuilder private var mods: some View {
        if !game.mods.isEmpty {
            ConsoleGroupedList(title: t("launch.mods"), footer: t("launch.modsNote")) {
                ForEach(Array(game.mods.enumerated()), id: \.element.id) { index, mod in
                    if index > 0 { ConsoleRowDivider() }
                    ConsoleToggleListRow(id: "console.mod." + mod.name, scope: scope, title: mod.name, subtitle: mod.usable ? "" : t("launch.modCode"),
                                         isOn: mod.on, enabled: mod.usable) {
                        driver.setMod(gameID: game.id, name: mod.name, on: !mod.on)
                    }
                }
            }
        }
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
        // one grouped list per section, in the order the settings come
        let sections = game.advancedSettings.reduce(into: [(title: String, settings: [LaunchSetting])]()) { out, setting in
            if out.last?.title == setting.sectionTitle { out[out.count - 1].settings.append(setting) } else { out.append((setting.sectionTitle, [setting])) }
        }
        VStack(alignment: .leading, spacing: DS.Console.Space.xl) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                ConsoleGroupedList(title: section.title) {
                    ForEach(Array(section.settings.enumerated()), id: \.element.id) { index, setting in
                        if index > 0 { ConsoleRowDivider() }
                        consoleOptionRow(setting, game: game, driver: driver, lang: lang, compact: compact, scope: Self.scope, editing: $editing)
                    }
                }
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
            ConsoleSectionHeading(title: t("console.library.games"), compact: compact)
            ForEach(ConsolePref.onLibrary, id: \.self) { pref in
                ConsoleSwitchRow(id: "console.pref." + pref.rawValue, scope: scope, title: t(pref.titleKey), note: t("console.library.filterNote"),
                                 isOn: prefs[pref], compact: compact) { driver.setPref(pref, on: !prefs[pref]) }
            }
            ConsoleSectionHeading(title: t("console.manage"), compact: compact).padding(.top, 14)
            ConsoleMenuRow(id: "console.library.saves", scope: scope, symbol: "icloud", title: t(ConsoleCloudSaves.menuKey),
                           note: "", compact: compact) { driver.openCloudSaves() }
            ConsoleMenuRow(id: "console.library.supported", scope: scope, symbol: "list.bullet.rectangle", title: t("supported.title"),
                           note: "", compact: compact) { driver.openSupportedGames() }
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
            ConsoleSectionHeading(title: t("console.settings.preferences"), compact: compact)
            ConsoleMenuRow(id: "console.settings.language", scope: scope, symbol: "globe", title: t("console.language.title"),
                           note: "", value: languageName, compact: compact) { driver.openLanguage() }
            ForEach(ConsolePref.onSettings, id: \.self) { pref in
                ConsoleSwitchRow(id: "console.pref." + pref.rawValue, scope: scope, title: t(pref.titleKey), note: t(pref.noteKey), isOn: prefs[pref], compact: compact) { driver.setPref(pref, on: !prefs[pref]) }
                    .accessibilityHint(t(pref.noteKey))
            }
            ConsoleSectionHeading(title: t("console.settings.updates"), compact: compact).padding(.top, 14)
            ConsoleMenuRow(id: "console.settings.update", scope: scope, symbol: "arrow.down.app", title: t("console.update.title"),
                           note: updateNote, value: updateValue, compact: compact) { driver.appUpdateAction() }
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
            ConsoleGroupedList(title: t("cheats.title")) {
                ConsoleToggleListRow(id: "console.cheats.master", scope: scope, title: t("cheats.master"), isOn: cheats.masterOn) {
                    driver.setCheatsMaster(gameID: game.id, on: !cheats.masterOn)
                }
                ForEach(cheats.items) { cheat in
                    ConsoleRowDivider()
                    switch cheat.kind {
                    case .label:
                        Text(cheat.name).font(DS.Console.Font.footnote).foregroundStyle(DS.Color.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DS.Console.Space.l).padding(.vertical, DS.Console.Space.s)
                            .accessibilityAddTraits(.isHeader)
                    case .alwaysOn:
                        ConsoleInfoRow(title: cheat.name, value: t("cheats.alwaysOn"))
                    case .cheat:
                        ConsoleToggleListRow(id: "console.cheat." + cheat.key, scope: scope, title: cheat.name, isOn: cheat.on, enabled: cheats.masterOn) {
                            driver.setCheat(gameID: game.id, key: cheat.key, on: !cheat.on)
                        }
                    }
                }
            }
        } else if let note = game.cheats?.note, game.status == .ready {
            ConsoleGroupedList(title: t("cheats.title")) { ConsoleInfoRow(title: note, value: "") }
        }
    }


}
