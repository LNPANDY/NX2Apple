import Foundation
import Combine
import NXCore

// The build inputs: the four rows (base game, update, add-on content, keys) and what fills them (LNPANDY/NX2Apple#387).

extension BuildStore {
    /// Fill every slot from a folder: NSP/XCI classified by title ID (…000 base,
    /// …800 update, anything above base+0x1000 add-on content), plus prod.keys.
    /// Subfolders are scanned too — a dump usually arrives as 本体/ 更新/ DLC/ folders —
    /// pruning the build folders this pipeline itself writes so a rescan is not slow.
    package func scan(folder: String) {
        gameDir = folder
        let found = GameInputs.classify(GameInputs.inputFiles(in: folder))
        updateSlot("base") { $0.paths = found.base.map { [$0] } ?? []; $0.problem = found.base == nil ? "data.noBase" : "" }
        updateSlot("update") { $0.paths = found.update.map { [$0] } ?? []; $0.problem = ""; $0.note = updateNote(found) }
        updateSlot("dlc") { $0.paths = found.dlc; $0.problem = "" }
        updateSlot("keys") { $0.paths = found.keys.map { [$0] } ?? []; $0.problem = "" }
        if !found.anyGame {
            updateSlot("base") { $0.problem = "data.noNsp" }
        }
    }

    /// The update row's note when the files held several updates: which one was taken and why one is enough.
    package func updateNote(_ found: GameInputs.Found) -> String {
        guard found.update != nil, found.updateCount > 1 else { return "" }
        return String(format: t("data.updateNewest"), found.updateVersion, found.updateCount)
    }

    /// The row's message for a rejected file, as a finished sentence in the current language.
    package func rowProblemText(_ mismatch: GameInputs.RowMismatch, name: String) -> String {
        func hex(_ tid: UInt64) -> String { String(format: "%016llX", tid) }
        switch mismatch {
        case .notBase(let tid): return String(format: t("data.rowNotBase"), name, hex(tid))
        case .notUpdate(let tid): return String(format: t("data.rowNotUpdate"), name, hex(tid))
        case .notDLC(let tid): return String(format: t("data.rowNotDLC"), name, hex(tid))
        case .otherGame: return String(format: t("data.rowOtherGame"), name)
        }
    }

    /// Asks the app's file picker for files for one row and takes them. The panel is AppKit's: it reaches the store as `pickFiles`.
    package func pickFiles(kind: InputKind) {
        var message: String?, prompt: String?
        switch kind {
        case .dlc:
            message = t("data.dlcPanelMessage")
            prompt = t("data.dlcPanelPrompt")
        case .update: message = t("data.updatePanelMessage")
        default: break
        }
        let picked = choosePaths(FilePick(allowsMultiple: kind == .dlc, fileTypes: GameInputs.allowedFileTypes(for: kind), message: message, prompt: prompt))
        guard !picked.isEmpty else { return }
        take(picked: picked, kind: kind)
    }

    /// Files chosen for one row: those that fit it are taken, the first that does not is named on the row
    /// and left out (it is not moved to another row: the row the user chose stays as they set it).
    package func take(picked: [String], kind: InputKind) {
        let id = kind == .base ? "base" : kind == .update ? "update" : kind == .dlc ? "dlc" : "keys"
        let baseName = kind == .base ? nil : (basePath as NSString).lastPathComponent
        var fitting: [String] = [], problem = ""
        for path in picked {
            let name = (path as NSString).lastPathComponent
            if let why = GameInputs.rowMismatch(kind, name: name, base: baseName) {
                if problem.isEmpty { problem = rowProblemText(why, name: name) }
            } else { fitting.append(path) }
        }
        updateSlot(id) { s in
            if !fitting.isEmpty {
                s.paths = kind == .dlc ? Array(Set(s.paths + fitting)).sorted() : Array(fitting.prefix(1))
                s.note = ""
            }
            s.problem = problem
        }
        if kind == .base, let first = fitting.first { gameDir = (first as NSString).deletingLastPathComponent }
    }

    package func clear(_ id: String) { updateSlot(id) { $0.paths = []; $0.problem = "" } }
}
