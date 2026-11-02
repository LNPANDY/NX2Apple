import Foundation
import NXCore

// Game files dropped on the Builds page (issue #68): NSP, NSZ and XCI files, a folder, prod.keys, in any
// mix. They are sorted into the slots by the same classification as Choose game folder
// (GameInputs.classify), so a drop and a picked folder never disagree about what is the update.

extension BuildStore {
    /// One dropped folder is the same as choosing it; anything else (files, several folders, a mix) is added to
    /// what is already chosen: a slot the drop has something for is replaced, add-on content is added to.
    package func take(dropped paths: [String]) {
        func isFolder(_ p: String) -> Bool {
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
        }
        if paths.count == 1, isFolder(paths[0]) { scan(folder: paths[0]); return }
        var found = GameInputs.classify(paths.flatMap { isFolder($0) ? GameInputs.inputFiles(in: $0) : [$0] })
        // update and add-on files of another game than the base (the dropped one, else the one already chosen)
        let baseName = (found.base ?? (basePath.isEmpty ? nil : basePath)).map { ($0 as NSString).lastPathComponent }
        var rejected: [InputKind: String] = [:]
        func fits(_ path: String, _ kind: InputKind) -> Bool {
            let name = (path as NSString).lastPathComponent
            guard let why = GameInputs.rowMismatch(kind, name: name, base: baseName) else { return true }
            if rejected[kind] == nil { rejected[kind] = rowProblemText(why, name: name) }
            return false
        }
        if let u = found.update, !fits(u, .update) { found.update = nil }
        found.dlc = found.dlc.filter { fits($0, .dlc) }
        slots = Self.merged(slots, with: found)
        for (kind, text) in rejected { updateSlot(kind == .update ? "update" : "dlc") { $0.problem = text } }
        if found.update != nil { updateSlot("update") { $0.note = updateNote(found) } }
        if let base = found.base { gameDir = (base as NSString).deletingLastPathComponent }
    }

    /// The slots after a drop of `found`. Nothing usable in it leaves the slots as they were, but says so on an empty base row.
    package nonisolated static func merged(_ slots: [Slot], with found: GameInputs.Found) -> [Slot] {
        slots.map { s in
            var s = s
            switch s.id {
            case "base":
                if let base = found.base { s.paths = [base]; s.problem = "" }
                else if !found.anyGame && found.keys == nil && s.paths.isEmpty { s.problem = "data.noNsp" }
            case "update": if let update = found.update { s.paths = [update]; s.problem = "" }
            case "dlc": if !found.dlc.isEmpty { s.paths = Array(Set(s.paths + found.dlc)).sorted(); s.problem = "" }
            case "keys": if let keys = found.keys { s.paths = [keys]; s.problem = "" }
            default: break
            }
            return s
        }
    }
}
