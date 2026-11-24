import Foundation
import NXCore

@MainActor private final class MngSaveSettingsBox {
    var provider: (_ titleID: String) -> (global: SaveGlobalSettings, game: SaveGameOverride) = { _ in
        (SaveGlobalSettings(), SaveGameOverride())
    }
    var codesignEnabled = true
}

@MainActor private let mngSaveSettingsBoxes = NSMapTable<BuildStore, MngSaveSettingsBox>.weakToStrongObjects()

extension BuildStore {
    private var mngSaveSettingsBox: MngSaveSettingsBox {
        if let existing = mngSaveSettingsBoxes.object(forKey: self) {
            return existing
        }
        let box = MngSaveSettingsBox()
        mngSaveSettingsBoxes.setObject(box, forKey: self)
        return box
    }

    /// Narrow read closure wired by `LauncherStores` so `BuildStore` can resolve the active `DM_SAVE` path
    /// without coupling to `SaveSettingsStore`.
    package var saveLocationSettings: (_ titleID: String) -> (global: SaveGlobalSettings, game: SaveGameOverride) {
        get { mngSaveSettingsBox.provider }
        set { mngSaveSettingsBox.provider = newValue }
    }

    /// Allows tests with stand-in `.app` bundles to exercise `Info.plist` injection without running `/usr/bin/codesign`.
    package var codesignInjectedMngApp: Bool {
        get { mngSaveSettingsBox.codesignEnabled }
        set { mngSaveSettingsBox.codesignEnabled = newValue }
    }

    /// True when the installed MacNativeGames checkout contains #2375 and supports shared `dm` saves
    /// for the current game (or overall when no game input is selected).
    package var isMacNativeGamesSharedSaveSupported: Bool {
        guard MacNativeGamesBuilder.featureEnabled, macNativeGamesInstalled else { return false }
        if let tid = detectedGameTitleID16 {
            return MngSharedSave.checkoutSupportsSharedSave(forTitleID: tid, in: macNativeGamesPath)
        }
        if hasSelectedGameInput {
            return false
        }
        return MngSharedSave.checkoutSupportsSharedSave(in: macNativeGamesPath)
    }

    /// Resolves the save directory displayed and revealed by `EngineSwitcherCard` for MacNativeGames.
    package func mngSaveDisplayTarget(
        support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> MacNativeGamesSaveEngine.SaveTarget {
        guard isMacNativeGamesSharedSaveSupported else {
            return MacNativeGamesSaveEngine.resolveSaveTarget(titleID: gameTitleID, support: support)
        }
        let fm = FileManager.default
        if let tid = detectedGameTitleID16 {
            let settings = saveLocationSettings(tid)
            let sampleAppPath: String
            if !macAppPath.isEmpty {
                sampleAppPath = macAppPath
            } else if !effectiveOutputFolder.isEmpty {
                sampleAppPath = URL(fileURLWithPath: effectiveOutputFolder, isDirectory: true)
                    .appendingPathComponent("MNG.app").path
            } else {
                sampleAppPath = ""
            }
            let effective = SaveLocations.effectiveSave(
                titleID: tid,
                appPath: sampleAppPath,
                global: settings.global,
                game: settings.game,
                support: support,
                engine: MngSharedDmSaveEngine()
            )
            let saveURL = effective.path
            let reveal: URL
            if fm.fileExists(atPath: saveURL.path) {
                reveal = saveURL
            } else {
                let parent = saveURL.deletingLastPathComponent()
                let nxRoot = support.appendingPathComponent("nxnative", isDirectory: true)
                reveal = fm.fileExists(atPath: parent.path) ? parent : (fm.fileExists(atPath: nxRoot.path) ? nxRoot : support)
            }
            return MacNativeGamesSaveEngine.SaveTarget(displaySaveURL: saveURL, revealURL: reveal)
        }
        let nxRoot = support.appendingPathComponent("nxnative", isDirectory: true)
        let reveal = fm.fileExists(atPath: nxRoot.path) ? nxRoot : support
        return MacNativeGamesSaveEngine.SaveTarget(displaySaveURL: nxRoot, revealURL: reveal)
    }

    /// Injects `LSEnvironment["DM_SAVE"]` and shared-save metadata into a freshly built #2375 MNG `.app` bundle
    /// before preflight runs so Finder double-clicks and LaunchServices launches use the shared `dm` save path.
    func injectMngSharedSaveConfigIfNeeded(app: URL, titleID: String) async {
        guard activeBuildUpstream == .macNativeGames,
              MngSharedSave.checkoutSupportsSharedSave(forTitleID: titleID, in: macNativeGamesPath) else {
            return
        }
        let tid = titleID.uppercased()
        let settings = saveLocationSettings(tid)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let savePath = SaveLocations.effectiveSave(
            titleID: tid,
            appPath: app.path,
            global: settings.global,
            game: settings.game,
            support: support,
            engine: MngSharedDmSaveEngine()
        ).path.path
        let shouldSign = codesignInjectedMngApp && !Self.bundleUsesSystemTrueStub(app)
        let runner = self.runner
        let errText: String? = await Task.detached(priority: .userInitiated) {
            do {
                try MngAppLaunchConfig.configure(
                    appURL: app,
                    titleID: tid,
                    savePath: savePath,
                    codesign: shouldSign,
                    runner: runner
                )
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let errText {
            say("⚠ MNG DM_SAVE config: " + errText)
        }
    }

    private nonisolated static func bundleUsesSystemTrueStub(_ app: URL) -> Bool {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let exe = info["CFBundleExecutable"] as? String,
              !exe.isEmpty else {
            return false
        }
        let resolved = app.appendingPathComponent("Contents/MacOS/" + exe).resolvingSymlinksInPath().path
        return resolved == "/usr/bin/true" || resolved == "/bin/echo"
    }
}
