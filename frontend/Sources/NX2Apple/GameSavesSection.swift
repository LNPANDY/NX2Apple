import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher

/// The Saves section shared between `LaunchOptionsView` (Saves tab) and `SavesView`:
/// shows save location (Show in Finder / Change / Reset), unified import (folders, `.zip`, JKSV `.zip`, slot dirs, single/multi files),
/// clear exports (folder or JKSV `.zip`), and backups.
struct GameSavesSection: View {
    let game: LibraryGame
    @ObservedObject var settings: SaveSettingsStore
    @ObservedObject var players: PlayerProfileStore
    var support: URL? = nil
    var padScope: String = "launch"
    var chooseFolder: (URL?) -> URL? = CloudSavesCard.openPanel
    var chooseImportURLs: (URL?) -> [URL] = GameSavesSection.openImportPanelURLs
    var chooseImport: ((URL?) -> URL?)? = nil
    var chooseSaveZip: (String) -> URL? = GameSavesSection.saveZipPanel
    var running: @Sendable (String) -> Bool = { SaveTransfer.runningOnMac(titleID: $0) }
    var revealMNGTarget: (MacNativeGamesSaveEngine.SaveTarget) -> Void = MacNativeGamesSaveFinder.reveal
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @State private var result: (text: String, ok: Bool)?
    @State private var importing: SaveImportPlan?
    @State private var busy = false
    @State private var generation: UInt64 = 0

    private var override: SaveGameOverride { settings.game(game.titleID) }
    private var engine: any SaveEngine { SaveEngines.forApp(game.appPath, titleID: game.titleID) }
    private var isExternalMNG: Bool { engine is MacNativeGamesSaveEngine }
    private var isSharedMNG: Bool { engine is MngSharedDmSaveEngine }
    private var effective: SaveLocations.EffectiveSave {
        if let support {
            return SaveLocations.effectiveSave(titleID: game.titleID, appPath: game.appPath, global: settings.global, game: override, support: support, engine: engine)
        }
        return SaveLocations.effectiveSave(titleID: game.titleID, appPath: game.appPath, global: settings.global, game: override, engine: engine)
    }

    var body: some View {
        let _ = settings.revision
        let save = effective
        let managed = engine.managesSavesInLauncher
        let mngTarget = isExternalMNG ? MacNativeGamesSaveEngine.resolveSaveTarget(titleID: game.titleID) : nil
        let shownURL = mngTarget?.displaySaveURL ?? save.path
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("savesloc.localTitle")).font(DS.Font.headline).foregroundStyle(DS.Color.textSecondary).padding(.leading, 2)
            VStack(spacing: 0) {
                CardRow(loc.t("savesloc.folder"), detail: SaveLocationText.shown(shownURL.path), detail2: "", help: shownURL.path) {
                    Button(loc.t("savesloc.show")) {
                        if let mngTarget { revealMNGTarget(mngTarget) } else { reveal(save.path) }
                    }
                    .padTarget("saves.show", scope: padScope) {
                        if let mngTarget { revealMNGTarget(mngTarget) } else { reveal(save.path) }
                    }
                    if managed {
                        Button(loc.t("savesloc.change")) { change() }
                            .disabled(busy)
                            .padTarget("saves.change", scope: padScope, enabled: !busy) { if !busy { change() } }
                        if override.saveFolder != nil {
                            Button(loc.t("savesloc.reset")) { resetFolder() }
                                .disabled(busy)
                                .accessibilityLabel(String(format: loc.t("savesloc.resetFor"), game.name))
                                .padTarget("saves.reset", scope: padScope, enabled: !busy) { if !busy { resetFolder() } }
                        }
                    }
                }
                if managed {
                    CardDivider()
                    originRow(save)
                    CardDivider()
                    CardRow(loc.t("savesloc.importGroup"), detail: loc.t("savesloc.importUnifiedNote")) {
                        Button(loc.t("savesloc.importButtonLong")) { pickImport(into: save.path) }
                            .disabled(busy)
                            .padTarget("saves.import", scope: padScope, enabled: !busy) { if !busy { pickImport(into: save.path) } }
                    }
                    CardDivider()
                    CardRow(loc.t("savesloc.exportGroup"), detail: loc.t("savesloc.exportUnifiedNote")) {
                        Button(loc.t("savesloc.exportFolder")) { export(save.path) }
                            .disabled(busy)
                            .padTarget("saves.export", scope: padScope, enabled: !busy) { if !busy { export(save.path) } }
                        Button(loc.t("savesloc.exportZip")) { exportJKSV(save.path) }
                            .disabled(busy)
                            .padTarget("saves.exportZip", scope: padScope, enabled: !busy) { if !busy { exportJKSV(save.path) } }
                    }
                    if let backups = backupsFolder(save.path) {
                        CardDivider()
                        CardRow(loc.t("saves.backups"), detail: SaveLocationText.shown(backups.path), help: backups.path) {
                            Button(loc.t("saves.backups")) { reveal(backups) }
                                .padTarget("saves.backups", scope: padScope) { reveal(backups) }
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
                if isExternalMNG {
                    Text(loc.t("mng.saves.externalNote"))
                        .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                        .padding(.leading, 2).fixedSize(horizontal: false, vertical: true)
                }
            } else if busy {
                HStack(spacing: DS.Space.xs) {
                    ProgressView().controlSize(.small)
                    Text(loc.t("cloud.sync.syncing")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                }
                .padding(.leading, 2)
            } else if let result {
                Text(result.text).font(DS.Font.callout).foregroundStyle(result.ok ? DS.Color.textSecondary : CloudSavesCard.attention)
                    .padding(.leading, 2).fixedSize(horizontal: false, vertical: true)
            } else if isSharedMNG {
                Text(loc.t("mng.saves.sharedNote"))
                    .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    .padding(.leading, 2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: game.titleID) { _ in
            generation &+= 1
            busy = false
            importing = nil
            result = nil
        }
        .onChange(of: importing != nil) { open in
            pad.scope = open ? "saveimport" : padScope
        }
        .sheet(item: $importing) { plan in
            SaveImportSheet(
                gameName: game.displayName(loc.lang),
                plan: plan,
                target: save.path.path,
                cancel: { importing = nil },
                confirm: { mode in performImport(plan, mode: mode, into: save.path) }
            )
            .environmentObject(loc)
            .environmentObject(pad)
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

    // ---- unified import & export ----

    private func pickImport(into save: URL) {
        guard !busy else { return }
        guard !running(game.titleID) else { result = (String(format: loc.t("saves.running"), game.name), false); return }
        let urls: [URL]
        if let chooseImport {
            urls = chooseImport(nil).map { [$0] } ?? []
        } else {
            urls = chooseImportURLs(nil)
        }
        guard !urls.isEmpty else { return }
        previewImport(urls, into: save)
    }

    private func previewImport(_ urls: [URL], into save: URL) {
        let titleID = game.titleID
        let gameName = game.displayName(loc.lang)
        generation &+= 1
        let reqGen = generation
        busy = true
        result = nil

        Task {
            let outcome: Result<SaveImportPlan, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try SaveImport.preview(urls, expectedTitleID: titleID, into: save))
                } catch {
                    return .failure(error)
                }
            }.value
            guard generation == reqGen, game.titleID == titleID else { return }
            busy = false
            switch outcome {
            case .success(let plan):
                importing = plan
            case .failure(let failure as SaveImportFailure):
                result = (importFailureMessage(failure, gameName: gameName), false)
            case .failure(let error):
                result = (String(format: loc.t("saves.failed"), error.localizedDescription), false)
            }
        }
    }

    private func performImport(_ plan: SaveImportPlan, mode: SaveImportMode, into save: URL) {
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
            let outcome: Result<URL?, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let isRunningNow = runningCheck(titleID)
                    let backup = try SaveImport.execute(plan, into: save, mode: mode, gameRunning: isRunningNow)
                    return .success(backup)
                } catch {
                    return .failure(error)
                }
            }.value
            guard generation == reqGen, game.titleID == titleID else { return }
            busy = false
            switch outcome {
            case .success(let backup):
                settings.notifySaveChanged()
                let text = backup.map { String(format: loc.t("savesloc.imported"), SaveLocationText.shown($0.path)) }
                    ?? loc.t("savesloc.importedFresh")
                let cloudOn = SaveLocations.effectiveCloud(
                    global: globalSettings,
                    game: gameOverride,
                    own: GameCloudSaves(titleID: titleID, appPath: appPath).setting
                ).isOn
                result = (cloudOn ? text + " " + loc.t("savesloc.importedCloud") : text, true)
            case .failure(let failure as SaveImportFailure):
                result = (importFailureMessage(failure, gameName: gameName), false)
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

    private func importFailureMessage(_ failure: SaveImportFailure, gameName: String) -> String {
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
        case .multipleArchivesNotAllowed:
            return loc.t("savesloc.multipleZips")
        case .nothingToImport:
            return loc.t("savesloc.nothingToImport")
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

    /// Unified import panel: allows folders, `.zip` archives, and any regular files (including extensionless files like Stardew Valley saves).
    static func openImportPanelURLs(_ start: URL?) -> [URL] {
        let panel = openImportPanelConfigured(start)
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Builds the configured `NSOpenPanel` for unified save selection (exposed for regression testing).
    static func openImportPanelConfigured(_ start: URL?) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = []
        panel.directoryURL = start
        return panel
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

/// Preview and confirmation sheet for a save import: shows source summary, format tag, target folder, file list preview,
/// and replace/merge strategy when a local save already exists.
struct SaveImportSheet: View {
    let gameName: String
    let plan: SaveImportPlan
    let target: String
    let cancel: () -> Void
    let confirm: (SaveImportMode) -> Void

    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @State private var mode: SaveImportMode

    init(gameName: String, plan: SaveImportPlan, target: String, cancel: @escaping () -> Void, confirm: @escaping (SaveImportMode) -> Void) {
        self.gameName = gameName
        self.plan = plan
        self.target = target
        self.cancel = cancel
        self.confirm = confirm
        self._mode = State(initialValue: plan.recommendedMode)
    }

    private static let maxPreviewRows = 6

    private var kindBadge: String {
        switch plan.kind {
        case .jksvZip(let tid):
            if let tid { return String(format: loc.t("savesloc.kind.jksvTid"), tid) }
            return loc.t("savesloc.kind.jksv")
        case .zip:
            return loc.t("savesloc.kind.zip")
        case .slotFolder:
            return loc.t("savesloc.kind.slot")
        case .archiveFolders, .folder:
            return loc.t("savesloc.kind.folder")
        case .files(let slot):
            return slot != nil ? loc.t("savesloc.kind.slot") : loc.t("savesloc.kind.files")
        }
    }

    private var contentsSummary: String {
        let formattedSize = ByteCountFormatter.string(fromByteCount: Int64(min(plan.totalBytes, UInt64(Int64.max))), countStyle: .file)
        return String(format: loc.t("savesloc.importStats"), plan.fileCount, formattedSize)
    }

    private var noteText: String {
        if !plan.hasExistingTargetSave {
            return loc.t("savesloc.importFreshNote")
        }
        return mode == .merge ? loc.t("savesloc.importMergeNote") : loc.t("savesloc.importReplaceNote")
    }

    var body: some View {
        let destructive = plan.hasExistingTargetSave && mode == .replace
        DSSheet(width: 540, title: loc.t("savesloc.importTitle"), message: gameName) {
            DSSection("") {
                DSRow(loc.t("savesloc.source"), detail: SaveLocationText.shown(plan.sourceSummary), help: plan.sourceSummary) {
                    DSTag(kindBadge)
                }
                DSRowDivider()
                DSRow(loc.t("savesloc.target"), detail: SaveLocationText.shown(target), help: target) {}
                DSRowDivider()
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    DSRow(loc.t("savesloc.contents"), detail: contentsSummary) {}
                    if !plan.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(plan.entries.prefix(Self.maxPreviewRows)) { entry in
                                Text(entry.displayPath)
                                    .font(DS.Font.mono)
                                    .foregroundStyle(DS.Color.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if plan.entries.count > Self.maxPreviewRows {
                                Text(String(format: loc.t("savesloc.moreFiles"), plan.entries.count - Self.maxPreviewRows))
                                    .font(DS.Font.footnote)
                                    .foregroundStyle(DS.Color.textTertiary)
                            }
                        }
                        .padding(.horizontal, DS.Space.m)
                        .padding(.bottom, DS.Space.s)
                    }
                }
            }
            if plan.hasExistingTargetSave {
                DSSection("") {
                    DSRow(loc.t("savesloc.modeTitle")) {
                        LauncherSegmented(
                            options: [
                                (SaveImportMode.replace.rawValue, loc.t("savesloc.mode.replace")),
                                (SaveImportMode.merge.rawValue, loc.t("savesloc.mode.merge")),
                            ],
                            selection: mode.rawValue,
                            size: 12.5,
                            semibold: true
                        ) { raw in
                            mode = SaveImportMode(rawValue: raw) ?? .replace
                        }
                        .fixedSize()
                        .padTarget("saveimport.mode", scope: "saveimport", activate: {
                            mode = (mode == .replace) ? .merge : .replace
                        })
                    }
                }
            }
            Text(noteText)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            DSSheetConfirmButtons(
                cancelTitle: loc.t("saves.cancel"),
                confirmTitle: loc.t(plan.hasExistingTargetSave && mode == .merge ? "savesloc.mergeButton" : "savesloc.importButton"),
                role: destructive ? .destructive : .primary,
                confirmTakesReturn: false,
                scope: "saveimport",
                cancel: cancel,
                confirm: { confirm(plan.hasExistingTargetSave ? mode : .replace) }
            )
        }
        .padScope("saveimport", pad)
    }
}
