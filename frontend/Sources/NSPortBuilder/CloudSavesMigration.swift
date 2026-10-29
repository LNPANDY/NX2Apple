import Foundation

/// Keeps a player's cloud saves where they were when the engine's own cloud saves replaced the fork's (seedds/nxnative#617).
///
/// How a player's choice is stored, on each side:
/// - The Mac app's settings window keeps an explicit folder path (`cloudSaves.folder` in the app's preferences) and
///   dm/mac/launcher.c passes it on as `DM_SAVE_SYNC`. The iPhone app keeps a security-scoped bookmark (`cloudSavesBookmark`) and
///   passes the folder it resolves to. Both are paths, so the engine's change does not touch them.
/// - Only the keyword `DM_SAVE_SYNC=icloud` resolves a folder by itself, on the Mac, and a player can only have it from a line in
///   the app's `env.txt` (the launcher never writes it). It meant iCloud Drive › NX2Apple Saves and now means
///   iCloud Drive › nxnative Saves, so a Mac on the keyword would move to a folder the iPhone app (a bookmark to NX2Apple Saves)
///   does not use, and the two would stop syncing without a message.
///
/// So for a game whose `env.txt` has `DM_SAVE_SYNC=icloud` and whose iCloud Drive has an NX2Apple Saves folder, the line gets that
/// folder's path instead of the keyword. Nothing is copied, moved or deleted: the folder the iPhone app uses stays the folder the
/// Mac app uses, and the engine's file format (`<title ID>/save.dmsync`) is the same on both sides of the change. A Mac without an
/// NX2Apple Saves folder never synced through the keyword before, and gets the engine's new folder, nxnative Saves.
enum CloudSavesMigration {
    static let oldFolder = "NX2Apple Saves"
    static let key = "DM_SAVE_SYNC"

    /// The comment written above the line: `#` lines are ignored by dm/mac/launcher.c's env.txt reader.
    static let comment = "# NX2Apple: `icloud` used to be the folder NX2Apple Saves in iCloud Drive and is now nxnative Saves. The path keeps this game's Mac and iPhone apps in the folder they already share."

    static var drive: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    }

    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("nxnative")
    }

    /// `text` with the effective `DM_SAVE_SYNC=icloud` line given `folder`, or nil when there is nothing to change. Read the way
    /// dm/mac/launcher.c reads an env.txt: `KEY=VALUE` lines, `#` starts a comment, spaces around the key are dropped, and the
    /// first line for a key wins (a later one is ignored by the launcher, so it is left alone here too).
    static func pinned(_ text: String, to folder: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let line = raw.drop(while: { $0 == " " || $0 == "\t" })
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            guard line[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            var value = String(line[line.index(after: eq)...])
            var ending = ""
            while let last = value.last, last == "\r" || last == " " || last == "\t" { ending = String(last) + ending; value.removeLast() }
            guard value == "icloud" else { return nil }   // the first DM_SAVE_SYNC line decides
            lines[i] = "\(key)=\(folder)\(ending)"
            lines.insert(comment + (ending.contains("\r") ? "\r" : ""), at: i)
            return lines.joined(separator: "\n")
        }
        return nil
    }

    /// Every game's `env.txt` under `support` (`<title ID>/env.txt`). Returns the title IDs it changed. A file it cannot read or
    /// write is left as it is. `drive` is iCloud Drive's folder.
    @discardableResult
    static func run(support: URL = CloudSavesMigration.support, drive: URL = CloudSavesMigration.drive,
                    log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let old = drive.appendingPathComponent(oldFolder)
        guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue,
              let games = try? fm.contentsOfDirectory(atPath: support.path) else { return [] }
        var changed: [String] = []
        for game in games.sorted() {
            let file = support.appendingPathComponent(game).appendingPathComponent("env.txt")
            guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8),
                  let text2 = pinned(text, to: old.path) else { continue }
            do { try Data(text2.utf8).write(to: file, options: .atomic) } catch {
                log("cloud saves: \(file.path) could not be updated: \(error.localizedDescription)"); continue
            }
            log("cloud saves: \(game) keeps syncing through \(old.path) (its env.txt said DM_SAVE_SYNC=icloud)")
            changed.append(game)
        }
        return changed
    }
}
