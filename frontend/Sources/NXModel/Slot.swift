import Foundation
import NXCore

/// One row of the build's inputs: the base game, the update, the add-on content or the keys.
package struct Slot: Identifiable {
    package let id: String
    package let kind: InputKind
    package let title: String
    package let optional: Bool
    package var paths: [String] = []
    package var problem: String = ""
    /// A finished sentence shown beside the file name (the update row: which of several updates was taken).
    package var note: String = ""
    package var ok: Bool { paths.contains { FileManager.default.fileExists(atPath: $0) } }
    /// `problem` holds either a finished message or a key + arguments, resolved by the model
    /// (it needs the current language, which a struct cannot read).
    package var problemText: String { problem }

    package init(id: String, kind: InputKind, title: String, optional: Bool, paths: [String] = [], problem: String = "", note: String = "") {
        self.id = id; self.kind = kind; self.title = title; self.optional = optional
        self.paths = paths; self.problem = problem; self.note = note
    }

    package func summary(_ t: (String) -> String) -> String {
        if !problem.isEmpty { return problem.hasPrefix("data.") ? t(problem) : problem }
        if paths.isEmpty {
            if kind == .dlc { return t("data.notSelectedDlc") }
            return optional ? t("data.notSelectedOptional") : t("data.notSelected")
        }
        if paths.count == 1 {
            let name = (paths[0] as NSString).lastPathComponent
            return note.isEmpty ? name : name + "\n" + note
        }
        return String(format: t("data.files"), paths.count) + paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    }
}
