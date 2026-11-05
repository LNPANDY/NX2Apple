import Foundation

/// What the shell app's real launcher applies to start one game's engine: the environment (set with overwrite, before
/// the engine reads anything), the `dm_main` arguments and the framework to load. Computed from a `LaunchableGame` and
/// the app's locations, mirroring `boot_env()` in `dm/ios/Sources/main.m` and the table in `docs/launcher-c-plan.md`
/// ("Environment at game start"). Pure: the only side effect is `createFolders()`, called explicitly.
public struct EngineLaunchPlan: Equatable, Sendable {
    /// Set with overwrite, before the engine reads anything.
    public var environment: [String: String]
    /// `dm_main` argv: `["dmhost", "<framework>/dm", <manifest modules...>]`.
    public var arguments: [String]
    /// `<framework>/<manifest.framework_executable>`.
    public var frameworkExecutable: URL
    /// `manifest.image_marker`: the symbol or section that tells the loader which image is the game's.
    public var imageMarker: String
    /// `Documents/log.txt`, the engine log the per-game app also writes.
    public var logURL: URL
    /// `Documents`.
    public var workingDirectory: URL
    /// The save and temp folders.
    public var foldersToCreate: [URL]

    /// `envFileText` is the shared `Documents/env.txt`. `gameEnvFileText` is the game's own `Documents/games/<title ID>/env.txt`
    /// (#557), read from `game.appFolder` when it is nil. A key in the game's file wins over the shared file, and the launch
    /// environment (the player's settings, the paths above) wins over both. The game's own `mods/` folder sets
    /// `DM_ROMFS_OVERLAY` (`GameMods`) when the game's env file does not, and it wins over the shared file. The order is: launch
    /// environment, game env.txt, game mods folder, shared env.txt, framework dm/env.txt.
    /// The framework file carries build-time defaults such as CPU BC decoding for older GPUs (#719). Automatic `DM_PSO_BUNDLE`
    /// discovery is a fallback after all env files, so an explicit archive path or `off` can override it.
    public static func make(game: LaunchableGame, appResources: URL, documents: URL, envFileText: String?, gameEnvFileText: String? = nil,
                            fileManager fm: FileManager = .default) -> EngineLaunchPlan {
        let manifest = game.manifest, fw = game.frameworkURL, gdir = game.appFolder
        func isDirectory(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        var env: [String: String] = [:]

        let perGameProfile = gdir.appendingPathComponent("profile.tsv")
        env["DM_PROFILE"] = (fm.fileExists(atPath: perGameProfile.path) ? perGameProfile : fw.appendingPathComponent(manifest.profile)).path
        if let romfs = romfs(in: game.dataURL, manifest: manifest, fm, isDirectory) { env["DM_ROMFS"] = romfs.path }
        let save = gdir.appendingPathComponent("save", isDirectory: true), temp = gdir.appendingPathComponent("temp", isDirectory: true)
        env["DM_SAVE"] = save.path
        env["DM_TEMP"] = temp.path
        env["DM_NVN_SHMAP"] = fw.appendingPathComponent(manifest.shaderMap).path
        let ownMSL = gdir.appendingPathComponent("msl", isDirectory: true)
        let bundledMSL = game.shaderResourcesURL ?? fw.appendingPathComponent("msl", isDirectory: true)
        env["DM_MSL_DIR"] = (isDirectory(ownMSL) ? ownMSL : bundledMSL).path
        let ownPSO = gdir.appendingPathComponent("pso", isDirectory: true), fwPSO = fw.appendingPathComponent("pso", isDirectory: true)
        let dataAOC = game.dataURL.appendingPathComponent("aoc", isDirectory: true), ownAOC = gdir.appendingPathComponent("aoc", isDirectory: true)
        if isDirectory(dataAOC) { env["DM_AOC_DIR"] = dataAOC.path } else if isDirectory(ownAOC) { env["DM_AOC_DIR"] = ownAOC.path }
        env["DM_CHEATS"] = gdir.appendingPathComponent("cheats", isDirectory: true).path
        env["DM_FONT_DIR"] = appResources.appendingPathComponent("dm/font", isDirectory: true).path
        if let cloud = game.cloudSavesURL { env["DM_SAVE_SYNC"] = cloud.path }
        // The shell already showed its own settings, the per-game launcher screen stays out of the way.
        env["DM_LAUNCHER"] = "0"
        for (key, value) in game.environment { env[key] = value }

        var fromFile: [String] = []
        let ownText = gameEnvFileText ?? fm.contents(atPath: gdir.appendingPathComponent("env.txt").path).flatMap { String(data: $0, encoding: .utf8) }
        func apply(_ text: String?) {
            for (key, value) in parseEnvFile(text ?? "") where env[key] == nil {
                env[key] = value
                fromFile.append(key)
            }
        }
        apply(ownText)
        if env["DM_ROMFS_OVERLAY"] == nil,
           let overlay = GameMods.overlay(in: gdir.appendingPathComponent("mods", isDirectory: true), titleID: game.titleID, fm) {
            env["DM_ROMFS_OVERLAY"] = overlay
        }
        apply(envFileText)
        apply(fm.contents(atPath: fw.appendingPathComponent("dm/env.txt").path).flatMap { String(data: $0, encoding: .utf8) })
        env["DM_ENV_FILE_KEYS"] = fromFile.joined(separator: " ")
        if env["DM_PSO_BUNDLE"] == nil {
            if isDirectory(ownPSO) { env["DM_PSO_BUNDLE"] = ownPSO.path } else if isDirectory(fwPSO) { env["DM_PSO_BUNDLE"] = fwPSO.path }
        }

        return EngineLaunchPlan(
            environment: env,
            arguments: ["dmhost", fw.appendingPathComponent("dm", isDirectory: true).path] + manifest.modules,
            frameworkExecutable: fw.appendingPathComponent(manifest.frameworkExecutable),
            imageMarker: manifest.imageMarker,
            logURL: documents.appendingPathComponent("log.txt"),
            workingDirectory: documents,
            foldersToCreate: [save, temp])
    }

    /// Creates the save and temp folders (and their parents) when they are missing. The temp folder is kept out of the backup, the
    /// save folder stays in it (`BackupExclusion`, #618).
    public func createFolders(fileManager fm: FileManager = .default) throws {
        for url in foldersToCreate {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            if !GameDeletion.isSave(url.lastPathComponent) { BackupExclusion.exclude(url) }
        }
    }

    /// `KEY=VALUE` lines in order: `#` starts a comment line, blank lines and lines without `=` or with an empty key
    /// are skipped, whitespace around a line is trimmed (as `boot_env` reads `env.txt`).
    public static func parseEnvFile(_ text: String) -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            result.append((key: String(line[..<eq]), value: String(line[line.index(after: eq)...])))
        }
        return result
    }

    /// `DM_ROMFS`: a non-empty `romfs.img` (any case, the exact name first, like `romfs_document_images`), else a
    /// `romfs/` tree or the folder itself, each only when it holds the manifest's marker.
    private static func romfs(in data: URL, manifest: GameManifest, _ fm: FileManager, _ isDirectory: (URL) -> Bool) -> URL? {
        let marker = manifest.romfsMarker
        let names = ((try? fm.contentsOfDirectory(atPath: data.path)) ?? []).filter { $0.lowercased() == "romfs.img" }
        for name in names.sorted(by: { ($0 == "romfs.img" ? 0 : 1, $0) < ($1 == "romfs.img" ? 0 : 1, $1) }) {
            let url = data.appendingPathComponent(name)
            if DataLocator.isComplete(url, manifest: manifest, fm) { return url }   // a partial copy is not the game's image
        }
        for tree in [data.appendingPathComponent("romfs", isDirectory: true), data]
        where isDirectory(tree) && fm.fileExists(atPath: tree.appendingPathComponent(marker).path) { return tree }
        return nil
    }
}
