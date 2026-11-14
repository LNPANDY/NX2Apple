import Darwin
import Foundation

/// Refresh classification displayed on the library hero card.
package enum HeroRefreshState: Equatable, Sendable {
    case upToDate
    case specificFast(version: String)
    case specificFull(version: String)
    case generalSync(fast: Bool)
}

/// Complete off-thread refresh assessment for a built game in the library.
package struct GameRefreshAssessment: Equatable, Sendable {
    package var heroState: HeroRefreshState
    package var hasSpecificUpdate: Bool
    package var versionLabel: String
    package var canFastRefreshMac: Bool
    package var canFastRefreshIOS: Bool
    package var needsMissingImgGuideIOS: Bool
    package var missingOriginalPackage: Bool
    package var expectedRomfsIdentity: String? = nil

    package init(
        heroState: HeroRefreshState,
        hasSpecificUpdate: Bool,
        versionLabel: String,
        canFastRefreshMac: Bool,
        canFastRefreshIOS: Bool,
        needsMissingImgGuideIOS: Bool,
        missingOriginalPackage: Bool,
        expectedRomfsIdentity: String? = nil
    ) {
        self.heroState = heroState
        self.hasSpecificUpdate = hasSpecificUpdate
        self.versionLabel = versionLabel
        self.canFastRefreshMac = canFastRefreshMac
        self.canFastRefreshIOS = canFastRefreshIOS
        self.needsMissingImgGuideIOS = needsMissingImgGuideIOS
        self.missingOriginalPackage = missingOriginalPackage
        self.expectedRomfsIdentity = expectedRomfsIdentity
    }

    package var canFastRefreshAny: Bool { canFastRefreshMac || canFastRefreshIOS }
}

/// Catalog of game-specific compatibility or performance updates per release and refresh eligibility evaluation.
package enum GameUpdateCatalog {
    package static let defaultVersion = "1.2.0"

    /// Strips any pre-release or local build suffix starting at `-` (and optional leading `v`) and trims whitespace.
    package static func releaseBaseVersion(_ appVersion: String) -> String {
        var trimmed = appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dash = trimmed.firstIndex(of: "-") {
            trimmed = String(trimmed[..<dash]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if (trimmed.hasPrefix("v") || trimmed.hasPrefix("V")), trimmed.dropFirst().first?.isNumber == true {
            trimmed = String(trimmed.dropFirst())
        }
        return trimmed
    }

    /// Uppercase 16-hex TitleIDs mapped to the most recent release carrying game-specific updates (unlisted defaults to "1.2.0").
    package static let updatedVersions: [String: String] = [
        // 1.5.0 (18 titles)
        "0100152000022000": "1.5.0", "01001B300B9BE000": "1.5.0", "010049900F546000": "1.5.0",
        "010051701FB46000": "1.5.0", "01005CA01580E000": "1.5.0", "01006F8002326000": "1.5.0",
        "0100726014352000": "1.5.0", "01007820196A6000": "1.5.0", "0100A00019DE0000": "1.5.0",
        "0100A5C00D162000": "1.5.0", "0100B99019412000": "1.5.0", "0100F2C0115B6000": "1.5.0",
        "0400380020056000": "1.5.0", "0400486024DEC000": "1.5.0", "040074A01BF12000": "1.5.0",
        "04008E001F098000": "1.5.0", "0400C3F00006E000": "1.5.0", "0400D4201C6EA000": "1.5.0",
        // 1.4.0 (19 titles)
        "010012101468C000": "1.4.0", "010014C011146000": "1.4.0", "010019A01E2F2000": "1.4.0",
        "01002B00111A2000": "1.4.0", "0100429011144000": "1.4.0", "010055D009F78000": "1.4.0",
        "010056B015FE8000": "1.4.0", "010057D006492000": "1.4.0", "010061D00DB74000": "1.4.0",
        "01007300020FA000": "1.4.0", "01007EF00011E000": "1.4.0", "01008DD013200000": "1.4.0",
        "01009BC00C38A000": "1.4.0", "0100A6301214E000": "1.4.0", "0100A7C01B792000": "1.4.0",
        "0100B8E016F76000": "1.4.0", "0100CE4010AAC000": "1.4.0", "0100DA801624E000": "1.4.0",
        "0400C76024710000": "1.4.0",
        // 1.3.0 (8 titles)
        "0100276009872000": "1.3.0", "010035F022078000": "1.3.0", "01006A800016E000": "1.3.0",
        "01008D9022462000": "1.3.0", "01008F701C074000": "1.3.0", "0100B7C00933A000": "1.3.0",
        "0100ECD018EBE000": "1.3.0", "0100ED7012DB2000": "1.3.0",
        // 1.2.2 (3 titles)
        "01001F5010DFA000": "1.2.2", "040077201BE50000": "1.2.2", "04007EF01F8AE000": "1.2.2",
    ]

    /// Evaluates whether a game has game-specific changes in the active engine/release and returns its display version label.
    package static func hasSpecificUpdate(
        titleID: String,
        appVersion: String,
        gitSpecificChanged: Bool?
    ) -> (hasSpecific: Bool, versionLabel: String) {
        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let baseVer = releaseBaseVersion(appVersion)
        let catalogVer = updatedVersions[tid] ?? defaultVersion
        if let gitChanged = gitSpecificChanged {
            if gitChanged {
                return (true, catalogVer == defaultVersion ? baseVer : catalogVer)
            }
            return (false, baseVer)
        }
        return (!baseVer.isEmpty && catalogVer == baseVer) ? (true, catalogVer) : (false, baseVer)
    }

    /// Evaluates the 4-state refresh posture and platform fast-refresh capabilities for a built game off the main thread.
    package static func assess(
        titleID: String,
        isMarkedOlder: Bool,
        hasMacBuild: Bool,
        macAppPath: String,
        hasIOSBuild: Bool,
        hasReadableSourceInputs: Bool,
        outDir: String,
        gameName: String?,
        appVersion: String,
        gitSpecificChanged: Bool?,
        seedRoot: String = BuildSeedCache.defaultRoot(),
        repoPath: String
    ) -> GameRefreshAssessment {
        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let spec = hasSpecificUpdate(titleID: tid, appVersion: appVersion, gitSpecificChanged: gitSpecificChanged)

        if !isMarkedOlder || (!hasMacBuild && !hasIOSBuild) || tid.isEmpty {
            return GameRefreshAssessment(
                heroState: .upToDate,
                hasSpecificUpdate: false,
                versionLabel: spec.versionLabel,
                canFastRefreshMac: false,
                canFastRefreshIOS: false,
                needsMissingImgGuideIOS: false,
                missingOriginalPackage: false,
                expectedRomfsIdentity: nil
            )
        }

        let fm = FileManager.default
        let resolvedOutDir = resolveOutputDirectory(outDir: outDir, macAppPath: macAppPath)
        let workDir = resolvedOutDir.isEmpty ? "" : (resolvedOutDir + "/" + tid + "_build")

        let inspection = BuildSeedCache.inspect(titleID: tid, seedRoot: seedRoot, repoPath: repoPath, fm: fm)
        let effectiveSeedPath: BuildSeedCache.RefreshPath?
        if inspection.isUsable {
            effectiveSeedPath = inspection.path ?? .pathB
        } else {
            effectiveSeedPath = inspectAdoptableLegacyWorkDir(
                workDir: workDir, macAppPath: macAppPath, repoPath: repoPath, fm: fm
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

        let canFastRefreshMac: Bool
        let canFastRefreshIOS: Bool
        let needsMissingImgGuideIOS: Bool

        switch effectiveSeedPath {
        case .none:
            canFastRefreshMac = false
            canFastRefreshIOS = false
            needsMissingImgGuideIOS = false
        case .some(.pathA):
            let macReachable = macAppPath.isEmpty || fm.fileExists(atPath: macAppPath) || !candidates.isEmpty
            canFastRefreshMac = hasMacBuild && macReachable
            canFastRefreshIOS = hasIOSBuild
            needsMissingImgGuideIOS = false
        case .some(.pathB):
            let hasLocalIOSImg = candidates.contains { $0.lowercased().hasSuffix(".img") && !$0.contains(".app/") }
                || (!workDir.isEmpty && RomFSArchive.extractedVersion(in: workDir + "/extract") != nil)
            let hasSeedMetalSources = fm.fileExists(atPath: inspection.seedDir + "/metal-sources")
            let hasMacPrefill = !candidates.isEmpty || hasSeedMetalSources
            let macReachable = macAppPath.isEmpty
                ? hasMacPrefill
                : (fm.fileExists(atPath: macAppPath) || candidates.contains { $0.lowercased().hasSuffix(".img") })
            canFastRefreshMac = hasMacBuild && hasMacPrefill && macReachable
            canFastRefreshIOS = hasIOSBuild && hasLocalIOSImg
            needsMissingImgGuideIOS = hasIOSBuild && !hasLocalIOSImg
        }

        let anyPlatformNeedsFull = (hasMacBuild && !canFastRefreshMac) || (hasIOSBuild && !canFastRefreshIOS)
        let missingOriginalPackage = anyPlatformNeedsFull && !hasReadableSourceInputs
        let fastAny = canFastRefreshMac || canFastRefreshIOS
        let heroState: HeroRefreshState = spec.hasSpecific
            ? (fastAny ? .specificFast(version: spec.versionLabel) : .specificFull(version: spec.versionLabel))
            : .generalSync(fast: fastAny)

        return GameRefreshAssessment(
            heroState: heroState,
            hasSpecificUpdate: spec.hasSpecific,
            versionLabel: spec.versionLabel,
            canFastRefreshMac: canFastRefreshMac,
            canFastRefreshIOS: canFastRefreshIOS,
            needsMissingImgGuideIOS: needsMissingImgGuideIOS,
            missingOriginalPackage: missingOriginalPackage,
            expectedRomfsIdentity: inspection.record?.romfsIdentity
        )
    }

    private static func resolveOutputDirectory(outDir: String, macAppPath: String) -> String {
        if !outDir.isEmpty { return outDir }
        if !macAppPath.isEmpty {
            let parent = (macAppPath as NSString).deletingLastPathComponent
            if !parent.isEmpty && parent != "/" { return parent }
        }
        return ""
    }

    private static func normalizeChain(_ chain: String?) -> String? {
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

    private static func hasLegacyExeFS(in workDir: String, fm: FileManager) -> Bool {
        if isDirectory(workDir + "/ExeFS", fm: fm) { return true }
        let extractDir = workDir + "/extract"
        guard let entries = try? fm.contentsOfDirectory(atPath: extractDir) else { return false }
        return entries.contains { entry in
            (entry.hasPrefix("v") || entry.hasPrefix("patched_v"))
                && isDirectory(extractDir + "/" + entry + "/ExeFS", fm: fm)
        }
    }

    private static func inspectAdoptableLegacyWorkDir(
        workDir: String,
        macAppPath: String,
        repoPath: String,
        fm: FileManager
    ) -> BuildSeedCache.RefreshPath? {
        guard !workDir.isEmpty,
              isDirectory(workDir, fm: fm),
              isDirectory(workDir + "/shader", fm: fm),
              hasLegacyExeFS(in: workDir, fm: fm) else { return nil }

        if isDirectory(workDir + "/shader/ios/vk", fm: fm) || isDirectory(workDir + "/shader/ios/gl", fm: fm) {
            return .pathA
        }
        guard let normRepoChain = normalizeChain(EngineLayout.shaderChain(repo: repoPath)) else {
            return .pathB
        }
        let chainTag = "b-" + normRepoChain
        for base in [workDir + "/shader/ios/" + chainTag, workDir + "/shader/cache/" + chainTag] {
            if fm.fileExists(atPath: base) || fm.fileExists(atPath: base + ".img") { return .pathA }
        }
        if !macAppPath.isEmpty {
            if fm.fileExists(atPath: macAppPath + "/Contents/Resources/msl/" + chainTag + ".img") {
                return .pathA
            }
            if let bundle = try? MacGameBundle.read(URL(fileURLWithPath: macAppPath)),
               normalizeChain(bundle.shaderChain) == normRepoChain {
                return .pathA
            }
        }
        return .pathB
    }
}

/// Fast `DMROMFSID1` identity verification for `DMROMFS1` images (aligned with `dm/host/romfs_identity.h` and `romfs_image.py`).
package enum RomfsImageIdentity {
    package static let offsetBasis: UInt64 = 0xcbf29ce484222325
    package static let prime: UInt64 = 0x100000001b3

    private static let headerSize: UInt64 = 32
    private static let footerSize: UInt64 = 64
    private static let mslAlignment: UInt64 = 16384
    private static let footerAlignment: UInt64 = 8
    private static let chunkSize: Int = 1 << 20
    private static let headerMagic: [UInt8] = Array("DMROMFS1".utf8)
    private static let footerMagic: [UInt8] = Array("DMMSLTR1".utf8)

    package struct Parsed: Equatable, Sendable {
        package let title: String
        package let size: UInt64
        package let index: UInt64

        package init(title: String, size: UInt64, index: UInt64) {
            self.title = title
            self.size = size
            self.index = index
        }
    }

    private final class IdentityCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (size: UInt64, index: UInt64)] = [:]
        private let maxEntries = 4096

        func get(_ key: String) -> (size: UInt64, index: UInt64)? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]
        }

        func set(_ key: String, value: (size: UInt64, index: UInt64)) {
            lock.lock()
            defer { lock.unlock() }
            if entries.count >= maxEntries { entries.removeAll(keepingCapacity: true) }
            entries[key] = value
        }
    }

    private static let cache = IdentityCache()

    /// Parses a `DMROMFSID1 title=... version=... build=... size=<dec> index=<hex>` line.
    package static func parseIdentityLine(_ line: String) -> Parsed? {
        let firstLine = line.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        guard trimmed.hasPrefix("DMROMFSID1") else { return nil }
        let rest = trimmed.dropFirst(10)
        guard rest.isEmpty || rest.first == " " else { return nil }

        var title = ""
        var size: UInt64 = 0
        var index: UInt64 = 0
        var haveSize = false
        var haveIndex = false

        for tokenSub in rest.split(separator: " ", omittingEmptySubsequences: true) {
            guard let eq = tokenSub.firstIndex(of: "=") else { continue }
            let key = tokenSub[..<eq]
            let val = tokenSub[tokenSub.index(after: eq)...]
            if key == "title" {
                title = String(val)
            } else if key == "size" {
                guard !val.isEmpty, val.allSatisfy({ $0.isASCII && $0.isWholeNumber }),
                      let parsedSize = UInt64(val, radix: 10) else { return nil }
                size = parsedSize
                haveSize = true
            } else if key == "index" {
                guard !val.isEmpty, val.count <= 16, val.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                      let parsedIndex = UInt64(val, radix: 16) else { return nil }
                index = parsedIndex
                haveIndex = true
            }
        }
        guard haveSize && haveIndex else { return nil }
        return Parsed(title: title, size: size, index: index)
    }

    /// Computes `(size: baseSize, index: fnv1a64)` for a valid regular `DMROMFS1` image file without reading payload data.
    package static func computeIdentity(of path: String) -> (size: UInt64, index: UInt64)? {
        computeIdentityInternal(of: path, expectedBaseSize: nil)
    }

    /// Verifies `imagePath` against `expectedIdentityLine`, short-circuiting on header `baseSize` mismatch before hashing.
    package static func matches(imagePath: String, expectedIdentityLine: String) -> Bool {
        guard let expected = parseIdentityLine(expectedIdentityLine),
              let computed = computeIdentityInternal(of: imagePath, expectedBaseSize: expected.size) else {
            return false
        }
        return computed.size == expected.size && computed.index == expected.index
    }

    /// Scans depth 0 (`<driveFolder>/*.img`) and depth 1 (`<driveFolder>/<SubDir>/*.img`) for a regular matching `.img`.
    /// Always completes both depth 0 and depth 1 without early-returning on non-matching or stale entries at depth 0.
    package static func scanExternalDriveForMatchingImage(
        driveFolder: String,
        titleID: String,
        expectedIdentity: String?
    ) -> String? {
        guard !driveFolder.isEmpty, !driveFolder.utf8.contains(0) else { return nil }
        var rootStat = Darwin.stat()
        guard Darwin.lstat(driveFolder, &rootStat) == 0,
              (rootStat.st_mode & S_IFMT) == S_IFDIR else { return nil }

        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let trimmedExpected = expectedIdentity?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExpected = (trimmedExpected?.isEmpty == false)
        if let exp = trimmedExpected, !exp.isEmpty, parseIdentityLine(exp) == nil { return nil }

        let fm = FileManager.default
        guard let topEntries = try? fm.contentsOfDirectory(atPath: driveFolder) else { return nil }

        struct Candidate {
            let path: String
            let fileName: String
            let parentSubDir: String?
            let mtimeSec: Int64
            let mtimeNsec: Int64
        }

        var depth0Candidates: [Candidate] = []
        var depth1Dirs: [(name: String, path: String)] = []

        for name in topEntries.sorted() where !name.hasPrefix(".") {
            let childPath = joinPath(driveFolder, name)
            var st = Darwin.stat()
            guard Darwin.lstat(childPath, &st) == 0 else { continue }
            let mode = st.st_mode & S_IFMT
            if mode == S_IFREG, isCandidateImgName(name) {
                depth0Candidates.append(Candidate(
                    path: childPath, fileName: name, parentSubDir: nil,
                    mtimeSec: Int64(st.st_mtimespec.tv_sec), mtimeNsec: Int64(st.st_mtimespec.tv_nsec)
                ))
            } else if mode == S_IFDIR {
                depth1Dirs.append((name: name, path: childPath))
            }
        }

        var depth1Candidates: [Candidate] = []
        for sub in depth1Dirs {
            guard let subEntries = try? fm.contentsOfDirectory(atPath: sub.path) else { continue }
            for name in subEntries.sorted() where !name.hasPrefix(".") && isCandidateImgName(name) {
                let imgPath = joinPath(sub.path, name)
                var st = Darwin.stat()
                guard Darwin.lstat(imgPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                depth1Candidates.append(Candidate(
                    path: imgPath, fileName: name, parentSubDir: sub.name,
                    mtimeSec: Int64(st.st_mtimespec.tv_sec), mtimeNsec: Int64(st.st_mtimespec.tv_nsec)
                ))
            }
        }

        let allCandidates = depth0Candidates + depth1Candidates
        guard !allCandidates.isEmpty else { return nil }

        if hasExpected, let exp = trimmedExpected {
            var matched: [(candidate: Candidate, tidPreferred: Bool)] = []
            for cand in allCandidates where matches(imagePath: cand.path, expectedIdentityLine: exp) {
                let preferred = !tid.isEmpty && candidateAssociatesWithTitleID(
                    path: cand.path, fileName: cand.fileName, parentSubDir: cand.parentSubDir,
                    driveFolder: driveFolder, tid: tid
                ) == true
                matched.append((cand, preferred))
            }
            let chosen = matched.max { lhs, rhs in
                if lhs.tidPreferred != rhs.tidPreferred { return !lhs.tidPreferred && rhs.tidPreferred }
                if (lhs.candidate.parentSubDir != nil) != (rhs.candidate.parentSubDir != nil) {
                    return lhs.candidate.parentSubDir != nil
                }
                if lhs.candidate.mtimeSec != rhs.candidate.mtimeSec {
                    return lhs.candidate.mtimeSec < rhs.candidate.mtimeSec
                }
                return lhs.candidate.mtimeNsec < rhs.candidate.mtimeNsec
            }
            return chosen?.candidate.path
        }

        guard !tid.isEmpty else { return nil }
        var fallbackMatched: [Candidate] = []
        for cand in allCandidates {
            guard candidateAssociatesWithTitleID(
                path: cand.path, fileName: cand.fileName, parentSubDir: cand.parentSubDir,
                driveFolder: driveFolder, tid: tid
            ) == true else { continue }
            if let sidecarLine = readRegularSmallText(cand.path + ".id"), parseIdentityLine(sidecarLine) != nil {
                guard matches(imagePath: cand.path, expectedIdentityLine: sidecarLine) else { continue }
            } else {
                guard computeIdentity(of: cand.path) != nil else { continue }
            }
            fallbackMatched.append(cand)
        }

        return fallbackMatched.max { lhs, rhs in
            if (lhs.parentSubDir != nil) != (rhs.parentSubDir != nil) { return lhs.parentSubDir != nil }
            if lhs.mtimeSec != rhs.mtimeSec { return lhs.mtimeSec < rhs.mtimeSec }
            return lhs.mtimeNsec < rhs.mtimeNsec
        }?.path
    }

    // MARK: - Internal helpers

    private static func computeIdentityInternal(
        of path: String,
        expectedBaseSize: UInt64?
    ) -> (size: UInt64, index: UInt64)? {
        guard !path.isEmpty, !path.utf8.contains(0) else { return nil }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size >= Int64(headerSize) else { return nil }

        let fileSize = UInt64(st.st_size)
        guard fileSize <= UInt64(Int64.max) else { return nil }

        let mtimeSec = st.st_mtimespec.tv_sec
        let mtimeNsec = st.st_mtimespec.tv_nsec
        let cacheKey = "\(path)|\(st.st_size)|\(mtimeSec).\(mtimeNsec)"
        if let cached = cache.get(cacheKey) {
            if let expectedBaseSize, cached.size != expectedBaseSize { return nil }
            return cached
        }

        var header = [UInt8](repeating: 0, count: Int(headerSize))
        guard preadInto(fd: fd, buffer: &header, count: Int(headerSize), offset: 0),
              Array(header[0..<8]) == headerMagic else { return nil }

        let ioff = readUInt64LE(header, at: 8)
        let isz = readUInt64LE(header, at: 16)
        guard ioff >= headerSize, ioff <= fileSize, isz <= fileSize - ioff else { return nil }
        let baseSize = ioff + isz

        if let expectedBaseSize, baseSize != expectedBaseSize { return nil }
        if fileSize > baseSize, !validateTrailerFooter(fd: fd, fileSize: fileSize, baseSize: baseSize) {
            return nil
        }

        var hash = mixLittleEndianWords(offsetBasis, buffer: header, count: Int(headerSize))
        if isz > 0 {
            var buf = [UInt8](repeating: 0, count: chunkSize + 8)
            var at: UInt64 = 0
            while at < isz {
                let rem = isz - at
                let toRead = rem < UInt64(chunkSize) ? Int(rem) : chunkSize
                guard preadInto(fd: fd, buffer: &buf, count: toRead, offset: ioff + at) else { return nil }
                let padded = (toRead + 7) & ~7
                if padded > toRead {
                    for idx in toRead..<padded { buf[idx] = 0 }
                }
                hash = mixLittleEndianWords(hash, buffer: buf, count: padded)
                at += UInt64(toRead)
            }
        }

        let result = (size: baseSize, index: hash)
        var stAfter = Darwin.stat()
        guard Darwin.fstat(fd, &stAfter) == 0 else { return nil }
        if stAfter.st_size == st.st_size,
           stAfter.st_mtimespec.tv_sec == mtimeSec,
           stAfter.st_mtimespec.tv_nsec == mtimeNsec {
            cache.set(cacheKey, value: result)
        }
        return result
    }

    private static func validateTrailerFooter(fd: Int32, fileSize: UInt64, baseSize: UInt64) -> Bool {
        guard fileSize - baseSize >= footerSize else { return false }
        let footerOffset = fileSize - footerSize
        var raw = [UInt8](repeating: 0, count: Int(footerSize))
        guard preadInto(fd: fd, buffer: &raw, count: Int(footerSize), offset: footerOffset),
              Array(raw[0..<8]) == footerMagic else { return false }

        let version = readUInt32LE(raw, at: 8)
        let gfxAPI = raw[12]
        let chainLen = Int(readUInt16LE(raw, at: 14))
        let footerBaseSize = readUInt64LE(raw, at: 16)
        let mslOffset = readUInt64LE(raw, at: 24)
        let mslSize = readUInt64LE(raw, at: 32)

        guard version == 1,
              gfxAPI >= 1 && gfxAPI <= 3,
              footerBaseSize == baseSize,
              baseSize <= UInt64.max - (mslAlignment - 1) else { return false }

        let expectedMslOffset = (baseSize + (mslAlignment - 1)) & ~(mslAlignment - 1)
        guard mslOffset == expectedMslOffset,
              mslSize >= headerSize,
              mslOffset <= footerOffset,
              mslSize <= footerOffset - mslOffset else { return false }

        let rawEnd = mslOffset + mslSize
        guard rawEnd <= UInt64.max - (footerAlignment - 1) else { return false }
        let expectedFooterOffset = (rawEnd + (footerAlignment - 1)) & ~(footerAlignment - 1)
        guard expectedFooterOffset == footerOffset, chainLen <= 24 else { return false }

        for idx in 0..<chainLen {
            let b = raw[40 + idx]
            if b == 0 || b >= 0x80 { return false }
        }
        for idx in chainLen..<24 where raw[40 + idx] != 0 {
            return false
        }
        return true
    }

    private static func mixLittleEndianWords(_ initial: UInt64, buffer: [UInt8], count: Int) -> UInt64 {
        var h = initial
        var offset = 0
        while offset < count {
            h = (h ^ readUInt64LE(buffer, at: offset)) &* prime
            offset += 8
        }
        return h
    }

    private static func readUInt16LE(_ b: [UInt8], at i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func readUInt32LE(_ b: [UInt8], at i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    private static func readUInt64LE(_ b: [UInt8], at i: Int) -> UInt64 {
        UInt64(readUInt32LE(b, at: i)) | (UInt64(readUInt32LE(b, at: i + 4)) << 32)
    }

    private static func preadInto(fd: Int32, buffer: inout [UInt8], count: Int, offset: UInt64) -> Bool {
        guard count >= 0,
              count <= buffer.count,
              offset <= UInt64(Int64.max),
              UInt64(count) <= UInt64(Int64.max) - offset else { return false }
        var got = 0
        while got < count {
            let rc = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.pread(fd, base.advanced(by: got), count - got, off_t(offset + UInt64(got)))
            }
            if rc < 0 {
                if errno == EINTR { continue }
                return false
            }
            if rc == 0 { return false }
            got += rc
        }
        return true
    }

    private static func isCandidateImgName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        let lower = name.lowercased()
        return (lower as NSString).pathExtension == "img" && !lower.contains(".nxpart")
    }

    private static func joinPath(_ base: String, _ component: String) -> String {
        if base == "/" { return "/" + component }
        return (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/" + component
    }

    private static func readRegularSmallText(_ path: String) -> String? {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size >= 0 && st.st_size <= 65536 else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private static func candidateAssociatesWithTitleID(
        path: String,
        fileName: String,
        parentSubDir: String?,
        driveFolder: String,
        tid: String
    ) -> Bool? {
        if let sidecar = readRegularSmallText(path + ".id") {
            if let parsed = parseIdentityLine(sidecar), !parsed.title.isEmpty && parsed.title != "-" {
                return parsed.title.caseInsensitiveCompare(tid) == .orderedSame
            }
            if let data = sidecar.data(using: .utf8),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let jsonTitle = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !jsonTitle.isEmpty {
                return jsonTitle.caseInsensitiveCompare(tid) == .orderedSame
            }
        }
        if let sub = parentSubDir {
            let subPath = joinPath(driveFolder, sub)
            if let marker = readRegularSmallText(joinPath(subPath, ".titleid"))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !marker.isEmpty {
                return marker.caseInsensitiveCompare(tid) == .orderedSame
            }
            if sub.caseInsensitiveCompare(tid) == .orderedSame { return true }
            if sub.range(of: "(\(tid))", options: .caseInsensitive) != nil { return true }
            if sub.count == 16 && sub.allSatisfy(\.isHexDigit) { return false }
        }
        let stem = (fileName as NSString).deletingPathExtension
        if stem.caseInsensitiveCompare(tid) == .orderedSame { return true }
        if stem.range(of: tid, options: .caseInsensitive) != nil { return true }
        return nil
    }
}
