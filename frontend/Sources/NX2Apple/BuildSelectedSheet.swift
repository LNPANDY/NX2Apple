import SwiftUI
import NXCore
import NXLauncher
import NXModel

/// "Build selected games…" (LNPANDY/NX2Apple#997): a checklist of the library's games with files. "Add to queue" makes one queue entry
/// of each, in the library's order, with the inputs, target and output folder the library holds for it right now, and the engine the
/// launcher has selected. A game already waiting in the queue is not added twice (BuildQueueStore.enqueue).
struct BuildSelectedSheet: View {
    let library: GameLibrary
    @ObservedObject var queue: BuildQueueStore
    let engineID: String
    /// Default target from the Build page (`BuildTarget.mac` or `BuildTarget.ios`). Committed to the builder only when games are added.
    var target: String = BuildTarget.mac
    /// Whether the Build page currently builds into the shared app (either direct install or shared IPA export).
    var packagesSharedApp: Bool = false
    var exportsFramework: Bool = false
    var added: (String) -> Void = { _ in }
    let close: () -> Void
    @EnvironmentObject var loc: Localizer
    @State private var selectedTarget = BuildTarget.mac
    @State private var checked: Set<UUID> = []
    @State private var icons: [UUID: NSImage] = [:]
    @EnvironmentObject private var focus: PadFocus

    private func available(_ game: LibraryGame) -> Bool { targets.contains { queue.canEnqueue(game.titleID, target: $0) } }
    private var canAdd: Bool { candidates.contains { checked.contains($0.id) && available($0) } }
    private var sourceGames: [LibraryGame] { library.games.filter { $0.inputs[GameLibrary.folderInput] != nil || !($0.inputs["base"] ?? []).isEmpty } }

    private var iconLoadKey: String {
        let entries = sourceGames.map { "\($0.id.uuidString)|\($0.titleID)|\($0.appPath)|\($0.inputs["base"]?.first ?? "")" }
        return loc.lang.code + "\n" + entries.joined(separator: "\n")
    }

    private var candidates: [LibraryGame] { sourceGames.filter(available) }

    var body: some View {
        DSScrollingSheet(width: 680, height: min(720, (NSScreen.main?.visibleFrame.height ?? 800) - 80),
                         title: loc.t("queue.select").replacingOccurrences(of: "…", with: ""), message: loc.t("queue.selectNote"),
                         scrollTarget: focus.focused) {
            HStack(spacing: DS.Space.s) {
                Text(loc.t("queue.buildFor")).font(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                Spacer()
                LauncherSegmented(options: [(BuildTarget.mac, loc.t("library.section.mac")), (BuildTarget.ios, loc.t("build.ios")), ("both", loc.t("onboarding.platform.both"))],
                                  selection: selectedTarget) { selectedTarget = $0 }
                    .frame(width: 260)
                    .padTarget("batch.platform", scope: "batch", activate: changeTarget,
                               adjust: { adjustTarget($0) })
            }
            if candidates.isEmpty {
                Text(loc.t(sourceGames.isEmpty ? "queue.selectEmpty" : "queue.noApplicable")).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
            } else {
                DSSection("") {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, game in
                        if index > 0 { DSRowDivider() }
                        row(game)
                    }
                }
            }
        } leading: {
            EmptyView()
        } buttons: {
            Button(loc.t("queue.close"), action: close).buttonStyle(DSSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                .padTarget("batch.cancel", scope: "batch", activate: close)
            DSSheetPrimaryButton(loc.t("queue.add"), takesReturn: false, action: add)
                .disabled(!canAdd)
                .padTarget("batch.add", scope: "batch", focusColor: DS.Color.accentOn, enabled: canAdd, activate: add)
        }
        .background(ConsoleKeyboardInput { input in
            guard focus.scope == "batch" else { return }
            focus.show(default: candidates.first.map { "batch.game." + $0.id.uuidString } ?? "batch.cancel")
            switch input {
            case .up: focus.move(dx: 0, dy: -1)
            case .down: focus.move(dx: 0, dy: 1)
            case .left: focus.horizontal(-1)
            case .right: focus.horizontal(1)
            case .activate: focus.activate()
            case .back: close()
            default: break
            }
        })
        .environment(\.padRingStyle, .hug)
        .padScope("batch", focus)
        .task(id: iconLoadKey) {
            let games = sourceGames
            let banners = library.artworkDirectory
            let language = loc.lang.code
            let fallbackKeys = library.keysFile()
            var loaded: [UUID: NSImage] = [:]
            for game in games {
                guard !Task.isCancelled else { return }
                if let image = await GameLibrary.loadAppIcon(
                    for: game,
                    banners: banners,
                    language: language,
                    fallbackKeys: fallbackKeys,
                    maxPixel: ArtworkImages.iconPixels
                ) {
                    loaded[game.id] = image
                }
            }
            guard !Task.isCancelled else { return }
            icons = loaded
        }
        .onChange(of: selectedTarget) { _ in
            checked.removeAll()
            if let id = focus.focused, id.hasPrefix("batch.game."), !candidates.contains(where: { "batch.game." + $0.id.uuidString == id }) {
                focus.focused = "batch.platform"
            }
        }
        .onAppear {
            selectedTarget = target
            focus.scope = "batch"
            focus.focused = candidates.first(where: available).map { "batch.game." + $0.id.uuidString } ?? "batch.cancel"
        }
    }

    /// A game of the checklist: the check (the accent when chosen), its icon, its name and the platforms it already waits for.
    private func row(_ game: LibraryGame) -> some View {
        let on = checked.contains(game.id)
        return Button { toggle(game.id) } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 17))
                    .foregroundStyle(on ? DS.Color.symbolAccent : DS.Color.symbolDefault)
                Group {
                    if let icon = icons[game.id] {
                        Image(nsImage: icon).resizable().scaledToFill()
                    } else {
                        Image(systemName: "gamecontroller.fill").font(.system(size: 16)).foregroundStyle(DS.Color.symbolDefault)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(DS.Color.surfaceRaised)
                    }
                }
                .frame(width: DS.Control.thumbnail, height: DS.Control.thumbnail)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip))
                .accessibilityHidden(true)
                Text(game.displayName(loc.lang)).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: DS.Space.xs)
                if let existing = queue.games.first(where: { $0.titleID.caseInsensitiveCompare(game.titleID) == .orderedSame }), existing.waiting || existing.running || existing.entries.contains(where: { $0.packagePending != nil }) {
                    BuildPlatformChip(targets: existing.entries.map(\.target))
                        .help(loc.t("queue.alreadyQueued"))
                }
            }
            .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!available(game))
        .accessibilityAddTraits(on ? .isSelected : [])
        .padTarget("batch.game." + game.id.uuidString, scope: "batch", radius: DS.Radius.chip, enabled: available(game)) { toggle(game.id) }
    }

    private var targets: [String] { selectedTarget == "both" ? [BuildTarget.mac, BuildTarget.ios] : [selectedTarget] }
    private func changeTarget() { adjustTarget(1) }
    private func adjustTarget(_ by: Int) {
        let values = [BuildTarget.mac, BuildTarget.ios, "both"]
        selectedTarget = values[((values.firstIndex(of: selectedTarget) ?? 0) + by + values.count) % values.count]
    }

    private func toggle(_ id: UUID) { if checked.contains(id) { checked.remove(id) } else { checked.insert(id) } }

    private func add() {
        guard canAdd else { return }
        let batch = UUID()
        queue.enqueue(candidates.filter { checked.contains($0.id) }.flatMap { game in
            targets.map { target in
                QueueEntry(game: game, engineID: engineID, target: target, batch: batch,
                           packageAfter: packagesSharedApp && target != BuildTarget.mac,
                           exportIPA: target != BuildTarget.mac && exportsFramework ? true : nil,
                           exportFramework: target != BuildTarget.mac && exportsFramework ? true : nil)
            }
        })
        added(selectedTarget == BuildTarget.mac ? BuildTarget.mac : BuildTarget.ios)
        close()
    }
}

extension QueueEntry {
    /// The snapshot of a library game for the build queue: the inputs and output folder the library holds for it now, and the target.
    /// The hero's "Rebuild" is `stores.queue.enqueue([QueueEntry(game: game, engineID: engine.selection.engineID)])`, "Rebuild all" the
    /// same for `library.games.filter { toolsAge.older.contains($0.id) }`.
    init(game: LibraryGame, engineID: String, target: String? = nil, batch: UUID = UUID(), packageAfter: Bool = false, exportIPA: Bool? = nil, exportFramework: Bool? = nil) {
        self.init(gameID: game.id, titleID: game.titleID, name: game.name, target: target ?? game.lastTarget,
                  inputs: game.inputs.filter { $0.key != GameLibrary.folderInput }, gameFolder: game.inputs[GameLibrary.folderInput]?.first,
                  outputDirectory: game.outputDirectory, engineID: engineID, batch: batch, packageAfter: packageAfter, exportIPA: exportIPA, exportFramework: exportFramework)
    }
}
