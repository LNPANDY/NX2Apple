import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The Cloud saves section of a game's settings (#499): the folder the game syncs through and where that was set, Choose
/// folder and Turn off, a notice when the folder cannot be the one another device uses, and what the last session's log says
/// about the sync, with the time of that session. The state is only what the log says: the launcher does not watch a running game.
struct CloudSavesCard: View {
    let game: LibraryGame
    /// Visual QA: a store with example values and a last session, read instead of the files.
    var saves: GameCloudSaves?
    /// The global setup and this game's own cloud choice (#864). Without it the card works on the game's env.txt and preferences only, as before.
    var overrides: SaveSettingsStore?
    var preview: (check: CloudSaveSync.FolderCheck?, last: (state: CloudSaveSync.LogState?, date: Date?)?)?
    var chooseFolder: (URL?) -> URL? = CloudSavesCard.openPanel
    var home = NSHomeDirectory()
    @EnvironmentObject var loc: Localizer
    @State private var revision = 0
    @State private var last: (state: CloudSaveSync.LogState?, date: Date?)?? = nil
    @State private var problem: String?

    /// What counts for this game: its own choice here, else what the game has, else the setup for every game.
    private var shownSetting: CloudSaveSync.Setting {
        let own = store.setting
        guard let overrides else { return own }
        let effective = SaveLocations.effectiveCloud(global: overrides.global, game: overrides.game(game.titleID), own: own)
        let source: CloudSaveSync.Source = effective.source == .game && overrides.game(game.titleID).cloud != nil ? .preference : own.source
        return CloudSaveSync.Setting(source: effective.source == .global ? .none : source, value: effective.folder ?? (effective.isOn ? nil : "0"),
                                     folder: effective.folder.flatMap { CloudSaveSync.folder(for: $0, home: home) })
    }

    private var inheritsGlobal: Bool {
        guard let overrides else { return false }
        return SaveLocations.effectiveCloud(global: overrides.global, game: overrides.game(game.titleID), own: store.setting).source == .global
    }

    private var store: GameCloudSaves { saves ?? GameCloudSaves(titleID: game.titleID, appPath: game.appPath) }
    static let attention = Color(red: 1, green: 0.78, blue: 0.24)

    var body: some View {
        let _ = revision
        let _ = overrides?.revision
        let setting = shownSetting
        let check = preview?.check ?? setting.folder.map { CloudSaveSync.check(folder: $0, titleID: game.titleID) }
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("cloud.title")).font(.manrope(15, .semibold)).foregroundStyle(LauncherPalette.secondaryText).padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) {
                folderRow(setting)
                if let check, let notice = notice(check) {
                    Divider().opacity(0.25).padding(.leading, 18)
                    notice
                }
                Divider().opacity(0.25).padding(.leading, 18)
                lastRow
            }
            .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
            Text(problem ?? loc.t(setting.isOn ? "cloud.applies" : "cloud.offNote")).font(.manrope(12))
                .foregroundStyle(problem == nil ? .secondary : Self.attention)
                .padding(.leading, 2).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: readLog)
    }

    // ---- the folder ----

    private func folderRow(_ setting: CloudSaveSync.Setting) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: setting.isOn ? "icloud" : "icloud.slash").font(.system(size: 17, weight: .medium))
                .foregroundStyle(setting.isOn ? LauncherPalette.accent : .secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(setting.folder.map(Self.name) ?? loc.t("cloud.off")).font(.manrope(14, .medium)).lineLimit(1)
                if let folder = setting.folder {
                    Text(Self.shown(folder, home: home)).font(.manrope(11.5)).foregroundStyle(LauncherPalette.secondaryText).lineLimit(1).truncationMode(.middle)
                        .help(folder)
                }
                if let source = sourceText(setting) { Text(source).font(.manrope(11.5)).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 12)
            if setting.isOn {
                Button(loc.t("cloud.turnOff")) { change { try turnOff() } }
                    .padTarget("cloud.off", scope: "launch") { change { try turnOff() } }
            }
            if let overrides, overrides.game(game.titleID).cloud != nil {   // back to the setup for every game
                Button(loc.t("savesloc.useGlobal")) { change { try useGlobal() } }
                    .padTarget("cloud.global", scope: "launch") { change { try useGlobal() } }
            }
            Button(loc.t("cloud.choose")) { choose(from: setting.folder) }
                .padTarget("cloud.choose", scope: "launch") { choose(from: setting.folder) }
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
        .padding(.horizontal, 18).padding(.vertical, 13).frame(minHeight: 56)
    }

    private func sourceText(_ setting: CloudSaveSync.Setting) -> String? {
        switch setting.source {
        case .playerEnv: return loc.t("cloud.fromPlayerEnv")
        case .appEnv: return loc.t("cloud.fromAppEnv")
        case .preference, .none:
            guard overrides != nil else { return nil }
            return loc.t(inheritsGlobal ? "savesloc.cloudFromGlobal" : "savesloc.cloudFromGame")
        }
    }

    /// iCloud Drive's own folders by their name in the Finder, anything else by its last part.
    static func name(_ folder: String) -> String { (folder as NSString).lastPathComponent }

    static func shown(_ folder: String, home: String = NSHomeDirectory()) -> String {
        let drive = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if folder == drive { return "iCloud Drive" }
        if folder.hasPrefix(drive + "/") { return "iCloud Drive › " + folder.dropFirst(drive.count + 1).replacingOccurrences(of: "/", with: " › ") }
        return (folder as NSString).abbreviatingWithTildeInPath
    }

    // ---- what the folder holds ----

    private func notice(_ check: CloudSaveSync.FolderCheck) -> AnyView? {
        switch check {
        case .missing: return AnyView(noticeRow("exclamationmark.triangle", loc.t("cloud.missing"), Self.attention))
        case .noSave: return AnyView(noticeRow("exclamationmark.triangle", loc.t("cloud.noSave"), Self.attention))
        case .hasSave(let date):
            guard let date else { return nil }
            return AnyView(noticeRow("checkmark.icloud", String(format: loc.t("cloud.hasSave"), when(date)), .secondary))
        }
    }

    private func noticeRow(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(tint).frame(width: 22)
            Text(text).font(.manrope(12.5)).foregroundStyle(tint == .secondary ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
    }

    // ---- the last session ----

    @ViewBuilder private var lastRow: some View {
        let shown = preview?.last ?? last ?? nil
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Circle().fill(color(shown?.state)).frame(width: 8, height: 8).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(stateText(shown)).font(.manrope(13.5, .medium)).fixedSize(horizontal: false, vertical: true)
                if let date = shown?.date {
                    Text(String(format: loc.t("cloud.lastSession"), when(date))).font(.manrope(11.5)).foregroundStyle(LauncherPalette.secondaryText)
                }
            }
            Spacer(minLength: 0)
            if let backups = backupsFolder {   // the save a sync or a choice replaced (#957): <DM_SAVE>-backups
                Button(loc.t("cloud.showBackups")) { NSWorkspace.shared.activateFileViewerSelecting([backups]) }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .padTarget("cloud.backups", scope: "launch") { NSWorkspace.shared.activateFileViewerSelecting([backups]) }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    /// The game's save backups on this Mac, when there are any.
    private var backupsFolder: URL? {
        guard preview == nil, !game.appPath.isEmpty else { return nil }
        let save = SaveTransfer.macSave(titleID: game.titleID, appPath: game.appPath).save
        let folder = URL(fileURLWithPath: save.path + "-backups")
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    private func stateText(_ last: (state: CloudSaveSync.LogState?, date: Date?)?) -> String {
        guard let last else { return loc.t("cloud.state.notPlayed") }
        switch last.state {
        case nil: return loc.t("cloud.state.none")
        case .inStep: return loc.t("cloud.state.inStep")
        case .sent: return loc.t("cloud.state.sent")
        case .broughtIn(let device): return String(format: loc.t("cloud.state.broughtIn"), device)
        case .waitingToSend: return loc.t("cloud.state.waiting")
        case .waitingForChoice: return loc.t("cloud.state.choose")
        case .offline: return loc.t("cloud.state.offline")
        case .nothingYet: return loc.t("cloud.state.nothingYet")
        case .off(let why): return String(format: loc.t("cloud.state.off"), why)
        case .failed(let why): return String(format: loc.t("cloud.state.failed"), why)
        }
    }

    private func color(_ state: CloudSaveSync.LogState?) -> Color {
        switch state {
        case .inStep, .sent, .broughtIn: return Color(red: 0.25, green: 0.84, blue: 0.47)
        case .waitingToSend, .waitingForChoice, .offline, .off: return Self.attention
        case .failed: return Color(red: 1, green: 0.42, blue: 0.40)
        case .nothingYet, nil: return LauncherPalette.ink(0.3)
        }
    }

    /// In the launcher's language, not the Mac's.
    private func when(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: loc.lang.code)
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }

    // ---- changes ----

    private func choose(from folder: String?) {
        let start = folder.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs")
        guard let url = chooseFolder(start) else { return }
        change {
            try store.choose(url.path)
            if let overrides { var value = overrides.game(game.titleID); value.cloud = .folder(url.path); overrides.setGame(game.titleID, value) }
        }
    }

    /// Off for this game even when the setup for every game is on: the game's own choice, kept apart from the global one.
    private func turnOff() throws {
        try store.turnOff()
        if let overrides { var value = overrides.game(game.titleID); value.cloud = SaveCloudChoice.off; overrides.setGame(game.titleID, value) }
    }

    private func useGlobal() throws {
        guard let overrides else { return }
        var value = overrides.game(game.titleID)
        value.cloud = nil
        overrides.setGame(game.titleID, value)
    }

    private func change(_ body: () throws -> Void) {
        do { try body(); problem = nil } catch { problem = String(format: loc.t("cloud.failed"), error.localizedDescription) }
        revision += 1
    }

    private func readLog() {
        guard preview == nil else { return }
        let store = store
        DispatchQueue.global(qos: .utility).async {
            let result = store.lastSession()
            DispatchQueue.main.async { last = .some(result) }
        }
    }

    /// The folder panel, opened at the current folder or iCloud Drive.
    static func openPanel(_ start: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }
}
