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

        package var titleIDHex: String { String(format: "%016llX", titleID) }
        package var basePath: String { folder + "/base" }
        /// The script packs the newest update (the version to pack defaults to the newest in the folder).
        package var newestUpdate: (version: Int, path: String)? { updates.last }

        package static func == (a: Self, b: Self) -> Bool {
            a.folder == b.folder && a.titleID == b.titleID
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
    }

    /// Packages that make the script take the folder as a folder of packages. A `.nup` (a newer engine reads one) is taken first too.
    private static let packages: Set<String> = ["nsp", "xci", "nsz", "xcz", "nup"]

    /// Whether the folder is meant as a game folder: it has `base/exefs/main.npdm`, or `exefs/main.npdm` with no `base/` (the
    /// files one level too high). Cheap: the folder picker asks this before it walks a folder that may hold 80,000 files.
    package static func isCandidate(_ folder: String) -> Bool {
        let fm = FileManager.default
        if isFile(folder + "/base/exefs/main.npdm") { return true }
        return isFile(folder + "/exefs/main.npdm") && !fm.fileExists(atPath: folder + "/base")
    }

    /// What the folder holds, or the first reason it cannot be built, in the order the script finds them.
    package static func scan(_ folder: String) -> Result<Contents, Problem> {
        let fm = FileManager.default
        func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue }
        func dirs(_ p: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: p)) ?? []).filter { !$0.hasPrefix(".") && isDir(p + "/" + $0) }.sorted()
        }
        let top = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted()
        if let pkg = top.first(where: { !$0.hasPrefix("._") && packages.contains(($0 as NSString).pathExtension.lowercased()) && isFile(folder + "/" + $0) }) {
            return .failure(.packageBeside(pkg))
        }
        let npdm = folder + "/base/exefs/main.npdm"
        if !isFile(npdm) {
            if isFile(folder + "/exefs/main.npdm") && !fm.fileExists(atPath: folder + "/base") { return .failure(.noBaseFolder) }
            return .failure(.missing("base/exefs/main.npdm"))
        }
        let versions = isDir(folder + "/updates") ? dirs(folder + "/updates").filter { !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) } : []
        // A newer engine takes a folder whose base has no RomFS when an update has one (pack_dump.py at seedds/nxnative 641d148).
        guard isDir(folder + "/base/romfs") || versions.contains(where: { isDir(folder + "/updates/" + $0 + "/romfs") }) else {
            return .failure(.missing("base/romfs"))
        }
        guard let data = fm.contents(atPath: npdm), let app = programID(npdm: data) else { return .failure(.unreadableNPDM) }
        if app & 0xFFF != 0 { return .failure(.notBaseTitle(app)) }
        let updates = versions.compactMap { v in Int(v).map { (version: $0, path: folder + "/updates/" + v) } }.sorted { $0.version < $1.version }
        var dlc: [(titleID: UInt64, path: String)] = []
        for name in isDir(folder + "/dlc") ? dirs(folder + "/dlc") : [] {
            let path = folder + "/dlc/" + name
            guard name.count <= 16, let tid = UInt64(name, radix: 16) else { return .failure(.dlcName(name)) }
            guard tid > app + 0x1000, tid - app - 0x1000 <= 2000 else { return .failure(.notDLC(name, tid)) }
            let numbered = dirs(path).filter { isDir(path + "/" + $0 + "/romfs") }
            let count = numbered.isEmpty ? (isDir(path + "/romfs") ? 1 : 0) : numbered.count
            guard count == 1 else { return .failure(.dlcRomFS(name, count)) }
            dlc.append((titleID: tid, path: path))
        }
        return .success(Contents(folder: folder, titleID: app, updates: updates, dlc: dlc.sorted { $0.titleID < $1.titleID }))
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

    /// Whether the engine has a profile for the game. The script packs a game folder only for a game with a profile: the survey
    /// that makes a provisional one reads NSPs.
    package static func engineHasProfile(_ titleID: UInt64, engineRoot: String) -> Bool {
        !engineRoot.isEmpty && FileManager.default.fileExists(atPath: engineRoot + "/dm/games/" + String(format: "%016llX", titleID) + "/game.tsv")
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
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
