import AppKit
import SwiftUI

/// A game's launch options: the settings its Mac app was packed with (dm/launcher.json), drawn as the
/// iPhone launcher draws them, grouped by section. The basic settings come first, then the game's mods, and the rest
/// under Advanced settings. A row of the list is a saved choice in the app's own preferences domain (SavedChoices.swift), which the
/// app reads at every start; Play passes only the launch overrides (what the list has no row for, the mods) as its environment.
struct LaunchOptionsView: View {
    @ObservedObject var m: BuildModel
    @ObservedObject var library: GameLibrary
    let gameID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var advancedOpen = false
    @State private var choicesRevision = 0   // bumped by a change: the values are read from the store again
    @State private var modsRevision = 0   // bumped by Refresh: the folder is read again
    @State private var frameTimesRevision = 0   // bumped by the switch and Refresh: the recordings are read again
    @EnvironmentObject private var focus: PadFocus

    private var game: LibraryGame? { library.games.first { $0.id == gameID } }
    private var settings: [LaunchSetting]? {
        game.flatMap { LaunchSetting.forMac(app: $0.appPath, titleID: $0.titleID, repo: m.repoPath, labels: m.t) }
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.t("launch.title")).font(.manrope(26, .heavy)).tracking(-0.6)
                    if let game { Text(game.name).font(.manrope(14)).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 20)
            if let settings, !settings.isEmpty, let game {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        groups(settings.filter(\.isBasic), game, all: settings)
                        modsSection(game)
                        frameTimesSection(game)
                        let advanced = settings.filter { !$0.isBasic }
                        if !advanced.isEmpty {
                            card {
                                Button { withAnimation(.easeInOut(duration: 0.18)) { advancedOpen.toggle() } } label: {
                                    HStack(spacing: 8) {
                                        Text(m.t("launch.advanced")).font(.manrope(14, .medium))
                                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                                            .rotationEffect(.degrees(advancedOpen ? 90 : 0))
                                        Spacer()
                                        Text(String(format: m.t("launch.advancedCount"), advanced.count)).font(.manrope(12)).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 18).frame(minHeight: 52).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padTarget("opt.advanced", scope: "launch", radius: 14) { withAnimation(.easeInOut(duration: 0.18)) { advancedOpen.toggle() } }
                            }
                            if advancedOpen { groups(advanced, game, all: settings) }
                        }
                    }
                    .padding(.horizontal, 30).padding(.bottom, 24)
                }
                .onChange(of: focus.focused) { id in if let id { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } } }
                }
            } else {
                Text(m.t("launch.none")).font(.manrope(14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider().opacity(0.3)
            HStack(spacing: 14) {
                Text(m.t("launch.applied")).font(.manrope(12)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                if let game, let settings, !game.launchOptions.isEmpty || (store?.hasChoices(settings) ?? false) {
                    Button(m.t("launch.reset")) { reset(settings) }
                        .buttonStyle(LauncherSecondaryButtonStyle())
                        .padTarget("opt.reset", scope: "launch") { reset(settings) }
                }
                Button { dismiss() } label: {
                    Text(m.t("launch.done")).font(.manrope(13.5, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(LauncherPalette.cream, in: Capsule())
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                .padTarget("opt.done", scope: "launch", radius: 20) { dismiss() }
            }
            .padding(.horizontal, 30).padding(.vertical, 16)
        }
        .padScope("launch", focus)
        .onAppear { library.migrateLaunchOptions() }
        .frame(width: 600, height: 700)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
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
        Text(text).font(.manrope(15, .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
    }

    private var divider: some View { Divider().opacity(0.25).padding(.leading, 18) }

    /// The translated heading of a section this launcher knows; a section it does not know is drawn under its own name.
    private func sectionName(_ section: String) -> String {
        let key = "launch.section." + section
        let name = m.t(key)
        return name == key ? section : name
    }

    private func set(_ s: LaunchSetting, _ value: String) {
        if s.storeBacked { store?.set(s, value) } else { library.setLaunchOption(s, value, for: gameID) }
        choicesRevision += 1
    }

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
                Text(s.label).font(.manrope(14, .medium))
                if let full = s.kind == "range" ? s.pixels(scale: 1, docked: isDocked) : nil {
                    // The render scale in pixels: the share of the game's own size in the console mode chosen
                    Text(String(format: m.t(isDocked ? "launch.scaleOfDocked" : "launch.scaleOfHandheld"), Int(((Double(value) ?? 1) * 100).rounded()), full))
                        .font(.manrope(12)).foregroundStyle(.secondary)
                } else if !s.note.isEmpty {
                    Text(s.note).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control(s, value, pixels: pixels).frame(width: LaunchControl.width, alignment: .trailing)
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

    /// The setting's control, filling the column every row shares (a toggle keeps its size at the column's right edge).
    @ViewBuilder private func control(_ s: LaunchSetting, _ value: String, pixels: String?) -> some View {
        HStack(spacing: 10) {
            switch s.kind {
            case "choice":
                let options = (s.options ?? []).map { (value: $0[0], label: $0.count > 1 ? $0[1] : $0[0]) }
                if options.count <= 3 {
                    LauncherSegmented(options: options, selection: value) { set(s, $0) }
                } else {
                    LauncherMenuPicker(options: options, selection: value, fill: true) { set(s, $0) }
                }
            case "range":
                let lo = s.min ?? 0, hi = s.max ?? 1
                LauncherSlider(value: Double(value) ?? Double(s.def) ?? lo, range: lo...hi, step: s.step ?? 0.05) {
                    set(s, String(format: "%.2f", $0))
                }
                Text(pixels ?? "\(Int(((Double(value) ?? 0) * 100).rounded()))%")
                    .font(.manrope(13, .semibold)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: pixels == nil ? 44 : 72, alignment: .trailing)
            default:
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { value == s.onValue }, set: { set(s, $0 ? s.onValue : s.offValue) }))
                    .labelsHidden().toggleStyle(LauncherSwitchStyle())
            }
        }
    }

    // ---- mods ----

    /// The game's mods folder as switches. A mod changes the files the game reads, saves included: the note says so, and
    /// Show saves opens the folder to back them up before switching one.
    @ViewBuilder private func modsSection(_ game: LibraryGame) -> some View {
        let list = mods
        VStack(alignment: .leading, spacing: 10) {
            heading(m.t("launch.mods"))
            card {
                if list.isEmpty {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.t("launch.modsNone")).font(.manrope(14, .medium))
                            Text(m.t("launch.modsHow")).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                                    Text(m.t("launch.modCode")).font(.manrope(12)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 12)
                            Toggle("", isOn: Binding(get: { mod.usable && game.mods.contains(mod.name) },
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
                    Button(m.t("launch.modsRefresh")) { modsRevision += 1 }
                        .padTarget("mods.refresh", scope: "launch") { modsRevision += 1 }
                    Button(m.t("launch.modsOpen")) { openModsFolder() }
                        .padTarget("mods.open", scope: "launch") { openModsFolder() }
                    Button(m.t("launch.savesShow")) { showSaves(game) }
                        .padTarget("mods.saves", scope: "launch") { showSaves(game) }
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            Text(m.t(list.count > 1 ? "launch.modsNoteOrder" : "launch.modsNote")).font(.manrope(12)).foregroundStyle(.secondary)
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
            heading(m.t("launch.frameTimes"))
            card {
                HStack(spacing: 16) {
                    Text(m.t("launch.frameTimesRecord")).font(.manrope(14, .medium))
                    Spacer(minLength: 12)
                    Toggle("", isOn: on).labelsHidden().toggleStyle(LauncherSwitchStyle())
                }
                .padding(.horizontal, 18).padding(.vertical, 13).frame(minHeight: 52)
                .padTarget("frameTimes.record", scope: "launch", radius: 10,
                           activate: { on.wrappedValue.toggle() }, adjust: { _ in on.wrappedValue.toggle() })
                divider
                if recent.isEmpty {
                    Text(m.t("launch.frameTimesNone")).font(.manrope(13)).foregroundStyle(.secondary)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                    divider
                }
                ForEach(recent, id: \.self) { file in
                    FrameTimesRecordingView(file: file, t: m.t)
                    divider
                }
                HStack(spacing: 10) {
                    Spacer()
                    Button(m.t("launch.modsRefresh")) { frameTimesRevision += 1 }
                        .padTarget("frameTimes.refresh", scope: "launch") { frameTimesRevision += 1 }
                    Button(m.t("launch.frameTimesOpen")) { openFolder(folder) }
                        .padTarget("frameTimes.open", scope: "launch") { openFolder(folder) }
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            Text(m.t("launch.frameTimesNote")).font(.manrope(12)).foregroundStyle(.secondary)
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
