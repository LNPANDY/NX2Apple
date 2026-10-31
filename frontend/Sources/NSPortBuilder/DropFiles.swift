import SwiftUI
import UniformTypeIdentifiers

// Game files dropped on the Builds page (issue #68): NSP, NSZ and XCI files, a folder, prod.keys, in any
// mix. They are sorted into the slots by the same classification as Choose game folder
// (BuildModel.classify), so a drop and a picked folder never disagree about what is the update.

extension BuildModel {
    /// One dropped folder is the same as choosing it; anything else (files, several folders, a mix) is added to
    /// what is already chosen: a slot the drop has something for is replaced, add-on content is added to.
    func take(dropped paths: [String]) {
        func isFolder(_ p: String) -> Bool {
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
        }
        if paths.count == 1, isFolder(paths[0]) { scan(folder: paths[0]); return }
        var found = Self.classify(paths.flatMap { isFolder($0) ? Self.inputFiles(in: $0) : [$0] })
        // update and add-on files of another game than the base (the dropped one, else the one already chosen)
        let baseName = (found.base ?? (basePath.isEmpty ? nil : basePath)).map { ($0 as NSString).lastPathComponent }
        var rejected: [InputKind: String] = [:]
        func fits(_ path: String, _ kind: InputKind) -> Bool {
            let name = (path as NSString).lastPathComponent
            guard let why = Self.rowMismatch(kind, name: name, base: baseName) else { return true }
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
    nonisolated static func merged(_ slots: [Slot], with found: FoundInputs) -> [Slot] {
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

/// The Builds page as a drop target: a highlight while files are dragged over it, the files to the model when dropped.
struct GameFilesDrop: ViewModifier {
    let enabled: Bool
    let label: String
    let onDrop: ([String]) -> Void
    @State private var targeted: Bool

    /// `targeted` starts the highlight on (visual QA renders it without a drag).
    init(enabled: Bool, label: String, targeted: Bool = false, onDrop: @escaping ([String]) -> Void) {
        self.enabled = enabled; self.label = label; self.onDrop = onDrop
        _targeted = State(initialValue: targeted)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted && enabled {
                    // the page dimmed under the label, so the label reads wherever it lands
                    ZStack {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(LauncherPalette.background.opacity(0.72))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(LauncherPalette.cream.opacity(0.8),
                                                                                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                        Label(label, systemImage: "square.and.arrow.down")
                            .font(.manrope(15, .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(LauncherPalette.cream, in: Capsule())
                    }
                    .padding(12)
                    .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard enabled else { return false }
                Self.paths(from: providers) { onDrop($0) }
                return true
            }
    }

    /// The file URLs of a drop, delivered on the main queue once all have loaded.
    static func paths(from providers: [NSItemProvider], then done: @escaping ([String]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var paths: [String] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                    lock.lock(); paths.append(url.path); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !paths.isEmpty { done(paths) } }
    }
}
