import SwiftUI
import AppKit
import NXCore
import NXModel
import NXLauncher

/// What a desktop scene opens the launcher with: its page, the wizard's step and the state the launcher takes at launch.
struct GalleryLauncher {
    var page: LauncherPage = .library
    var editor = false
    var search: String? = nil
    var olderTools: Set<UUID> = []
    var assessments: [UUID: GameRefreshAssessment] = [:]
    var launching = false
    var allGames = false
    var category: SettingsCategory = .general
    var step = 0
    var activeBuildID: UUID? = nil
    var manageOpen = false
    var padRing = false
    var prompt = false
    var artworkEditor: ArtworkEditor? = nil
    var driver: AnyConsoleDriver? = nil
    var dismissal: BuildCompletionDismissal? = nil
    var gallery = LauncherGalleryState()
}

/// The desktop's states beyond the first scenes (GalleryScene's own cases): the library's cards and hero in each state, the Manage
/// menu, the artwork panel, the filters, each result and send of a build, the queue and the transfers, Settings' update and engine
/// states, and the sheets' other states. Each one is the real view on the fixture stores (GalleryFixtures).
enum GalleryDesktopScene: String, CaseIterable {
    // the library
    case cardEveryState, heroPlay, heroOnDevice, heroRefreshFast, heroRefreshFull, heroSignature, heroResign, heroUnverified
    case manageMenu, manageMenuPad, noArtwork, consolePrompt, controllerToast, buildJustFinished
    case artworkHero, artworkThumbnail, artworkLoading, artworkOffline, artworkNoScreenshots, artworkWarning, artworkError
    // All games
    case filterOwned, filterMac, filterIOS, sortName
    // Builds
    case completionExported, completionNeedsData
    case sendSending, sendSent, sendAppNotFound, sendChooseApp, sendRefused, sendFailed, sendCopying, sendCopied
    case queueEveryState, queueRunning, transfersEveryState, logOpen
    case footerVerifying, footerExporting, footerInstalling, footerRenewing, footerSending
    // Settings
    case appChecking, appDownloading, appPreparing, appAvailable, engineExperimental, missingTool, players, libraryFolders
    case nxkitIdle, nxkitChecking, nxkitWaiting, nxkitUnreachable, nxkitAppleSilicon
    case nxkitBadSignature, nxkitChecksum, nxkitIncompatible, nxkitIncomplete, nxkitDownload, nxkitUnpack, nxkitCancelled
    // sheets
    case savesNoDevices, savesNotConnected, savesNotInstalled, savesReading, savesReady, savesFailed, savesTimedOut
    case freeSpaceRunning, freeSpaceFailed, sendSelectedDrive, deleteGameIOS, controllerMapping, frameTimes
    // the design system's controls in a state a capture cannot reach with the pointer
    case dropdownList
    // MacNativeGames, LNPANDY/NX2Apple#1473 (GalleryMacNativeGames.swift)
    case mngLibrary, mngRecommend, mngRecommendInstalled, mngBlocked, mngDropdownDisabled, mngUpdateAvailable

    var title: String {
        switch self {
        case .cardEveryState: return "Cards: every state and chip"
        case .heroPlay: return "Hero: Play"
        case .heroOnDevice: return "Hero: Open on iPhone"
        case .heroRefreshFast: return "Hero: update, fast refresh"
        case .heroRefreshFull: return "Hero: update, full rebuild"
        case .heroSignature: return "Notice: signature runs out"
        case .heroResign: return "Notice: after renewing the signature"
        case .heroUnverified: return "Hero: profile not verified, help open"
        case .manageMenu: return "Manage menu"
        case .manageMenuPad: return "Manage menu, controller focus"
        case .noArtwork: return "Games without artwork"
        case .consolePrompt: return "Controller connected: switch to console mode?"
        case .controllerToast: return "Controller toast"
        case .buildJustFinished: return "A build just finished, footer"
        case .artworkHero: return "Artwork panel: hero"
        case .artworkThumbnail: return "Artwork panel: card"
        case .artworkLoading: return "Artwork panel: loading screenshots"
        case .artworkOffline: return "Artwork panel: offline"
        case .artworkNoScreenshots: return "Artwork panel: no screenshots"
        case .artworkWarning: return "Artwork panel: low resolution warning"
        case .artworkError: return "Artwork panel: import failed"
        case .filterOwned: return "Filter: owned"
        case .filterMac: return "Filter: Mac"
        case .filterIOS: return "Filter: iPhone"
        case .sortName: return "Sorted by name"
        case .completionExported: return "Finished: IPA exported"
        case .completionNeedsData: return "Finished: game data needed"
        case .sendSending: return "Send game data: sending"
        case .sendSent: return "Send game data: sent"
        case .sendAppNotFound: return "Send game data: no shared app"
        case .sendChooseApp: return "Send game data: several apps"
        case .sendRefused: return "Send game data: refused"
        case .sendFailed: return "Send game data: failed"
        case .sendCopying: return "Copy to a drive: copying"
        case .sendCopied: return "Copy to a drive: copied"
        case .queueEveryState: return "Queue: every state"
        case .queueRunning: return "Queue: running, up next"
        case .transfersEveryState: return "Transfers: every state"
        case .logOpen: return "Build log open"
        case .footerVerifying: return "Activity: verifying the first start"
        case .footerExporting: return "Activity: exporting the IPA"
        case .footerInstalling: return "Activity: installing"
        case .footerRenewing: return "Activity: renewing the signature"
        case .footerSending: return "Activity: sending game data"
        case .appChecking: return "App update: checking"
        case .appDownloading: return "App update: downloading"
        case .appPreparing: return "App update: preparing"
        case .appAvailable: return "App update: available"
        case .engineExperimental: return "Engine: Experimental channel"
        case .missingTool: return "General: a tool is missing"
        case .players: return "Library: players"
        case .libraryFolders: return "Library: folders, one missing"
        case .nxkitIdle: return "nxkit: not checked yet"
        case .nxkitChecking: return "nxkit: checking"
        case .nxkitWaiting: return "nxkit: update waits for the build"
        case .nxkitUnreachable: return "nxkit: check got no answer"
        case .nxkitAppleSilicon: return "nxkit: needs Apple silicon"
        case .nxkitBadSignature: return "nxkit: bad signature"
        case .nxkitChecksum: return "nxkit: checksum"
        case .nxkitIncompatible: return "nxkit: incompatible"
        case .nxkitIncomplete: return "nxkit: incomplete release"
        case .nxkitDownload: return "nxkit: download failed"
        case .nxkitUnpack: return "nxkit: unpack failed"
        case .nxkitCancelled: return "nxkit: update cancelled"
        case .savesNoDevices: return "Saves: no device"
        case .savesNotConnected: return "Saves: device not connected"
        case .savesNotInstalled: return "Saves: game not on the device"
        case .savesReading: return "Saves: reading the device"
        case .savesReady: return "Saves: device read"
        case .savesFailed: return "Saves: device unreachable"
        case .savesTimedOut: return "Saves: device timed out"
        case .freeSpaceRunning: return "Free space: a build runs"
        case .freeSpaceFailed: return "Free space: removal failed"
        case .sendSelectedDrive: return "Copy game data: drive"
        case .deleteGameIOS: return "Delete game: iPhone app"
        case .controllerMapping: return "A game's controller mapping"
        case .frameTimes: return "Frame times: a recording"
        case .dropdownList: return "Dropdown open"
        case .mngLibrary: return "MacNativeGames: built with it, MNG tag"
        case .mngRecommend: return "MacNativeGames: recommended, Download & Switch"
        case .mngRecommendInstalled: return "MacNativeGames: recommended, Switch"
        case .mngBlocked: return "MacNativeGames: title it does not maintain"
        case .mngDropdownDisabled: return "MacNativeGames: dimmed in the engine pop-up"
        case .mngUpdateAvailable: return "MacNativeGames: newer version on GitHub"
        }
    }

    var group: GalleryScene.Group {
        switch self {
        case .filterOwned, .filterMac, .filterIOS, .sortName: return .allGames
        case .completionExported, .completionNeedsData, .sendSending, .sendSent, .sendAppNotFound, .sendChooseApp, .sendRefused, .sendFailed,
             .sendCopying, .sendCopied, .queueEveryState, .queueRunning, .transfersEveryState, .logOpen,
             .footerVerifying, .footerExporting, .footerInstalling, .footerRenewing, .footerSending, .mngRecommend, .mngRecommendInstalled: return .builds
        case .appChecking, .appDownloading, .appPreparing, .appAvailable, .engineExperimental, .missingTool, .players, .libraryFolders,
             .mngBlocked, .mngUpdateAvailable, .mngDropdownDisabled: return .settings
        case .nxkitIdle, .nxkitChecking, .nxkitWaiting, .nxkitUnreachable, .nxkitAppleSilicon, .nxkitBadSignature, .nxkitChecksum,
             .nxkitIncompatible, .nxkitIncomplete, .nxkitDownload, .nxkitUnpack, .nxkitCancelled: return .nxkit
        case .savesNoDevices, .savesNotConnected, .savesNotInstalled, .savesReading, .savesReady, .savesFailed, .savesTimedOut,
             .freeSpaceRunning, .freeSpaceFailed, .sendSelectedDrive, .deleteGameIOS, .controllerMapping, .frameTimes: return .sheets
        case .dropdownList: return .design
        default: return .library
        }
    }

    /// A scene taller than the window: Settings' update part is under the fold.
    var size: CGSize? {
        switch self {
        case .appChecking, .appDownloading, .appPreparing, .appAvailable, .players: return CGSize(width: 1280, height: 1500)
        case .logOpen, .transfersEveryState: return CGSize(width: 1280, height: 2000)
        default: return nil
        }
    }

    /// A sheet: drawn without the title bar, at its own size (nil: its width, its content's height).
    var isSheet: Bool { group == .sheets }
    var sheetSize: CGSize? {
        switch self {
        case .savesNoDevices, .savesNotConnected, .savesNotInstalled, .savesReading, .savesReady, .savesFailed, .savesTimedOut: return CGSize(width: 600, height: 560)
        case .freeSpaceRunning, .freeSpaceFailed: return CGSize(width: 560, height: 690)
        case .sendSelectedDrive, .controllerMapping: return CGSize(width: 680, height: 720)
        case .frameTimes: return CGSize(width: 720, height: 300)
        default: return nil
        }
    }
}

extension GalleryFixtures {
    func desktopView(_ scene: GalleryDesktopScene, stores: LauncherStores, library: GameLibrary, controls: ControlLayout,
                     launcher: (GalleryLauncher) -> AnyView) -> AnyView {
        let build = stores.build
        let t = stores.localizer.t
        let game = library.games.first ?? LibraryGame(titleID: catalog[0].titleID, name: catalog[0].name)
        func edit(_ index: Int, _ change: (inout LibraryGame) -> Void) {
            guard library.games.indices.contains(index) else { return }
            var entry = library.games[index]
            change(&entry)
            library.upsert(entry)
        }
        func file(_ name: String) -> String {
            let url = directory.appendingPathComponent("files-" + UUID().uuidString).appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: url)
            return url.path
        }
        /// A stand-in iOS app on a device: its Info.plist, so the library sees the game as installed there.
        func onDevice(_ index: Int) {
            let app = directory.appendingPathComponent("ios-" + UUID().uuidString + "/Game.app")
            try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try? PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.nxnative.gallery.ios"], format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Info.plist"))
            stores.deviceStore.devices = [AppleDevice(id: "gallery-iphone", name: "iPhone", model: "iPhone17,1", os: "26.1", reachable: true)]
            edit(index) { $0.iosAppPath = app.path; $0.installedDevice = "gallery-iphone" }
        }
        func assessment(_ state: HeroRefreshState) -> GameRefreshAssessment {
            GameRefreshAssessment(heroState: state, hasSpecificUpdate: true, versionLabel: "1.2.0", canFastRefreshMac: true, canFastRefreshIOS: false,
                                  needsMissingImgGuideIOS: false, missingOriginalPackage: false, hasUsableSeed: true)
        }
        func artwork(_ slot: ArtworkSlot, media: ArtworkStore.MediaLoad?, notice: ArtworkEditor.Notice? = nil) -> AnyView {
            let fixed = media
            let banner = library.artworkDirectory.appendingPathComponent(game.titleID.uppercased() + ".jpg")
            let env = ArtworkEditorEnvironment(
                media: { _, _ in
                    guard let fixed else { try? await Task.sleep(nanoseconds: 3_600_000_000_000); return .none }   // loading: never answers
                    return fixed
                },
                candidate: { _, _ in banner }, cachedCandidate: { _, _ in banner },
                banner: { _ in FileManager.default.fileExists(atPath: banner.path) ? banner : nil },
                prepare: { _, _, _ in throw CocoaError(.featureUnsupported) }, pixelWidth: { _ in 1280 },
                pixelSize: { _ in CGSize(width: 1280, height: 720) }, removeFile: { _ in })
            let editor = ArtworkEditor(game: game, slot: slot, artworkDirectory: library.artworkDirectory, env: env, labels: t)
            if let notice { editor.showNoticeForGallery(notice) }
            return launcher(GalleryLauncher(artworkEditor: editor))
        }
        func nxkit(_ state: NxkitUpdateState) -> AnyView {
            build.selectUpstream(.nxkit)
            build.setNxkitUpdateForGallery(state)
            return launcher(GalleryLauncher(page: .settings, category: .tools))
        }
        func send(_ state: DataSend, drive: Bool = false) -> AnyView {
            configureBuild(stores, library: library)
            build.target = BuildTarget.ios
            build.runningTarget = BuildTarget.ios
            build.exportedIPAPath = "/Volumes/Games/NX2Apple.ipa"
            build.archivePath = "/Volumes/Games/games/" + game.titleID
            build.stages = [Stage(id: 1, name: "Shaders", state: .done), Stage(id: 2, name: "Export", state: .done)]
            build.done = true
            if drive { stores.deviceStore.sendWhere = SendWhere.drive }
            build.send = state
            return launcher(GalleryLauncher(page: .builds, editor: true, step: 2))
        }
        func footer(_ kind: ActiveOperation.Kind) -> AnyView {
            configureBuild(stores, library: library)
            build.running = true
            build.stages = [Stage(id: 1, name: "Sign", state: .running, detail: "", percent: 55)]
            build.setOperationForGallery(ActiveOperation(kind: kind, game: game.name, titleID: game.titleID))
            return launcher(GalleryLauncher())
        }
        func saves(_ state: SavesModel.DeviceState) -> AnyView {
            onDevice(0)
            return AnyView(SavesView(m: build, library: library, gameID: game.id, devicectl: DeviceControl { _ in (false, "") },
                                     support: directory.appendingPathComponent("support", isDirectory: true), listDevices: { [] }, galleryState: state))
        }
        func queueEntry(_ index: Int, _ status: QueueEntry.Status, reason: String? = nil) -> QueueEntry {
            let g = library.games[min(index, library.games.count - 1)]
            var entry = QueueEntry(game: g, engineID: stores.engineSync.selection.engineID, target: BuildTarget.mac, batch: UUID(),
                                   packageAfter: false, exportIPA: nil, exportFramework: nil)
            entry.status = status
            entry.reason = reason
            return entry
        }

        switch scene {
        case .cardEveryState:
            // 0 Mac, 1 iPhone only, 2 both, 3 building, 4 files to fix, 5 not built, the rest without their files
            _ = makeMacApp(for: 0, in: library)
            let ipa = file("Game.ipa")
            edit(1) { $0.ipaPath = ipa }
            _ = makeMacApp(for: 2, in: library)
            edit(2) { $0.ipaPath = ipa }
            let broken = directory.appendingPathComponent("broken-" + UUID().uuidString + "/Game.app")
            try? FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            edit(4) { $0.appPath = broken.path }
            let base = file("base.nsp")
            edit(5) { $0.inputs["base"] = [base] }
            build.buildingGame = true   // the building card's game: a build runs for it
            build.running = true
            return launcher(GalleryLauncher(allGames: true, activeBuildID: library.games[3].id))
        case .heroPlay:
            _ = makeMacApp(for: 0, in: library)
            return launcher(GalleryLauncher(assessments: [game.id: assessment(.upToDate)]))
        case .heroOnDevice:
            onDevice(0)
            return launcher(GalleryLauncher())
        case .heroRefreshFast, .heroRefreshFull:
            _ = makeMacApp(for: 0, in: library)
            let state: HeroRefreshState = scene == .heroRefreshFast ? .specificFast(version: "1.2.0") : .specificFull(version: "1.2.0")
            return launcher(GalleryLauncher(assessments: [game.id: assessment(state)]))
        case .heroSignature:
            onDevice(0)
            return launcher(GalleryLauncher(gallery: LauncherGalleryState(signatureExpiry: [game.id: Date().addingTimeInterval(36 * 3600)])))
        case .heroResign:
            onDevice(0)
            return launcher(GalleryLauncher(gallery: LauncherGalleryState(resignNote: t("dev.resignNoTeam"))))
        case .heroUnverified:
            // a game the engine has no verified profile for, chosen
            var extra = LibraryGame(titleID: "0100000000FF0000", name: "Harbor Lights")
            extra.inputs["base"] = ["/Volumes/Games/Harbor Lights.nsp"]
            library.upsert(extra)
            library.selectedID = library.games.first { $0.titleID == extra.titleID }?.id
            return launcher(GalleryLauncher(gallery: LauncherGalleryState(profileHelpOpen: true)))
        case .manageMenu, .manageMenuPad:
            _ = makeMacApp(for: 0, in: library)
            return launcher(GalleryLauncher(manageOpen: true, padRing: scene == .manageMenuPad))
        case .noArtwork:
            let bare = GameLibrary(file: directory.appendingPathComponent("bare-\(UUID().uuidString).json"),
                                   artwork: directory.appendingPathComponent("no-artwork-\(UUID().uuidString)", isDirectory: true))
            bare.applicationFolders = []
            for (index, entry) in catalog.prefix(6).enumerated() {
                var g = LibraryGame(titleID: entry.titleID, name: entry.name)
                g.lastPlayed = Date(timeIntervalSince1970: 1_790_000_000 - Double(index) * 86_400)
                bare.upsert(g)
            }
            bare.selectedID = bare.games.first?.id
            return AnyView(LauncherView(stores: stores, library: bare, performStartupChecks: false, controls: controls,
                                        artworkStore: ArtworkStore(directory: bare.artworkDirectory, titleList: directory.appendingPathComponent("no-titles.json"), fallbacks: [:])))
        case .consolePrompt:
            return launcher(GalleryLauncher(prompt: true))
        case .controllerToast:
            let driver = MockConsoleDriver(scenario: .full, lang: lang, animated: false)
            driver.state.toast = ConsoleToast(message: String(format: L10n.string("console.connected", lang), L10n.string("console.demoController2", lang), 2))
            return launcher(GalleryLauncher(driver: AnyConsoleDriver(driver)))
        case .buildJustFinished:
            configureBuild(stores, library: library)
            let app = makeMacApp(for: 0, in: library)
            build.runningTarget = BuildTarget.mac
            build.macAppPath = library.games.first { $0.id == app }?.appPath ?? ""
            build.stages = [Stage(id: 1, name: "Shaders", state: .done), Stage(id: 2, name: "Package", state: .done)]
            build.done = true
            return launcher(GalleryLauncher())
        case .artworkHero: return artwork(.hero, media: .loaded(ArtworkStore.Media(screenshots: ["one", "two", "three"])))
        case .artworkThumbnail: return artwork(.thumbnail, media: ArtworkStore.MediaLoad.none)
        case .artworkLoading: return artwork(.hero, media: nil)
        case .artworkOffline: return artwork(.hero, media: .offline)
        case .artworkNoScreenshots: return artwork(.thumbnail, media: ArtworkStore.MediaLoad.none)
        case .artworkWarning: return artwork(.hero, media: ArtworkStore.MediaLoad.none, notice: .warning(String(format: t("artwork.lowResWarning"), 640)))
        case .artworkError: return artwork(.hero, media: ArtworkStore.MediaLoad.none, notice: .error(t("artwork.saveFailed")))
        case .filterOwned, .filterMac, .filterIOS:
            _ = makeMacApp(for: 0, in: library)
            _ = makeMacApp(for: 2, in: library)
            let ipa = file("Game.ipa")
            edit(1) { $0.ipaPath = ipa }
            edit(2) { $0.ipaPath = ipa }
            let filter: LibraryFilter = [GalleryDesktopScene.filterOwned: .owned, .filterMac: .mac][scene] ?? .ios
            filter.saveDesktop(stores.defaults)
            return launcher(GalleryLauncher(allGames: true))
        case .sortName:
            LibrarySort.name.save(stores.defaults)
            return launcher(GalleryLauncher(allGames: true))
        case .completionExported: return send(.idle)
        case .completionNeedsData:
            configureBuild(stores, library: library)
            build.target = BuildTarget.ios
            build.runningTarget = BuildTarget.ios
            build.installedOn = "iPhone"
            build.archivePath = "/Volumes/Games/games/" + game.titleID
            build.installedDataComplete = false
            build.stages = [Stage(id: 1, name: "Shaders", state: .done), Stage(id: 2, name: "Install", state: .done)]
            build.done = true
            return launcher(GalleryLauncher(page: .builds, editor: true, step: 2))
        case .sendSending: return send(.sending(done: 1_200_000_000, total: 2_900_000_000, note: String(format: t("shell.copyWired"), "iPhone")))
        case .sendSent: return send(.sent(app: "NX2Apple"))
        case .sendAppNotFound: return send(.appNotFound)
        case .sendChooseApp: return send(.chooseApp([InstalledApp(bundle: "org.nxnative.shell", name: "NX2Apple"), InstalledApp(bundle: "com.example.shell", name: "NX2Apple (2)")]))
        case .sendRefused: return send(.refused(detail: "ERROR: The operation couldn't be completed. (com.apple.dt.CoreDeviceError error 7000.)"))
        case .sendFailed: return send(.failed("The device is locked."))
        case .sendCopying: return send(.copying(done: 800_000_000, total: 2_900_000_000), drive: true)
        case .sendCopied: return send(.copied(folder: "/Volumes/Transfer/NX2Apple/" + game.titleID), drive: true)
        case .queueEveryState:
            stores.queue.showForGallery([queueEntry(1, .done), queueEntry(2, .failed, reason: "Shaders: exit code 1"), queueEntry(3, .skipped),
                                         queueEntry(4, .stopped), queueEntry(5, .queued), queueEntry(6, .queued)])
            return launcher(GalleryLauncher(page: .builds))
        case .queueRunning:
            configureBuild(stores, library: library)
            build.buildingGame = true
            build.running = true
            build.overallProgress = 0.35
            build.stages = [Stage(id: 1, name: "Shaders", state: .running, detail: "12 / 50", percent: 24)]
            stores.queue.showForGallery([queueEntry(0, .running), queueEntry(1, .queued), queueEntry(2, .queued), queueEntry(3, .queued)])
            return launcher(GalleryLauncher(page: .builds))
        case .transfersEveryState:
            let statuses: [TransferEntry.Status] = [.sending, .queued, .waiting, .failed, .done, .cancelling]
            stores.transfers.showForGallery(statuses.enumerated().map { index, status in
                let g = library.games[index]
                return TransferEntry(titleID: g.titleID, name: g.name, archive: "/Volumes/Games/games/" + g.titleID, deviceID: "gallery-iphone",
                                     deviceName: "iPhone", status: status, doneBytes: status == .sending ? 900_000_000 : 0, totalBytes: 2_400_000_000,
                                     reason: status == .failed ? "The device is locked." : nil)
            })
            return launcher(GalleryLauncher(page: .builds))
        case .logOpen:
            configureBuild(stores, library: library)
            for line in ["== Extract", "romfs: 1834 files", "== Shaders", "translating 412 programs", "shader cache: 380 reused, 32 new", "== Package", "Built Marble Orchard.app"] {
                build.say(line)
            }
            return launcher(GalleryLauncher(page: .builds, gallery: LauncherGalleryState(buildLogOpen: true)))
        case .footerVerifying: return footer(.verifyingFirstStart)
        case .footerExporting: return footer(.exportingIPA)
        case .footerInstalling: return footer(.installing)
        case .footerRenewing: return footer(.renewingSignature)
        case .footerSending: return footer(.sendingGameData)
        case .appChecking, .appDownloading, .appPreparing, .appAvailable:
            stores.appUpdates.update = AppUpdate.Release(tag: "v1.2.0", url: "", digest: nil, notes: "## What is new\n\n- The state gallery shows every state.")
            switch scene {
            case .appChecking: stores.appUpdates.setPhaseForGallery(.checking)
            case .appDownloading: stores.appUpdates.setPhaseForGallery(.downloading, progress: 0.42)
            case .appPreparing: stores.appUpdates.setPhaseForGallery(.preparing)
            default: break
            }
            return launcher(GalleryLauncher(page: .settings))
        case .engineExperimental:
            stores.engineSync.selection = EngineSelection(channel: .experimental, engineID: String(repeating: "e", count: 40), version: "1.6.0-beta", previousID: "")
            if stores.engineSync.bundle == nil { stores.engineSync.bundle = URL(fileURLWithPath: "/nonexistent/nx-gallery-engine") }
            return launcher(GalleryLauncher(page: .settings, category: .tools))
        case .missingTool:
            stores.dependencies.deps = [Dep(id: "xcode", name: "Xcode", hint: "", present: true, installCmd: []),
                                        Dep(id: "python", name: "Python 3.12", hint: "", present: false, installCmd: [])]
            return launcher(GalleryLauncher(page: .settings))
        case .players:
            stores.players.create(name: "Alex")
            stores.players.create(name: "Sam")
            return launcher(GalleryLauncher(page: .settings, category: .library))
        case .libraryFolders:
            let games = directory.appendingPathComponent("Games", isDirectory: true)
            try? FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
            library.addFolder(games)
            library.addFolder(URL(fileURLWithPath: "/Volumes/NX-Gallery-Archive/Switch"))   // a drive that is not connected
            return launcher(GalleryLauncher(page: .settings, category: .library))
        case .nxkitIdle: return nxkit(.idle)
        case .nxkitChecking: return nxkit(.checking)
        case .nxkitWaiting: return nxkit(.waitingForBuild("0.11.0"))
        case .nxkitUnreachable: return nxkit(.unreachable)
        case .nxkitBadSignature: return nxkit(.rejected("0.11.0", .badSignature))
        case .nxkitChecksum: return nxkit(.rejected("0.11.0", .checksum))
        case .nxkitIncompatible: return nxkit(.rejected("0.11.0", .incompatible(.macOS("27.0"))))
        case .nxkitIncomplete: return nxkit(.rejected("0.11.0", .incomplete))
        case .nxkitDownload: return nxkit(.rejected("0.11.0", .download))
        case .nxkitUnpack: return nxkit(.rejected("0.11.0", .unpack))
        case .nxkitCancelled: return nxkit(.rejected("0.11.0", .cancelled))
        case .nxkitAppleSilicon:
            build.nxkitAvailability = .needsAppleSilicon
            build.refreshNxkit()
            return launcher(GalleryLauncher(page: .settings, category: .tools))
        case .savesNoDevices: return saves(.noDevices)
        case .savesNotConnected: return saves(.notConnected)
        case .savesNotInstalled: return saves(.notInstalled)
        case .savesReading: return saves(.reading)
        case .savesReady: return saves(.ready(SaveTransfer.Contents(newest: Date(timeIntervalSince1970: 1_789_990_000))))
        case .savesFailed: return saves(.failed("ERROR: The device is locked."))
        case .savesTimedOut: return saves(.timedOut)
        case .freeSpaceRunning, .freeSpaceFailed:
            let outcome = scene == .freeSpaceRunning ? t("free.running") : String(format: t("free.failed"), FreeSpaceError.notABuildFolder("/Volumes/Games").localizedDescription)
            return AnyView(FreeSpaceView(m: build, game: game, survey: BuildFolderSurvey(folder: "/Volumes/Games/\(game.name)/\(game.titleID)_build",
                                                                                      sizes: [.extracted: 9_800_000_000, .shaders: 5_850_000_000], kept: 0, oldShaders: []),
                                         outcome: outcome))
        case .sendSelectedDrive:
            return AnyView(SendSelectedSheet(mode: .drive, build: build, close: {}))
        case .deleteGameIOS:
            let id = game.titleID
            return AnyView(DeleteGameSheet(game: game, shellRoot: "", plan: GameDeletion(titleID: id, items: [
                .init(kind: .ipa, paths: ["/Volumes/Games/\(id).ipa"], bytes: 380_000_000),
                .init(kind: .iosApp, paths: ["/Volumes/Games/\(game.name)/\(id).app"], bytes: 410_000_000)],
                saves: nil, shellRoot: nil)))
        case .controllerMapping:
            _ = makeMacApp(for: 0, in: library)
            let built = library.games.first ?? game
            return AnyView(GameControllerMappingView(game: built, globalControls: controls))
        case .frameTimes:
            let folder = directory.appendingPathComponent("frame-times-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let tsv = folder.appendingPathComponent("2026-11-20 19.04.tsv")
            var rows: [String] = []
            for n in 0..<600 {
                let ms = 16.6 + (n % 97 == 0 ? 48 : sin(Double(n) / 9) * 2.5)
                rows += ["\(n)\t@t_s\t\(Double(n) / 60)", "\(n)\t@frame_ms\t\(ms)", "\(n)\t@presented_ms\t\(n % 211 == 0 ? -1 : ms)"]
            }
            try? rows.joined(separator: "\n").write(to: tsv, atomically: true, encoding: .utf8)
            return AnyView(DSCard { FrameTimesRecordingView(file: tsv, t: t) }.padding(DS.Space.l))
        case .mngLibrary, .mngRecommend, .mngRecommendInstalled, .mngBlocked, .mngDropdownDisabled, .mngUpdateAvailable:
            return macNativeGamesView(scene, stores: stores, library: library, launcher: launcher)
        case .dropdownList:   // the list a dropdown opens, as the launcher's dropdown layer draws it under its button
            let options = Lang.all.map { (value: $0.code, label: $0.name) }
            return AnyView(LauncherDropdownList(options: options, selection: lang.code, label: t("settings.language"), choose: { _ in }, close: {})
                .frame(width: 280).padding(DS.Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        }
    }
}
