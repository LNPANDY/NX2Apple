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
        VStack(alignment: .leading, spacing: 20) {
            Text(loc.t("section.files")).font(.manrope(30, .bold))
            if build.gameDir.isEmpty && build.basePath.isEmpty {
                CardGroup("") {
                    CardRow(loc.t(build.gameDir.isEmpty ? "build.folderCTA" : "build.folderSelected"), detail: build.gameDir.isEmpty ? "" : URL(fileURLWithPath: build.gameDir).lastPathComponent, help: build.gameDir) {
                        Button(action: pickFolder) {
                            Label(loc.t("data.choose"), systemImage: "folder").padding(.horizontal, 18).frame(height: LauncherControl.height)
                        }.buttonStyle(LauncherActionButtonStyle())
                            .padTarget("set.build.folder", scope: "main", focusColor: LauncherPalette.onCream, enabled: !build.running, activate: pickFolder)
                    }
                }
            }
            CardGroup("") {
                HStack(spacing: 14) {
                    Group {
                        if let artwork { Image(nsImage: artwork).resizable().scaledToFit() }
                        else { Image(systemName: "gamecontroller.fill").font(.system(size: 22)).frame(maxWidth: .infinity, maxHeight: .infinity).background(LauncherPalette.surface) }
                    }.frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.t("data.base")).font(.manrope(14, .semibold))
                        Text(game?.displayName(loc.lang) ?? (build.gameName.isEmpty ? build.slot("base").summary(loc.t) : build.gameName))
                            .font(.manrope(12)).foregroundStyle(.secondary).lineLimit(2)
                            .help(build.gameFolderRowText("base") ?? build.slot("base").summary(loc.t))
                    }
                    Spacer(minLength: 8)
                    Button(loc.t(build.basePath.isEmpty ? "data.choose" : "data.change")) {
                        build.pickFiles(kind: .base)
                    }.padTarget("set.build.file.base", scope: "main", activate: {
                        build.pickFiles(kind: .base)
                    })
                }.padding(18)
            }
            if build.gameFolder == nil && (!build.keysReady || keyCheckNeedsAttention) {
                CardGroup("") {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: (!build.keysReady || keyCheckNeedsAttention) ? "key.slash.fill" : "key.fill")
                            .font(.system(size: 24)).foregroundStyle((!build.keysReady || keyCheckNeedsAttention) ? LauncherPalette.building : LauncherPalette.secondaryText)
                            .frame(width: 52, height: 52).background(LauncherPalette.ink(0.08), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(build.keysPath.isEmpty ? loc.t("build.keyHint") : URL(fileURLWithPath: build.keysPath).lastPathComponent).font(.manrope(14, .semibold)).multilineTextAlignment(.leading).help((build.keysFromSettings ? loc.t("keys.fromSettings") + "\n" : "") + build.keysPath)
                            if let keyCheck { KeyCheckLine(outcome: keyCheck.outcome, detailed: keyCheck, t: loc.t) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button(loc.t(build.keysPath.isEmpty ? "data.choose" : "data.change")) { build.pickFiles(kind: .keys) }
                            .padTarget("set.build.file.keys", scope: "main", activate: { build.pickFiles(kind: .keys) })
                    }.padding(18)
                }
            } else if let keyCheck, case .cannotCheck = keyCheck.outcome {
                KeyCheckLine(outcome: keyCheck.outcome, detailed: keyCheck, t: loc.t)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { optionalSections.frame(minWidth: 285) }
                VStack(spacing: 24) { optionalSections }
            }
            CardGroup(loc.t("build.saveTo"), help: ("set.build.output.help", loc.t("msg.workdirHint")), insetTitle: true) {
                HStack(spacing: 12) {
                    if build.outDir.isEmpty && build.inputFolder.isEmpty {
                        Text(loc.t("build.saveDefault")).font(.manrope(13)).foregroundStyle(.secondary)
                    } else {
                        Button { NSWorkspace.shared.open(destination) } label: {
                            Label("/" + destination.lastPathComponent, systemImage: "folder.fill").lineLimit(1).truncationMode(.middle)
                        }.buttonStyle(.link).help(destination.path)
                            .padTarget("set.build.output.reveal", scope: "main", activate: { NSWorkspace.shared.open(destination) })
                    }
                    Spacer(minLength: 8)
                    Button(loc.t("data.change")) { build.chooseBuildFolder() }
                        .padTarget("set.build.output", scope: "main", activate: { build.chooseBuildFolder() })
                }.padding(18)
            }
        }
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
    private var optionalSections: some View {
        ForEach(build.slots.filter(\.optional), id: \.id) { slot in
            CardGroup(loc.t(slot.id == "dlc" ? "flow.dlcTitle" : slot.title), qualifier: loc.t("flow.optional"), insetTitle: true) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(build.gameFolderRowText(slot.id) ?? (slot.paths.isEmpty ? loc.t("data.notSelected") : slot.summary(loc.t)))
                        .font(.manrope(12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                        .help(slot.paths.joined(separator: "\n"))
                    if build.gameFolderRowText(slot.id) == nil {
                        HStack(spacing: 12) {
                            Button(loc.t(slot.paths.isEmpty ? "data.choose" : "data.change")) { build.pickFiles(kind: slot.kind) }
                                .padTarget("set.build.file." + slot.id, scope: "main", activate: { build.pickFiles(kind: slot.kind) })
                            if !slot.paths.isEmpty {
                                Button(loc.t("data.clear")) { build.clear(slot.id) }
                                    .padTarget("set.build.clear." + slot.id, scope: "main", activate: { build.clear(slot.id) })
                            }
                        }
                    }
                }.padding(18)
            }
        }
    }

    private func pickFolder() { Self.pickFolder(build) }

    static func pickFolder(_ build: BuildStore) {
        guard !build.running else { return }
        let d = NSOpenPanel()
        d.canChooseDirectories = true; d.canChooseFiles = false
        if d.runModal() == .OK, let u = d.url { build.scan(folder: u.path) }
    }
}
