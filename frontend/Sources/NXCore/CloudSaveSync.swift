import Foundation

/// A Mac game's cloud saves as the engine reads them (#499), and what its last session's log says about the sync.
///
/// Where the folder comes from, in dm/mac/launcher.c's order (docs/frontends.md, "The cloud saves folder"): the first
/// `DM_SAVE_SYNC` line of `~/Library/Application Support/nxnative/<title ID>/env.txt`, then of the app's own
/// `Contents/Resources/dm/env.txt`, then `cloudSaves.folder` in the app's preferences domain. `icloud` is iCloud Drive ›
/// nxnative Saves, `0` or an empty value is off. The save is `<folder>/<TITLE ID>/save.dmsync`, or `<folder>/save.dmsync` for a
/// folder that is already the game's own (dm/host/save_sync.c, cloud_file).
package enum CloudSaveSync {
    package static let key = "DM_SAVE_SYNC"
    /// The key in the app's preferences domain (dm/mac/launcher.c, cloud_saves_folder).
    package static let preferenceKey = "cloudSaves.folder"
    package static let icloudFolder = "nxnative Saves"

    /// Where the folder that counts was set.
    package enum Source: Equatable { case playerEnv, appEnv, preference, none }

    /// The folder setting that counts, as the engine resolves it.
    package struct Setting: Equatable {
        package var source: Source
        /// The value as written (`icloud`, a path, `0`), nil when nothing sets it.
        package var value: String?
        /// The folder it means, nil when cloud saves are off.
        package var folder: String?
        package init(source: Source, value: String?, folder: String?) { self.source = source; self.value = value; self.folder = folder }
        package var isOn: Bool { folder != nil }
    }

    /// The first `DM_SAVE_SYNC` value of an env.txt, read as launcher.c's env_file does: `KEY=VALUE` lines, `#` starts a comment,
    /// spaces around the key and at the end of the value are dropped, the first line for a key wins.
    package static func envValue(_ text: String) -> String? { envLine(text)?.value }

    private static func envLine(_ text: String) -> (index: Int, value: String, ending: String)? {
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.drop(while: { $0 == " " || $0 == "\t" })
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "="), eq != line.startIndex,
                  line[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            var value = String(line[line.index(after: eq)...])
            var ending = ""
            while let last = value.last, last == "\r" || last == " " || last == "\t" { ending = String(last) + ending; value.removeLast() }
            return (i, value, ending)
        }
        return nil
    }

    /// The folder a value means: nil for off (`0`, empty), iCloud Drive › nxnative Saves for `icloud`, else the path as written
    /// without a trailing slash.
    package static func folder(for value: String?, home: String = NSHomeDirectory()) -> String? {
        guard let value, !value.isEmpty, value != "0" else { return nil }
        if value == "icloud" { return home + "/Library/Mobile Documents/com~apple~CloudDocs/" + icloudFolder }
        var path = (value as NSString).expandingTildeInPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The setting that counts, from the two env.txt texts (nil when the file is missing) and the preference.
    package static func resolve(playerEnv: String?, appEnv: String?, preference: String?, home: String = NSHomeDirectory()) -> Setting {
        if let v = playerEnv.flatMap(envValue) { return Setting(source: .playerEnv, value: v, folder: folder(for: v, home: home)) }
        if let v = appEnv.flatMap(envValue) { return Setting(source: .appEnv, value: v, folder: folder(for: v, home: home)) }
        if let v = preference, !v.isEmpty { return Setting(source: .preference, value: v, folder: folder(for: v, home: home)) }
        return Setting(source: .none, value: nil, folder: nil)
    }

    /// `<folder>/<TITLE ID>/save.dmsync`, or `<folder>/save.dmsync` when the folder is the game's own.
    package static func saveFile(folder: String, titleID: String) -> String {
        let id = titleID.uppercased()
        return (folder as NSString).lastPathComponent.uppercased() == id ? folder + "/save.dmsync" : folder + "/" + id + "/save.dmsync"
    }

    /// The player's env.txt with its first `DM_SAVE_SYNC` line set to `value`, or the line added at the end when it has none.
    /// Comments and every other line stay as they are.
    package static func settingEnv(_ text: String?, to value: String) -> String {
        let text = text ?? ""
        var lines = text.components(separatedBy: "\n")
        if let line = envLine(text) {
            lines[line.index] = "\(key)=\(value)\(line.ending)"
            return lines.joined(separator: "\n")
        }
        let body = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        return body + "\(key)=\(value)\n"
    }

    /// What the folder holds for the game: a notice before the first play, so a wrong folder shows (#490).
    package enum FolderCheck: Equatable { case missing, noSave, hasSave(Date?) }

    package static func check(folder: String, titleID: String, fm: FileManager = .default) -> FolderCheck {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { return .missing }
        let file = saveFile(folder: folder, titleID: titleID)
        guard fm.fileExists(atPath: file) else { return .noSave }
        return .hasSave((try? fm.attributesOfItem(atPath: file))?[.modificationDate] as? Date)
    }

    /// What the last session's log says about the sync: the last result of the `save sync:` lines (dm/host/save_sync.c).
    package enum LogState: Equatable {
        case off(String)              // "off: <why>"
        case inStep                   // the save here and the cloud's are the same
        case broughtIn(String)        // a newer save came from the cloud, from the device named
        case waitingToSend            // this device's save is newer and goes to the cloud, and no send followed in this log
        case sent(String)             // "sent: <n> files, saved <time>, to <file>": the part before ", to"
        case offline                  // the cloud's save could not be read in time: sent later
        case waitingForChoice         // both changed: neither replaced the other, the launcher asks at the next start (#957)
        case nothingYet               // no save here or in the cloud yet
        case failed(String)           // a [RED] line, its text
    }

    /// The state the log ends with, nil when the session did not sync (cloud saves off, or the game never mounted its save).
    package static func state(fromLog text: String) -> LogState? {
        var state: LogState?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard let at = line.range(of: "save sync: ") else { continue }
            let message = String(line[at.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.contains("[RED] save sync:") { state = .failed(message); continue }
            if message.hasPrefix("off: ") { state = .off(String(message.dropFirst(5))) }
            else if message.hasPrefix("sent: ") {
                let detail = message.dropFirst(6)
                state = .sent(String(detail.range(of: ", to ").map { detail[..<$0.lowerBound] } ?? detail))
            }
            else if message == "in step with the cloud" { state = .inStep }
            else if message.hasPrefix("brought in the cloud's save") {
                let from = message.range(of: "(from ").flatMap { r in message[r.upperBound...].range(of: ", saved ").map { String(message[r.upperBound..<$0.lowerBound]) } }
                state = .broughtIn(from ?? "")
            }
            else if message.hasPrefix("this device's save") && message.hasSuffix("it goes to the cloud") { state = .waitingToSend }
            else if message.hasSuffix("cannot be read now; sending later") || message.hasPrefix("the cloud's save did not come within") { state = .offline }
            else if message == "no save here or in the cloud yet" { state = .nothingYet }
            else if message.hasPrefix("both changed: ") || (message.hasPrefix("not sent: ") && message.hasSuffix("until the player chooses at the next start")) { state = .waitingForChoice }
        }
        return state
    }
}
