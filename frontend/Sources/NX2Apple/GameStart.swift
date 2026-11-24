import AppKit
import Foundation
import NXCore
import NXLauncher

/// What Play starts a Mac game with, in one place: the desktop launcher's Play button and the console mode both use it, so a
/// game gets the same environment from either (the saved choices for an app that does not read them itself, the mods, the Controls
/// page's layout for older builds, shared saved maps for capable builds, DM_PAD_MERGE, DM_SCREEN and DM_LAUNCHER=0). Console mode plays on a TV-sized screen with a controller, so it asks for
/// `fullscreen`, which forces DM_FULLSCREEN on whatever the game's Display setting says, and `homeMenu`, the Home menu's way back to it (#952).
enum GameStart {
    @MainActor static func environment(for game: LibraryGame, library: GameLibrary, controls: ControlLayout, repo: String,
                                       labels: (String) -> String, lang: Lang = Lang.initial(), fullscreen: Bool = false, player: PlayerProfile? = nil,
                                       saves: (global: SaveGlobalSettings, game: SaveGameOverride)? = nil,
                                       sticks: StickDeadzoneSettings? = nil, homeMenu: Bool = false, launcherBundleID: String? = Bundle.main.bundleIdentifier,
                                       screen: NSScreen? = NSApp?.keyWindow?.screen ?? NSScreen.main,
                                       defaults: UserDefaults = .standard) -> [String: String] {
        library.migrateLaunchOptions()
        CloudSavesMigration.run()   // before the app reads its env.txt: DM_SAVE_SYNC=icloud keeps the folder the iPhone app uses
        let settings = LaunchSetting.forMac(app: game.appPath, titleID: game.titleID, repo: repo, labels: labels) ?? []
        let overrides = game.launchEnvironment(settings).merging(game.controllerLaunchOverrides) { _, manual in manual }
        let savingEnabled = game.controllerSavingEnabled(environment: overrides)
        let mappings = SavedChoices.appReadsControllerMappings(app: game.appPath) ? game.controllerPreferences() : nil
        // nxkit's host reads no DM_ROMFS_OVERLAY: an app it built starts without the mods
        let mods = NxkitLaunch.isNxkit(app: game.appPath) ? [] : GameMod.list(in: GameMod.folder(for: game, library: library.folder), titleID: game.titleID)
        var environment = game.startEnvironment(controls: controls.environment, settings: settings, mods: mods,
                                                store: SavedChoices(app: game.appPath, titleID: game.titleID),
                                                appReadsStore: SavedChoices.appReadsStore(app: game.appPath),
                                                controllerStore: mappings, savingEnabled: savingEnabled)
        if fullscreen, settings.contains(where: { $0.env == "DM_FULLSCREEN" }) { environment["DM_FULLSCREEN"] = "1" }
        if let id = GameDisplay.displayID(savedUUID: defaults.string(forKey: GameDisplay.defaultsKey) ?? "", launcher: screen, screens: NSScreen.screens) {
            environment["DM_SCREEN"] = String(id)
        }
        environment["DM_HOME_QUIT_TEXT"] = HomeButtonHint.promptText(gameName: game.displayName(lang), labels: labels, homeMenu: homeMenu)   // the game's Home button quit prompt in the launcher's language (#336)
        // Console mode's game: the Home menu's Back to console mode, which pauses it in the background (#952). The desktop's Play passes none.
        if homeMenu { environment.merge(HomeButtonHint.homeMenuEnvironment(launcherBundleID: launcherBundleID)) { $1 } }
        if let sticks { environment.merge(sticks.environment) { _, own in own } }
        // An app nxkit built reads nxkit's names only: full screen from console mode (the player's own choice is its NXKIT_FULLSCREEN
        // row, a saved choice the host reads itself), the screen, the Home button's texts and the Controls page's maps. From console
        // mode it opens over the console (overlay): the Starting screen is its loading screen and Quit fades it out with the console
        // right under it. Its Home menu has Resume and Quit: no launcher is named, so it has no Back to console mode
        if NxkitLaunch.isNxkit(app: game.appPath) {
            let nxkit = NxkitLaunch.environment(fullscreen: fullscreen || environment["DM_FULLSCREEN"] == "1",
                                                displayID: environment["DM_SCREEN"].flatMap(UInt32.init),
                                                homeText: environment["DM_HOME_QUIT_TEXT"],
                                                overlay: homeMenu)
            environment.merge(nxkit) { $1 }
            environment.merge(NxkitLaunch.controlMaps(environment)) { $1 }
        }   // DM_STICK_DEADZONE_L / _R: off adds nothing
        // The global setup and this game's own choices (SaveLocation.swift): a save folder and a cloud folder, under the names of
        // the app's engine (SaveEngine.swift). Engines whose saves are outside launcher management (MNG, S2Arm) receive neither DM_SAVE nor DM_SAVE_SYNC.
        let engine = SaveEngines.forApp(game.appPath, titleID: game.titleID)
        if engine.managesSavesInLauncher {
            var base = SaveTransfer.macSave(titleID: game.titleID, appPath: game.appPath, engine: engine).save
            if let saves {
                let own = GameCloudSaves(titleID: game.titleID, appPath: game.appPath).setting
                let save = SaveLocations.effectiveSave(titleID: game.titleID, appPath: game.appPath, global: saves.global, game: saves.game, engine: engine)
                let cloud = SaveLocations.effectiveCloud(global: saves.global, game: saves.game, own: own)
                let saveEnv = SaveLocations.environment(save: save, cloud: cloud, engine: engine)
                if let folder = saveEnv[engine.saveKey] { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
                environment.merge(saveEnv) { $1 }
                base = save.path
            }
            // The player's own save folder (PlayerProfile.swift); the default player adds nothing, so their saves stay where they were
            if let player {
                let playerEnv = player.environment(base: base, existing: environment, engine: engine)
                if let save = playerEnv[engine.saveKey] { try? FileManager.default.createDirectory(atPath: save, withIntermediateDirectories: true) }
                environment.merge(playerEnv) { $1 }
            }
        }
        return environment
    }

    /// The display the game's window should open on: the launcher window's screen (front_mac.m DM_SCREEN reads this NSScreenNumber).
    static func displayID(of screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Tracks armed Mac cheat sessions by process ID and generation token: disarms after 30 s of stable play
/// (or on a >= 30 s exit), and trips the crash fuse if the game exits within 30 s.
@MainActor final class CheatFuseMonitor {
    static let shared = CheatFuseMonitor()

    struct PendingArm {
        let token: UInt64
        let files: CheatFiles
        let buildID: String
        let appURL: URL
        let startedAt: Date
    }

    private struct ActiveSession {
        let token: UInt64
        let files: CheatFiles
        let buildID: String
        let appURL: URL
        let startedAt: Date
        let timer: Task<Void, Never>
    }

    private let isProcessAlive: (Int32, URL) -> Bool
    private var nextToken: UInt64 = 0
    private var sessions: [Int32: ActiveSession] = [:]

    init(isProcessAlive: @escaping (Int32, URL) -> Bool = CheatFuseMonitor.defaultIsProcessAlive) {
        self.isProcessAlive = isProcessAlive
    }

    static func defaultIsProcessAlive(pid: Int32, appURL: URL) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        guard let runningURL = app.bundleURL?.standardizedFileURL else { return false }
        return runningURL == appURL.standardizedFileURL
    }

    /// Recovers any leftover armed receipt from a prior crash, then arms the new Mac launch if cheats will run.
    func prepareAndArm(for game: LibraryGame, shellRoot: String = "", support: URL? = nil, now: Date = Date()) -> PendingArm? {
        let files = support.map { CheatFiles(titleID: game.titleID, support: $0) } ?? CheatFiles(titleID: game.titleID)
        if !SaveTransfer.runningOnMac(titleID: game.titleID) {
            files.recoverIfArmed(now: now)
        }
        let buildID = CheatFiles.buildID(appPath: game.appPath, iosAppPath: game.iosAppPath, titleID: game.titleID, shellRoot: shellRoot)
        guard let armed = files.armBeforeLaunch(buildID: buildID, now: now) else { return nil }
        nextToken &+= 1
        return PendingArm(
            token: nextToken,
            files: files,
            buildID: armed.buildID,
            appURL: URL(fileURLWithPath: game.appPath).standardizedFileURL,
            startedAt: now
        )
    }

    /// Cancels an armed receipt if LaunchServices failed to start the game process.
    func abort(_ pending: PendingArm?) {
        guard let pending else { return }
        if let armed = pending.files.readArmed(), armed.buildID == pending.buildID {
            try? FileManager.default.removeItem(at: pending.files.armedFile)
        }
    }

    /// Binds an armed receipt to the launched process ID and schedules automatic disarm after `delaySeconds`.
    func didStart(pid: Int32, pending: PendingArm?, delaySeconds: TimeInterval = CheatFiles.fuseDisarmSeconds) {
        guard let pending else { return }
        sessions[pid]?.timer.cancel()
        let token = pending.token
        let timer = Task { [weak self] in
            let ns = UInt64(max(0, delaySeconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled, let self, let active = self.sessions[pid], active.token == token else { return }
            guard self.isProcessAlive(pid, active.appURL) else { return }
            active.files.disarmAndRecordStable(expectedBuildID: active.buildID)
            self.sessions.removeValue(forKey: pid)
        }
        sessions[pid] = ActiveSession(
            token: token,
            files: pending.files,
            buildID: pending.buildID,
            appURL: pending.appURL,
            startedAt: pending.startedAt,
            timer: timer
        )
    }

    /// Resolves a tracked process exit: disarms as stable at >= threshold, otherwise trips the fuse.
    @discardableResult
    func didExit(pid: Int32, threshold: TimeInterval = CheatFiles.fuseDisarmSeconds, now: Date = Date()) -> CheatFiles.TrippedReceipt? {
        guard let active = sessions.removeValue(forKey: pid) else { return nil }
        active.timer.cancel()
        let elapsed = now.timeIntervalSince(active.startedAt)
        return active.files.handleProcessExit(elapsed: elapsed, threshold: threshold, now: now)
    }
}
