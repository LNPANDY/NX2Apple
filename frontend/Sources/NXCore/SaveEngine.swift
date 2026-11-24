import Foundation

/// What the launcher's save flow needs of the engine that runs a Mac game: where the save is when the launcher names none,
/// the names of the environment that sets a save folder, a cloud folder and the player's choice before the start, and the
/// commands that compare and send the cloud's save. The save's layout around its folder (`_device`, `.sync`, `-backups`) and
/// the cloud file are the same for both engines (nxkit R67 to R69 ported dm/host/hle_fs.c and dm/host/save_sync.c), so the
/// save location, the players and the cloud saves run through one flow with one of these.
package protocol SaveEngine: Sendable {
    /// The committed save folder.
    var saveKey: String { get }
    /// The cloud saves folder: a path, `icloud` or `0`.
    var syncKey: String { get }
    /// The player's choice before the start (CloudSaveCheck.Choice).
    var choiceKey: String { get }
    /// The choice passed when the player was not asked, nil for none.
    var unaskedChoice: String? { get }
    /// The shared pipeline list of a player's own save folder (PlayerProfile), nil when the engine keeps none beside the save.
    var psoUserKey: String? { get }
    /// The engine keeps the save of an app in a library folder beside the app, `save/<title ID>`.
    var savesInLibraryFolder: Bool { get }
    /// True when the launcher manages this engine's save folder, import/export, player isolation, and cloud sync.
    var managesSavesInLauncher: Bool { get }
    /// True when this engine shares the same `dm` save folder as `nxnative`.
    var sharesSaveWithNxnative: Bool { get }
    /// True when `SaveLocations.environment` must always emit `saveKey` even for `.standard` paths.
    var alwaysInjectsSavePath: Bool { get }
    /// True when the launcher itself handles pre-launch pull and post-exit push against `save.dmsync`.
    var syncsCloudInLauncher: Bool { get }
    /// The save when the launcher names none.
    func defaultSave(titleID: String, support: URL) -> URL
    /// Engine-owned save and backup paths to remove when deleting a build (when `managesSavesInLauncher` is false).
    func deletionPaths(titleID: String, support: URL) -> [String]
    /// What a player adds besides the save folder. `name` is empty for a player who kept the default name.
    func playerEnvironment(name: String) -> [String: String]
    /// The engine follows the player's choice before the start.
    func takesChoice(app: String) -> Bool
    /// The command that prints the `save_sync_report` line before the start, waiting at most `wait` for the cloud's file. It runs
    /// with the game's environment, the only place such an engine reads its save and cloud folder from. nil when the launcher
    /// compares the saves itself (CloudSaveCheck) with the cloud folder the game set for itself (GameCloudSaves).
    func reportCommand(app: String, wait: TimeInterval) -> [String]?
    /// The command that sends what the game committed and did not send, after it ended. nil when the engine sends at its exit.
    func sendCommand(app: String) -> [String]?
}

extension SaveEngine {
    package var managesSavesInLauncher: Bool { true }
    package var sharesSaveWithNxnative: Bool { false }
    package var alwaysInjectsSavePath: Bool { false }
    package var syncsCloudInLauncher: Bool { false }
    package func deletionPaths(titleID: String, support: URL) -> [String] { [] }
}

package enum SaveEngines {
    /// Save engine descriptor for an explicitly known upstream kind without an `.app` bundle context.
    package static func forUpstream(_ upstream: EngineUpstreamKind) -> any SaveEngine {
        switch upstream {
        case .nxnative, .kidWithSword, .noLagKart:
            return DmSaveEngine()
        case .nxkit:
            return NxkitSaveEngine()
        case .macNativeGames:
            return MacNativeGamesSaveEngine()
        case .s2arm:
            return S2ArmSaveEngine()
        }
    }

    /// Save engine descriptor for an app bundle, resolving whether an MNG build supports #2375 shared `DM_SAVE`.
    package static func forApp(
        _ path: String,
        titleID: String? = nil,
        fallbackUpstream: EngineUpstreamKind? = nil
    ) -> any SaveEngine {
        guard !path.isEmpty else {
            return fallbackUpstream.map(forUpstream) ?? DmSaveEngine()
        }
        if let bundle = try? MacGameBundle.read(URL(fileURLWithPath: path)) {
            if bundle.upstream == .macNativeGames,
               MngSharedSave.appSupportsSharedDMSave(appPath: path, titleID: titleID ?? bundle.titleID) {
                return MngSharedDmSaveEngine()
            }
            return forUpstream(bundle.upstream)
        }
        if let detected = detectExternalUpstream(at: path) {
            if detected == .macNativeGames,
               MngSharedSave.appSupportsSharedDMSave(appPath: path, titleID: titleID) {
                return MngSharedDmSaveEngine()
            }
            return forUpstream(detected)
        }
        if let fallbackUpstream {
            if fallbackUpstream == .macNativeGames,
               MngSharedSave.appSupportsSharedDMSave(appPath: path, titleID: titleID) {
                return MngSharedDmSaveEngine()
            }
            return forUpstream(fallbackUpstream)
        }
        return DmSaveEngine()
    }

    /// Fallback detection when a bundle's Info.plist lacks binaries or title ID keys (e.g. partial builds or test stubs).
    private static func detectExternalUpstream(at path: String) -> EngineUpstreamKind? {
        let appURL = URL(fileURLWithPath: path)
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plistURL),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            let explicit = (info["DMUpstream"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let bundleID = (info["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let executable = (info["CFBundleExecutable"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if explicit == EngineUpstreamKind.macNativeGames.rawValue
                || (explicit == nil && (EngineUpstream.macNativeGamesBundleTitleIDs[bundleID] != nil || bundleID.hasPrefix("org.macnativegames."))) {
                return .macNativeGames
            }
            if explicit == EngineUpstreamKind.s2arm.rawValue
                || (explicit == nil && (bundleID == "org.s2arm.macos.game" || bundleID.hasPrefix("org.s2arm.") || executable == "s2arm-host" || executable == "s2arm-launch")) {
                return .s2arm
            }
            if explicit == EngineUpstreamKind.nxkit.rawValue
                || (explicit == nil && (bundleID.hasPrefix("org.nxkit.game.") || executable == NxkitBuilder.hostName)) {
                return .nxkit
            }
        }
        let stem = appURL.deletingPathExtension().lastPathComponent
        for kind in [EngineUpstreamKind.macNativeGames, .s2arm, .nxkit] {
            if !kind.appFilenameSuffix.isEmpty && stem.hasSuffix(" [\(kind.appFilenameSuffix)]") {
                return kind
            }
        }
        return nil
    }
}

/// The nxnative engine (dm): dm/mac/launcher.c reads `DM_SAVE` and `DM_SAVE_SYNC`, keeps a library folder's save beside the
/// app, and dm/host/save_sync.c sends at the game's exit. The launcher compares the saves itself before the start.
package struct DmSaveEngine: SaveEngine {
    package init() {}
    package var saveKey: String { "DM_SAVE" }
    package var syncKey: String { CloudSaveSync.key }
    package var choiceKey: String { "DM_SAVE_SYNC_CHOICE" }
    package var unaskedChoice: String? { nil }
    package var psoUserKey: String? { "DM_PSO_USER" }
    package var savesInLibraryFolder: Bool { true }
    package var sharesSaveWithNxnative: Bool { true }

    package func defaultSave(titleID: String, support: URL) -> URL {
        support.appendingPathComponent("nxnative").appendingPathComponent(titleID).appendingPathComponent("save")
    }

    package func playerEnvironment(name: String) -> [String: String] { [:] }

    /// Info.plist `DMSaveSyncChoice` 1 or more. An older build gets the download before its start, and no question it could not follow.
    package func takesChoice(app: String) -> Bool {
        let plist = URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let marker = info["DMSaveSyncChoice"] as? NSNumber else { return false }
        return marker.intValue >= 1
    }

    package func reportCommand(app: String, wait: TimeInterval) -> [String]? { nil }
    package func sendCommand(app: String) -> [String]? { nil }
}

/// The send after a game ended, for an engine that has a command for it, or one whose cloud sync runs in the launcher.
package enum CloudSaveSend {
    /// What to run after the game of `app` ended, nil when its engine has no send or the game started without cloud saves.
    /// `environment` is the one the game started with. The launcher's own environment is under it, as it is under the game's.
    package static func launch(app: String, environment: [String: String], engine: any SaveEngine,
                               base: [String: String] = ProcessInfo.processInfo.environment) -> ProcessLaunch? {
        guard CloudSaveSync.folder(for: environment[engine.syncKey]) != nil, let command = engine.sendCommand(app: app) else { return nil }
        return ProcessLaunch(command, environment: base.merging(environment) { $1 })
    }

    /// Runs the send in the background. Its exit code is 0 when the save is in step with the cloud or sync is off.
    package static func afterExit(app: String, titleID: String = "", environment: [String: String], engine: any SaveEngine,
                                  isRunning: (@Sendable () -> Bool)? = nil) {
        if let folder = CloudSaveSync.folder(for: environment[engine.syncKey]), engine.syncsCloudInLauncher {
            let resolvedTitle = resolvedTitleID(app: app, fallback: titleID)
            guard !resolvedTitle.isEmpty else { return }
            let saveURL = environment[engine.saveKey].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? engine.defaultSave(titleID: resolvedTitle, support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            let cloudFile = URL(fileURLWithPath: CloudSaveSync.saveFile(folder: folder, titleID: resolvedTitle))
            let runningCheck = isRunning ?? { false }
            let plan = CloudSaveNow.SyncPlan(
                titleID: resolvedTitle,
                gameName: resolvedTitle,
                save: saveURL,
                legacySave: nil,
                cloudFile: cloudFile,
                isDefaultPlayer: true
            )
            DispatchQueue.global(qos: .utility).async {
                _ = CloudSaveNow.syncNow(plan: plan, isRunning: runningCheck)
            }
            return
        }
        guard var launch = launch(app: app, environment: environment, engine: engine) else { return }
        launch.timeout = 120
        let job = launch
        DispatchQueue.global(qos: .utility).async { _ = SystemProcessRunner().capture(job) }
    }

    private static func resolvedTitleID(app: String, fallback: String) -> String {
        if let parsed = MacNativeGamesBuilder.normalizedHex16(fallback) {
            return parsed
        }
        if let bundle = try? MacGameBundle.read(URL(fileURLWithPath: app)) {
            return bundle.titleID
        }
        return ""
    }
}

/// The game's users beside a save, in the registry both engines write (dm/host/hle_account.c, nxkit R68): user 1 plays in the
/// save itself, user `n` (2 to 8) in `<save>_user<n>`.
package enum SaveUsers {
    /// The game's users from `<save>.users` (`nxnative-users-1 <hex mask>`, bit 0 is user 1): 1 to 8, in order. A missing or
    /// unreadable file is user 1 alone, as the host reads it.
    package static func users(save: URL) -> [Int] {
        guard let text = try? String(contentsOfFile: save.path + ".users", encoding: .utf8) else { return [1] }
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, parts[0] == "nxnative-users-1", let mask = UInt32(parts[1], radix: 16) else { return [1] }
        return (1...8).filter { $0 == 1 || mask & (1 << ($0 - 1)) != 0 }
    }

    /// The folders and files of the save beside `save` that a user other than 1 and the registry add.
    package static func userPaths(save: URL) -> [String] {
        users(save: save).filter { $0 > 1 }.map { save.path + "_user\($0)" } + [save.path + ".users"]
    }
}
