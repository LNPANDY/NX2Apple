import Foundation

/// One of the four things the user points at.
package enum InputKind { case base, update, dlc, keys }

/// Which files make a game: classifying a folder or a set of dropped files into the four slots, and whether a file fits the row
/// it was put in. Functions of the file names, apart from `inputFiles` and the size check in `classify`, which read the disk.
package enum GameInputs {
    /// What a set of files holds for the four slots (`classify`).
    package struct Found: Equatable {
        package var base: String?
        package var update: String?
        package var dlc: [String] = []
        package var keys: String?
        /// How many updates the files held and the version of the one taken (the newest), for the update row's note.
        package var updateCount = 0
        package var updateVersion = 0
        package init(base: String? = nil, update: String? = nil, dlc: [String] = [], keys: String? = nil,
                     updateCount: Int = 0, updateVersion: Int = 0) {
            self.base = base; self.update = update; self.dlc = dlc; self.keys = keys
            self.updateCount = updateCount; self.updateVersion = updateVersion
        }
        package var anyGame: Bool { base != nil || update != nil || !dlc.isEmpty }
        package static func == (a: Self, b: Self) -> Bool {
            a.base == b.base && a.update == b.update && a.dlc == b.dlc && a.keys == b.keys
        }
    }

    /// The files under a folder, pruning the build folders this pipeline itself writes so a rescan is not slow.
    package static func inputFiles(in folder: String) -> [String] {
        let fm = FileManager.default
        var files: [String] = []
        var seen = 0
        let enumerator = fm.enumerator(atPath: folder)
        while let rel = enumerator?.nextObject() as? String {
            if seen > 8000 { break }   // a pathological tree should not hang the picker
            seen += 1
            let name = (rel as NSString).lastPathComponent
            if name.hasPrefix(".") { continue }
            let path = folder + "/" + rel
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            let low = name.lowercased()
            if isDir.boolValue {
                // the pipeline's own output, and anything hidden: never walk back into those
                if low == "archive" || low == "xcode" || low.hasSuffix("_build") || low.hasSuffix("_survey") { enumerator?.skipDescendants() }
                continue
            }
            files.append(path)
        }
        return files
    }

    /// NSP/XCI (and their compressed NSZ/XCZ) sorted by the title ID in the file name, plus the first prod.keys.
    /// Shared by Choose game folder and files dropped on the Builds page.
    package static func classify(_ files: [String]) -> Found {
        var base: [(String, Int)] = [], update: [(String, Int, Int)] = [], dlc: [String] = []
        var found = Found()
        for path in files {
            let name = (path as NSString).lastPathComponent
            let low = name.lowercased()
            if name.hasPrefix("._") { continue }   // an AppleDouble file macOS writes beside every real file on exFAT/FAT drives: its name carries the same [title ID], so counting it made one update read as two
            if found.keys == nil && (low == "prod.keys" || low.hasSuffix(".keys")) { found.keys = path; continue }
            guard ["nsp", "xci", "nsz", "xcz"].contains((low as NSString).pathExtension) else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
            guard size > 0 else { continue }   // an incomplete download leaves 0-byte files behind
            guard let tid = TitleID.parse(name) else { continue }   // a name without a title ID cannot be classified
            switch tid & 0xFFF {
            case 0: base.append((path, size))
            case 0x800: update.append((path, size, TitleID.updateVersion(name)))
            default: dlc.append(path)
            }
        }
        // several bases happen when a folder holds a repack beside the original: the largest wins
        found.base = base.sorted { $0.1 > $1.1 }.first?.0
        // a folder that holds other games too: only the update and add-on content of the chosen base game count
        if let app = found.base.flatMap({ TitleID.parse(($0 as NSString).lastPathComponent) }).map({ $0 & ~0xFFF }) {
            update = update.filter { TitleID.parse(($0.0 as NSString).lastPathComponent).map(TitleID.owner) == app }
            dlc = dlc.filter { TitleID.parse(($0 as NSString).lastPathComponent).map(TitleID.owner) == app }
        }
        // several updates: the newest version is the one a profile would pack (an update contains the earlier ones)
        let newest = update.sorted { $0.2 > $1.2 }.first
        found.update = newest?.0
        found.updateCount = update.count
        found.updateVersion = newest?.2 ?? 0
        found.dlc = dlc.sorted()
        return found
    }

    /// Why a file does not fit the row it was put in, judged by the title ID in its name.
    package enum RowMismatch: Equatable { case notBase(UInt64), notUpdate(UInt64), notDLC(UInt64), otherGame }

    /// A file whose name carries no title ID fits every row (the build script reads the ID from the package).
    /// `base` is the selected base game's file name, when it carries one.
    package static func rowMismatch(_ kind: InputKind, name: String, base: String?) -> RowMismatch? {
        guard kind != .keys, let tid = TitleID.parse(name) else { return nil }
        let low = tid & 0xFFF
        switch kind {
        case .base: if low != 0 { return .notBase(tid) }
        case .update: if low != 0x800 { return .notUpdate(tid) }
        case .dlc: if low == 0 || low == 0x800 { return .notDLC(tid) }
        case .keys: break
        }
        if kind != .base, let b = base.flatMap(TitleID.parse), TitleID.owner(tid) != b & ~0xFFF { return .otherGame }
        return nil
    }


    /// What the Choose… dialog of a row offers. The compressed NSZ / XCZ are accepted by the build
    /// script like their plain forms. DLC ships as NSP (or NSZ), never as a cartridge image.
    package static func allowedFileTypes(for kind: InputKind) -> [String] {
        switch kind {
        case .base, .update: return ["nsp", "xci", "nsz", "xcz"]
        case .dlc: return ["nsp", "nsz"]
        case .keys: return ["keys"]
        }
    }
}
