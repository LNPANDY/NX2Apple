import SwiftUI
import NXModel

/// Settings > Tools, "Build files" (#232): every game with build files, largest first, its size and Remove (after the same question
/// as the Manage menu's) and Details… (the per-part Free space sheet), then the total. Nothing is removed on its own. Remove is off for the
/// game that builds.
package struct BuildFilesCard: View {
    @ObservedObject var store: BuildFilesStore
    /// The game a build runs for, if any.
    let buildingID: UUID?
    let details: (UUID) -> Void
    @EnvironmentObject var loc: Localizer

    package init(store: BuildFilesStore, buildingID: UUID?, details: @escaping (UUID) -> Void = { _ in }) {
        self.store = store
        self.buildingID = buildingID
        self.details = details
    }

    package static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    package var body: some View {
        CardGroup(loc.t("buildfiles.card"), footnote: store.failure.map { String(format: loc.t("buildfiles.failed"), $0) } ?? loc.t("buildfiles.cardNote")) {
            if store.entries.isEmpty {
                CardRow(loc.t(store.measuring ? "buildfiles.measuring" : "buildfiles.none"),
                        detail: store.measuring ? "" : loc.t("buildfiles.noneNote")) {
                    if store.measuring { ProgressView().controlSize(.small) }
                }
            } else {
                ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry, index: index)
                    CardDivider()
                }
                CardRow(loc.t("buildfiles.total")) {
                    if store.measuring { ProgressView().controlSize(.small) }
                    Text(Self.bytes(store.total)).font(.manrope(13, .semibold)).monospacedDigit()
                        .accessibilityLabel(loc.t("buildfiles.total") + ": " + Self.bytes(store.total))
                }
            }
        }
    }

    private func row(_ entry: BuildFilesStore.Entry, index: Int) -> some View {
        let building = entry.id == buildingID
        let removing = store.removing == entry.id
        let detail = building ? loc.t("buildfiles.building") : removing ? loc.t("buildfiles.removing") : Self.bytes(entry.bytes)
        return CardRow(entry.name, detail: detail, help: entry.folder) {
            if removing { ProgressView().controlSize(.small) }
            Button(loc.t("buildfiles.details")) { details(entry.id) }
                .disabled(removing)
                .accessibilityLabel(String(format: loc.t("buildfiles.detailsNamed"), entry.name))
                .padTarget("set.buildfiles.details.\(index)", scope: "main") { if !removing { details(entry.id) } }
            Button(loc.t("buildfiles.remove")) { store.ask(entry.id, building: building) }
                .disabled(building || store.removing != nil)
                .accessibilityLabel(String(format: loc.t("buildfiles.removeNamed"), entry.name))
                .padTarget("set.buildfiles.\(index)", scope: "main") { if !building && store.removing == nil { store.ask(entry.id, building: building) } }
        }
    }
}

/// The question before a game's build files go: title, the game, the size and where they are, what removing them costs, Cancel (the
/// focus) and Remove in red.
package struct BuildFilesRemoveSheet: View {
    let entry: BuildFilesStore.Entry
    let cancel: () -> Void
    let confirm: () -> Void
    @EnvironmentObject var loc: Localizer

    package init(entry: BuildFilesStore.Entry, cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.entry = entry
        self.cancel = cancel
        self.confirm = confirm
    }

    package var body: some View {
        LauncherConfirmSheet(title: loc.t("buildfiles.title"), subtitle: entry.name, note: loc.t("buildfiles.note"),
                             cancelTitle: loc.t("saves.cancel"), confirmTitle: loc.t("buildfiles.remove"), destructive: true,
                             scope: "buildfiles", cancel: cancel, confirm: confirm) {
            VStack(spacing: 0) {
                CardRow(String(format: loc.t("buildfiles.frees"), BuildFilesCard.bytes(entry.bytes)), detail: loc.t("buildfiles.stays"),
                        detail2: (entry.folder as NSString).abbreviatingWithTildeInPath, help: entry.folder) { EmptyView() }
            }
            .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.ink(0.06)))
            .padding(.horizontal, 30)
        }
    }
}
