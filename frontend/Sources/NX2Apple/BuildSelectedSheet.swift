import SwiftUI
import NXCore
import NXLauncher
import NXModel

/// "Build selected games…" (LNPANDY/NX2Apple#997): a checklist of the library's games with files. "Add to queue" makes one queue entry
/// of each, in the library's order, with the inputs, target and output folder the library holds for it right now, and the engine the
/// launcher has selected. A game already waiting in the queue is not added twice (BuildQueueStore.enqueue).
struct BuildSelectedSheet: View {
    let library: GameLibrary
    let queue: BuildQueueStore
    let engineID: String
    /// Default target from the Build page (`BuildTarget.mac` or `BuildTarget.ios`). Starting the queue applies the player's final choice.
    var target: String = BuildTarget.mac
    /// Whether the Build page currently builds into the shared app (either direct install or shared IPA export).
    var packagesSharedApp: Bool = false
    let close: () -> Void
    @EnvironmentObject var loc: Localizer
    @State private var checked: Set<UUID> = []

    private var candidates: [LibraryGame] { library.games.filter { $0.inputs[GameLibrary.folderInput] != nil || !($0.inputs["base"] ?? []).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(loc.t("queue.select").replacingOccurrences(of: "…", with: "")).font(.manrope(26, .heavy)).tracking(-0.5)
                Text(loc.t("queue.selectNote")).font(.manrope(13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 20)
            ScrollView {
                if candidates.isEmpty {
                    Text(loc.t("queue.selectEmpty")).font(.manrope(14)).foregroundStyle(.secondary).padding(.horizontal, 30)
                }
                VStack(spacing: 0) {
                    ForEach(candidates) { game in
                        Button { toggle(game.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: checked.contains(game.id) ? "checkmark.square.fill" : "square").font(.system(size: 17))
                                Text(game.name).font(.manrope(14, .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
                            .padding(.horizontal, 30)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(checked.contains(game.id) ? .isSelected : [])
                    }
                }
            }
            Divider().opacity(0.3)
            HStack(spacing: 12) {
                Spacer()
                Button(loc.t("queue.close"), action: close).buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button { add() } label: {
                    Text(loc.t("queue.add")).font(.manrope(14, .semibold)).padding(.horizontal, 20).padding(.vertical, 10)
                }
                    .buttonStyle(LauncherActionButtonStyle())
                    .disabled(checked.isEmpty).opacity(checked.isEmpty ? 0.4 : 1)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 30).padding(.vertical, 16)
        }
        .frame(width: 680)
        .frame(maxHeight: min(720, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
        .background(LauncherPalette.background)
    }

    private func toggle(_ id: UUID) { if checked.contains(id) { checked.remove(id) } else { checked.insert(id) } }

    private func add() {
        let batch = UUID()
        queue.enqueue(candidates.filter { checked.contains($0.id) }.map {
            QueueEntry(game: $0, engineID: engineID, target: target, batch: batch,
                       packageAfter: packagesSharedApp && target != BuildTarget.mac)
        })
        close()
    }
}

extension QueueEntry {
    /// The snapshot of a library game for the build queue: the inputs and output folder the library holds for it now, and the target.
    /// The hero's "Rebuild" is `stores.queue.enqueue([QueueEntry(game: game, engineID: engine.selection.engineID)])`, "Rebuild all" the
    /// same for `library.games.filter { toolsAge.older.contains($0.id) }`.
    init(game: LibraryGame, engineID: String, target: String? = nil, batch: UUID = UUID(), packageAfter: Bool = false) {
        self.init(gameID: game.id, titleID: game.titleID, name: game.name, target: target ?? game.lastTarget,
                  inputs: game.inputs.filter { $0.key != GameLibrary.folderInput }, gameFolder: game.inputs[GameLibrary.folderInput]?.first,
                  outputDirectory: game.outputDirectory, engineID: engineID, batch: batch, packageAfter: packageAfter)
    }
}
