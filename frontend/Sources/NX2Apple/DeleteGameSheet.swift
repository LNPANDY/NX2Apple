import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The question before a game is deleted (#559): the same words as the iPhone and iPad app,
/// the list of what goes to the Trash with its size, the saves as a separate switch that starts off, and Cancel as the default
/// button: Return and Escape both cancel (DSSheetKeys), only a click or the controller deletes.
struct DeleteGameSheet: View {
    let game: LibraryGame
    let shellRoot: String
    /// The game's square icon (GameLibrary.appIcon), nil for the stand-in tile.
    let icon: NSImage?
    /// The library entry goes once the files are gone. Called with the paths that could not be moved.
    let finished: ([String]) -> Void
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    @Environment(\.dismiss) private var dismiss
    @State private var plan: GameDeletion?
    @State private var saves = false
    @State private var working = false
    /// Off only for the gallery's "measuring" state, which keeps the spinner.
    private let measures: Bool

    init(game: LibraryGame, shellRoot: String, icon: NSImage? = nil, plan: GameDeletion? = nil, saves: Bool = false, measures: Bool = true,
         finished: @escaping ([String]) -> Void = { _ in }) {
        self.measures = measures
        self.game = game
        self.shellRoot = shellRoot
        self.icon = icon
        self.finished = finished
        _plan = State(initialValue: plan)   // visual QA: a measured plan without files on disk
        _saves = State(initialValue: saves)
    }

    /// Whether anything goes to the Trash: a game with no files here only leaves the collection.
    private var trashes: Bool { plan.map { !$0.items.isEmpty || $0.saves != nil } ?? true }

    var body: some View {
        DSSheet(title: String(format: loc.t("delete.question"), game.displayName(loc.lang)),
                message: trashes ? loc.t("delete.note") : "") {
            if let plan {
                DSSection("") {
                    if plan.items.isEmpty { DSRow(loc.t("delete.nothing")) { EmptyView() } }
                    ForEach(Array(plan.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { DSRowDivider() }
                        row(item)
                    }
                }
                savesCard(plan.saves)
            } else {
                HStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(loc.t("free.measuring")).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
                }
                .padding(.vertical, DS.Space.xs)
            }
            Text(loc.t("delete.sources")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
        } buttons: {
            DSSheetConfirmButtons(cancelTitle: loc.t("saves.cancel"),
                                  confirmTitle: loc.t(saves && plan?.saves != nil ? "delete.confirmSaves" : "delete.confirm"),
                                  role: .destructive, enabled: plan != nil && !working, scope: "delete",
                                  cancel: { dismiss() }, confirm: delete)
        }
        .padScope("delete", focus)
        .onAppear { if plan == nil && measures { measure() } }
    }

    private func title(_ kind: GameDeletion.Item.Kind) -> String {
        switch kind {
        case .macApp: loc.t("delete.part.macApp")
        case .ipa: loc.t("delete.part.ipa")
        case .iosApp: loc.t("delete.part.iosApp")
        case .archive: loc.t("delete.part.archive")
        case .shellFramework: loc.t("delete.part.shellFramework")
        case .buildFolder: loc.t("delete.part.buildFolder")
        case .log: loc.t("delete.part.log")
        case .saves: loc.t("delete.saves")
        }
    }

    /// The line under a part's name: where it is, or for the shared app what happens.
    private func detail(_ item: GameDeletion.Item) -> String {
        if item.kind == .shellFramework { return loc.t("delete.part.shellFrameworkNote") }
        guard let first = item.paths.first else { return "" }
        let shown = item.kind == .buildFolder ? (first as NSString).deletingLastPathComponent : first
        return (shown as NSString).abbreviatingWithTildeInPath
    }

    /// A part with where it is: the path on one mono line cut in the middle with the whole path as its tooltip (DSRow), the shared
    /// app's note as prose.
    private func row(_ item: GameDeletion.Item) -> some View {
        DSRow(title(item.kind), detail: detail(item), help: item.paths.first ?? "") {
            if item.bytes > 0 { sizeText(item.bytes) }
            else if item.kind == .shellFramework {   // nothing here to measure: the size column says where it is (#1458)
                Text(loc.t("delete.part.onDevice")).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary).fixedSize()
            }
        }
    }

    private func savesCard(_ item: GameDeletion.Item?) -> some View {
        DSSection("") {
            DSRow(loc.t("delete.saves"), detail: item == nil ? loc.t("delete.noSaves") : loc.t(saves ? "delete.savesOn" : "delete.savesOff")) {
                if let item, item.bytes > 0 { sizeText(item.bytes) }
                Toggle(loc.t("delete.saves"), isOn: $saves).labelsHidden().toggleStyle(LauncherSwitchStyle()).disabled(item == nil || working)
            }
            .padTarget("delete.saves", scope: "delete", radius: DS.Radius.card, enabled: item != nil && !working,
                       activate: { if item != nil { saves.toggle() } }, adjust: { _ in if item != nil { saves.toggle() } })
        }
    }

    private func sizeText(_ bytes: Int64) -> some View {
        Text(FreeSpaceView.bytes(bytes)).font(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).monospacedDigit().fixedSize()
    }

    private func measure() {
        let game = game, root = shellRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let result = GameDeletion.plan(for: game, shellRoot: root)
            DispatchQueue.main.async { plan = result }
        }
    }

    private func delete() {
        guard let plan, !working else { return }
        working = true
        let withSaves = saves
        DispatchQueue.global(qos: .userInitiated).async {
            let failed = plan.run(saves: withSaves)
            DispatchQueue.main.async {
                working = false
                dismiss()
                finished(failed)
            }
        }
    }
}

extension View {
    /// The Delete sheet of `game`, and the controller's scope while it is open. Its own modifier keeps LauncherView's chain short.
    func deleteGameSheet(_ game: Binding<LibraryGame?>, shellRoot: String, library: GameLibrary, loc: Localizer, pad: PadFocus,
                         scope: @escaping () -> String) -> some View {
        sheet(item: game) { game in
            DeleteGameSheet(game: game, shellRoot: shellRoot, icon: GameLibrary.appIcon(for: game, banners: library.artworkDirectory)) { failed in
                library.remove(game.id)
                if !failed.isEmpty { library.error = String(format: loc.t("delete.failed"), failed.joined(separator: "\n")) }
            }
            .environmentObject(pad)
        }
        .onChange(of: game.wrappedValue?.id) { id in pad.scope = id != nil ? "delete" : scope() }
    }
}
