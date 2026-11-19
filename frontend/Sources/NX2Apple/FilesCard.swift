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
    var library: GameLibrary? = nil
    var artworkStore: ArtworkStore = .shared
    @State private var artwork: NSImage?
    @EnvironmentObject var loc: Localizer
    @Binding var extrasOpen: Bool   // the optional input rows, kept by the page so they stay as they were when it is left and back
    @State private var keyCheck: KeyCheck.DetailedOutcome?   // prod.keys against the chosen files (KeyCheck.swift)

    private var currentKeyInputs: KeyCheck.Inputs {
        KeyCheck.Inputs(keys: build.keysPath, files: [build.basePath, build.updatePath] + build.dlcPaths)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            // One section of uniform rows (#1458): the folder first with the step's one primary button, then each input with
            // "Not selected" or its file and a trailing Choose…. A dot in the leading slot once chosen, the base game's cover there.
            CardGroup(loc.t("files.title")) {
                VStack(spacing: 0) {
                    fileRow(loc.t("files.folder"), subtitle: build.gameDir.isEmpty ? loc.t("files.folderNote") : URL(fileURLWithPath: build.gameDir).lastPathComponent,
                            help: build.gameDir, chosen: !build.gameDir.isEmpty) {
                        if build.gameDir.isEmpty {
                            Button(action: pickFolder) { Text(loc.t("files.chooseFolder")).font(DS.Font.bodyStrong).padding(.horizontal, 15).frame(maxWidth: .infinity) }
                                .buttonStyle(DSPrimaryButtonStyle())
                                .padTarget("set.build.folder", scope: "main", focusColor: LauncherPalette.onCream, enabled: !build.running, activate: pickFolder)
                        } else {
                            Button(loc.t("data.change"), action: pickFolder)
                                .padTarget("set.build.folder", scope: "main", enabled: !build.running, activate: pickFolder)
                        }
                    }
                    CardDivider()
                    fileRow(loc.t("data.base"), subtitle: baseText, help: build.gameFolderRowText("base") ?? build.slot("base").summary(loc.t),
                            chosen: build.slot("base").ok || build.gameFolder != nil, thumbnail: artwork) {
                        if build.gameFolderRowText("base") == nil || build.gameFolder == nil {
                            Button(loc.t(build.basePath.isEmpty ? "data.choose" : "data.change")) { build.pickFiles(kind: .base) }
                                .padTarget("set.build.file.base", scope: "main", activate: { build.pickFiles(kind: .base) })
                        }
                    }
                    ForEach(build.slots.filter(\.optional), id: \.id) { slot in
                        CardDivider()
                        let folderText = build.gameFolderRowText(slot.id)
                        fileRow(loc.t(slot.id == "dlc" ? "data.dlc" : slot.title),
                                subtitle: folderText ?? (slot.paths.isEmpty ? loc.t("files.optional") : slot.summary(loc.t)),
                                help: slot.paths.joined(separator: "\n"), chosen: !slot.paths.isEmpty || (folderText != nil && build.gameFolder != nil)) {
                            if folderText == nil {
                                HStack(spacing: DS.Space.xs) {
                                    if !slot.paths.isEmpty {
                                        Button { build.clear(slot.id) } label: { Image(systemName: "xmark") }
                                            .buttonStyle(DSIconButtonStyle(size: 28)).accessibilityLabel(loc.t("data.clear"))
                                            .padTarget("set.build.clear." + slot.id, scope: "main", activate: { build.clear(slot.id) })
                                    }
                                    Button(loc.t(slot.paths.isEmpty ? "data.choose" : "data.change")) { build.pickFiles(kind: slot.kind) }
                                        .padTarget("set.build.file." + slot.id, scope: "main", activate: { build.pickFiles(kind: slot.kind) })
                                }
                            }
                        }
                    }
                    CardDivider()
                    fileRow(loc.t("files.keys"), subtitle: build.keysPath.isEmpty ? loc.t("data.notSelected") : URL(fileURLWithPath: build.keysPath).lastPathComponent,
                            help: (build.keysFromSettings ? loc.t("keys.fromSettings") + "\n" : "") + build.keysPath,
                            chosen: build.keysReady && !keyCheckNeedsAttention, problem: build.keysReady && keyCheckNeedsAttention,
                            extra: keyCheck.map { AnyView(KeyCheckLine(outcome: $0.outcome, detailed: $0, t: loc.t)) }) {
                        Button(loc.t(build.keysPath.isEmpty ? "data.choose" : "data.change")) { build.pickFiles(kind: .keys) }
                            .padTarget("set.build.file.keys", scope: "main", activate: { build.pickFiles(kind: .keys) })
                    }
                }
            }
            CardGroup(loc.t("build.saveTo"), help: ("set.build.output.help", loc.t("msg.workdirHint"))) {
                fileRow(loc.t("build.saveTo"), subtitle: build.outDir.isEmpty && build.inputFolder.isEmpty ? loc.t("build.saveDefault") : destination.path,
                        help: destination.path, chosen: nil) {
                    HStack(spacing: DS.Space.xs) {
                        if !(build.outDir.isEmpty && build.inputFolder.isEmpty) {
                            Button { NSWorkspace.shared.open(destination) } label: { Image(systemName: "folder") }
                                .buttonStyle(DSIconButtonStyle(size: 28)).accessibilityLabel(loc.t("shell.showInFinder"))
                                .padTarget("set.build.output.reveal", scope: "main", activate: { NSWorkspace.shared.open(destination) })
                        }
                        Button(loc.t("data.change")) { build.chooseBuildFolder() }
                            .padTarget("set.build.output", scope: "main", activate: { build.chooseBuildFolder() })
                    }
                }
            }
        }
        .buttonStyle(DSRowButtonStyle())
        .task(id: (build.gameTitleID ?? "") + loc.lang.code) {
            artwork = nil
            guard let id = build.gameTitleID else { return }
            let url = await artworkStore.fetchIcon(id, language: loc.lang.code)
            guard !Task.isCancelled, build.gameTitleID == id else { return }
            if let url { artwork = NSImage(contentsOf: url) }
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

    private var game: LibraryGame? { library?.games.first { $0.titleID == build.gameTitleID } }
    private var destination: URL {
        URL(fileURLWithPath: build.outDir.isEmpty ? (build.inputFolder.isEmpty ? NSHomeDirectory() : build.inputFolder) : build.outDir, isDirectory: true)
    }
    private var keyCheckNeedsAttention: Bool {
        guard let keyCheck else { return false }
        switch keyCheck.outcome { case .fits, .cannotCheck: return false; default: return true }
    }
    private var baseText: String {
        if let text = build.gameFolderRowText("base") { return text }
        if build.basePath.isEmpty { return loc.t("data.notSelected") }
        return game?.displayName(loc.lang) ?? (build.gameName.isEmpty ? build.slot("base").summary(loc.t) : build.gameName)
    }

    /// One row of the list: a thumbnail-sized leading slot (the cover, a dot once chosen, empty otherwise), the title, one
    /// secondary line and the trailing control column. `chosen` nil leaves the slot out (the Save to row).
    private func fileRow<Trailing: View>(_ title: String, subtitle: String, help: String, chosen: Bool?, problem: Bool = false, thumbnail: NSImage? = nil,
                                         extra: AnyView? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: DS.Space.s) {
            if let chosen {
                ZStack {
                    if let thumbnail, chosen {
                        Image(nsImage: thumbnail).resizable().scaledToFill()
                            .frame(width: DS.Control.thumbnail, height: DS.Control.thumbnail).clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip))
                    } else if chosen || problem {
                        Circle().fill(problem ? DS.Color.statusWarning : DS.Color.statusSuccess).frame(width: 8, height: 8)
                    }
                }
                .frame(width: DS.Control.thumbnail, height: DS.Control.thumbnail)
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary)
                Text(subtitle).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(2).truncationMode(.middle).help(help)
                if let extra { extra.padding(.top, DS.Space.xxs) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing().frame(width: DS.Control.columnWidth, alignment: .trailing)
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .frame(minHeight: 60)
        .accessibilityElement(children: .contain)
    }
    private func pickFolder() { Self.pickFolder(build) }

    static func pickFolder(_ build: BuildStore) {
        guard !build.running else { return }
        let d = NSOpenPanel()
        d.canChooseDirectories = true; d.canChooseFiles = false
        if d.runModal() == .OK, let u = d.url { build.scan(folder: u.path) }
    }
}
