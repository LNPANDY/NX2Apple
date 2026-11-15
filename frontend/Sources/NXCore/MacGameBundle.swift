import Foundation

/// A game's Mac app as the library reads it: its title ID, its bundle name and its names by language (`DMTitleNames`).
package struct MacGameBundle {
    package let titleID: String
    package let name: String
    package let version: String?
    package let shaderChain: String?
    let displayName: String?
    package var titleNames: [String: String] = [:]

    enum Invalid: LocalizedError {
        case notGame
        var errorDescription: String? { L10n.string("library.notGame", Lang.initial()) }
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
        let titleNames: [String: String]
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: CachedEntry] = [:]

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
            guard fm.isExecutableFile(atPath: bundleURL.appendingPathComponent("Contents/MacOS/" + entry.executable).path),
                  fm.isExecutableFile(atPath: bundleURL.appendingPathComponent("Contents/MacOS/dmhost").path) else {
                removeCached(bundleKey)
                throw Invalid.notGame
            }
            return MacGameBundle(titleID: entry.titleID, name: entry.displayName ?? url.deletingPathExtension().lastPathComponent,
                                 version: entry.version, shaderChain: entry.shaderChain, displayName: entry.displayName,
                                 titleNames: entry.titleNames)
        }
        LauncherWork.count(.infoPlistRead)
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let rawID = info["DMTitleID"] as? String,
              rawID.range(of: "^[0-9A-Fa-f]{16}$", options: .regularExpression) != nil,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/"),
              fm.isExecutableFile(atPath: bundleURL.appendingPathComponent("Contents/MacOS/" + executable).path),
              fm.isExecutableFile(atPath: bundleURL.appendingPathComponent("Contents/MacOS/dmhost").path)
        else {
            removeCached(bundleKey)
            throw Invalid.notGame
        }
        let title = [info["CFBundleDisplayName"], info["CFBundleName"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let upperID = rawID.uppercased()
        let ver = displayVersion(info)
        let chain = info["DMChain"] as? String
        let names = GameTitleNames.read(info)
        storeCached(CachedEntry(plistInode: plistInode, plistSize: plistSize, plistModified: plistModified,
                                executable: executable, titleID: upperID, displayName: title, version: ver,
                                shaderChain: chain, titleNames: names), for: bundleKey)
        return MacGameBundle(titleID: upperID, name: title ?? url.deletingPathExtension().lastPathComponent,
                             version: ver, shaderChain: chain, displayName: title,
                             titleNames: names)
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
