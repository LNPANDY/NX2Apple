import Foundation

/// A game that comes as a folder of its files instead of NSP or XCI packages (LNPANDY/NX2Apple#512, #445). Switch 2 games come
/// this way. The engine builds such a folder with `scripts/pack_dump.py`, called by `build_ipa_from_nsp.py` when it is given the
/// folder, and needs no `prod.keys` for it: the files are not encrypted. The layout, as pack_dump.py reads it:
///
///     <folder>/base/exefs/        main, main.npdm, sdk, rtld, subsdk*
///     <folder>/base/romfs/
///     <folder>/updates/<version>/exefs/, romfs/    optional, the version as a decimal number, the patched RomFS
///     <folder>/dlc/<DLC title ID>/<n>/romfs/      optional, the DLC title ID in hex
///
/// The rules here are pack_dump.py's `is_dump` and `scan`, and build_ipa_from_nsp.py's `dump_folder`, so the launcher refuses
/// what the script would refuse, and names the missing piece instead of "no NSP in this folder". Reads only names, and the
/// first bytes of main.npdm: never the game's data.
///
/// The same game can come as one NUP container (a `.nup` file, https://github.com/a55uka/nup, SPEC v1): base, updates and DLC
/// as the same trees in one file, not encrypted either. The engine reads one from seedds/nxnative 423a674 (`scripts/pack_nup.py`),
/// given the file or a folder that holds it. The launcher reads only its header and package table (`readNUP`).
package enum GameFolder {
    /// What a game folder holds.
    package struct Contents: Equatable {
        package let folder: String
        /// The program ID in base/exefs/main.npdm, which the script takes as the title ID.
        package let titleID: UInt64
        /// The update folders by version, oldest first.
        package let updates: [(version: Int, path: String)]
        /// The DLC folders (dlc/<title ID>) with their title IDs, sorted by title ID.
        package let dlc: [(titleID: UInt64, path: String)]
        /// The NUP file the game is in, nil for a folder of files.
        package var nup: String? = nil

        package var titleIDHex: String { String(format: "%016llX", titleID) }
        package var basePath: String {
            if let nup { return nup }
            if FileManager.default.fileExists(atPath: folder + "/base/exefs/main.npdm") { return folder + "/base" }
            return updates.last?.path ?? (folder + "/base")
        }
        /// What the script is given: the NUP file, else the folder.
        package var scriptInput: String { nup ?? folder }
        /// The title ID is known (a NUP whose package table names none leaves it to the script, from the code in the container).
        package var hasTitleID: Bool { titleID != 0 }
        /// The script packs the newest update (the version to pack defaults to the newest in the folder).
        package var newestUpdate: (version: Int, path: String)? { updates.last }

        package static func == (a: Self, b: Self) -> Bool {
            a.folder == b.folder && a.titleID == b.titleID && a.nup == b.nup
                && a.updates.map(\.version) == b.updates.map(\.version) && a.updates.map(\.path) == b.updates.map(\.path)
                && a.dlc.map(\.titleID) == b.dlc.map(\.titleID) && a.dlc.map(\.path) == b.dlc.map(\.path)
        }
    }

    /// Why a folder that is meant as a game folder cannot be built.
    package enum Problem: Error, Equatable {
        /// `base/exefs/main.npdm`, or a RomFS (`base/romfs`, or one in `updates/<version>/`), is not there. The piece is named.
        case missing(String)
        /// `exefs/` and `romfs/` sit in the folder itself: they belong in a folder named `base`.
        case noBaseFolder
        /// main.npdm is not an NPDM, or has no ACI0 section with a program ID.
        case unreadableNPDM
        /// The program ID is not a base game's (its low 12 bits are not zero).
        case notBaseTitle(UInt64)
        /// A game package sits beside the folders: the script would build the package and ignore the folders.
        case packageBeside(String)
        /// A folder under dlc/ whose name is not a title ID in hex.
        case dlcName(String)
        /// A folder under dlc/ whose title ID is not add-on content of this game.
        case notDLC(String, UInt64)
        /// A DLC folder without exactly one `<n>/romfs` (or `romfs`) folder: the name and how many there were.
        case dlcRomFS(String, Int)
        /// The file is not a NUP of format version 1: its name.
        case notNUP(String)
        /// The NUP is shorter or longer than its header says (copied or downloaded in part): its name.
        case nupPartial(String)
        /// More than one NUP in the folder: how many. The script takes one game per folder.
        case severalNUPs(Int)
    }

    /// Packages that make the script take the folder as a folder of packages.
    private static let packages: Set<String> = ["nsp", "xci", "nsz", "xcz"]

    /// Subfolders that belong inside a dump or build tree and are never outer wrapper folders.
    private static let skipWrapperDirs: Set<String> = [
        "base", "updates", "dlc", "romfs", "exefs", "extract", "tools",
        "venv", "archive", "harness", "runs", "shader", "node_modules", "xcode"
    ]

    /// The NUP files at the top of a folder (build_ipa_from_nsp.py `nup_file` looks there only), by name.
    package static func nupFiles(in folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter {
            !$0.hasPrefix("._") && ($0 as NSString).pathExtension.lowercased() == "nup" && isFile(folder + "/" + $0)
        }.sorted()
    }

    /// Whether `folder/updates/<version>/exefs/main.npdm` exists (an update-only dump without `base/`, pack_dump.py).
    private static func hasUpdateCode(_ folder: String) -> Bool {
        guard isDir(folder + "/updates") else { return false }
        return subdirs(in: folder + "/updates").contains {
            !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) && isFile(folder + "/updates/" + $0 + "/exefs/main.npdm")
        }
    }

    /// Whether `path` itself is an unpacked dump directory (`base/exefs/main.npdm`, `updates/<v>/exefs/main.npdm`, or
    /// misplaced `exefs/main.npdm` without `base/`), as opposed to a `.nup` file or a folder holding `.nup` files.
    package static func isDumpDirectory(_ path: String) -> Bool {
        let fm = FileManager.default
        if isFile(path + "/base/exefs/main.npdm") || hasUpdateCode(path) { return true }
        return isFile(path + "/exefs/main.npdm") && !fm.fileExists(atPath: path + "/base")
    }

    private static func hasNestedGameFoldersOrPackages(in folder: String) -> Bool {
        for sub in wrapperSubdirs(in: folder) {
            if isDumpDirectory(sub) || !nupFiles(in: sub).isEmpty || hasPackages(in: sub) { return true }
            for child in wrapperSubdirs(in: sub) {
                if isDumpDirectory(child) || !nupFiles(in: child).isEmpty || hasPackages(in: child) { return true }
            }
        }
        return false
    }

    /// Whether `path` itself (without unwrapping parent/child folders) is a game folder or a `.nup` file.
    /// A folder holding a `.nup` alongside nested game folders or packages is a collection root, not a single-game folder.
    package static func isDirectCandidate(_ path: String) -> Bool {
        if (path as NSString).pathExtension.lowercased() == "nup" && isFile(path) { return true }
        if isDumpDirectory(path) { return true }
        return !nupFiles(in: path).isEmpty && !hasNestedGameFoldersOrPackages(in: path)
    }

    /// Resolves a picked or dropped folder to the actual game folder when the user selected an outer wrapper folder
    /// (1–2 levels above a single game folder or `.nup`) or stepped inside `base/`, `updates/`, `dlc/`, `exefs/`, or `romfs/`.
    package static func resolve(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if (path as NSString).pathExtension.lowercased() == "nup" && isFile(path) { return path }
        if let ancestor = enclosingGameFolder(of: path) { return ancestor }
        if isDirectCandidate(path) { return path }
        if let inner = unwrappedGameFolder(in: path) { return inner }
        return path
    }

    private static func enclosingGameFolder(of path: String) -> String? {
        var cur = path
        var best: String? = nil
        for _ in 0..<4 {
            let name = (cur as NSString).lastPathComponent.lowercased()
            let isInnerName = ["base", "exefs", "romfs", "updates", "dlc"].contains(name)
                || (!name.isEmpty && name.allSatisfy(\.isASCIIDigit))
                || (!name.isEmpty && name.count <= 16 && name.allSatisfy(\.isHexDigit))
            guard isInnerName else { break }
            let parent = (cur as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != cur else { break }
            if isFile(parent + "/base/exefs/main.npdm") || hasUpdateCode(parent) {
                best = parent
            }
            cur = parent
        }
        if let best { return best }
        let leaf = (path as NSString).lastPathComponent.lowercased()
        if leaf == "exefs" || leaf == "romfs" {
            let parent = (path as NSString).deletingLastPathComponent
            if isFile(parent + "/exefs/main.npdm") && !FileManager.default.fileExists(atPath: parent + "/base") {
                return parent
            }
        }
        return nil
    }

    private static func hasPackages(in folder: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).contains {
            !$0.hasPrefix("._") && packages.contains(($0 as NSString).pathExtension.lowercased()) && isFile(folder + "/" + $0)
        }
    }

    private static func wrapperSubdirs(in folder: String) -> [String] {
        subdirs(in: folder).filter { name in
            let low = name.lowercased()
            return !skipWrapperDirs.contains(low) && !low.hasSuffix(".app") && !low.hasSuffix("_build") && !low.hasSuffix("_survey")
        }.map { folder + "/" + $0 }
    }

    private static func unwrappedGameFolder(in path: String) -> String? {
        guard isDir(path), !hasPackages(in: path), nupFiles(in: path).isEmpty else { return nil }
        let level1 = wrapperSubdirs(in: path)
        if level1.contains(where: { hasPackages(in: $0) }) { return nil }
        let direct1 = level1.filter { isDirectCandidate($0) }
        if direct1.count > 1 { return nil }
        var level2: [String] = []
        for sub in level1 where !isDirectCandidate(sub) {
            if !nupFiles(in: sub).isEmpty { return nil }
            let children = wrapperSubdirs(in: sub)
            if children.contains(where: { hasPackages(in: $0) || (!isDirectCandidate($0) && !nupFiles(in: $0).isEmpty) }) { return nil }
            level2.append(contentsOf: children)
        }
        let candidates = direct1 + level2.filter { isDirectCandidate($0) }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Whether the path is meant as a game folder or a NUP: a `.nup` file, a folder with a `.nup` at its top, a folder with
    /// `base/exefs/main.npdm` (or `updates/<version>/exefs/main.npdm`), `exefs/main.npdm` with no `base/`, or a 1–2 level
    /// wrapper folder / inner subfolder of one. Cheap: reads only directory entries and never walks `romfs/`.
    package static func isCandidate(_ path: String) -> Bool {
        isDirectCandidate(resolve(path))
    }

    /// What the folder holds, or the first reason it cannot be built, in the order the script finds them.
    package static func scan(_ rawFolder: String) -> Result<Contents, Problem> {
        let folder = resolve(rawFolder)
        if (folder as NSString).pathExtension.lowercased() == "nup" && isFile(folder) { return readNUP(folder) }
        let fm = FileManager.default
        let top = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted()
        if let pkg = top.first(where: { !$0.hasPrefix("._") && packages.contains(($0 as NSString).pathExtension.lowercased()) && isFile(folder + "/" + $0) }) {
            return .failure(.packageBeside(pkg))
        }
        // A NUP in the folder is what the script builds, before any folders beside it
        let nups = nupFiles(in: folder)
        if nups.count > 1 { return .failure(.severalNUPs(nups.count)) }
        if let nup = nups.first { return readNUP(folder + "/" + nup) }
        let versions = isDir(folder + "/updates") ? subdirs(in: folder + "/updates").filter { !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) } : []
        let updates = versions.compactMap { v in Int(v).map { (version: $0, path: folder + "/updates/" + v) } }.sorted { $0.version < $1.version }
        let baseNPDM = folder + "/base/exefs/main.npdm"
        let npdm: String
        if isFile(baseNPDM) {
            // A newer engine takes a folder whose base has no RomFS when an update has one (pack_dump.py at seedds/nxnative 641d148).
            guard isDir(folder + "/base/romfs") || updates.contains(where: { isDir($0.path + "/romfs") }) else {
                return .failure(.missing("base/romfs"))
            }
            npdm = baseNPDM
        } else {
            // pack_dump.py also builds a dump with no base/ when updates/<version>/ holds both exefs/main.npdm and romfs/.
            let codeUpdates = updates.filter { isFile($0.path + "/exefs/main.npdm") }
            if let newestCode = codeUpdates.last {
                guard let full = codeUpdates.last(where: { isDir($0.path + "/romfs") }) else {
                    return .failure(.missing("updates/\(newestCode.version)/romfs"))
                }
                npdm = full.path + "/exefs/main.npdm"
            } else {
                if isFile(folder + "/exefs/main.npdm") && !fm.fileExists(atPath: folder + "/base") { return .failure(.noBaseFolder) }
                return .failure(.missing("base/exefs/main.npdm"))
            }
        }
        guard let data = fm.contents(atPath: npdm), let app = programID(npdm: data) else { return .failure(.unreadableNPDM) }
        if app & 0xFFF != 0 { return .failure(.notBaseTitle(app)) }
        var dlc: [(titleID: UInt64, path: String)] = []
        for name in isDir(folder + "/dlc") ? subdirs(in: folder + "/dlc") : [] {
            let path = folder + "/dlc/" + name
            guard name.count <= 16, let tid = UInt64(name, radix: 16) else { return .failure(.dlcName(name)) }
            guard tid > app + 0x1000, tid - app - 0x1000 <= 2000 else { return .failure(.notDLC(name, tid)) }
            let numbered = subdirs(in: path).filter { isDir(path + "/" + $0 + "/romfs") }
            let count = numbered.isEmpty ? (isDir(path + "/romfs") ? 1 : 0) : numbered.count
            guard count == 1 else { return .failure(.dlcRomFS(name, count)) }
            dlc.append((titleID: tid, path: path))
        }
        return .success(Contents(folder: folder, titleID: app, updates: updates, dlc: dlc.sorted { $0.titleID < $1.titleID }))
    }

    /// A NUP's title ID, updates and DLC from its header and package table (SPEC v1, pack_nup.py `Nup` and `scan`). The title ID
    /// is the base package's, else an update's with the low 12 bits cleared (a base may be an empty placeholder, Pokémon Pokopia),
    /// else 0: the script then reads it from the code. Checks the magic, the version and the file size, not the SHA-256s (the
    /// script checks every file it reads).
    package static func readNUP(_ path: String) -> Result<Contents, Problem> {
        let name = (path as NSString).lastPathComponent
        guard let h = FileHandle(forReadingAtPath: path) else { return .failure(.notNUP(name)) }
        defer { try? h.close() }
        func u(_ b: [UInt8], _ o: Int, _ n: Int) -> UInt64 { (0..<n).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) } }
        let head = [UInt8](h.readData(ofLength: 0x80))
        guard head.count == 0x80, head[0..<3].elementsEqual("NUP".utf8), head[3] == 1 else { return .failure(.notNUP(name)) }
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 ?? 0
        if u(head, 0x40, 8) != size { return .failure(.nupPartial(name)) }
        let toc = u(head, 0x08, 8), count = Int(u(head, 0x48, 4))
        guard count > 0, count < 100_000, toc + 0x30 + UInt64(count) * 0x40 <= size else { return .failure(.notNUP(name)) }
        try? h.seek(toOffset: toc)
        let table = [UInt8](h.readData(ofLength: 0x30 + count * 0x40))
        guard table.count == 0x30 + count * 0x40, table[0..<4].elementsEqual([0x54, 0x4F, 0x43, 0x01]) else { return .failure(.notNUP(name)) }
        var base: UInt64 = 0, updates: [(version: Int, path: String)] = [], addons: [UInt64] = [], updateTitle: UInt64 = 0
        for i in 0..<count {
            let o = 0x30 + i * 0x40, tid = u(table, o, 8), version = Int(u(table, o + 20, 4))
            switch table[o + 24] {
            case 0: base = tid
            case 1: updates.append((version: version, path: path)); if updateTitle == 0 { updateTitle = tid & ~0xFFF }
            case 2: addons.append(tid)
            default: break
            }
        }
        let app = base != 0 && base & 0xFFF == 0 ? base : updateTitle
        return .success(Contents(folder: (path as NSString).deletingLastPathComponent, titleID: app,
                                 updates: updates.sorted { $0.version < $1.version }, dlc: addons.sorted().map { (titleID: $0, path: path) }, nup: path))
    }

    /// The ACI0 program ID of an NPDM (pack_dump.py `program_id`): the ACI0 offset and size at 0x70, the ID at ACI0 + 0x10.
    package static func programID(npdm d: Data) -> UInt64? {
        let b = [UInt8](d)
        func u32(_ o: Int) -> Int? { o + 4 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 : nil }
        guard b.count >= 0x78, b[0..<4].elementsEqual("META".utf8), let off = u32(0x70), let size = u32(0x74),
              size >= 0x18, off + 0x18 <= b.count, b[off..<off + 4].elementsEqual("ACI0".utf8) else { return nil }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[off + 0x10 + $1]) << (8 * UInt64($1)) }
    }

    /// Whether the engine builds game folders: it has `scripts/pack_dump.py` (seedds/nxnative 99947471, in the pin since v1.0.1).
    package static func engineBuildsFolders(_ engineRoot: String) -> Bool {
        !engineRoot.isEmpty && FileManager.default.fileExists(atPath: engineRoot + "/scripts/pack_dump.py")
    }

    /// Whether the engine builds NUP files: it has `scripts/pack_nup.py` (seedds/nxnative 423a674, in the pin from 641d148).
    package static func engineBuildsNUPs(_ engineRoot: String) -> Bool {
        !engineRoot.isEmpty && FileManager.default.fileExists(atPath: engineRoot + "/scripts/pack_nup.py")
    }

    /// Whether the engine has a profile for the game: `dm/games/<title ID>/game.tsv`. An engine that surveys a game without one
    /// (`engineSurveysWithoutProfile`) does not need it to build a NUP or a game folder.
    package static func engineHasProfile(_ titleID: UInt64, engineRoot: String) -> Bool {
        !engineRoot.isEmpty && FileManager.default.fileExists(atPath: engineRoot + "/dm/games/" + String(format: "%016llX", titleID) + "/game.tsv")
    }

    /// Whether the engine builds a NUP or a game folder of a game with no profile, from a provisional profile it makes by a survey:
    /// `scripts/build_ipa_from_nsp.py` has `survey_nup` and `survey_dump` (seedds/nxnative 056e41fe, PR #1295). An older engine packs
    /// a game folder only for a game with a profile.
    package static func engineSurveysWithoutProfile(_ engineRoot: String) -> Bool {
        guard !engineRoot.isEmpty, let data = FileManager.default.contents(atPath: engineRoot + "/scripts/build_ipa_from_nsp.py") else { return false }
        return data.range(of: Data("def survey_nup".utf8)) != nil
    }

    /// The `name` row of the game's profile: a game folder has no control data, so the script names the app after it too.
    package static func profileName(_ titleID: UInt64, engineRoot: String) -> String? {
        guard !engineRoot.isEmpty,
              let text = try? String(contentsOfFile: engineRoot + "/dm/games/" + String(format: "%016llX", titleID) + "/game.tsv", encoding: .utf8),
              let row = text.split(separator: "\n").first(where: { $0.hasPrefix("name\t") }) else { return nil }
        let name = row.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Whether the engine's profile is a Switch 2 game's. No profile key says so yet (#445 asks upstream for one): every Switch 2
    /// profile at seedds/nxnative 641d148 names it in its first line, "# Donkey Kong Bananza (Switch 2, update v458752)", and the
    /// launcher reads that. The `04` start of their title IDs is not used: it is an observation, not a rule.
    package static func profileIsSwitch2(_ titleID: String, engineRoot: String) -> Bool {
        guard !engineRoot.isEmpty, titleID.count == 16,
              let handle = FileHandle(forReadingAtPath: engineRoot + "/dm/games/" + titleID.uppercased() + "/game.tsv") else { return false }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 512), as: UTF8.self)
        guard let first = head.split(separator: "\n", maxSplits: 1).first, first.hasPrefix("#") else { return false }
        return first.contains("(Switch 2")
    }

    private static func isFile(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && !d.boolValue
    }

    private static func isDir(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    private static func subdirs(in path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") && isDir(path + "/" + $0) }.sorted()
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
    var isHexDigit: Bool { ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self) }
}
