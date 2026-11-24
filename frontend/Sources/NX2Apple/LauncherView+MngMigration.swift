import Foundation
import NXCore
import NXModel

extension LauncherView {
    /// Refreshes `LSEnvironment["DM_SAVE"]` inside any built #2375 MNG `.app` bundles whenever save location settings change,
    /// so Finder double-click launches always point to the same shared `dm` save directory.
    func syncMngSharedAppsLSEnvironment() {
        let global = stores.saveSettings.global
        let snapshot: [(titleID: String, appPath: String, override: SaveGameOverride, isRunning: Bool)] = library.games.flatMap { game in
            let tid = game.titleID.uppercased()
            let override = stores.saveSettings.game(tid)
            let isRunning = SaveTransfer.runningOnMac(titleID: tid)
            let paths = Array(Set(([game.appPath] + game.allMacAppPaths).filter { !$0.isEmpty }))
            return paths.map { (tid, $0, override, isRunning) }
        }
        guard !snapshot.isEmpty else { return }
        let runner = stores.runner
        Task.detached(priority: .utility) {
            for item in snapshot {
                MngAppLaunchConfig.syncIfNeeded(
                    appPath: item.appPath,
                    titleID: item.titleID,
                    global: global,
                    game: item.override,
                    isRunning: item.isRunning,
                    codesign: !Self.usesSystemStub(item.appPath),
                    runner: runner
                )
            }
        }
    }

    /// Prompts for first-time MNG shared-save migration right after a standalone #2375 MNG build completes,
    /// so Finder double-clicks also see the migrated save immediately.
    func promptMngMigrationAfterBuildIfNeeded() {
        guard !stores.queue.active,
              m.runningTarget == BuildTarget.mac,
              !m.macAppPath.isEmpty,
              !mngMigration.isActive,
              !cloudGate.isActive,
              let game = library.games.first(where: { $0.appPath == m.macAppPath || $0.allMacAppPaths.contains(m.macAppPath) }) else {
            return
        }
        mngMigration.beginIfNeeded(
            titleID: game.titleID,
            gameName: game.displayName(loc.lang),
            appPath: m.macAppPath,
            saveSettings: stores.saveSettings,
            proceed: {},
            cancelled: {}
        )
    }

    private nonisolated static func usesSystemStub(_ appPath: String) -> Bool {
        let appURL = URL(fileURLWithPath: appPath)
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let exe = info["CFBundleExecutable"] as? String,
              !exe.isEmpty else {
            return false
        }
        let resolved = appURL.appendingPathComponent("Contents/MacOS/" + exe).resolvingSymlinksInPath().path
        return resolved == "/usr/bin/true" || resolved == "/bin/echo"
    }
}
