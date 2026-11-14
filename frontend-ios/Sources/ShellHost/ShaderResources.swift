import AppleArchive
import Foundation
import System

/// Where a game's usable Metal shader library was resolved from across the 4-tier fallback chain.
public enum ShaderSourceKind: Equatable, Sendable {
    case trailer(chain: String, gfxAPI: String)
    case documentsFolder(URL)
    case dataFolder(URL)
    case frameworkFolder(URL)
    case frameworkArchive(URL)
}

/// Readiness of a game's shader payload across embedded `DMMSLTR1` RomFS trailers, external/rescued `msl/` folders, and framework bundles.
public enum ShaderReadiness: Equatable, Sendable {
    case ready(ShaderSourceKind)
    case missing(hadUnjoinedParts: Bool)
    case staleTrailer(imageChain: String, expectedChain: String)
}

/// Marker and directory checks for `msl/` shader trees and stripped frameworks (#947).
public enum ExternalShaders {
    public static let markerFile = "external-msl.json"

    static func isIncompleteEntry(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix(".partial")
            || lower.hasSuffix(".part")
            || lower.hasSuffix(".partial")
            || lower.hasSuffix(".nxjoin")
            || name.contains(DataParts.marker)
            || lower.contains(".nxpart")
    }

    fileprivate static func scanTree(at mslURL: URL, fileManager fm: FileManager) -> (exists: Bool, hasCompleteFile: Bool, hasIncomplete: Bool) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: mslURL.path, isDirectory: &isDir), isDir.boolValue else {
            return (false, false, false)
        }
        guard let walk = fm.enumerator(at: mslURL, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: []) else {
            return (true, false, false)
        }
        var hasCompleteFile = false
        for case let url as URL in walk {
            let name = url.lastPathComponent
            if isIncompleteEntry(name) {
                return (true, hasCompleteFile, true)
            }
            if name.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    walk.skipDescendants()
                }
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                hasCompleteFile = true
            }
        }
        return (true, hasCompleteFile, false)
    }

    /// True when `frameworkURL` carries no inline `msl/` directory or `msl-*.aar` archive of its own (including legacy `external-msl.json` bundles and stripped frameworks).
    public static func isRequired(in frameworkURL: URL, fileManager fm: FileManager = .default) -> Bool {
        var isMSLDir: ObjCBool = false
        if fm.fileExists(atPath: frameworkURL.appendingPathComponent("msl").path, isDirectory: &isMSLDir), isMSLDir.boolValue {
            return false
        }
        if fm.fileExists(atPath: frameworkURL.appendingPathComponent(markerFile).path) {
            return true
        }
        var isFWDir: ObjCBool = false
        guard fm.fileExists(atPath: frameworkURL.path, isDirectory: &isFWDir), isFWDir.boolValue else {
            return false
        }
        if let archives = try? ShaderResources.shaderArchives(in: frameworkURL, fileManager: fm), !archives.isEmpty {
            return false
        }
        return true
    }

    /// True when `mslURL` is a directory holding at least one complete shader entry and no in-flight transfer parts.
    public static func hasCompleteTree(at mslURL: URL, fileManager fm: FileManager = .default) -> Bool {
        let scan = scanTree(at: mslURL, fileManager: fm)
        return scan.exists && scan.hasCompleteFile && !scan.hasIncomplete
    }

    /// True when `mslURL` is a directory suitable as an override in `EngineLaunchPlan` (an empty player test folder
    /// or a complete tree, never a folder holding in-flight `.nxpart` / `.part` / `.partial` files).
    public static func isUsableOverride(at mslURL: URL, fileManager fm: FileManager = .default) -> Bool {
        let scan = scanTree(at: mslURL, fileManager: fm)
        return scan.exists && !scan.hasIncomplete
    }

    public static func isSatisfied(entry: CatalogueEntry, appFolder: URL, dataURL: URL?, romfsURL: URL? = nil,
                                   fileManager fm: FileManager = .default) -> Bool {
        if case .ready = ShaderResources.readiness(entry: entry, appFolder: appFolder, dataURL: dataURL, romfsURL: romfsURL, fileManager: fm) {
            return true
        }
        return false
    }
}

/// Resolves 4-tier shader readiness and unpacks legacy `.aar` framework shader archives when needed.
public actor ShaderResources {
    public static let shared = ShaderResources()

    public init() {}

    /// Evaluates the 4-tier shader fallback chain:
    /// 1. Embedded `DMMSLTR1` trailer in the selected `.img` RomFS file
    /// 2. `Documents/games/<titleID>/msl` (`appFolder/msl`)
    /// 3. `<dataURL>/msl` (when `dataURL` differs from `appFolder`)
    /// 4. `entry.frameworkURL` then `entry.fallbackBundledFrameworkURL` (`msl/` folder or `msl-<UUID>.aar`)
    public static func readiness(entry: CatalogueEntry, appFolder: URL, dataURL: URL?, romfsURL: URL? = nil,
                                 fileManager fm: FileManager = .default) -> ShaderReadiness {
        let expectedChain = entry.manifest?.chain ?? ""
        let explicitAPI = entry.manifest?.gfxAPI.flatMap { $0.isEmpty ? nil : $0 }
        let expectedAPI: String?
        if let explicitAPI {
            expectedAPI = explicitAPI
        } else if expectedChain.hasPrefix("b-") {
            expectedAPI = "nvn"
        } else {
            expectedAPI = nil
        }

        var staleInfo: (imageChain: String, expectedChain: String)?

        // Tier 1: Embedded DMMSLTR1 trailer on the resolved RomFS .img file.
        if let imageURL = resolveRomfsImage(entry: entry, dataURL: dataURL, romfsURL: romfsURL, fileManager: fm),
           let trailer = RomfsTrailer.inspect(at: imageURL),
           let trailerAPI = gfxAPIName(for: trailer.gfxAPI) {
            if trailerMatches(trailerChain: trailer.chain, trailerAPI: trailerAPI, expectedChain: expectedChain, expectedAPI: expectedAPI) {
                return .ready(.trailer(chain: trailer.chain, gfxAPI: trailerAPI))
            }
            staleInfo = (trailer.chain, expectedChain)
        }

        var hadUnjoinedParts = false

        // Tier 2: Documents/games/<titleID>/msl (player override or rescued hot-framework shaders).
        let appMSL = appFolder.appendingPathComponent("msl", isDirectory: true)
        let appCheck = checkMSLDirectory(at: appMSL, expectedChain: expectedChain, expectedAPI: expectedAPI, explicitAPI: explicitAPI != nil, fileManager: fm)
        hadUnjoinedParts = hadUnjoinedParts || appCheck.hasIncomplete
        if appCheck.usable {
            return .ready(.documentsFolder(appMSL))
        }

        // Tier 3: <dataURL>/msl when dataURL is distinct from appFolder.
        if let dataURL, !sameDirectory(dataURL, appFolder) {
            let dataMSL = dataURL.appendingPathComponent("msl", isDirectory: true)
            let dataCheck = checkMSLDirectory(at: dataMSL, expectedChain: expectedChain, expectedAPI: expectedAPI, explicitAPI: explicitAPI != nil, fileManager: fm)
            hadUnjoinedParts = hadUnjoinedParts || dataCheck.hasIncomplete
            if dataCheck.usable {
                return .ready(.dataFolder(dataMSL))
            }
        }

        // Tier 4: Primary frameworkURL, then fallbackBundledFrameworkURL (inline msl/ directory or msl-<UUID>.aar archive).
        if let fwURL = entry.frameworkURL,
           let source = frameworkShaderSource(in: fwURL, expectedChain: expectedChain, expectedAPI: expectedAPI, explicitAPI: explicitAPI != nil, verifyManifestChain: false, fileManager: fm) {
            return .ready(source)
        }
        if let fallbackURL = entry.fallbackBundledFrameworkURL,
           entry.frameworkURL.map({ !sameDirectory(fallbackURL, $0) }) ?? true,
           let source = frameworkShaderSource(in: fallbackURL, expectedChain: expectedChain, expectedAPI: expectedAPI, explicitAPI: explicitAPI != nil, verifyManifestChain: true, fileManager: fm) {
            return .ready(source)
        }

        if let staleInfo {
            return .staleTrailer(imageChain: staleInfo.imageChain, expectedChain: staleInfo.expectedChain)
        }
        return .missing(hadUnjoinedParts: hadUnjoinedParts)
    }

    public func prepare(_ game: LaunchableGame, fileManager fm: FileManager = .default) throws -> URL? {
        if game.usesEmbeddedShaderTrailer {
            return nil
        }

        let cache = game.appFolder.appendingPathComponent(".shader-resources", isDirectory: true)
        let directories = ((try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        // Only this actor extracts into this cache. A partial directory present on entry survived an interrupted launch.
        for partial in directories where Self.hasUUIDName(partial.lastPathComponent, prefix: ".partial-") {
            try? fm.removeItem(at: partial)
        }

        // The launch plan already knows how to use an explicit setting, player/external shaders, or the loose framework tree.
        guard game.environment["DM_MSL_DIR"] == nil else { return nil }
        for folder in [game.appFolder, game.dataURL] {
            let msl = folder.appendingPathComponent("msl", isDirectory: true)
            if ExternalShaders.isUsableOverride(at: msl, fileManager: fm) { return nil }
        }
        let bundledMSL = game.frameworkURL.appendingPathComponent("msl", isDirectory: true)
        var isBundledDir: ObjCBool = false
        if fm.fileExists(atPath: bundledMSL.path, isDirectory: &isBundledDir), isBundledDir.boolValue {
            return nil
        }

        let primaryArchives = (try? Self.shaderArchives(in: game.frameworkURL, fileManager: fm)) ?? []
        if let archive = primaryArchives.first {
            guard primaryArchives.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
            return try unpack(archive, into: cache, existingDirectories: directories, fileManager: fm)
        }

        if let fallbackFW = game.fallbackBundledFrameworkURL {
            let fallbackMSL = fallbackFW.appendingPathComponent("msl", isDirectory: true)
            var isFallbackDir: ObjCBool = false
            if fm.fileExists(atPath: fallbackMSL.path, isDirectory: &isFallbackDir), isFallbackDir.boolValue {
                return fallbackMSL
            }
            let fallbackArchives = (try? Self.shaderArchives(in: fallbackFW, fileManager: fm)) ?? []
            if let archive = fallbackArchives.first {
                guard fallbackArchives.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
                return try unpack(archive, into: cache, existingDirectories: directories, fileManager: fm)
            }
        }

        return nil
    }

    fileprivate static func shaderArchives(in frameworkURL: URL, fileManager fm: FileManager) throws -> [URL] {
        let files = try fm.contentsOfDirectory(at: frameworkURL, includingPropertiesForKeys: nil)
        return files
            .filter { $0.pathExtension == "aar" && hasUUIDName($0.deletingPathExtension().lastPathComponent, prefix: "msl-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func hasUUIDName(_ name: String, prefix: String) -> Bool {
        name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private static func gfxAPIName(for code: UInt8) -> String? {
        switch code {
        case 1: "nvn"
        case 2: "vulkan"
        case 3: "gl"
        default: nil
        }
    }

    private static func trailerMatches(trailerChain: String, trailerAPI: String, expectedChain: String, expectedAPI: String?) -> Bool {
        switch expectedAPI {
        case "nvn":
            return trailerAPI == "nvn" && !trailerChain.isEmpty && (expectedChain.isEmpty || trailerChain == expectedChain)
        case "vulkan", "gl":
            return trailerAPI == expectedAPI && (trailerChain.isEmpty || expectedChain.isEmpty || trailerChain == expectedChain)
        case nil:
            return trailerAPI == "nvn" ? !trailerChain.isEmpty : (trailerAPI == "vulkan" || trailerAPI == "gl")
        default:
            return false
        }
    }

    private static func resolveRomfsImage(entry: CatalogueEntry, dataURL: URL?, romfsURL: URL?, fileManager fm: FileManager) -> URL? {
        if let romfsURL {
            return isRegularImageFile(romfsURL, fileManager: fm) ? romfsURL : nil
        }
        guard let dataURL else { return nil }
        if let manifest = entry.manifest {
            guard let located = DataLocator.romfs(in: dataURL, manifest: manifest, fm, allowPickedFile: true) else { return nil }
            return isRegularImageFile(located.romfs, fileManager: fm) ? located.romfs : nil
        }
        if isRegularImageFile(dataURL, fileManager: fm) {
            return dataURL
        }
        let canonical = dataURL.appendingPathComponent("romfs.img")
        if isRegularImageFile(canonical, fileManager: fm) {
            return canonical
        }
        let names = ((try? fm.contentsOfDirectory(atPath: dataURL.path)) ?? []).sorted()
        for name in names where RomfsImageName.isNonPartImage(name) {
            let candidate = dataURL.appendingPathComponent(name)
            if isRegularImageFile(candidate, fileManager: fm) {
                return candidate
            }
        }
        return nil
    }

    private static func isRegularImageFile(_ url: URL, fileManager fm: FileManager) -> Bool {
        guard RomfsImageName.isNonPartImage(url.lastPathComponent),
              let attrs = try? fm.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 else {
            return false
        }
        return true
    }

    private static func sameDirectory(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func checkMSLDirectory(at mslURL: URL, expectedChain: String, expectedAPI: String?, explicitAPI: Bool,
                                          fileManager fm: FileManager) -> (usable: Bool, hasIncomplete: Bool) {
        let scan = ExternalShaders.scanTree(at: mslURL, fileManager: fm)
        guard scan.exists else { return (false, false) }
        if scan.hasIncomplete { return (false, true) }
        guard scan.hasCompleteFile else { return (false, false) }
        if expectedChain.isEmpty && expectedAPI == nil {
            return (true, false)
        }

        func hasNonEmptyRegularFile(_ fileURL: URL) -> Bool {
            guard !ExternalShaders.isIncompleteEntry(fileURL.lastPathComponent),
                  let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 else {
                return false
            }
            return true
        }

        func matchesProgramRoot(_ root: URL) -> Bool {
            switch expectedAPI {
            case "vulkan":
                return ExternalShaders.hasCompleteTree(at: root.appendingPathComponent("vk", isDirectory: true), fileManager: fm)
            case "gl":
                return ExternalShaders.hasCompleteTree(at: root.appendingPathComponent("gl", isDirectory: true), fileManager: fm)
            default:
                if !expectedChain.isEmpty {
                    let chainDir = root.appendingPathComponent(expectedChain, isDirectory: true)
                    let chainImg = root.appendingPathComponent(expectedChain + ".img")
                    if ExternalShaders.hasCompleteTree(at: chainDir, fileManager: fm) || hasNonEmptyRegularFile(chainImg) {
                        return true
                    }
                    // Pre-PR #1270 manifests had no explicit gfx_api key even for Vulkan/GL games.
                    if !explicitAPI {
                        if ExternalShaders.hasCompleteTree(at: root.appendingPathComponent("vk", isDirectory: true), fileManager: fm)
                            || ExternalShaders.hasCompleteTree(at: root.appendingPathComponent("gl", isDirectory: true), fileManager: fm) {
                            return true
                        }
                    }
                    return false
                }
                return true
            }
        }

        if matchesProgramRoot(mslURL) {
            return (true, false)
        }
        let entries = ((try? fm.contentsOfDirectory(atPath: mslURL.path)) ?? []).sorted()
        for name in entries where name.count >= 2 && name.hasPrefix("p") && name.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) {
            let progRoot = mslURL.appendingPathComponent(name, isDirectory: true)
            if matchesProgramRoot(progRoot) {
                return (true, false)
            }
        }
        return (false, false)
    }

    private static func frameworkShaderSource(in frameworkURL: URL, expectedChain: String, expectedAPI: String?, explicitAPI: Bool,
                                              verifyManifestChain: Bool, fileManager fm: FileManager) -> ShaderSourceKind? {
        if verifyManifestChain, !expectedChain.isEmpty,
           let manifestData = fm.contents(atPath: frameworkURL.appendingPathComponent("game.manifest.json").path),
           let manifest = try? GameManifest.parse(manifestData),
           manifest.chain != expectedChain {
            return nil
        }
        let fwMSL = frameworkURL.appendingPathComponent("msl", isDirectory: true)
        if checkMSLDirectory(at: fwMSL, expectedChain: expectedChain, expectedAPI: expectedAPI, explicitAPI: explicitAPI, fileManager: fm).usable {
            return .frameworkFolder(fwMSL)
        }
        if let archives = try? shaderArchives(in: frameworkURL, fileManager: fm), archives.count == 1 {
            return .frameworkArchive(archives[0])
        }
        return nil
    }

    private func unpack(_ archive: URL, into cache: URL, existingDirectories directories: [URL], fileManager fm: FileManager) throws -> URL {
        var mutableCache = cache
        let destination = cache.appendingPathComponent(archive.deletingPathExtension().lastPathComponent, isDirectory: true)
        if (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            var attributes = URLResourceValues()
            attributes.isExcludedFromBackup = true
            try mutableCache.setResourceValues(attributes)

            let temporary = cache.appendingPathComponent(".partial-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: temporary) }
            try extract(archive, to: temporary)
            try fm.moveItem(at: temporary, to: destination)
        }
        // A new archive UUID comes from a new installed app. No running game can still use the old app's archive.
        for old in directories where old.lastPathComponent != destination.lastPathComponent &&
            Self.hasUUIDName(old.lastPathComponent, prefix: "msl-") {
            try? fm.removeItem(at: old)
        }
        return destination
    }

    private func extract(_ archive: URL, to directory: URL) throws {
        try ArchiveByteStream.withFileStream(path: FilePath(archive.path), mode: .readOnly, options: [], permissions: []) { file in
            try ArchiveByteStream.withDecompressionStream(readingFrom: file) { decompressed in
                try ArchiveStream.withDecodeStream(readingFrom: decompressed) { input in
                    try ArchiveStream.withExtractStream(extractingTo: FilePath(directory.path), flags: [.ignoreOperationNotPermitted]) { output in
                        _ = try ArchiveStream.process(readingFrom: input, writingTo: output)
                    }
                }
            }
        }
    }
}
