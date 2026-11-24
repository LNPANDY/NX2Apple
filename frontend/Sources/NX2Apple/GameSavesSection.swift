import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher

/// The Saves part of a game's options: where its save is (and whether that is the usual place, the setting for all games, or this game's own),
/// Show in Finder / Change / Reset, Import and Export (folders or JKSV `.zip` archives), and the backups.
struct GameSavesSection: View {
    let game: LibraryGame
    @ObservedObject var settings: SaveSettingsStore
    @ObservedObject var players: PlayerProfileStore
    var chooseFolder: (URL?) -> URL? = CloudSavesCard.openPanel
    var chooseImport: (URL?) -> URL? = GameSavesSection.openImportPanel
    var chooseZipImport: (URL?) -> URL? = GameSavesSection.openZipPanel
    var chooseSaveZip: (String) -> URL? = GameSavesSection.saveZipPanel
    var running: @Sendable (String) -> Bool = { SaveTransfer.runningOnMac(titleID: $0) }
    var revealMNGTarget: (MacNativeGamesSaveEngine.SaveTarget) -> Void = MacNativeGamesSaveFinder.reveal
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @State private var result: (text: String, ok: Bool)?
    @State private var importing: PendingImport?
    @State private var busy = false
    @State private var generation: UInt64 = 0

    private var override: SaveGameOverride { settings.game(game.titleID) }
    private var engine: any SaveEngine { SaveEngines.forApp(game.appPath) }
    private var isMacNativeGames: Bool { engine is MacNativeGamesSaveEngine }
    private var effective: SaveLocations.EffectiveSave {
        SaveLocations.effectiveSave(titleID: game.titleID, appPath: game.appPath, global: settings.global, game: override, engine: engine)
    }

    var body: some View {
        let _ = settings.revision
        let save = effective
        let managed = engine.managesSavesInLauncher
        let mngTarget = isMacNativeGames ? MacNativeGamesSaveEngine.resolveSaveTarget(titleID: game.titleID) : nil
        let shownURL = mngTarget?.displaySaveURL ?? save.path
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("saves.title")).font(DS.Font.headline).foregroundStyle(DS.Color.textSecondary).padding(.leading, 2)
            VStack(spacing: 0) {
                CardRow(loc.t("savesloc.folder"), detail: SaveLocationText.shown(shownURL.path), detail2: "", help: shownURL.path) {
                    Button(loc.t("savesloc.show")) {
                        if let mngTarget { revealMNGTarget(mngTarget) } else { reveal(save.path) }
                    }
                    .padTarget("saves.show", scope: "launch") {
                        if let mngTarget { revealMNGTarget(mngTarget) } else { reveal(save.path) }
                    }
                    if managed {
                        Button(loc.t("savesloc.change")) { change() }
                            .disabled(busy)
                            .padTarget("saves.change", scope: "launch", enabled: !busy) { if !busy { change() } }
                        if override.saveFolder != nil {
                            Button(loc.t("savesloc.reset")) { resetFolder() }
                                .disabled(busy)
                                .accessibilityLabel(String(format: loc.t("savesloc.resetFor"), game.name))
                                .padTarget("saves.reset", scope: "launch", enabled: !busy) { if !busy { resetFolder() } }
                        }
                    }
                }
                if managed {
                    CardDivider()
                    originRow(save)
                    CardDivider()
                    CardRow(loc.t("savesloc.transfer"), detail: loc.t("savesloc.importNote")) {
                        Button(loc.t("savesloc.import")) { pickImport() }
                            .disabled(busy)
                            .padTarget("saves.import", scope: "launch", enabled: !busy) { if !busy { pickImport() } }
                        Button(loc.t("savesloc.export")) { export(save.path) }
                            .disabled(busy)
                            .padTarget("saves.export", scope: "launch", enabled: !busy) { if !busy { export(save.path) } }
                    }
                    CardDivider()
                    CardRow(loc.t("savesloc.jksv"), detail: loc.t("savesloc.jksvNote")) {
                        Button(loc.t("savesloc.importZip")) { pickJKSVImport() }
                            .disabled(busy)
                            .padTarget("saves.importZip", scope: "launch", enabled: !busy) { if !busy { pickJKSVImport() } }
                        Button(loc.t("savesloc.exportZip")) { exportJKSV(save.path) }
                            .disabled(busy)
                            .padTarget("saves.exportZip", scope: "launch", enabled: !busy) { if !busy { exportJKSV(save.path) } }
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
            }
            .buttonStyle(LauncherSecondaryButtonStyle())
            .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
            if !managed {
                if isMacNativeGames {
                    Text(loc.t("mng.saves.externalNote"))
                        .font(DS.Font.callout).foregroundStyle(Color.secondary)
                        .padding(.leading, 2).fixedSize(horizontal: false, vertical: true)
                }
            } else if busy {
                HStack(spacing: DS.Space.xs) {
                    ProgressView().controlSize(.small)
                    Text(loc.t("cloud.sync.syncing")).font(DS.Font.callout).foregroundStyle(Color.secondary)
                }
                .padding(.leading, 2)
            } else if let result {
                Text(result.text).font(DS.Font.callout).foregroundStyle(result.ok ? Color.secondary : CloudSavesCard.attention)
                    .padding(.leading, 2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: game.titleID) { _ in
            generation &+= 1
            busy = false
            importing = nil
            result = nil
        }
        .sheet(item: $importing) { pending in
            SaveImportSheet(
                gameName: game.displayName(loc.lang),
                source: pending.sourcePath,
                target: save.path.path,
                detail: pending.detail(loc.t),
                cancel: { importing = nil },
                confirm: { performImport(pending, into: save.path) }
            )
            .environmentObject(loc)
            .environmentObject(pad)
        }
    }

    private enum PendingImport: Identifiable {
        case folder(SaveArchive.Preview)
        case jksv(JKSVArchive.Preview)

        var sourcePath: String {
            switch self {
            case .folder(let p): return p.source.path
            case .jksv(let p): return p.source.path
            }
        }

        var id: String { sourcePath }

        func detail(_ t: (String) -> String) -> String? {
            switch self {
            case .folder(let p):
                return String(format: t("savesloc.importCount"), p.fileCount)
            case .jksv(let p):
                if let tid = p.meta?.formattedTitleID {
                    return String(format: t("savesloc.jksvPreviewMeta"), p.fileCount, tid)
                }
                return String(format: t("savesloc.importCount"), p.fileCount)
            }
        }
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
        guard !busy else { return }
        let old = effective.path
        guard let picked = chooseFolder(old.deletingLastPathComponent()) else { return }
        let target = picked.appendingPathComponent("save", isDirectory: true)
        let titleID = game.titleID
        let gameName = game.displayName(loc.lang)
        let runningCheck = running
        let currentOverride = override
        generation &+= 1
        let reqGen = generation
        busy = true
        result = nil

        Task {
            let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    _ = try SaveMigration.copy(from: old, to: target, gameRunning: runningCheck(titleID))
                    return .success(())
                } catch SaveMigration.Failure.sourceMissing {
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            guard generation == reqGen, game.titleID == titleID else { return }
            busy = false
            switch outcome {
            case .success:
                var value = currentOverride
                value.saveFolder = target.path
                settings.setGame(titleID, value)
                result = (loc.t("savesloc.changed"), true)
            case .failure(let failure as SaveMigration.Failure):
                result = (message(failure, gameName: gameName), false)
            case .failure(let error):
                result = (error.localizedDescription, false)
            }
        }
    }

    private func resetFolder() {
        guard !busy else { return }
        guard !running(game.titleID) else { result = (String(format: loc.t("saves.running"), game.name), false); return }
        var value = override
        value.saveFolder = nil
        settings.setGame(game.titleID, value)   // the files stay where they are: they are the old folder's, not deleted
        result = (loc.t("savesloc.resetDone"), true)
    }

    private func message(_ failure: SaveMigration.Failure, gameName: String) -> String {
        switch failure {
        case .gameRunning: return String(format: loc.t("saves.running"), gameName)
        case .destinationNotEmpty: return loc.t("savesloc.notEmpty")
        case .volumeCannotHoldSaves: return loc.t("savesloc.volume")
        case .sourceMissing: return loc.t("savesloc.none")
        }
    }

    // ---- import and export ----

    private func pickImport() {
        guard !busy else { return }
        guard !running(game.titleID) else { result = (String(format: loc.t("saves.running"), game.name), false); return }
        guard let url = chooseImport(nil) else { return }
        if url.pathExtension.lowercased() == "zip" {
            previewJKSV(url)
            return
        }
        guard let preview = SaveArchive.preview(url) else { result = (loc.t("savesloc.nothingToImport"), false); return }
        importing = .folder(preview)
    }

    private func pickJKSVImport() {
        guard !busy else { return }
        guard !running(game.titleID) else { result = (String(format: loc.t("saves.running"), game.name), false); return }
        guard let url = chooseZipImport(nil) else { return }
        previewJKSV(url)
    }

    private func previewJKSV(_ url: URL) {
        let titleID = game.titleID
        let gameName = game.displayName(loc.lang)
        generation &+= 1
        let reqGen = generation
        busy = true
        result = nil

        Task {
            let outcome: Result<JKSVArchive.Preview, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try JKSVArchive.preview(url, expectedTitleID: titleID))
                } catch {
                    return .failure(error)
                }
            }.value
            guard generation == reqGen, game.titleID == titleID else { return }
            busy = false
            switch outcome {
            case .success(let preview):
                importing = .jksv(preview)
            case .failure(let failure as JKSVArchive.Failure):
                result = (jksvFailureMessage(failure, gameName: gameName), false)
            case .failure(let error):
                result = (String(format: loc.t("saves.failed"), error.localizedDescription), false)
            }
        }
    }

    private func performImport(_ pending: PendingImport, into save: URL) {
        guard !busy else { return }
        importing = nil
        let titleID = game.titleID
        let gameName = game.displayName(loc.lang)
        let appPath = game.appPath
        let globalSettings = settings.global
        let gameOverride = override
        let runningCheck = running
        generation &+= 1
        let reqGen = generation
        busy = true
        result = nil

        Task {
            let outcome: Result<(backup: URL?, isJKSV: Bool), Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let isRunningNow = runningCheck(titleID)
                    switch pending {
                    case .folder(let preview):
                        let backup = try SaveArchive.import(preview, into: save, gameRunning: isRunningNow)
                        return .success((backup, false))
                    case .jksv(let preview):
                        let backup = try JKSVArchive.import(preview, into: save, gameRunning: isRunningNow)
                        return .success((backup, true))
                    }
                } catch {
                    return .failure(error)
                }
            }.value
            guard generation == reqGen, game.titleID == titleID else { return }
            busy = false
            switch outcome {
            case .success(let done):
                if done.isJKSV {
                    settings.notifySaveChanged()
                }
                let text = done.backup.map { String(format: loc.t("savesloc.imported"), SaveLocationText.shown($0.path)) }
                    ?? loc.t("savesloc.importedFresh")
                let cloudOn = SaveLocations.effectiveCloud(
                    global: globalSettings,
                    game: gameOverride,
                    own: GameCloudSaves(titleID: titleID, appPath: appPath).setting
                ).isOn
                result = (cloudOn ? text + " " + loc.t("savesloc.importedCloud") : text, true)
            case .failure(SaveArchive.Failure.gameRunning):
                result = (String(format: loc.t("saves.running"), gameName), false)
            case .failure(SaveArchive.Failure.volumeCannotHoldSaves):
                result = (loc.t("savesloc.volume"), false)
            case .failure(let failure as JKSVArchive.Failure):
                result = (jksvFailureMessage(failure, gameName: gameName), false)
            case .failure(let error):
                result = (String(format: loc.t("saves.failed"), error.localizedDescription), false)
            }
        }
    }

    private func export(_ save: URL) {
        guard !busy else { return }
        guard let url = chooseFolder(nil) else { return }
        let titleID = game.titleID
        generation &+= 1
        let reqGen = generation
        busy = true
        result = nil

        Task {
            let outcome: Result<(folder: URL, files: Int), Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try SaveArchive.export(save: save, titleID: titleID, to: url))
                } catch {
                    return .failure(error)
                }
            }.value
            guard generation == reqGen, game.titleID == titleID else { return }
            busy = false
            switch outcome {
            case .success(let done):
                result = (String(format: loc.t("savesloc.exported"), done.files, SaveLocationText.shown(done.folder.path)), true)
                NSWorkspace.shared.activateFileViewerSelecting([done.folder])
            case .failure(SaveArchive.Failure.nothingToExport):
                result = (loc.t("savesloc.nothingToExport"), false)
            case .failure(SaveArchive.Failure.destinationInsideSave):
                result = (loc.t("savesloc.insideSave"), false)
            case .failure(let error):
                result = (String(format: loc.t("saves.failed"), error.localizedDescription), false)
            }
        }
    }

    private func exportJKSV(_ save: URL) {
        guard !busy else { return }
        let suggested = "\(game.name) [\(game.titleID.uppercased())].zip"
        guard let url = chooseSaveZip(suggested) else { return }
        let titleID = game.titleID
        let gameName = game.displayName(loc.lang)
        generation &+= 1
        let reqGen = generation
        busy = true
        result = nil

        Task {
            let outcome: Result<(file: URL, files: Int), Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try JKSVArchive.export(save: save, titleID: titleID, to: url))
                } catch {
                    return .failure(error)
                }
            }.value
            guard generation == reqGen, game.titleID == titleID else { return }
            busy = false
            switch outcome {
            case .success(let done):
                result = (String(format: loc.t("savesloc.exportedZip"), done.files, SaveLocationText.shown(done.file.path)), true)
                NSWorkspace.shared.activateFileViewerSelecting([done.file])
            case .failure(let failure as JKSVArchive.Failure):
                result = (jksvFailureMessage(failure, gameName: gameName), false)
            case .failure(let error):
                result = (String(format: loc.t("saves.failed"), error.localizedDescription), false)
            }
        }
    }

    private func jksvFailureMessage(_ failure: JKSVArchive.Failure, gameName: String) -> String {
        switch failure {
        case .gameRunning:
            return String(format: loc.t("saves.running"), gameName)
        case .pendingPullJournal:
            return loc.t("cloud.sync.pendingPull")
        case .volumeCannotHoldSaves:
            return loc.t("savesloc.volume")
        case .titleIDMismatch(let expected, let found):
            return String(format: loc.t("savesloc.jksvWrongGame"), found, expected)
        case .quotaExceeded:
            return loc.t("savesloc.jksvQuota")
        case .unsafePath, .symlinkNotAllowed:
            return loc.t("savesloc.jksvUnsafe")
        case .invalidArchive:
            return loc.t("savesloc.jksvInvalid")
        case .nothingToImport:
            return loc.t("savesloc.nothingToImport")
        case .nothingToExport:
            return loc.t("savesloc.nothingToExport")
        case .destinationInsideSave:
            return loc.t("savesloc.insideSave")
        }
    }

    static func openImportPanel(_ start: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func openZipPanel(_ start: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveZipPanel(_ suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum SaveLocationText {
    static func shown(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

/// The confirmation of an import, on the sheet layout: where the files come from, where they go, and that the
/// current save is backed up. Import replaces the save, so it is the destructive button: Return and Escape cancel.
struct SaveImportSheet: View {
    let gameName: String
    let source: String
    let target: String
    var detail: String? = nil
    let cancel: () -> Void
    let confirm: () -> Void
    @EnvironmentObject var loc: Localizer

    var body: some View {
        LauncherConfirmSheet(title: loc.t("savesloc.importTitle"), subtitle: gameName, note: loc.t("savesloc.importNote"),
                             cancelTitle: loc.t("saves.cancel"), confirmTitle: loc.t("savesloc.importButton"), destructive: true,
                             scope: "saveimport", cancel: cancel, confirm: confirm) {
            DSSection("") {
                DSRow(loc.t("savesloc.source"), detail: SaveLocationText.shown(source), help: source) {}
                DSRowDivider()
                DSRow(loc.t("savesloc.target"), detail: SaveLocationText.shown(target), help: target) {}
                if let detail {
                    DSRowDivider()
                    DSRow(loc.t("savesloc.contents"), detail: detail) {}
                }
            }
        }
    }
}
