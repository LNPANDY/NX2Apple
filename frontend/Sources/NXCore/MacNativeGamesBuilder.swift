import Foundation

package enum MacNativeGamesBuilder {
    package static var featureEnabled = ProcessInfo.processInfo.environment["NX2APPLE_MULTI_UPSTREAM"] != "0"

    package enum Route: Equatable, Sendable {
        case unifiedBuildApp
        case perGameScript(relativePath: String, supportsPlatformFlag: Bool, supportsUpdateFlag: Bool)
    }

    package static let unifiedTitleIDs: Set<String> = [
        "0100F2C0115B6000",
        "01007EF00011E000",
        "0400486024DEC000",
        "040074A01BF12000",
        "0400A3A01EE4C000"
    ]

    package static let perGameRoutes: [String: Route] = [
        "010093801237C000": .perGameScript(relativePath: "games/dread/build.py", supportsPlatformFlag: true, supportsUpdateFlag: true),
        "01002DA013484000": .perGameScript(relativePath: "games/ss/build.py", supportsPlatformFlag: false, supportsUpdateFlag: true),
        "010048900CF64000": .perGameScript(relativePath: "games/worldend/build.py", supportsPlatformFlag: false, supportsUpdateFlag: false)
    ]

    package static var supportedTitleIDs: Set<String> {
        unifiedTitleIDs.union(perGameRoutes.keys)
    }

    package static func isUsableTree(_ directory: String, fileManager fm: FileManager = .default) -> Bool {
        EngineUpstream.isTree(directory, kind: .macNativeGames, fileManager: fm)
    }

    package static func scriptPath(for route: Route, in tree: String) -> String {
        let prefix = tree.hasSuffix("/") ? tree : tree + "/"
        switch route {
        case .unifiedBuildApp:
            return prefix + "build_app.py"
        case .perGameScript(let relativePath, _, _):
            return prefix + relativePath
        }
    }

    package static func route(forTitleID titleID: String?, in tree: String, fileManager fm: FileManager = .default) -> Route? {
        guard let titleID else { return .unifiedBuildApp }
        let upper = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if upper.isEmpty {
            return .unifiedBuildApp
        }
        if unifiedTitleIDs.contains(upper) {
            return .unifiedBuildApp
        }
        if let known = perGameRoutes[upper] {
            return known
        }
        if !tree.isEmpty {
            let prefix = tree.hasSuffix("/") ? tree : tree + "/"
            let gamesDir = prefix + "games"
            if let entries = try? fm.contentsOfDirectory(atPath: gamesDir) {
                for entry in entries {
                    let gameJSONPath = gamesDir + "/" + entry + "/game.json"
                    guard fm.fileExists(atPath: gameJSONPath),
                          let data = try? Data(contentsOf: URL(fileURLWithPath: gameJSONPath)),
                          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let tid = json["title_id"] as? String,
                          tid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == upper,
                          let buildRel = json["build"] as? String,
                          !buildRel.isEmpty,
                          !buildRel.hasPrefix("/"),
                          !buildRel.contains("..") else {
                        continue
                    }
                    let filesDict = json["files"] as? [String: Any]
                    let updateArr = filesDict?["update"] as? [Any]
                    let supportsUpdate = !(updateArr?.isEmpty ?? true)
                    let scriptFullPath = prefix + buildRel
                    let scriptText = (try? String(contentsOfFile: scriptFullPath, encoding: .utf8)) ?? ""
                    let supportsPlatform = scriptText.contains("--platform")
                    return .perGameScript(
                        relativePath: buildRel,
                        supportsPlatformFlag: supportsPlatform,
                        supportsUpdateFlag: supportsUpdate
                    )
                }
            }
        }
        return nil
    }

    package static func arguments(
        route: Route,
        tree: String,
        gameInput: String,
        keysPath: String,
        isUnencryptedInput: Bool,
        updatePath: String,
        dlcPaths: [String],
        outputAppPath: String,
        workDir: String
    ) -> [String] {
        // Unencrypted inputs (.nup or unpacked Switch 2 dump folders) bundle their updates and DLCs inside gameInput;
        // passing --update or --dlc makes MacNativeGames reject the build.
        let unencrypted = isUnencryptedInput || (gameInput as NSString).pathExtension.lowercased() == "nup"
        let includesUpdate = !unencrypted && !updatePath.isEmpty && !isContainedOrSamePath(updatePath, in: gameInput)
        let externalDLCs = unencrypted ? [] : dlcPaths.filter { !$0.isEmpty && !isContainedOrSamePath($0, in: gameInput) }

        var args = [scriptPath(for: route, in: tree), gameInput]
        if !unencrypted && !keysPath.isEmpty {
            args += ["-k", keysPath]
        }
        switch route {
        case .unifiedBuildApp:
            args += ["--platform", "macos", "-o", outputAppPath, "--work", workDir]
            if includesUpdate {
                args += ["--update", updatePath]
            }
            for dlc in externalDLCs {
                args += ["--dlc", dlc]
            }
        case .perGameScript(_, let supportsPlatformFlag, let supportsUpdateFlag):
            if supportsPlatformFlag {
                args += ["--platform", "macos"]
            }
            args += ["-o", outputAppPath, "--work", workDir]
            if supportsUpdateFlag && includesUpdate {
                args += ["--update", updatePath]
            }
        }
        return args
    }

    private static func isContainedOrSamePath(_ candidate: String, in parentOrSame: String) -> Bool {
        let base = normalizedPath(parentOrSame)
        let target = normalizedPath(candidate)
        guard !base.isEmpty, !target.isEmpty else { return false }
        if target == base {
            return true
        }
        let prefix = base == "/" ? "/" : base + "/"
        return target.hasPrefix(prefix)
    }

    private static func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardized.path
        if standardized.count > 1 && standardized.hasSuffix("/") {
            return String(standardized.dropLast())
        }
        return standardized
    }

    package static func environment(languageCode: String) -> [String: String] {
        ["MNG_LANG": languageCode, "PYTHONUNBUFFERED": "1"]
    }

    package static func lastError(in log: String) -> String? {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if trimmed.hasPrefix("ERROR:") || trimmed.hasPrefix("BuildError:") {
                return trimmed
            }
        }
        return BuildProgress.lastMeaningfulLine(log)
    }
}
