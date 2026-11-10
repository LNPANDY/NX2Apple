import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The Saves part of a game's options: where its save is (and whether that is the usual place, the setting for all games, or this game's own),
/// Show in Finder / Change / Reset, Import and Export, and the backups. The cloud rows stay in CloudSavesCard beside it. The sheet's
/// category layout places this view, it adds no layout of its own (#411, #864, #1041).
struct GameSavesSection: View {
    let game: LibraryGame
    @ObservedObject var settings: SaveSettingsStore
    @ObservedObject var players: PlayerProfileStore
    var chooseFolder: (URL?) -> URL? = CloudSavesCard.openPanel
    var running: (String) -> Bool = { SaveTransfer.runningOnMac(titleID: $0) }
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @State private var result: (text: String, ok: Bool)?
    @State private var importing: SaveArchive.Preview?

    private var override: SaveGameOverride { settings.game(game.titleID) }
    private var effective: SaveLocations.EffectiveSave {
        SaveLocations.effectiveSave(titleID: game.titleID, appPath: game.appPath, global: settings.global, game: override)
    }

    var body: some View {
        let _ = settings.revision
        let save = effective
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("saves.title")).font(.manrope(15, .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
            VStack(spacing: 0) {
                CardRow(loc.t("savesloc.folder"), detail: SaveLocationText.shown(save.path.path), detail2: "", help: save.path.path) {
                    Button(loc.t("savesloc.show")) { reveal(save.path) }
                        .padTarget("saves.show", scope: "launch") { reveal(save.path) }
                    Button(loc.t("savesloc.change")) { change() }
                        .padTarget("saves.change", scope: "launch") { change() }
                    if override.saveFolder != nil {
                        Button(loc.t("savesloc.reset")) { resetFolder() }
                            .accessibilityLabel(String(format: loc.t("savesloc.resetFor"), game.name))
                            .padTarget("saves.reset", scope: "launch") { resetFolder() }
                    }
                }
                CardDivider()
                originRow(save)
                CardDivider()
                CardRow(loc.t("savesloc.transfer"), detail: loc.t("savesloc.importNote")) {
                    Button(loc.t("savesloc.import")) { pickImport() }
                        .padTarget("saves.import", scope: "launch") { pickImport() }
                    Button(loc.t("savesloc.export")) { export(save.path) }
                        .padTarget("saves.export", scope: "launch") { export(save.path) }
                }
                if let backups = backupsFolder(save.path) {
                    CardDivider()
                    CardRow(loc.t("saves.backups"), detail: SaveLocationText.shown(backups.path), help: backups.path) {
                        Button(loc.t("saves.backups")) { reveal(backups) }
                            .padTarget("saves.backups", scope: "launch") { reveal(backups) }
                    }
                }
                if let secondary = secondaryPlayer {
                    CardDivider()
                    CardRow(String(format: loc.t("savesloc.secondary"), secondary), detail: loc.t("savesloc.secondaryNote"), dot: LauncherPalette.building) {}
                }
            }
            .buttonStyle(LauncherSecondaryButtonStyle())
            .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
            if let result {
                Text(result.text).font(.manrope(12)).foregroundStyle(result.ok ? Color.secondary : CloudSavesCard.attention)
                    .padding(.leading, 2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: Binding(get: { importing.map { PendingImport(preview: $0) } }, set: { if $0 == nil { importing = nil } })) { pending in
            SaveImportSheet(gameName: game.name, source: pending.preview.source.path, target: save.path.path,
                            cancel: { importing = nil }, confirm: { performImport(pending.preview, into: save.path) })
                .environmentObject(loc).environmentObject(pad)
        }
    }

    private struct PendingImport: Identifiable {
        let preview: SaveArchive.Preview
        var id: String { preview.source.path }
    }

    /// Where the folder comes from: the usual place, the library folder, the setting for all games, or this game's own.
    private func originRow(_ save: SaveLocations.EffectiveSave) -> some View {
        let (text, dot): (String, Color) = {
            switch save.source {
            case .standard: return (loc.t("savesloc.usual"), LauncherPalette.unbuilt)
            case .libraryFolder: return (loc.t("savesloc.library"), LauncherPalette.unbuilt)
            case .global: return (loc.t("savesloc.fromGlobal"), LauncherPalette.ready)
            case .game: return (loc.t("savesloc.fromGame"), LauncherPalette.ready)
            case .fallback: return (loc.t("savesloc.fallback"), LauncherPalette.building)
            }
        }()
        return CardRow(text, detail: save.source == .game || save.source == .global ? loc.t("savesloc.copyNote") : "", dot: dot) {}
    }

    private var secondaryPlayer: String? {
        players.active.isDefault ? nil : players.displayName(players.active)
    }

    private func backupsFolder(_ save: URL) -> URL? {
        let folder = URL(fileURLWithPath: save.path + "-backups")
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    private func reveal(_ url: URL) {
        let target = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // ---- changes ----

    /// A new folder for this game: the save is copied there, the old folder stays, nothing is overwritten and nothing moves while the game runs.
    private func change() {
        let old = effective.path
        guard let picked = chooseFolder(old.deletingLastPathComponent()) else { return }
        let target = picked.appendingPathComponent("save", isDirectory: true)
        do {
            let copied = try SaveMigration.copy(from: old, to: target, gameRunning: running(game.titleID))
            _ = copied
        } catch let failure as SaveMigration.Failure {
            if failure != .sourceMissing { result = (message(failure), false); return }   // no save yet: the folder is just remembered
        } catch { result = (error.localizedDescription, false); return }
        var value = override
        value.saveFolder = target.path
        settings.setGame(game.titleID, value)
        result = (loc.t("savesloc.changed"), true)
    }

    private func resetFolder() {
        guard !running(game.titleID) else { result = (String(format: loc.t("saves.running"), game.name), false); return }
        var value = override
        value.saveFolder = nil
        settings.setGame(game.titleID, value)   // the files stay where they are: they are the old folder's, not deleted
        result = (loc.t("savesloc.resetDone"), true)
    }

    private func message(_ failure: SaveMigration.Failure) -> String {
        switch failure {
        case .gameRunning: return String(format: loc.t("saves.running"), game.name)
        case .destinationNotEmpty: return loc.t("savesloc.notEmpty")
        case .volumeCannotHoldSaves: return loc.t("savesloc.volume")
        case .sourceMissing: return loc.t("savesloc.none")
        }
    }

    // ---- import and export ----

    private func pickImport() {
        guard !running(game.titleID) else { result = (String(format: loc.t("saves.running"), game.name), false); return }
        guard let url = chooseFolder(nil) else { return }
        guard let preview = SaveArchive.preview(url) else { result = (loc.t("savesloc.nothingToImport"), false); return }
        importing = preview
    }

    private func performImport(_ preview: SaveArchive.Preview, into save: URL) {
        importing = nil
        do {
            let backup = try SaveArchive.import(preview, into: save, gameRunning: running(game.titleID))
            let text = backup.map { String(format: loc.t("savesloc.imported"), SaveLocationText.shown($0.path)) } ?? loc.t("savesloc.importedFresh")
            // With cloud saves on, the imported save is this Mac's newest. The engine sends it at the next start, and the check before a start
            // (CloudSaveGate) protects the cloud's save if that changed too. The launcher does not write the cloud's file itself.
            let cloudOn = SaveLocations.effectiveCloud(global: settings.global, game: override, own: GameCloudSaves(titleID: game.titleID, appPath: game.appPath).setting).isOn
            result = (cloudOn ? text + " " + loc.t("savesloc.importedCloud") : text, true)
        } catch SaveArchive.Failure.gameRunning {
            result = (String(format: loc.t("saves.running"), game.name), false)
        } catch SaveArchive.Failure.volumeCannotHoldSaves {
            result = (loc.t("savesloc.volume"), false)
        } catch { result = (String(format: loc.t("saves.failed"), error.localizedDescription), false) }
    }

    private func export(_ save: URL) {
        guard let url = chooseFolder(nil) else { return }
        do {
            let done = try SaveArchive.export(save: save, titleID: game.titleID, to: url)
            result = (String(format: loc.t("savesloc.exported"), done.files, SaveLocationText.shown(done.folder.path)), true)
            NSWorkspace.shared.activateFileViewerSelecting([done.folder])
        } catch SaveArchive.Failure.nothingToExport {
            result = (loc.t("savesloc.nothingToExport"), false)
        } catch SaveArchive.Failure.destinationInsideSave {
            result = (loc.t("savesloc.insideSave"), false)
        } catch { result = (String(format: loc.t("saves.failed"), error.localizedDescription), false) }
    }
}

enum SaveLocationText {
    static func shown(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

/// The 560 pt confirmation of an import: the game, where the files come from, where they go, and that the current save is backed up.
/// Cancel has the focus, so Return never replaces a save.
struct SaveImportSheet: View {
    let gameName: String
    let source: String
    let target: String
    let cancel: () -> Void
    let confirm: () -> Void
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(loc.t("savesloc.importTitle")).font(.manrope(26, .heavy)).tracking(-0.6)
                Text(gameName).font(.manrope(13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 18)
            VStack(spacing: 0) {
                CardRow(loc.t("savesloc.source"), detail: SaveLocationText.shown(source), help: source) {}
                CardDivider()
                CardRow(loc.t("savesloc.target"), detail: SaveLocationText.shown(target), help: target) {}
            }
            .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 30)
            Text(loc.t("savesloc.importNote")).font(.manrope(12.5)).foregroundStyle(.secondary).padding(.horizontal, 32).padding(.top, 12)
            Divider().opacity(0.3).padding(.top, 20)
            HStack(spacing: 12) {
                Spacer(minLength: 8)
                Button(loc.t("saves.cancel"), action: cancel).keyboardShortcut(.cancelAction).focused($cancelFocused)
                    .padTarget("saveimport.cancel", scope: "saveimport", activate: cancel)
                Button(loc.t("savesloc.importButton"), action: confirm)
                    .padTarget("saveimport.confirm", scope: "saveimport", activate: confirm)
            }
            .buttonStyle(LauncherSecondaryButtonStyle())
            .padding(.horizontal, 30).padding(.vertical, 16)
        }
        .padScope("saveimport", pad)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(LauncherPalette.background)
        .launcherAppearance()
        .tint(LauncherPalette.cream)
        .onAppear { cancelFocused = true }
    }
}
