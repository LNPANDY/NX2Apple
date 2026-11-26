import Foundation
import NXCore

/// The build-files folder: `<title ID>_build` (the extracted game, rewritten code, shaders) can live apart from the finished app,
/// for example on an external drive while the app stays on the Mac and plays without the drive. The rules are in `BuildFilesFolder`.
extension BuildStore {
    /// Where the build files go when the player keeps them apart from the app, saved in the defaults (BuildFilesFolder.key).
    /// Empty: beside the app, as before the setting. Read from the defaults each time, so the store keeps no copy of it.
    package var buildFilesFolder: String {
        get { BuildFilesFolder.chosen(defaults) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: BuildFilesFolder.key)
        }
    }

    /// The build folder of a build that is starting, or nil after `fail` when the chosen build-files folder is on a drive
    /// that is not connected: the build would fill the Mac's own disk.
    package func startingBuildWorkDir(baseDir: String, tidHex: String, upstream: EngineUpstreamKind? = nil) -> String? {
        let workDir = buildWorkDir(baseDir: baseDir, tidHex: tidHex, upstream: upstream)
        if let why = buildFilesDriveProblem(workDir: workDir) {
            fail(why)
            return nil
        }
        return workDir
    }

    /// The folder the finished app (and a one-game IPA) goes to: the output folder, else beside the game files.
    package func appFolder(baseDir: String) -> String {
        outDir.isEmpty ? baseDir : outDir
    }

    /// `<build-files folder>/<TID>[_<variant>]_build`, or the same in the app folder when no build-files folder is chosen. Each
    /// engine keeps its own folder (`nxnativeWorkDirectory`).
    package func buildWorkDir(baseDir: String, tidHex: String, upstream: EngineUpstreamKind? = nil) -> String {
        nxnativeWorkDirectory(baseOut: BuildFilesFolder.root(chosen: buildFilesFolder, appFolder: appFolder(baseDir: baseDir)),
                              tidHex: tidHex, upstream: upstream)
    }

    /// The app's folder, given to `MacAppOutput` only when the build files are kept elsewhere, so a build without the setting
    /// behaves as it always did.
    package func separateAppFolder(baseDir: String) -> URL? {
        buildFilesFolder.isEmpty ? nil : URL(fileURLWithPath: appFolder(baseDir: baseDir))
    }

    /// The message when the chosen build-files folder is on a drive that is not connected, nil otherwise. A build there would
    /// write into `/Volumes/<name>` on the Mac's own disk. Without a chosen folder the build goes on as it always did.
    package func buildFilesDriveProblem(workDir: String) -> String? {
        guard !buildFilesFolder.isEmpty, BuildFilesFolder.driveMissing(workDir, volumes: volumesRoot) else { return nil }
        return String(format: t("msg.buildFilesOffline"), BuildFilesFolder.driveName(workDir, volumes: volumesRoot) ?? workDir)
    }

    /// The same message for the chosen folder itself, shown on the Builds page as soon as it opens (a rebuild from the library),
    /// before the player looks at inputs that are missing only because they sit on the same drive.
    package var buildFilesOfflineNote: String? {
        buildFilesDriveProblem(workDir: buildFilesFolder)
    }

    /// Settings: pick the build-files folder.
    package func chooseBuildFilesFolder() {
        guard let path = chooseFolder() else { return }
        buildFilesFolder = path
    }

    /// Settings: the build files go beside the app again.
    package func clearBuildFilesFolder() {
        buildFilesFolder = ""
    }
}
