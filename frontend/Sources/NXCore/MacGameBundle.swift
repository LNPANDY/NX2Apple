import Foundation

/// A game's Mac app as the library reads it: its title ID, its bundle name and its names by language (`DMTitleNames`).
package struct MacGameBundle {
    package let titleID: String
    package let name: String
    package let version: String?
    package let shaderChain: String?
    let displayName: String?
    package var titleNames: [String: String] = [:]
    package var upstream: EngineUpstreamKind = .nxnative

    package enum Invalid: LocalizedError {
        case notGame, missingData
        package var errorDescription: String? {
            L10n.string(self == .missingData ? "ios.ui.missingDataChip" : "library.notGame", Lang.initial())
        }
    }

    private struct CachedEntry {
        let plistInode: UInt64
        let plistSize: UInt64
        let plistModified: TimeInterval
        let executable: String
        let titleID: String
        let displayName: String?
        let version: String?
        let shaderChain: String?
        let requiresRomFS: Bool
        let titleNames: [String: String]
        let upstream: EngineUpstreamKind
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: CachedEntry] = [:]

    private static func isHexTitleID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard raw.range(of: "^[0-9A-Fa-f]{16}$", options: .regularExpression) != nil else { return nil }
        return raw.uppercased()
    }

    private static func hasRequiredBinaries(in bundleURL: URL, executable: String, upstream: EngineUpstreamKind, fm: FileManager) -> Bool {
        guard fm.isExecutableFile(atPath: bundleURL.appendingPathComponent("Contents/MacOS/" + executable).path) else {
            return false
        }
        switch upstream {
        case .nxnative:
            return fm.isExecutableFile(atPath: bundleURL.appendingPathComponent("Contents/MacOS/dmhost").path)
        case .macNativeGames:
            return true
        case .s2arm:
            if executable == "s2arm-host" {
                return fm.fileExists(atPath: bundleURL.appendingPathComponent("Contents/MacOS/libs2a_vaguard.dylib").path)
            }
            return true
        }
    }

    package static func read(_ url: URL) throws -> MacGameBundle {
        guard url.pathExtension.lowercased() == "app" else { throw Invalid.notGame }
        let bundleURL = url.standardizedFileURL
        let bundleKey = bundleURL.path
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let fm = FileManager.default
        guard let attr = try? fm.attributesOfItem(atPath: plistURL.path),
              let plistSize = attr[.size] as? UInt64,
              let plistModified = (attr[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            removeCached(bundleKey)
            throw Invalid.notGame
        }
        let plistInode = attr[.systemFileNumber] as? UInt64 ?? 0
        if let entry = cached(bundleKey),
           entry.plistInode == plistInode,
           entry.plistSize == plistSize,
           entry.plistModified == plistModified {
            guard hasRequiredBinaries(in: bundleURL, executable: entry.executable, upstream: entry.upstream, fm: fm) else {
                removeCached(bundleKey)
                throw Invalid.notGame
            }
            guard requiredDataExists(in: bundleURL, required: entry.requiresRomFS) else {
                removeCached(bundleKey)
                throw Invalid.missingData
            }
            return MacGameBundle(titleID: entry.titleID, name: entry.displayName ?? url.deletingPathExtension().lastPathComponent,
                                 version: entry.version, shaderChain: entry.shaderChain, displayName: entry.displayName,
                                 titleNames: entry.titleNames, upstream: entry.upstream)
        }
        LauncherWork.count(.infoPlistRead)
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            removeCached(bundleKey)
            throw Invalid.notGame
        }

        if let pkgType = info["CFBundlePackageType"] as? String, pkgType != "APPL" {
            removeCached(bundleKey)
            throw Invalid.notGame
        }

        let rawExplicit = (info["DMUpstream"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let explicitUpstream = (rawExplicit?.isEmpty == false) ? rawExplicit : nil
        if let explicitUpstream {
            guard EngineUpstreamKind(rawValue: explicitUpstream) != nil else {
                removeCached(bundleKey)
                throw Invalid.notGame
            }
        }

        let bundleID = (info["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        let upstream: EngineUpstreamKind
        let upperID: String
        if explicitUpstream == "macnativegames" || (explicitUpstream == nil && (EngineUpstream.macNativeGamesBundleTitleIDs[bundleID] != nil || bundleID.hasPrefix("org.macnativegames."))) {
            if bundleID.contains(".shaders.") || bundleID.contains(".data.") || bundleID == "org.macnativegames.launcher" {
                removeCached(bundleKey)
                throw Invalid.notGame
            }
            guard let resolvedID = isHexTitleID(info["DMTitleID"] as? String)
                    ?? isHexTitleID(info["MNGTitleID"] as? String)
                    ?? EngineUpstream.macNativeGamesBundleTitleIDs[bundleID] else {
                removeCached(bundleKey)
                throw Invalid.notGame
            }
            upstream = .macNativeGames
            upperID = resolvedID
        } else if explicitUpstream == "s2arm" || (explicitUpstream == nil && (bundleID == "org.s2arm.macos.game" || bundleID.hasPrefix("org.s2arm."))) {
            guard let resolvedID = isHexTitleID(info["DMTitleID"] as? String)
                    ?? isHexTitleID(info["S2ATitleID"] as? String) else {
                removeCached(bundleKey)
                throw Invalid.notGame
            }
            upstream = .s2arm
            upperID = resolvedID
        } else {
            guard let resolvedID = isHexTitleID(info["DMTitleID"] as? String) else {
                removeCached(bundleKey)
                throw Invalid.notGame
            }
            upstream = .nxnative
            upperID = resolvedID
        }

        guard let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/"),
              hasRequiredBinaries(in: bundleURL, executable: executable, upstream: upstream, fm: fm) else {
            removeCached(bundleKey)
            throw Invalid.notGame
        }

        let title = [info["CFBundleDisplayName"], info["CFBundleName"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let ver = displayVersion(info)
        let chain = info["DMChain"] as? String
        let names = GameTitleNames.read(info)
        let requiresRomFS = info["DMRomfsMarker"] != nil
        guard requiredDataExists(in: bundleURL, required: requiresRomFS) else { throw Invalid.missingData }
        storeCached(CachedEntry(plistInode: plistInode, plistSize: plistSize, plistModified: plistModified,
                                executable: executable, titleID: upperID, displayName: title, version: ver,
                                shaderChain: chain, requiresRomFS: requiresRomFS, titleNames: names, upstream: upstream), for: bundleKey)
        return MacGameBundle(titleID: upperID, name: title ?? url.deletingPathExtension().lastPathComponent,
                             version: ver, shaderChain: chain, displayName: title,
                             titleNames: names, upstream: upstream)
    }

    /// Current packages declare DMRomfsMarker and ship a RomFS image or tree. Older bundles keep their existing contract.
    private static func requiredDataExists(in app: URL, required: Bool) -> Bool {
        guard required else { return true }
        let resources = app.appendingPathComponent("Contents/Resources")
        var directory: ObjCBool = false
        let fm = FileManager.default
        if fm.fileExists(atPath: resources.appendingPathComponent("romfs.img").path, isDirectory: &directory), !directory.boolValue { return true }
        return fm.fileExists(atPath: resources.appendingPathComponent("romfs").path, isDirectory: &directory) && directory.boolValue
    }

    private static func cached(_ key: String) -> CachedEntry? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private static func storeCached(_ entry: CachedEntry, for key: String) {
        cacheLock.lock()
        if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = entry
        cacheLock.unlock()
    }

    private static func removeCached(_ key: String) {
        cacheLock.lock()
        cache.removeValue(forKey: key)
        cacheLock.unlock()
    }

    package static func invalidateCache(forApp path: String) {
        guard !path.isEmpty else { return }
        removeCached(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    /// The version of the package the app was packed with. A Mac app packed with DMPackageVersion states it in DMDisplayVersion, else
    /// (an update packed from a dump or a NUP without control data) only as the packed version, whose CFBundleShortVersionString is 1.0
    /// and not what runs (#953). The base game packed without a display version (v0) states none. An older app states it in
    /// CFBundleShortVersionString. Unknown stays nil: it is never guessed from the base game or from CFBundleVersion.
    static func displayVersion(_ info: [String: Any]) -> String? {
        let trimmed = { (key: String) in ((info[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let package = trimmed("DMPackageVersion")
        let version: String
        if !package.isEmpty {
            let display = trimmed("DMDisplayVersion")
            version = !display.isEmpty ? display : package == "v0" ? "" : package
        } else {
            version = trimmed("CFBundleShortVersionString")
        }
        return version.isEmpty ? nil : version
    }
}
