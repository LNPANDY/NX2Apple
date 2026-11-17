import Foundation
import NXCore

/// The build-files folder: `<title ID>_build` (the extracted game, rewritten code, shaders) can live apart from the finished app,
/// for example on an external drive while the app stays on the Mac and plays without the drive. The rules are in `BuildFilesFolder`.
extension BuildStore {
    /// The folder the finished app (and a one-game IPA) goes to: the output folder, else beside the game files.
    package func appFolder(baseDir: String) -> String {
        outDir.isEmpty ? baseDir : outDir
    }

    /// `<build-files folder>/<key>_build`, or `<app folder>/<key>_build` when no build-files folder is chosen.
    package func buildWorkDir(key: String, baseDir: String) -> String {
        BuildFilesFolder.workDir(root: BuildFilesFolder.root(chosen: buildFilesFolder, appFolder: appFolder(baseDir: baseDir)), key: key)
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
