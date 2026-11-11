import CommonCrypto
import SwiftUI
import Combine
import NXCore
import NXModel
import NXLauncher

/// What `BuildFilesStore` (#232) measures and removes in a game's build folder: every part `BuildFolder` knows (the extracted game files,
/// the shaders, the Xcode build, the caches), with the paths Free space never touches kept (the apps, the IPA, the game data archive,
/// the NSPs and keys) and the folder's logs, profile, saves and converted NSPs left in place. Also discovers orphaned `<16Hex>_build`
/// directories left in output or library folders when a package was removed or a build stopped before entering the library.
enum BuildFiles {
    nonisolated static func measure(_ game: BuildFilesStore.Game) -> Int64 {
        BuildFolder.survey(game.folder, protecting: game.protecting).sizes.values.reduce(0, +)
    }

    nonisolated static func remove(_ game: BuildFilesStore.Game) throws -> Int64 {
        try BuildFolder.remove(Set(BuildFolderPart.allCases), in: game.folder, protecting: game.protecting, buildRunning: false)
    }

    /// Parses a valid 16-hex-character TitleID from a `<TitleID>_build` directory name, returning uppercase hex or nil.
    nonisolated static func orphanTitleID(folderName: String) -> String? {
        guard folderName.hasSuffix("_build") else { return nil }
        let prefix = String(folderName.dropLast("_build".count))
        guard prefix.count == 16,
              prefix.unicodeScalars.allSatisfy({
                  ($0.value >= 0x30 && $0.value <= 0x39)
                      || ($0.value >= 0x41 && $0.value <= 0x46)
                      || ($0.value >= 0x61 && $0.value <= 0x66)
              }) else { return nil }
        return prefix.uppercased()
    }

    /// Deterministic UUID derived from a canonicalized orphan build folder path so confirmations and sheets remain stable across refreshes.
    nonisolated static func orphanUUID(forResolvedPath path: String) -> UUID {
        let bytes = Array(("orphan-build:" + path).utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        bytes.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(bytes.count), &digest)
        }
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    /// Attempts to read a human-readable game title from `<buildFolder>/profile/**/game.tsv`, sibling `.app` bundles, or engine profiles.
    nonisolated static func metadataName(forBuildFolder folder: String, titleID: String, engineRoot: String = "") -> String? {
        let fm = FileManager.default
        let tsvCandidates = [
            folder + "/profile/game.tsv",
            folder + "/profile/" + titleID + "/game.tsv",
            folder + "/profile/" + titleID.lowercased() + "/game.tsv",
            engineRoot.isEmpty ? "" : engineRoot + "/dm/games/" + titleID + "/game.tsv",
        ].filter { !$0.isEmpty }
        for path in tsvCandidates {
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
               let parsed = parseGameTSVName(text) {
                return parsed
            }
        }
        let parent = (folder as NSString).deletingLastPathComponent
        if let entries = try? fm.contentsOfDirectory(atPath: parent) {
            for item in entries.sorted() where item.hasSuffix(".app") {
                let plistURL = URL(fileURLWithPath: parent).appendingPathComponent(item).appendingPathComponent("Contents/Info.plist")
                guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any],
                      let bundleTitle = (dict["DMTitleID"] as? String)?.uppercased(),
                      bundleTitle == titleID else { continue }
                if let display = (dict["CFBundleDisplayName"] as? String ?? dict["CFBundleName"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !display.isEmpty {
                    return display
                }
            }
        }
        return nil
    }

    private nonisolated static func parseGameTSVName(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name\t") {
                let value = String(trimmed.dropFirst("name\t".count)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Scans candidate output/library roots (depth 1 and immediate game subfolders at depth 2) for `<TitleID>_build` folders
    /// not claimed by any known library game.
    nonisolated static func orphanGames(
        in roots: [String],
        knownFolders: Set<String>,
        engineRoot: String = "",
        t: ((String) -> String)? = nil
    ) -> [BuildFilesStore.Game] {
        let fm = FileManager.default
        var seenResolved = knownFolders
        var candidateBuildDirs: [(resolved: String, raw: String, titleID: String)] = []
        var uniqueRoots: [String] = []
        var seenRoots = Set<String>()
        for rawRoot in roots where !rawRoot.isEmpty {
            let resolvedRoot = BuildFolder.resolved(rawRoot)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: resolvedRoot, isDirectory: &isDir), isDir.boolValue,
                  seenRoots.insert(resolvedRoot).inserted else { continue }
            uniqueRoots.append(resolvedRoot)
        }
        for root in uniqueRoots {
            guard let topEntries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in topEntries.sorted() where !entry.hasPrefix(".") {
                let full = root + "/" + entry
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
                if let tid = orphanTitleID(folderName: entry) {
                    let resolved = BuildFolder.resolved(full)
                    if seenResolved.insert(resolved).inserted {
                        candidateBuildDirs.append((resolved, full, tid))
                    }
                    continue
                }
                if entry.hasSuffix(".app") || entry == "games" || entry.hasSuffix("_build") { continue }
                guard let subEntries = try? fm.contentsOfDirectory(atPath: full) else { continue }
                for sub in subEntries.sorted() where !sub.hasPrefix(".") {
                    guard let tid = orphanTitleID(folderName: sub) else { continue }
                    let subFull = full + "/" + sub
                    var subDir: ObjCBool = false
                    guard fm.fileExists(atPath: subFull, isDirectory: &subDir), subDir.boolValue else { continue }
                    let resolved = BuildFolder.resolved(subFull)
                    if seenResolved.insert(resolved).inserted {
                        candidateBuildDirs.append((resolved, subFull, tid))
                    }
                }
            }
        }
        return candidateBuildDirs.map { item in
            let parent = (item.resolved as NSString).deletingLastPathComponent
            let protected = [
                parent + "/games/" + item.titleID,
                parent + "/games/" + item.titleID + "/romfs.img",
                parent + "/" + item.titleID + ".app",
            ].map(BuildFolder.resolved)
            let displayName: String
            if let found = metadataName(forBuildFolder: item.resolved, titleID: item.titleID, engineRoot: engineRoot) {
                if let t {
                    let fmt = t("orphanBuild.named")
                    displayName = fmt == "orphanBuild.named" ? "\(found) (\(item.titleID))" : String(format: fmt, found, item.titleID)
                } else {
                    displayName = "\(found) (\(item.titleID))"
                }
            } else if let t {
                let fmt = t("orphanBuild.title")
                displayName = fmt == "orphanBuild.title" ? "Unlisted build (\(item.titleID))" : String(format: fmt, item.titleID)
            } else {
                displayName = "Unlisted build (\(item.titleID))"
            }
            return BuildFilesStore.Game(
                id: orphanUUID(forResolvedPath: item.resolved),
                name: displayName,
                folder: item.resolved,
                protecting: protected
            )
        }
    }

    /// The library's games that have a build folder plus any orphaned `<TitleID>_build` directories in candidate output folders.
    @MainActor static func games(
        _ games: [LibraryGame],
        lang: Lang,
        extraRoots: [String] = [],
        engineRoot: String = "",
        t: ((String) -> String)? = nil
    ) -> [BuildFilesStore.Game] {
        let knownList: [BuildFilesStore.Game] = games.compactMap { game in
            BuildFolder.location(for: game).map {
                BuildFilesStore.Game(
                    id: game.id,
                    name: game.displayName(lang),
                    folder: $0,
                    protecting: BuildFolder.protectedPaths(for: game)
                )
            }
        }
        var claimed = Set(knownList.map { BuildFolder.resolved($0.folder) })
        for game in games {
            for candidate in BuildFolder.candidates(for: game) {
                claimed.insert(BuildFolder.resolved(candidate))
            }
        }
        let allRoots = extraRoots + games.flatMap { [$0.outputDirectory, $0.sourceFolder] }
        guard allRoots.contains(where: { !$0.isEmpty }) else { return knownList }
        let orphans = orphanGames(in: allRoots, knownFolders: claimed, engineRoot: engineRoot, t: t)
        return knownList + orphans
    }

    /// Resolves a `LibraryGame` for the Free Space detail sheet — either from the library or synthesized from an orphan entry.
    @MainActor static func freeSpaceGame(id: UUID, in libraryGames: [LibraryGame], store: BuildFilesStore) -> LibraryGame? {
        if let known = libraryGames.first(where: { $0.id == id }) {
            return known
        }
        guard let entry = store.entry(id),
              let titleID = orphanTitleID(folderName: (entry.folder as NSString).lastPathComponent) else {
            return nil
        }
        let parent = (entry.folder as NSString).deletingLastPathComponent
        return LibraryGame(
            id: entry.id,
            titleID: titleID,
            name: entry.name,
            outputDirectory: parent
        )
    }

    /// The Manage menu's row title: "Remove build files (31 GB)" once the size is known.
    @MainActor static func menuTitle(_ store: BuildFilesStore, game: UUID, t: (String) -> String) -> String? {
        if let entry = store.entry(game) { return String(format: t("buildfiles.menu"), BuildFilesCard.bytes(entry.bytes)) }
        return store.isMeasured(game) ? nil : t("buildfiles.title")
    }
}

/// Keeps the store's sizes current (the library changed, a build was recorded, or output folders changed) and shows its question as a sheet.
private struct BuildFilesWiring: ViewModifier {
    @ObservedObject var store: BuildFilesStore
    @ObservedObject var library: GameLibrary
    @ObservedObject var build: BuildStore
    let recorded: PassthroughSubject<Void, Never>
    let buildingID: UUID?
    let pad: PadFocus
    let scope: () -> String
    @EnvironmentObject var loc: Localizer

    func body(content: Content) -> some View {
        content
            .onAppear(perform: refresh)
            .onChange(of: library.games.map(\.id)) { _ in refresh() }
            .onChange(of: library.folder) { _ in refresh() }
            .onChange(of: build.outDir) { _ in refresh() }
            .onChange(of: loc.lang) { _ in refresh() }
            .onReceive(recorded) { refresh() }
            .sheet(item: Binding(get: { store.confirmingEntry }, set: { if $0 == nil { store.confirming = nil } })) { entry in
                BuildFilesRemoveSheet(
                    entry: entry,
                    cancel: { store.confirming = nil },
                    confirm: { store.remove(entry.id, building: entry.id == buildingID) }
                )
                .environmentObject(pad).environmentObject(loc)
            }
            .onChange(of: store.confirming) { id in pad.scope = id != nil ? "buildfiles" : scope() }
    }

    private func refresh() {
        store.refresh(
            BuildFiles.games(
                library.games,
                lang: loc.lang,
                extraRoots: [library.folder, build.outDir, build.gameDir],
                engineRoot: EngineLayout.root(build.repo.path),
                t: loc.t
            )
        )
    }
}

extension View {
    func buildFilesWiring(
        _ store: BuildFilesStore,
        library: GameLibrary,
        build: BuildStore,
        recorded: PassthroughSubject<Void, Never>,
        buildingID: UUID?,
        pad: PadFocus,
        scope: @escaping () -> String
    ) -> some View {
        modifier(BuildFilesWiring(store: store, library: library, build: build, recorded: recorded, buildingID: buildingID, pad: pad, scope: scope))
    }
}
