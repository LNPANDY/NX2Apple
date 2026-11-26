import Foundation

/// Why a seed-based refresh cannot skip shader compilation and must rebuild shader libraries.
package enum ShaderRebuildReason: String, Equatable, Sendable, Codable {
    /// Upstream updated `DMSH_CHAIN`, invalidating previously compiled shader libraries.
    case chainChanged
    /// The game profile's shader tables or `nvn_*`/`shader_*` settings changed (`dmsh_chain.py --inputs`).
    case inputsChanged
    /// The platform's compiled shader library (`shader/cache/b-<chain>` for Mac or `shader/ios/b-<chain>` for iOS) is absent or incomplete.
    case cacheMissing
    /// The iOS shader image left out pulling vertex libraries (`_bp_left_out`) that this build needs.
    case pullingMissing
    /// `c1_full.tsv` or `cb_extent.tsv` is missing or its `# chain` header does not match the shader library stamp.
    case tablesMismatch
}

/// Platform-specific refresh execution plan shared by UI precheck and queue/build execution.
package enum PlatformRefreshPlan: Equatable, Sendable {
    /// Reuses existing compiled shader libraries via `--from-seed` without rebuilding shaders.
    case fastReuse
    /// Runs via `--from-seed` (without original NSP/keys) using prefill sources, rebuilding shaders (slower).
    case seedRebuildShaders(ShaderRebuildReason)
    /// iOS has a usable build seed but lacks a local `.img` for prefill; guide recovery before running `--from-seed`.
    case needsImgRecovery(rebuildsShaders: Bool)
    /// Cannot use `--from-seed`; requires original game packages for a full rebuild.
    case fullRebuild(missingPackage: Bool)

    package var canFastRefresh: Bool {
        self == .fastReuse
    }

    package var canRefreshFromSeed: Bool {
        switch self {
        case .fastReuse, .seedRebuildShaders:
            return true
        case .needsImgRecovery, .fullRebuild:
            return false
        }
    }

    package var needsShaderRebuild: Bool {
        switch self {
        case .seedRebuildShaders:
            return true
        case .needsImgRecovery(let rebuildsShaders):
            return rebuildsShaders
        case .fastReuse, .fullRebuild:
            return false
        }
    }

    package var shaderRebuildReason: ShaderRebuildReason? {
        if case .seedRebuildShaders(let reason) = self {
            return reason
        }
        return nil
    }
}

/// Combined Mac and iOS refresh precheck result derived from a single source of truth.
package struct RefreshPlanAssessment: Equatable, Sendable {
    package var macPlan: PlatformRefreshPlan
    package var iosPlan: PlatformRefreshPlan
    package var hasUsableSeed: Bool
    package var seedDir: String
    package var expectedRomfsIdentity: String?

    package var canFastRefreshMac: Bool { macPlan.canFastRefresh }
    package var canFastRefreshIOS: Bool { iosPlan.canFastRefresh }
    package var canSeedRefreshMac: Bool { macPlan.canRefreshFromSeed }
    package var canSeedRefreshIOS: Bool { iosPlan.canRefreshFromSeed }
    package var needsShaderRebuildMac: Bool { macPlan.needsShaderRebuild }
    package var needsShaderRebuildIOS: Bool { iosPlan.needsShaderRebuild }
    package var shaderRebuildReasonMac: ShaderRebuildReason? { macPlan.shaderRebuildReason }
    package var shaderRebuildReasonIOS: ShaderRebuildReason? { iosPlan.shaderRebuildReason }

    package var needsMissingImgGuideIOS: Bool {
        if case .needsImgRecovery = iosPlan { return true }
        return false
    }

    package init(
        macPlan: PlatformRefreshPlan,
        iosPlan: PlatformRefreshPlan,
        hasUsableSeed: Bool,
        seedDir: String,
        expectedRomfsIdentity: String?
    ) {
        self.macPlan = macPlan
        self.iosPlan = iosPlan
        self.hasUsableSeed = hasUsableSeed
        self.seedDir = seedDir
        self.expectedRomfsIdentity = expectedRomfsIdentity
    }
}

/// Single source of truth predicting and validating whether `--from-seed` can reuse shader libraries or must rebuild them.
package enum RefreshPrecheck {

    /// Evaluates Mac and iOS refresh feasibility and shader-reuse posture using the same rules as `build_ipa_from_nsp.py`.
    package static func evaluate(
        titleID: String,
        hasMacBuild: Bool,
        macAppPath: String,
        hasIOSBuild: Bool,
        hasReadableSourceInputs: Bool,
        outDir: String,
        gameName: String?,
        seedRoot: String = BuildSeedCache.defaultRoot(),
        repoPath: String,
        externalIOSImgPath: String? = nil,
        iosWantsPulling: Bool = true,
        buildFilesFolder: String = "",
        fm: FileManager = .default
    ) -> RefreshPlanAssessment {
        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !tid.isEmpty else {
            return RefreshPlanAssessment(
                macPlan: hasMacBuild ? .fullRebuild(missingPackage: !hasReadableSourceInputs) : .fullRebuild(missingPackage: false),
                iosPlan: hasIOSBuild ? .fullRebuild(missingPackage: !hasReadableSourceInputs) : .fullRebuild(missingPackage: false),
                hasUsableSeed: false,
                seedDir: "",
                expectedRomfsIdentity: nil
            )
        }

        let resolvedOutDir = resolveOutputDirectory(outDir: outDir, macAppPath: macAppPath)
        // The build folder a refresh would use, or the one an earlier build left beside the app (BuildFilesFolder)
        let workDirs = BuildFilesFolder.candidates(key: tid, chosen: buildFilesFolder, others: [resolvedOutDir])
        let workDir = workDirs.first { var dir: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &dir) && dir.boolValue }
            ?? workDirs.first ?? ""

        let inspection = BuildSeedCache.inspect(titleID: tid, seedRoot: seedRoot, repoPath: repoPath, fm: fm)
        let hasUsableSeed = inspection.isUsable
        let legacyAdoptable = !hasUsableSeed && isAdoptableLegacyWorkDir(workDir: workDir, fm: fm)
        let canUseSeedPipeline = hasUsableSeed || legacyAdoptable

        guard canUseSeedPipeline else {
            let full = PlatformRefreshPlan.fullRebuild(missingPackage: !hasReadableSourceInputs)
            return RefreshPlanAssessment(
                macPlan: hasMacBuild ? full : .fullRebuild(missingPackage: false),
                iosPlan: hasIOSBuild ? full : .fullRebuild(missingPackage: false),
                hasUsableSeed: false,
                seedDir: inspection.seedDir,
                expectedRomfsIdentity: nil
            )
        }

        let candidates = BuildSeedCache.prefillCandidates(
            titleID: tid,
            outDir: resolvedOutDir,
            gameName: gameName,
            macAppPath: macAppPath,
            workDir: workDir.isEmpty ? nil : workDir,
            fm: fm
        )

        let repoChain = normalizeChain(EngineLayout.shaderChain(repo: repoPath))
        let seedRecord = inspection.record
        let effectiveGfxAPI = resolveGfxAPI(
            record: seedRecord,
            legacyWorkDir: legacyAdoptable ? workDir : nil,
            macAppPath: macAppPath,
            fm: fm
        )
        let isNVN = effectiveGfxAPI == "nvn"
        let isMultiProgram = seedRecord?.isMultiProgram == true

        let profileDir = resolveProfileDir(
            titleID: tid,
            baseTitleID: seedRecord?.baseTitleID,
            profileID: seedRecord?.profileID,
            profileKind: seedRecord?.profileKind,
            pkgVer: seedRecord?.pkgVer,
            seedDir: hasUsableSeed ? inspection.seedDir : nil,
            repoPath: repoPath,
            fm: fm
        )
        let currentInputsDigest = profileDir.flatMap { computeProfileInputsDigest(profileDir: $0, fm: fm) }
        let expectedProfileID = profileDir.map { ($0 as NSString).lastPathComponent }

        let effectiveExternalImg = externalIOSImgPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExternalImg = effectiveExternalImg.map { !$0.isEmpty && fm.fileExists(atPath: $0) } ?? false
        let hasLocalIOSImg = hasExternalImg
            || candidates.contains { $0.lowercased().hasSuffix(".img") && !$0.contains(".app/") }
            || (!workDir.isEmpty && RomFSArchive.extractedVersion(in: workDir + "/extract") != nil)

        let iosShaderDir = hasUsableSeed ? (inspection.seedDir + "/shader/ios") : (workDir + "/shader/ios")
        let tablesDir = hasUsableSeed ? (inspection.seedDir + "/shader/tables") : (workDir + "/shader/tables")
        let seedChain = normalizeChain(seedRecord?.chain)

        let iosPlan: PlatformRefreshPlan
        if !hasIOSBuild {
            iosPlan = .fullRebuild(missingPackage: false)
        } else if !isNVN {
            let apiLib = iosShaderDir + "/" + effectiveGfxAPI + "/" + effectiveGfxAPI + "_shaders.metallib"
            if fm.fileExists(atPath: apiLib) {
                iosPlan = .fastReuse
            } else if hasLocalIOSImg {
                iosPlan = .seedRebuildShaders(.cacheMissing)
            } else {
                iosPlan = .needsImgRecovery(rebuildsShaders: true)
            }
        } else {
            let iosCheck = evaluateNVNIOS(
                seedChain: seedChain,
                repoChain: repoChain,
                hasUsableSeed: hasUsableSeed,
                iosShaderDir: iosShaderDir,
                tablesDir: tablesDir,
                profileDir: profileDir,
                expectedProfileID: expectedProfileID,
                currentInputsDigest: currentInputsDigest,
                isMultiProgram: isMultiProgram,
                iosWantsPulling: iosWantsPulling,
                fm: fm
            )
            if let reason = iosCheck {
                iosPlan = hasLocalIOSImg ? .seedRebuildShaders(reason) : .needsImgRecovery(rebuildsShaders: true)
            } else {
                iosPlan = .fastReuse
            }
        }

        let macPlan: PlatformRefreshPlan
        if !hasMacBuild {
            macPlan = .fullRebuild(missingPackage: false)
        } else {
            let macReachable = macAppPath.isEmpty || fm.fileExists(atPath: macAppPath) || !candidates.isEmpty
            let metalSourcesDir = inspection.seedDir + "/metal-sources"
            let hasSeedMetalSources = hasUsableSeed
                && (try? fm.destinationOfSymbolicLink(atPath: metalSourcesDir)) == nil
                && isDirectory(metalSourcesDir, fm: fm)
            let hasMacPrefill = !candidates.isEmpty || hasSeedMetalSources

            if !isNVN {
                let macLayerLib = workDir.isEmpty ? "" : (workDir + "/shader/" + effectiveGfxAPI + "/" + effectiveGfxAPI + "_shaders.metallib")
                if !macLayerLib.isEmpty && fm.fileExists(atPath: macLayerLib) && macReachable {
                    macPlan = .fastReuse
                } else if hasMacPrefill && macReachable {
                    macPlan = .seedRebuildShaders(.cacheMissing)
                } else {
                    macPlan = .fullRebuild(missingPackage: !hasReadableSourceInputs)
                }
            } else {
                macPlan = evaluateNVNMac(
                    workDir: workDir,
                    seedChain: seedChain,
                    repoChain: repoChain,
                    macAppPath: macAppPath,
                    macReachable: macReachable,
                    hasMacPrefill: hasMacPrefill,
                    hasReadableSourceInputs: hasReadableSourceInputs,
                    candidates: candidates,
                    expectedProfileID: expectedProfileID,
                    currentInputsDigest: currentInputsDigest,
                    isMultiProgram: isMultiProgram,
                    fm: fm
                )
            }
        }

        return RefreshPlanAssessment(
            macPlan: macPlan,
            iosPlan: iosPlan,
            hasUsableSeed: canUseSeedPipeline,
            seedDir: inspection.seedDir,
            expectedRomfsIdentity: seedRecord?.romfsIdentity
        )
    }

    // MARK: - Platform evaluators

    private static func evaluateNVNIOS(
        seedChain: String?,
        repoChain: String?,
        hasUsableSeed: Bool,
        iosShaderDir: String,
        tablesDir: String,
        profileDir: String?,
        expectedProfileID: String?,
        currentInputsDigest: String?,
        isMultiProgram: Bool,
        iosWantsPulling: Bool,
        fm: FileManager
    ) -> ShaderRebuildReason? {
        guard let repoChain else { return .chainChanged }
        if hasUsableSeed, seedChain != repoChain {
            return .chainChanged
        }

        let stamp = readShaderLibraryStamp(
            parentDir: iosShaderDir,
            chain: repoChain,
            isMultiProgram: isMultiProgram,
            fm: fm
        )
        guard stamp.exists && stamp.hasLibrary else {
            return hasOtherChainLibraries(in: iosShaderDir, excluding: repoChain, isMultiProgram: isMultiProgram, fm: fm)
                ? .chainChanged
                : .cacheMissing
        }
        guard let libInputs = stamp.inputsDigest, !libInputs.isEmpty else {
            return .inputsChanged
        }
        if let expectedProfileID, let libGame = stamp.gameID,
           !expectedProfileID.isEmpty, !libGame.isEmpty,
           libGame.caseInsensitiveCompare(expectedProfileID) != .orderedSame {
            return .inputsChanged
        }
        if let currentInputsDigest, libInputs != currentInputsDigest {
            return .inputsChanged
        }
        if iosWantsPulling && stamp.hasLeftOutPulling {
            return .pullingMissing
        }
        if !tablesMatchStamp(chain: repoChain, stampInputs: libInputs, tablesDir: tablesDir, profileDir: profileDir, fm: fm) {
            return .tablesMismatch
        }
        return nil
    }

    private static func evaluateNVNMac(
        workDir: String,
        seedChain: String?,
        repoChain: String?,
        macAppPath: String,
        macReachable: Bool,
        hasMacPrefill: Bool,
        hasReadableSourceInputs: Bool,
        candidates: [String],
        expectedProfileID: String?,
        currentInputsDigest: String?,
        isMultiProgram: Bool,
        fm: FileManager
    ) -> PlatformRefreshPlan {
        let macAppReachable = macAppPath.isEmpty
            ? hasMacPrefill
            : (fm.fileExists(atPath: macAppPath) || candidates.contains { $0.lowercased().hasSuffix(".img") })

        guard let repoChain else {
            return (hasMacPrefill && macAppReachable)
                ? .seedRebuildShaders(.chainChanged)
                : .fullRebuild(missingPackage: !hasReadableSourceInputs)
        }

        let macCacheDir = workDir.isEmpty ? "" : (workDir + "/shader/cache")
        if !macCacheDir.isEmpty {
            let stamp = readShaderLibraryStamp(
                parentDir: macCacheDir,
                chain: repoChain,
                isMultiProgram: isMultiProgram,
                fm: fm
            )
            if stamp.exists && stamp.hasLibrary,
               let libInputs = stamp.inputsDigest, !libInputs.isEmpty {
                let gameMatches = expectedProfileID == nil || stamp.gameID == nil
                    || stamp.gameID!.caseInsensitiveCompare(expectedProfileID!) == .orderedSame
                let inputsMatch = currentInputsDigest == nil || libInputs == currentInputsDigest
                if gameMatches && inputsMatch && macReachable {
                    return .fastReuse
                }
                if hasMacPrefill && macAppReachable {
                    return .seedRebuildShaders(.inputsChanged)
                }
            }
        }

        guard hasMacPrefill && macAppReachable else {
            return .fullRebuild(missingPackage: !hasReadableSourceInputs)
        }

        if let seedChain, seedChain != repoChain {
            return .seedRebuildShaders(.chainChanged)
        }
        if !macCacheDir.isEmpty,
           hasOtherChainLibraries(in: macCacheDir, excluding: repoChain, isMultiProgram: isMultiProgram, fm: fm) {
            return .seedRebuildShaders(.chainChanged)
        }
        if !macAppPath.isEmpty,
           let bundle = try? MacGameBundle.read(URL(fileURLWithPath: macAppPath)),
           let appChain = normalizeChain(bundle.shaderChain),
           appChain != repoChain {
            return .seedRebuildShaders(.chainChanged)
        }
        return .seedRebuildShaders(.cacheMissing)
    }

    // MARK: - Helpers

    private static func tablesMatchStamp(
        chain: String,
        stampInputs: String,
        tablesDir: String,
        profileDir: String?,
        fm: FileManager
    ) -> Bool {
        let want = "# chain b-" + chain + " inputs " + stampInputs
        let matches: (String) -> Bool = { line in
            line == want || line.hasPrefix(want + " ")
        }
        for name in ["c1_full.tsv", "cb_extent.tsv"] {
            if let profileDir,
               let pHead = firstLine(of: profileDir + "/" + name, fm: fm),
               matches(pHead) {
                continue
            }
            guard let sHead = firstLine(of: tablesDir + "/" + name, fm: fm),
                  matches(sHead) else {
                return false
            }
        }
        return true
    }

    private static func firstLine(of path: String, fm: FileManager) -> String? {
        guard let data = fm.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first.map(String.init)
    }

    private static func resolveProfileDir(
        titleID: String,
        baseTitleID: String?,
        profileID: String?,
        profileKind: String?,
        pkgVer: String?,
        seedDir: String?,
        repoPath: String,
        fm: FileManager
    ) -> String? {
        let engineRoot = EngineLayout.root(repoPath)
        let gamesRoot = engineRoot.isEmpty ? "" : (engineRoot + "/dm/games")

        let kind = (profileKind ?? "registered").lowercased()
        if let seedDir, !seedDir.isEmpty, (kind == "derived" || kind == "provisional") {
            let seedProfRoot = seedDir + "/profile"
            var candDir: String?
            if let profileID, !profileID.isEmpty,
               fm.fileExists(atPath: seedProfRoot + "/" + profileID + "/game.tsv") {
                candDir = seedProfRoot + "/" + profileID
            } else if let entries = try? fm.contentsOfDirectory(atPath: seedProfRoot) {
                for entry in entries.sorted() where !entry.hasPrefix(".") {
                    let dir = seedProfRoot + "/" + entry
                    if fm.fileExists(atPath: dir + "/game.tsv") {
                        candDir = dir
                        break
                    }
                }
            }
            if let candDir {
                if let pkgVer, !pkgVer.isEmpty,
                   let builds = readBuildVersions(gameTSV: candDir + "/game.tsv"),
                   !builds.isEmpty, !builds.contains(pkgVer) {
                    // Stale derived profile falls back to registered repo profile if present.
                } else {
                    return candDir
                }
            }
        }

        guard !gamesRoot.isEmpty else { return nil }
        if let profileID, !profileID.isEmpty,
           fm.fileExists(atPath: gamesRoot + "/" + profileID + "/game.tsv") {
            return gamesRoot + "/" + profileID
        }

        let candidates = [baseTitleID, titleID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
        for cand in candidates {
            let lowerDir = gamesRoot + "/" + cand.lowercased()
            if fm.fileExists(atPath: lowerDir + "/game.tsv") { return lowerDir }
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: gamesRoot) else { return nil }
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let dir = gamesRoot + "/" + entry
            let tsv = dir + "/game.tsv"
            guard let text = try? String(contentsOfFile: tsv, encoding: .utf8) else { continue }
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let cols = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
                if cols.count >= 2, cols[0].trimmingCharacters(in: .whitespaces) == "title_id" {
                    let rowTID = cols[1].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    if candidates.contains(rowTID) { return dir }
                    break
                }
            }
        }
        return nil
    }

    private static func readBuildVersions(gameTSV: String) -> Set<String>? {
        guard let text = try? String(contentsOfFile: gameTSV, encoding: .utf8) else { return nil }
        var versions = Set<String>()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let cols = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
            if cols.count >= 2, cols[0].trimmingCharacters(in: .whitespaces) == "build" {
                versions.insert(cols[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return versions
    }

    private static func resolveGfxAPI(
        record: BuildSeedRecord?,
        legacyWorkDir: String?,
        macAppPath: String,
        fm: FileManager
    ) -> String {
        if let raw = record?.gfxAPI?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           raw == "vulkan" || raw == "gl" || raw == "nvn" {
            return raw
        }
        if let legacyWorkDir, !legacyWorkDir.isEmpty {
            if isDirectory(legacyWorkDir + "/shader/ios/vk", fm: fm)
                || isDirectory(legacyWorkDir + "/shader/vk", fm: fm) {
                return "vulkan"
            }
            if isDirectory(legacyWorkDir + "/shader/ios/gl", fm: fm)
                || isDirectory(legacyWorkDir + "/shader/gl", fm: fm) {
                return "gl"
            }
        }
        if !macAppPath.isEmpty,
           let data = fm.contents(atPath: macAppPath + "/Contents/Resources/dm/launcher.json"),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let api = (obj["gfx_api"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           api == "vulkan" || api == "gl" {
            return api
        }
        return "nvn"
    }

    private static func hasOtherChainLibraries(
        in dir: String,
        excluding chain: String,
        isMultiProgram: Bool,
        fm: FileManager
    ) -> Bool {
        let targetName = "b-" + chain
        let checkDir: (String) -> Bool = { folder in
            guard let entries = try? fm.contentsOfDirectory(atPath: folder) else { return false }
            for entry in entries where entry.hasPrefix("b-") {
                let stem = entry.hasSuffix(".img") ? String(entry.dropLast(4)) : entry
                guard stem != targetName, stem.count == 14 else { continue }
                let lib = readSingleShaderLib(basePath: folder + "/" + stem, fm: fm)
                if lib.hasLibrary { return true }
            }
            return false
        }
        if checkDir(dir) { return true }
        if isMultiProgram && checkDir(dir + "/p0") { return true }
        return false
    }

    private static func isAdoptableLegacyWorkDir(workDir: String, fm: FileManager) -> Bool {
        guard !workDir.isEmpty,
              isDirectory(workDir, fm: fm),
              isDirectory(workDir + "/shader", fm: fm) else {
            return false
        }
        if isDirectory(workDir + "/ExeFS", fm: fm) { return true }
        let extractDir = workDir + "/extract"
        guard let entries = try? fm.contentsOfDirectory(atPath: extractDir) else { return false }
        return entries.contains { entry in
            (entry.hasPrefix("v") || entry.hasPrefix("patched_v"))
                && isDirectory(extractDir + "/" + entry + "/ExeFS", fm: fm)
        }
    }

    private static func resolveOutputDirectory(outDir: String, macAppPath: String) -> String {
        if !outDir.isEmpty { return outDir }
        if !macAppPath.isEmpty {
            let parent = (macAppPath as NSString).deletingLastPathComponent
            if !parent.isEmpty && parent != "/" { return parent }
        }
        return ""
    }

    static func normalizeChain(_ chain: String?) -> String? {
        guard let chain, !chain.isEmpty else { return nil }
        let trimmed = chain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("b-") ? String(trimmed.dropFirst(2)) : trimmed
    }

    private static func isDirectory(_ path: String, fm: FileManager) -> Bool {
        guard !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
