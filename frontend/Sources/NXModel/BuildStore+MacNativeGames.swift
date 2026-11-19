import Foundation
import NXCore

extension BuildStore {
    package var isMacNativeGamesSelected: Bool {
        MacNativeGamesBuilder.featureEnabled && buildUpstream == .macNativeGames
    }

    package var usesExternalUpstreamRepo: Bool {
        (isMacNativeGamesSelected && target == BuildTarget.mac && macNativeGamesInstalled) || (isS2ArmSelected && s2armInstalled)
    }

    func macNativeGamesProblem() -> String? {
        guard isMacNativeGamesSelected else { return nil }
        guard target == BuildTarget.mac else { return t("upstream.mngMacOnly") }
        guard MacNativeGamesBuilder.isUsableTree(macNativeGamesPath) else {
            return macNativeGamesPath.isEmpty ? t("upstream.mngMissing") : String(format: t("upstream.mngInvalid"), shortPath(macNativeGamesPath))
        }
        guard let route = MacNativeGamesBuilder.route(forTitleID: gameTitleID, in: macNativeGamesPath) else {
            return String(format: t("upstream.mngUnsupportedGame"), gameTitleID ?? "")
        }
        let script = MacNativeGamesBuilder.scriptPath(for: route, in: macNativeGamesPath)
        guard FileManager.default.fileExists(atPath: script) else {
            return String(format: t("msg.toolsOld"), (script as NSString).lastPathComponent)
        }
        return nil
    }

    func macNativeGamesLaunch(python py: String, workDir: String, outputAppPath: String, environment: [String: String]) -> ProcessLaunch? {
        guard let route = MacNativeGamesBuilder.route(forTitleID: gameTitleID, in: macNativeGamesPath) else { return nil }
        let gameInput = gameFolder?.scriptInput ?? basePath
        let unencrypted = gameFolder != nil || (gameInput as NSString).pathExtension.lowercased() == "nup"
        let effectiveUpdatePath = unencrypted ? "" : updatePath
        let effectiveDlcPaths = unencrypted ? [] : dlcPaths
        let args = MacNativeGamesBuilder.arguments(
            route: route,
            tree: macNativeGamesPath,
            gameInput: gameInput,
            keysPath: keysPath,
            isUnencryptedInput: unencrypted,
            updatePath: effectiveUpdatePath,
            dlcPaths: effectiveDlcPaths,
            outputAppPath: outputAppPath,
            workDir: workDir
        )
        say(String(format: t("msg.running"), py) + " " + args.joined(separator: " "))
        lastBuildCommand = [py] + args
        let mergedEnv = environment.merging(MacNativeGamesBuilder.environment(languageCode: lang.code)) { $1 }
        return ProcessLaunch(executable: py, arguments: args, environment: mergedEnv, directory: macNativeGamesPath, groupPython: py)
    }

    func macNativeGamesFailureNote(status: Int32) -> String {
        if let line = MacNativeGamesBuilder.lastError(in: logTail) {
            return String(format: t("msg.buildFailedReason"), line)
        }
        return String(format: t("msg.buildFailed"), status)
    }
}
