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
    /// The library entry goes once the files are gone. Called with the paths that could not be moved.
    let finished: ([String]) -> Void
    /// Multi-build aware completion passing `(deletedUpstreamOrNilForAll, failedPaths)`.
    let onComplete: ((EngineUpstreamKind?, [String]) -> Void)?
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    @Environment(\.dismiss) private var dismiss
    @State private var plan: GameDeletion?
    @State private var saves = false
    @State private var working = false
    @State private var deleteAllBuilds: Bool
    @State private var selectedUpstream: EngineUpstreamKind
    /// Off only for the gallery's "measuring" state, which keeps the spinner.
    private let measures: Bool

    private var availableBuilds: [LibraryMacBuild] { game.sortedMacBuilds }
    private var hasMultipleBuilds: Bool { availableBuilds.count > 1 }
    private var activeUpstreamScope: EngineUpstreamKind? {
        (hasMultipleBuilds && !deleteAllBuilds) ? selectedUpstream : nil
    }

    init(game: LibraryGame, shellRoot: String, plan: GameDeletion? = nil, saves: Bool = false, measures: Bool = true,
         initialScopeUpstream: EngineUpstreamKind? = nil,
         finished: @escaping ([String]) -> Void = { _ in },
         onComplete: ((EngineUpstreamKind?, [String]) -> Void)? = nil) {
        self.measures = measures
        self.game = game
        self.shellRoot = shellRoot
        self.finished = finished
        self.onComplete = onComplete
        _plan = State(initialValue: plan)   // visual QA: a measured plan without files on disk
        _saves = State(initialValue: saves)
        let builds = game.sortedMacBuilds
        let defaultUp = initialScopeUpstream ?? game.activeMacUpstream(defaults: nil) ?? builds.first?.upstream ?? .nxnative
        _selectedUpstream = State(initialValue: defaultUp)
        _deleteAllBuilds = State(initialValue: builds.count <= 1)
    }

    /// Whether anything goes to the Trash: a game with no files here only leaves the collection.
    private var trashes: Bool { plan.map { !$0.items.isEmpty || $0.saves != nil } ?? true }

    var body: some View {
        DSSheet(title: String(format: loc.t("delete.question"), game.displayName(loc.lang)),
                message: trashes ? loc.t("delete.note") : "") {
            if hasMultipleBuilds {
                scopeSection
            }
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
        if item.kind == .buildFolder {
            var seen = Set<String>()
            let folders = item.paths.map { ($0 as NSString).deletingLastPathComponent }.filter { seen.insert($0).inserted }
            return folders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
        }
        return (first as NSString).abbreviatingWithTildeInPath
    }

    private func helpText(_ item: GameDeletion.Item) -> String {
        guard item.kind == .buildFolder else { return item.paths.first ?? "" }
        var seen = Set<String>()
        return item.paths.map { ($0 as NSString).deletingLastPathComponent }.filter { seen.insert($0).inserted }.joined(separator: "\n")
    }

    /// A part with where it is: the path on one mono line cut in the middle with the whole path as its tooltip (DSRow), the shared
    /// app's note as prose.
    private func row(_ item: GameDeletion.Item) -> some View {
        DSRow(title(item.kind), detail: detail(item), help: helpText(item)) {
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

    @ViewBuilder private var scopeSection: some View {
        let scopeOptions = [
            ("single", loc.t("delete.scope.single")),
            ("all", loc.t("delete.scope.all"))
        ]
        let engineOptions = availableBuilds.map { ($0.upstream.rawValue, $0.upstream.displayName) }
        DSSection("") {
            DSRow(loc.t("delete.scope.label")) {
                LauncherSegmented(options: scopeOptions, selection: deleteAllBuilds ? "all" : "single") { next in
                    let isAll = next == "all"
                    if deleteAllBuilds != isAll {
                        deleteAllBuilds = isAll
                        if measures { remeasure() }
                    }
                }
                .disabled(working)
            }
            if !deleteAllBuilds {
                DSRowDivider()
                DSRow(loc.t("delete.scope.engine")) {
                    LauncherDropdown(options: engineOptions, selection: selectedUpstream.rawValue, label: loc.t("delete.scope.engine")) { raw in
                        if let next = EngineUpstreamKind(rawValue: raw), next != selectedUpstream {
                            selectedUpstream = next
                            if measures { remeasure() }
                        }
                    }
                    .disabled(working)
                }
            }
        }
    }

    private func remeasure() {
        plan = nil
        saves = false
        measure()
    }

    private func measure() {
        let game = game, root = shellRoot, scope = activeUpstreamScope
        DispatchQueue.global(qos: .userInitiated).async {
            let result = GameDeletion.plan(for: game, shellRoot: root, upstream: scope)
            DispatchQueue.main.async { plan = result }
        }
    }

    private func delete() {
        guard let plan, !working else { return }
        working = true
        let withSaves = saves
        let scope = activeUpstreamScope
        DispatchQueue.global(qos: .userInitiated).async {
            let failed = plan.run(saves: withSaves)
            DispatchQueue.main.async {
                working = false
                dismiss()
                if let onComplete {
                    onComplete(scope, failed)
                } else {
                    finished(failed)
                }
            }
        }
    }
}

extension View {
    /// The Delete sheet of `game`, and the controller's scope while it is open. Its own modifier keeps LauncherView's chain short.
    func deleteGameSheet(_ game: Binding<LibraryGame?>, shellRoot: String, library: GameLibrary, loc: Localizer, pad: PadFocus,
                         scope: @escaping () -> String) -> some View {
        sheet(item: game) { game in
            DeleteGameSheet(game: game, shellRoot: shellRoot, onComplete: { removedUpstream, failed in
                if let removedUpstream {
                    library.removeBuildArtifact(upstream: removedUpstream, for: game.id)
                } else {
                    library.remove(game.id)
                }
                if !failed.isEmpty { library.error = String(format: loc.t("delete.failed"), failed.joined(separator: "\n")) }
            })
            .environmentObject(pad)
        }
        .onChange(of: game.wrappedValue?.id) { id in pad.scope = id != nil ? "delete" : scope() }
    }
}
