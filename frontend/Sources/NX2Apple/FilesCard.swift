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
    @State private var keyCheck: KeyCheck.DetailedOutcome?   // prod.keys against the chosen files (KeyCheck.swift)

    private var currentKeyInputs: KeyCheck.Inputs {
        KeyCheck.Inputs(keys: build.keysPath, files: [build.basePath, build.updatePath] + build.dlcPaths)
    }

    var body: some View {
        // The report's own mistake, and a reasonable one: the output folder silently decides where
        // the build cache lives, so changing it threw away a finished build. Say it under Save to, all the time.
        CardGroup(loc.t("section.files"), footnote: loc.t("msg.workdirHint")) {
            Button(action: pickFolder) {
                CardRow(loc.t(build.gameDir.isEmpty ? "build.folderCTA" : "build.folderSelected"),
                    detail: build.gameDir.isEmpty ? loc.t("build.folderNote") : build.shortPath(build.gameDir), help: build.gameDir) {
                    Text(loc.t(build.gameDir.isEmpty ? "data.choose" : "data.change"))
                        .font(.manrope(13, .semibold)).foregroundStyle(LauncherPalette.onCream)
                        .launcherRowControlFrame()
                        .background(LauncherPalette.cream, in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(build.slots.filter { !$0.optional }, id: \.id) { s in
                CardDivider()
                slotRow(s)
                if s.id == "keys", build.gameFolder == nil, let keyCheck {
                    KeyCheckLine(outcome: keyCheck.outcome, detailed: keyCheck, t: loc.t)
                }
            }
            CardDivider()
            CardDisclosure(loc.t("build.options"), isOpen: extrasOpen) { extrasOpen.toggle() }
            if extrasOpen {
                ForEach(build.slots.filter(\.optional), id: \.id) { s in
                    CardDivider()
                    slotRow(s)
                }
            }
            CardDivider()
            CardRow(loc.t("build.saveTo"), detail: build.outDir.isEmpty ? loc.t("build.saveDefault") : build.shortPath(build.outDir), help: build.outDir) {
                Button(loc.t("data.change")) { build.chooseBuildFolder() }
            }
        }
        .task(id: currentKeyInputs) {
            let inputs = currentKeyInputs
            let generation = build.keyCheckGeneration
            guard build.gameFolder == nil, !inputs.keys.isEmpty, inputs.files.first.map({ !$0.isEmpty }) == true else {
                keyCheck = nil
                build.keyProblem = nil
                return
            }
            let checked = await KeyCheck.runDetailedDetached(inputs)
            guard !Task.isCancelled,
                  build.keyCheckGeneration == generation,
                  build.gameFolder == nil,
                  currentKeyInputs == inputs else { return }
            keyCheck = checked
            if let checked, KeyCheck.blocksBuild(checked) {
                build.keyProblem = KeyCheck.detailedMessage(checked, loc.t)
            } else {
                build.keyProblem = nil
            }
        }
        .onChange(of: loc.lang) { _ in
            if let keyCheck, KeyCheck.blocksBuild(keyCheck) {
                build.keyProblem = KeyCheck.detailedMessage(keyCheck, loc.t)
            }
        }
        .disabled(build.running)
    }

    private func slotRow(_ s: Slot) -> some View {
        // A game folder (a Switch 2 game) fills the rows from its folders: they say what it holds, the keys row that none are
        // needed, and only the base row can be cleared (which clears the folder). An empty prod.keys row says where the file comes from.
        // An empty keys row, or one whose file is gone, shows the keys saved in Settings, which the build takes (#996).
        let folderText = build.gameFolderRowText(s.id)
        let saved = s.id == "keys" && build.keysFromSettings
        let ready = folderText != nil ? (s.id == "keys" || s.ok) : s.ok || saved
        let detail = folderText ?? (saved ? (build.savedKeys as NSString).lastPathComponent + "\n" + loc.t("keys.fromSettings")
            : s.id == "keys" && s.paths.isEmpty ? loc.t("build.keyHint") : s.summary(loc.t))
        return CardRow(loc.t(s.title), detail: detail,
            dot: ready ? LauncherPalette.ready : LauncherPalette.unbuilt, help: saved ? build.savedKeys : s.paths.joined(separator: "\n")) {
            if !s.paths.isEmpty && (folderText == nil || s.id == "base") {
                Button(loc.t("data.clear")) { build.clear(s.id) }.buttonStyle(.plain)
                    .font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
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
