import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// A game's launch options: the settings its Mac app was packed with (dm/launcher.json), drawn as the
/// iPhone launcher draws them, grouped by section. The basic settings come first, then the game's mods, and the rest
/// under Advanced settings. A row of the list is a saved choice in the app's own preferences domain (SavedChoices.swift), which the
/// app reads at every start; Play passes only the launch overrides (what the list has no row for, the mods) as its environment.
struct LaunchOptionsView: View {
    @ObservedObject var m: BuildStore
    @EnvironmentObject var loc: Localizer
    @ObservedObject var library: GameLibrary
    let gameID: UUID
    var globalControls: ControlLayout? = nil
    @State private var showControllerMapping = false
    var controllerMappingPresentation: Binding<Bool>? = nil
    private var mappingPresentation: Binding<Bool> { controllerMappingPresentation ?? $showControllerMapping }
    @Environment(\.dismiss) private var dismiss
    @State private var advancedOpen = false
    @State private var category: LaunchCategory = .game
    @State private var defaultsSaved = false   // Use for new games ran: the note says so until the sheet closes
    @State private var askingTested = false   // Use tested values asks first (#453)
    /// Build this game…: the launcher closes the sheet and opens the Builds page with this game's form (nil in a test).
    var onBuild: (LibraryGame) -> Void = { _ in }
    /// The cheats and the saves have sheets of their own: the launcher closes this one and opens them (nil: the row does nothing).
    var openCheats: ((UUID) -> Void)? = nil
    var openSaves: ((UUID) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choicesRevision = 0   // bumped by a change: the values are read from the store again
    @State private var modsRevision = 0   // bumped by Refresh: the folder is read again
    @State private var frameTimesRevision = 0   // bumped by the switch and Refresh: the recordings are read again
    @EnvironmentObject private var focus: PadFocus
    @EnvironmentObject private var saveSettings: SaveSettingsStore   // the global setup and this game's own choices (SaveLocation.swift)
    @EnvironmentObject private var players: PlayerProfileStore

    private var game: LibraryGame? { library.games.first { $0.id == gameID } }
    private var settings: [LaunchSetting]? {
        game.flatMap { LaunchSetting.forMac(app: $0.appPath, titleID: $0.titleID, repo: m.repo.path, labels: loc.t) }
    }
    private var store: SavedChoices? { game.map { SavedChoices(app: $0.appPath, titleID: $0.titleID) } }
    /// A saved choice for a row of the list, else the tested default; what only this launcher has comes from the library.
    private func value(_ s: LaunchSetting, _ game: LibraryGame) -> String {
        _ = choicesRevision
        return s.storeBacked ? (store?.current(s) ?? s.def) : game.launchValue(s)
    }
    private var modsFolder: URL? { game.map { GameMod.folder(for: $0, library: library.folder) } }
    private var mods: [GameMod] {
        _ = modsRevision
        guard let game, let modsFolder else { return [] }
        return GameMod.list(in: modsFolder, titleID: game.titleID)
    }

    var body: some View {
        let _ = choicesRevision
        let destination = game.map(LaunchDestination.init) ?? .none
        let shown = destination.categories.contains(category) ? category : (destination.categories.first ?? .game)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t("launch.title")).font(.manrope(26, .heavy)).tracking(-0.6)
                    if let game { Text(game.displayName(loc.lang)).font(.manrope(14)).foregroundStyle(LauncherPalette.secondaryText) }
                }
                Spacer()
                // One action at the top while a setting differs from its tested value: it asks first and names how many change (#453)
                if destination == .mac, let game, let settings, !Self.changed(settings, value: { value($0, game) }).isEmpty {
                    Button(loc.t("launch.useTested")) { askingTested = true }
                        .buttonStyle(LauncherSecondaryButtonStyle())
                        .padTarget("opt.useTested", scope: "launch") { askingTested = true }
                }
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 20)
            // The selector stays where it is while the content below it scrolls
            if !destination.categories.isEmpty {
                LauncherSegmented(options: destination.categories.map { ($0.rawValue, loc.t($0.labelKey)) }, selection: shown.rawValue, size: 13, semibold: true) {
                    category = LaunchCategory(rawValue: $0) ?? .game
                }
                .accessibilityElement(children: .contain).accessibilityLabel(loc.t("launch.title"))
                .padTarget("opt.category", scope: "launch", radius: 17, activate: { moveCategory(1, in: destination) }, adjust: { moveCategory($0, in: destination) })
                .padding(.horizontal, 30).padding(.bottom, 16)
            }
            if let game {
                if destination == .none { noBuild(game) } else { content(game, destination: destination, category: shown) }
            }
            Divider().opacity(0.3)
            footer(game, destination: destination, category: shown)
        }
        .padScope("launch", focus)
        .onAppear { library.migrateLaunchOptions() }
        .onChange(of: mappingPresentation.wrappedValue) { open in
            // The launcher owns routing when embedded, while standalone sheets keep the same scope behavior.
            if controllerMappingPresentation == nil { focus.scope = open ? "controls" : "launch" }
        }
        .sheet(isPresented: $askingTested) {
            if let game, let settings {
                let count = Self.changed(settings, value: { value($0, game) }).count
                LauncherConfirmSheet(title: loc.t("launch.useTested"), subtitle: game.displayName(loc.lang),
                                     note: count == 1 ? loc.t("launch.useTestedOne") : String(format: loc.t("launch.useTestedMany"), count),
                                     cancelTitle: loc.t("saves.cancel"), confirmTitle: loc.t("launch.useTested"), scope: "tested",
                                     cancel: { askingTested = false }, confirm: { askingTested = false; reset(settings) })
                    .environmentObject(focus).environmentObject(loc)
            }
        }
        .onChange(of: askingTested) { open in focus.scope = open ? "tested" : "launch" }
        .sheet(isPresented: mappingPresentation) {
            if let game {
                GameControllerMappingView(game: game, globalControls: globalControls)
                    .environmentObject(focus).environmentObject(loc).launcherDropdownHost()
            }
        }
        .frame(width: LauncherSheet.width, height: LauncherSheet.maxHeight(screen: NSScreen.main?.visibleFrame.height ?? 800))
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .launcherAppearance()
        .tint(LauncherPalette.accent)
    }

    private func moveCategory(_ by: Int, in destination: LaunchDestination) {
        let all = destination.categories
        guard !all.isEmpty else { return }
        let at = all.firstIndex(of: category) ?? 0
        category = all[(at + by + all.count) % all.count]
    }

    /// A game with no build for any destination: one explanation, and Build this game… with the game's form filled in.
    private func noBuild(_ game: LibraryGame) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(loc.t("launch.noBuild")).font(.manrope(14)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
            Button(loc.t("library.setUpBuild")) { dismiss(); onBuild(game) }
                .buttonStyle(LauncherSecondaryButtonStyle()).launcherRowControls()
                .disabled(m.running || game.inputs["base", default: []].isEmpty)
                .padTarget("opt.build", scope: "launch") { if !m.running { dismiss(); onBuild(game) } }
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func content(_ game: LibraryGame, destination: LaunchDestination, category: LaunchCategory) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch category {
                    case .game, .performance: settingsCategory(game, category)
                    case .mods: modsAndCheats(game, destination: destination)
                    case .saves: saves(game, destination: destination)
                    }
                }
                .padding(.horizontal, 30).padding(.bottom, 24)
            }
            .id(category)   // each part opens at its top
            .onChange(of: focus.focused) { id in if let id { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } } }
        }
    }

    /// Game and Performance: the rows of the game's list that belong to the part, basic first, the rest under Advanced settings.
    @ViewBuilder private func settingsCategory(_ game: LibraryGame, _ category: LaunchCategory) -> some View {
        if category == .game, SavedChoices.appReadsControllerMappings(app: game.appPath) {
            Button(loc.t("controls.mapping")) { mappingPresentation.wrappedValue = true }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .padTarget("opt.controllerMapping", scope: "launch") { mappingPresentation.wrappedValue = true }
        }
        if let settings, !settings.isEmpty {
            let mine = settings.filter { LaunchCategory.of($0) == category }
            if category == .performance, let note = ResolutionNote.text(settings, shown: { $0.isShown(in: settings) { value($0, game) } }, t: loc.t) { resolutionNote(note) }
            groups(mine.filter(\.isBasic), game, all: settings)
            if category == .performance { frameTimesSection(game) }
            let advanced = mine.filter { !$0.isBasic }
            if !advanced.isEmpty {
                card {
                    Button { withAnimation(LauncherMotion.animation(.easeInOut(duration: 0.18), reduceMotion: reduceMotion)) { advancedOpen.toggle() } } label: {
                        HStack(spacing: 8) {
                            Text(loc.t("launch.advanced")).font(.manrope(14, .medium))
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(LauncherPalette.secondaryText)
                                .rotationEffect(.degrees(advancedOpen ? 90 : 0))
                            Spacer()
                            Text(String(format: loc.t("launch.advancedCount"), advanced.count)).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText)
                        }
                        .padding(.horizontal, 18).frame(minHeight: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padTarget("opt.advanced", scope: "launch", radius: 14) { withAnimation(LauncherMotion.animation(.easeInOut(duration: 0.18), reduceMotion: reduceMotion)) { advancedOpen.toggle() } }
                }
                if advancedOpen { groups(advanced, game, all: settings) }
            }
        } else if category == .game {
            Text(loc.t("launch.none")).font(.manrope(14)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        if category == .performance, settings?.contains(where: { LaunchCategory.of($0) == .performance }) != true {
            Text(loc.t("launch.noPerformance")).font(.manrope(14)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Mods (Mac only: they replace files of the Mac app) and the cheats, which have their own sheet.
    @ViewBuilder private func modsAndCheats(_ game: LibraryGame, destination: LaunchDestination) -> some View {
        if destination == .mac { modsSection(game) }
        VStack(alignment: .leading, spacing: 10) {
            heading(loc.t("cheats.menu"))
            card {
                actionRow(title: loc.t("cheats.menu"), detail: loc.t(game.cheatsNeedIOSNote ? "launch.cheatsIOSNote" : "launch.cheatsNote"),
                          button: loc.t("launch.open"), id: "opt.cheats") { openCheats?(game.id) }
            }
        }
    }

    /// Saves: the cloud state of a Mac game and the sheet that imports, exports and shows the backups.
    @ViewBuilder private func saves(_ game: LibraryGame, destination: LaunchDestination) -> some View {
        GameSavesSection(game: game, settings: saveSettings, players: players)   // first: the save files, import and export
        if destination == .mac { CloudSavesCard(game: game, overrides: saveSettings) }
        VStack(alignment: .leading, spacing: 10) {
            heading(loc.t("saves.menu"))
            card {
                actionRow(title: loc.t("saves.menu"), detail: loc.t("launch.savesNote"), button: loc.t("launch.open"), id: "opt.saves") { openSaves?(game.id) }
            }
        }
    }

    private func actionRow(title: String, detail: String, button: String, id: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.manrope(14, .medium))
                Text(detail).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(button, action: action).buttonStyle(LauncherSecondaryButtonStyle()).launcherRowControls()
                .accessibilityLabel(title)
                .padTarget(id, scope: "launch", activate: action)
        }
        .padding(.horizontal, 18).padding(.vertical, 13).frame(minHeight: 52)
    }

    /// Use for new games and Done (Use tested values is at the top of the sheet). Use for new games copies this game's language, display and rumble into the defaults other games start from.
    private func footer(_ game: LibraryGame?, destination: LaunchDestination, category: LaunchCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("launch.applied")).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText).lineLimit(2)
            HStack(spacing: 12) {
                if destination == .mac, category == .game {
                    Text(defaultsSaved ? loc.t("launch.useForNewDone") : loc.t("defaults.note"))
                        .font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText).lineLimit(2)
                }
                Spacer(minLength: 8)
                if destination == .mac, let game, let settings {
                    if category == .game {
                        Button(loc.t("launch.useForNew")) { useForNewGames(game, settings) }
                            .buttonStyle(LauncherSecondaryButtonStyle())
                            .launcherRowControls()
                            .accessibilityLabel(loc.t("launch.useForNewLabel"))
                            .padTarget("opt.useForNew", scope: "launch") { useForNewGames(game, settings) }
                    }
                }
                Button { dismiss() } label: {
                    Text(loc.t("launch.done")).font(.manrope(13.5, .bold))
                        .padding(.horizontal, 22).padding(.vertical, 9)
                }
                .buttonStyle(LauncherActionButtonStyle()).keyboardShortcut(.defaultAction)
                .padTarget("opt.done", scope: "launch", radius: 20) { dismiss() }
            }
        }
        .padding(.horizontal, 30).padding(.vertical, 16)
    }

    /// This game's language, display and rumble become what a game added from now on starts with (PersonalDefaults). Nothing changes in
    /// the games already in the library, this one included.
    private func useForNewGames(_ game: LibraryGame, _ settings: [LaunchSetting]) {
        var personal = PersonalDefaults.load()
        for s in settings where PersonalDefaults.envs.contains(s.env) {
            let current = value(s, game)
            switch s.env {
            case "DM_LANG": personal.set(current, for: "DM_LANG")
            case "DM_FULLSCREEN": personal.set(current == "1" ? "1" : "", for: "DM_FULLSCREEN")
            case "DM_RUMBLE": personal.set(current == s.offValue ? "0" : "", for: "DM_RUMBLE")
            default: break
            }
        }
        personal.save()
        defaultsSaved = true
    }

    // ---- groups of settings ----

    @ViewBuilder private func groups(_ rows: [LaunchSetting], _ game: LibraryGame, all: [LaunchSetting]) -> some View {
        // A sub-setting (needs) is drawn only while its parent has the value; a section left empty is not drawn
        let shown = rows.filter { $0.isShown(in: all) { value($0, game) } }
        ForEach(LaunchSetting.orderedSections(shown), id: \.self) { section in
            let inSection = shown.filter { $0.sectionTitle == section }
            VStack(alignment: .leading, spacing: 10) {
                heading(sectionName(section))
                card {
                    ForEach(inSection) { s in
                        row(s, game, all: all)
                        if s.id != inSection.last?.id { divider }
                    }
                }
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.manrope(15, .semibold)).foregroundStyle(LauncherPalette.secondaryText).padding(.leading, 2)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
    }

    private var divider: some View { Divider().opacity(0.25).padding(.leading, 18) }

    /// Why there is no resolution row (#574), above the settings, where the player looks for one.
    private func resolutionNote(_ note: ResolutionNote.Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(LauncherPalette.secondaryText)
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title).font(.manrope(14, .medium))
                if let detail = note.detail {
                    Text(detail).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
        .accessibilityElement(children: .combine)
    }

    /// The translated heading of a section this launcher knows; a section it does not know is drawn under its own name.
    private func sectionName(_ section: String) -> String {
        let key = "launch.section." + section
        let name = loc.t(key)
        return name == key ? section : name
    }

    /// A setting's text in the launcher's language when this launcher has it (a game's launcher.json is in English), else the list's own.
    private func text(_ key: String, _ fallback: String) -> String {
        guard loc.lang != .en else { return fallback }
        let translated = loc.t(key)
        return translated == key ? fallback : translated
    }
    private func label(_ s: LaunchSetting) -> String { text("launch.set." + s.env, s.label) }
    private func note(_ s: LaunchSetting) -> String { s.note.isEmpty ? "" : text("launch.set." + s.env + ".note", s.note) }

    private func set(_ s: LaunchSetting, _ value: String) {
        if s.storeBacked { store?.set(s, value) } else { library.setLaunchOption(s, value, for: gameID) }
        choicesRevision += 1
    }

    /// The settings whose value differs from the game profile's tested default, hidden sub-settings included: what Use tested values
    /// changes (#453). The same test as each row's dot.
    static func changed(_ settings: [LaunchSetting], value: (LaunchSetting) -> String) -> [LaunchSetting] {
        settings.filter { !$0.isDefault(value($0)) }
    }

    /// Use tested values: the per-setting reset of every choice, so each setting takes its tested default again.
    private func reset(_ settings: [LaunchSetting]) {
        store?.reset(settings)
        library.resetLaunchOptions(for: gameID)
        choicesRevision += 1
    }

    /// Docked unless the console mode chosen is handheld (DM_OPMODE 0), for the render scale's pixels.
    private func docked(_ game: LibraryGame, _ all: [LaunchSetting]) -> Bool {
        all.first { $0.env == "DM_OPMODE" }.map { value($0, game) != "0" } ?? true
    }

    @ViewBuilder private func row(_ s: LaunchSetting, _ game: LibraryGame, all: [LaunchSetting]) -> some View {
        let value = self.value(s, game)
        let isDocked = docked(game, all)
        let pixels = s.kind == "range" ? s.pixels(scale: Double(value) ?? 1, docked: isDocked) : nil
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                ChangedLabel(text: label(s), changed: !s.isDefault(value), hint: loc.t("launch.changedDot"))
                if let full = s.kind == "range" ? s.pixels(scale: 1, docked: isDocked) : nil {
                    // The render scale in pixels: the share of the game's own size in the console mode chosen
                    Text(String(format: loc.t(isDocked ? "launch.scaleOfDocked" : "launch.scaleOfHandheld"), Int(((Double(value) ?? 1) * 100).rounded()), full))
                        .font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText)
                } else if !note(s).isEmpty {
                    Text(note(s)).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control(s, value, pixels: pixels).launcherRowControls().frame(width: LaunchControl.width, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .frame(minHeight: 52)
        .padTarget("opt." + s.env, scope: "launch", radius: 10, activate: { step(s, value, 1) }, adjust: { step(s, value, $0) })
    }

    /// A controller's step through a setting: the next or previous choice (wrapping), the slider by its step, the switch flipped.
    private func step(_ s: LaunchSetting, _ value: String, _ by: Int) {
        switch s.kind {
        case "choice":
            let values = (s.options ?? []).map { $0[0] }
            guard !values.isEmpty else { return }
            let at = values.firstIndex(of: value) ?? 0
            set(s, values[(at + by + values.count) % values.count])
        case "range":
            let lo = s.min ?? 0, hi = s.max ?? 1, st = s.step ?? 0.05
            let next = min(max(((Double(value) ?? lo) / st).rounded() * st + Double(by) * st, lo), hi)
            set(s, String(format: "%.2f", next))
        default:
            set(s, value == s.onValue ? s.offValue : s.onValue)
        }
    }

    /// The setting's control in the column every row shares: a segmented choice or a slider fills it, a dropdown is LauncherControl.width wide
    /// at its right edge, and a toggle keeps its size there. A slider ends in a reset arrow while its value differs from the
    /// tested default: a slider is hard to put back on the exact default by hand. Its slot is always there, so the slider keeps its length.
    @ViewBuilder private func control(_ s: LaunchSetting, _ value: String, pixels: String?) -> some View {
        HStack(spacing: 10) {
            switch s.kind {
            case "choice":
                let options = (s.options ?? []).map { (value: $0[0], label: text("launch.opt.\(s.env).\($0[0])", $0.count > 1 ? $0[1] : $0[0])) }
                if LaunchControl.isSegmented(env: s.env, labels: options.map(\.label)) {
                    LauncherSegmented(options: options, selection: value) { set(s, $0) }
                } else {
                    LauncherDropdown(options: options, selection: value, label: label(s), fill: true) { set(s, $0) }
                }
            case "range":
                let lo = s.min ?? 0, hi = s.max ?? 1
                LauncherSlider(value: Double(value) ?? Double(s.def) ?? lo, range: lo...hi, step: s.step ?? 0.05) {
                    set(s, String(format: "%.2f", $0))
                }
                .accessibilityLabel(label(s))
                .accessibilityValue(pixels ?? "\(Int(((Double(value) ?? 0) * 100).rounded()))%")
                Text(pixels ?? "\(Int(((Double(value) ?? 0) * 100).rounded()))%")
                    .font(.manrope(13, .semibold)).monospacedDigit().foregroundStyle(LauncherPalette.secondaryText)
                    .frame(width: LaunchControl.valueWidth, alignment: .trailing)
                ZStack {
                    if Double(value) != Double(s.def) {
                        Button { set(s, s.def) } label: {
                            Image(systemName: "arrow.uturn.backward.circle").font(.system(size: 15))
                                .foregroundStyle(LauncherPalette.secondaryText).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(loc.t("launch.rowReset"))
                        .accessibilityLabel(Self.resetLabel(loc, label(s)))
                    }
                }
                .frame(width: 16)
            default:
                Spacer(minLength: 0)
                Toggle(label(s), isOn: Binding(get: { value == s.onValue }, set: { set(s, $0 ? s.onValue : s.offValue) }))
                    .labelsHidden().toggleStyle(LauncherSwitchStyle())
            }
        }
    }

    /// What VoiceOver says for a row's reset button: the action and the setting it resets.
    @MainActor static func resetLabel(_ loc: Localizer, _ setting: String) -> String {
        loc.t("launch.rowReset") + ": " + setting
    }

    // ---- mods ----

    /// The game's mods folder as switches. A mod changes the files the game reads, saves included: the note says so, and
    /// Show saves opens the folder to back them up before switching one.
    @ViewBuilder private func modsSection(_ game: LibraryGame) -> some View {
        let list = mods
        VStack(alignment: .leading, spacing: 10) {
            heading(loc.t("launch.mods"))
            card {
                if list.isEmpty {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(loc.t("launch.modsNone")).font(.manrope(14, .medium))
                            Text(loc.t("launch.modsHow")).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 18).padding(.vertical, 13)
                } else {
                    ForEach(list) { mod in
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mod.name).font(.manrope(14, .medium)).lineLimit(1)
                                if !mod.usable {
                                    Text(loc.t("launch.modCode")).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText)
                                }
                            }
                            Spacer(minLength: 12)
                            Toggle(mod.name, isOn: Binding(get: { mod.usable && game.mods.contains(mod.name) },
                                                     set: { library.setMod(mod.name, on: $0, for: gameID) }))
                                .labelsHidden().toggleStyle(LauncherSwitchStyle()).disabled(!mod.usable)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 13).frame(minHeight: 52)
                        .padTarget("mod." + mod.name, scope: "launch", radius: 10,
                                   activate: { if mod.usable { library.setMod(mod.name, on: !game.mods.contains(mod.name), for: gameID) } },
                                   adjust: { _ in if mod.usable { library.setMod(mod.name, on: !game.mods.contains(mod.name), for: gameID) } })
                        divider
                    }
                }
                if list.isEmpty { divider }
                HStack(spacing: 10) {
                    Spacer()
                    Button(loc.t("launch.modsRefresh")) { modsRevision += 1 }
                        .padTarget("mods.refresh", scope: "launch") { modsRevision += 1 }
                    Button(loc.t("launch.modsOpen")) { openModsFolder() }
                        .padTarget("mods.open", scope: "launch") { openModsFolder() }
                    Button(loc.t("launch.savesShow")) { showSaves(game) }
                        .padTarget("mods.saves", scope: "launch") { showSaves(game) }
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            Text(loc.t(list.count > 1 ? "launch.modsNoteOrder" : "launch.modsNote")).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText)
                .padding(.leading, 2).fixedSize(horizontal: false, vertical: true)
        }
    }

    // ---- frame times ----

    /// Recording frame times (FrameTimes.swift): the switch for the next Play, and the last recordings with their numbers.
    @ViewBuilder private func frameTimesSection(_ game: LibraryGame) -> some View {
        let _ = frameTimesRevision
        let folder = FrameTimes.folder(titleID: game.titleID, library: library.folder)
        let recent = Array(FrameTimes.recordings(in: folder).prefix(3))
        let on = Binding(get: { _ = frameTimesRevision; return FrameTimes.enabled(titleID: game.titleID) },
                         set: { FrameTimes.setEnabled($0, titleID: game.titleID); frameTimesRevision += 1 })
        VStack(alignment: .leading, spacing: 10) {
            heading(loc.t("launch.frameTimes"))
            card {
                HStack(spacing: 16) {
                    Text(loc.t("launch.frameTimesRecord")).font(.manrope(14, .medium))
                    Spacer(minLength: 12)
                    Toggle(loc.t("launch.frameTimesRecord"), isOn: on).labelsHidden().toggleStyle(LauncherSwitchStyle())
                }
                .padding(.horizontal, 18).padding(.vertical, 13).frame(minHeight: 52)
                .padTarget("frameTimes.record", scope: "launch", radius: 10,
                           activate: { on.wrappedValue.toggle() }, adjust: { _ in on.wrappedValue.toggle() })
                divider
                if recent.isEmpty {
                    Text(loc.t("launch.frameTimesNone")).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                    divider
                }
                ForEach(recent, id: \.self) { file in
                    FrameTimesRecordingView(file: file, t: loc.t)
                    divider
                }
                HStack(spacing: 10) {
                    Spacer()
                    Button(loc.t("launch.modsRefresh")) { frameTimesRevision += 1 }
                        .padTarget("frameTimes.refresh", scope: "launch") { frameTimesRevision += 1 }
                    Button(loc.t("launch.frameTimesOpen")) { openFolder(folder) }
                        .padTarget("frameTimes.open", scope: "launch") { openFolder(folder) }
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            Text(loc.t("launch.frameTimesNote")).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText)
                .padding(.leading, 2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openFolder(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func openModsFolder() {
        guard let folder = modsFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
        modsRevision += 1
    }

    /// The app's saves (dm/mac/launcher.c: ~/Library/Application Support/nxnative/<title ID>/), to back them up.
    private func showSaves(_ game: LibraryGame) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nxnative").appendingPathComponent(game.titleID)
        let save = support.appendingPathComponent("save")
        let target = FileManager.default.fileExists(atPath: save.path) ? save : support
        if FileManager.default.fileExists(atPath: target.path) { NSWorkspace.shared.activateFileViewerSelecting([target]) }
        else { NSWorkspace.shared.open(support.deletingLastPathComponent()) }
    }
}

/// The note of a game whose build has no render scale row (#574). The row comes only with a render scale hook in the engine
/// for that game (today Breath of the Wild and Tears of the Kingdom, #534), so a player of another game looks for a resolution
/// setting and finds none. The note says so and names the rows of the sheet that come closest, Console mode and Upscaling,
/// with their labels as the sheet shows them and where they are when they sit under Advanced settings.
enum ResolutionNote {
    struct Text: Equatable {
        let title: String
        let detail: String?
    }

    /// The rows that come closest to a resolution setting, in the order the note names them.
    static let closest = ["DM_OPMODE", "DM_PRESENT_UPSCALE"]

    /// nil when the list has a render scale row (shown or not: the build has one), or no row at all. `shown` is the sheet's own test
    /// for a sub-setting (needs), so the note names only rows the player can find.
    static func text(_ settings: [LaunchSetting], shown: (LaunchSetting) -> Bool = { _ in true }, t: (String) -> String) -> Text? {
        guard !settings.isEmpty, !settings.contains(where: { $0.env == "DM_RENDER_SCALE" }) else { return nil }
        let names = closest.compactMap { env in settings.first { $0.env == env && shown($0) } }
            .map { $0.isBasic ? $0.label : String(format: t("launch.noResolution.advanced"), $0.label) }
        let detail: String?
        switch names.count {
        case 0: detail = nil
        case 1: detail = String(format: t("launch.noResolution.one"), names[0])
        default: detail = String(format: t("launch.noResolution.two"), names[0], names[1])
        }
        return Text(title: t("launch.noResolution"), detail: detail)
    }
}

/// A setting's label, with a small amber dot before it while its value differs from the game profile's tested default (#453). VoiceOver
/// reads the dot as "Changed from the tested value" after the label.
struct ChangedLabel: View {
    let text: String
    let changed: Bool
    let hint: String
    var body: some View {
        HStack(spacing: 7) {
            if changed {
                Circle().fill(LauncherPalette.building).frame(width: 6, height: 6)
                    .help(hint)
                    .accessibilityLabel(hint)
            }
            Text(text).font(.manrope(14, .medium))
        }
        .accessibilityElement(children: .combine)
    }
}
