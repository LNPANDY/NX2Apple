import SwiftUI
import AppKit
import NXCore
import NXLauncher
import NXModel

/// The Builds page's first card: the game folder, the four input rows (base game, update, add-on content, prod.keys) and where the
/// build goes. Observes the build store. It stays in the app target because it runs `KeyCheck` (KeyCheck.swift, which needs
/// CommonCrypto) on the chosen files.
struct FilesCard: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer
    @Binding var extrasOpen: Bool   // the optional input rows, kept by the page so they stay as they were when it is left and back
    @State private var keyCheck: KeyCheck.Outcome?   // prod.keys against the chosen files (KeyCheck.swift)

    var body: some View {
        // The report's own mistake, and a reasonable one: the output folder silently decides where
        // the build cache lives, so changing it threw away a finished build. Say it under Save to, all the time.
        CardGroup(loc.t("section.files"), footnote: loc.t("msg.workdirHint")) {
            Button(action: pickFolder) {
                CardRow(loc.t(build.gameDir.isEmpty ? "build.folderCTA" : "build.folderSelected"),
                    detail: build.gameDir.isEmpty ? loc.t("build.folderNote") : build.shortPath(build.gameDir), help: build.gameDir) {
                    Text(loc.t(build.gameDir.isEmpty ? "data.choose" : "data.change"))
                        .font(.manrope(13, .semibold)).foregroundStyle(.black)
                        .launcherRowControlFrame()
                        .background(LauncherPalette.cream, in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(build.slots.filter { !$0.optional }, id: \.id) { s in
                CardDivider(); slotRow(s)
                if s.id == "keys", build.gameFolder == nil, let keyCheck { KeyCheckLine(outcome: keyCheck, t: loc.t) }
            }
            CardDivider()
            CardDisclosure(loc.t("build.options"), isOpen: extrasOpen) { extrasOpen.toggle() }
            if extrasOpen {
                ForEach(build.slots.filter(\.optional), id: \.id) { s in CardDivider(); slotRow(s) }
            }
            CardDivider()
            CardRow(loc.t("build.saveTo"), detail: build.outDir.isEmpty ? loc.t("build.saveDefault") : build.shortPath(build.outDir), help: build.outDir) {
                Button(loc.t("data.change")) { build.chooseBuildFolder() }
            }
        }
        .task(id: KeyCheck.Inputs(keys: build.keysPath, files: [build.basePath, build.updatePath] + build.dlcPaths)) {
            keyCheck = await KeyCheck.runDetached(KeyCheck.Inputs(keys: build.keysPath, files: [build.basePath, build.updatePath] + build.dlcPaths))
        }
        .disabled(build.running)
    }

    private func slotRow(_ s: Slot) -> some View {
        // A game folder (a Switch 2 game) fills the rows from its folders: they say what it holds, the keys row that none are
        // needed, and only the base row can be cleared (which clears the folder). An empty prod.keys row says where the file comes from.
        let folderText = build.gameFolderRowText(s.id)
        let ready = folderText != nil ? (s.id == "keys" || s.ok) : s.ok
        return CardRow(loc.t(s.title), detail: folderText ?? (s.id == "keys" && s.paths.isEmpty ? loc.t("build.keyHint") : s.summary(loc.t)),
            dot: ready ? LauncherPalette.ready : LauncherPalette.unbuilt, help: s.paths.joined(separator: "\n")) {
            if !s.paths.isEmpty && (folderText == nil || s.id == "base") {
                Button(loc.t("data.clear")) { build.clear(s.id) }.buttonStyle(.plain)
                    .font(.manrope(13)).foregroundStyle(.secondary)
            }
            if folderText == nil {
                Button(s.paths.isEmpty ? loc.t("data.choose") : loc.t("data.change")) { build.pickFiles(kind: s.kind) }
            }
        }
    }

    private func pickFolder() {
        let d = NSOpenPanel()
        d.canChooseDirectories = true; d.canChooseFiles = false
        if d.runModal() == .OK, let u = d.url { build.scan(folder: u.path) }
    }
}
