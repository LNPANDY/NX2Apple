import AppKit
import SwiftUI
import NXCore
import NXLauncher
import NXModel

/// The Saves page (#1079): the setup for every game (GlobalSavesCard) and every built Mac game's save in one list, for the
/// player who plays now (PlayerProfile). Each row says where the save is and why, when it was last written and how big it is,
/// has the game's cloud saves switch, Show in Finder and the Mac ↔ iPhone Saves sheet, and a note when the game's save is in
/// another place while its own folder is empty (#1041). The data is SavesOverview's.
struct SavesPage: View {
    @ObservedObject var library: GameLibrary
    @ObservedObject var saveSettings: SaveSettingsStore
    @ObservedObject var players: PlayerProfileStore
    let repo: String
    var openSaves: (UUID) -> Void = { _ in }
    /// Visual QA: rows given instead of read from the disk, and the cloud saves store of a game.
    var preview: [SaveOverviewRow]?
    var cloudSaves: (LibraryGame) -> GameCloudSaves = { GameCloudSaves(titleID: $0.titleID, appPath: $0.appPath) }
    @EnvironmentObject var loc: Localizer
    @State private var measured: [UUID: SaveOverviewRow] = [:]
    @State private var problem: String?
    @State private var revision = 0

    private var player: PlayerProfile? { players.active.isDefault ? nil : players.active }

    private var rows: [SaveOverviewRow] {
        if let preview { return preview }
        let _ = revision
        return SavesOverview.rows(library.games, lang: loc.lang, global: saveSettings.global, game: saveSettings.game, player: player,
                                  cloudSetting: { cloudSaves($0).setting })
            .map { row in measured[row.id].map { merge(row, stats: $0) } ?? row }
    }

    var body: some View {
        let _ = saveSettings.revision
        let rows = rows
        LauncherPageScroll(memoryKey: "saves") {
            CardPageHeading(loc.t("savespage.title"), note: String(format: loc.t("savespage.note"), players.displayName(players.active)))
            GlobalSavesCard(settings: saveSettings)
            CardGroup(loc.t("savespage.games"), footnote: problem ?? loc.t("savespage.footnote")) {
                if rows.isEmpty {
                    CardRow(loc.t("savespage.empty"), detail: loc.t("savespage.emptyNote")) { EmptyView() }
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { CardDivider() }
                    rowView(row)
                }
            }
        }
        .task(id: measureKey(rows)) { await measure(rows) }
    }

    // ---- a row ----

    private func rowView(_ row: SaveOverviewRow) -> some View {
        let game = library.games.first { $0.id == row.id }
        return HStack(alignment: .center, spacing: 14) {
            thumbnail(game)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.manrope(15, .semibold)).lineLimit(1)
                Text(shown(row.folder)).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText)
                    .lineLimit(1).truncationMode(.middle).help(row.folder.path)
                Text(loc.t(SavesOverview.sourceKey(row.source)) + " · " + saveLine(row)).font(.manrope(12)).foregroundStyle(.tertiary).lineLimit(1)
                if let elsewhere = row.elsewhere {
                    Label(String(format: loc.t("savespage.elsewhere"), shown(elsewhere)), systemImage: "exclamationmark.triangle.fill")
                        .font(.manrope(12)).foregroundStyle(CloudSavesCard.attention).fixedSize(horizontal: false, vertical: true).help(elsewhere.path)
                }
            }
            Spacer(minLength: 12)
            cloudSwitch(row, game: game)
            Button(loc.t("savespage.finder")) { reveal(row) }
                .accessibilityLabel(String(format: loc.t("savespage.finderFor"), row.name))
            Button(loc.t("savespage.transfer")) { openSaves(row.id) }
                .accessibilityLabel(String(format: loc.t("savespage.transferFor"), row.name))
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    @ViewBuilder private func thumbnail(_ game: LibraryGame?) -> some View {
        let image = game.flatMap { GameLibrary.artwork(for: $0, slot: .thumbnail, repo: repo, maxPixel: 160) }
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(LauncherPalette.ink(0.08))
            if let image { ArtworkFill(image: image).clipShape(RoundedRectangle(cornerRadius: 8)) }
            else { Image(systemName: "gamecontroller").foregroundStyle(.tertiary) }
        }
        .frame(width: 72, height: 41)
        .accessibilityHidden(true)
    }

    /// The cloud icon names the switch on every row (the switch style draws no label), lit while the game syncs.
    private func cloudSwitch(_ row: SaveOverviewRow, game: LibraryGame?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.cloud.isOn ? "icloud" : "icloud.slash").font(.system(size: 15, weight: .medium))
                .foregroundStyle(row.cloud.isOn ? LauncherPalette.accent : .secondary).accessibilityHidden(true)
            cloudToggle(row, game: game)
        }
    }

    private func cloudToggle(_ row: SaveOverviewRow, game: LibraryGame?) -> some View {
        Toggle(isOn: Binding(get: { row.cloud.isOn }, set: { on in
            guard let game else { return }
            do { try SavesOverview.setCloud(on, titleID: game.titleID, saves: cloudSaves(game), settings: saveSettings); problem = nil }
            catch { problem = String(format: loc.t("cloud.failed"), error.localizedDescription) }
            revision += 1
        })) { Text(loc.t("savespage.cloud")).font(.manrope(13)) }
        .toggleStyle(LauncherSwitchStyle())
        .help(row.cloud.folder.flatMap { CloudSaveSync.folder(for: $0) }.map { CloudSavesCard.shown($0) }
              ?? loc.t(row.cloudFromEnv ? "savespage.cloudEnv" : "cloud.off"))
        .accessibilityLabel(String(format: loc.t("savespage.cloudFor"), row.name))
        .disabled(game == nil)
    }

    private func saveLine(_ row: SaveOverviewRow) -> String {
        guard row.hasSave, let newest = row.newest else { return loc.t("savespage.noSave") }
        let size = ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file)
        return String(format: loc.t("savespage.saved"), when(newest), size)
    }

    private func shown(_ folder: URL) -> String { (folder.path as NSString).abbreviatingWithTildeInPath }

    /// In the launcher's language, not the Mac's.
    private func when(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: loc.lang.code)
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }

    /// The save folder, or the nearest folder above it that exists (a game never played has none yet).
    private func reveal(_ row: SaveOverviewRow) {
        var target = row.elsewhere != nil && !row.hasSave ? row.elsewhere! : row.folder
        while !FileManager.default.fileExists(atPath: target.path), target.pathComponents.count > 1 { target.deleteLastPathComponent() }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // ---- the folders, measured off the main thread ----

    private func merge(_ row: SaveOverviewRow, stats: SaveOverviewRow) -> SaveOverviewRow {
        guard stats.folder == row.folder else { return row }
        var row = row
        row.newest = stats.newest; row.bytes = stats.bytes; row.files = stats.files; row.elsewhere = stats.elsewhere
        return row
    }

    private func measureKey(_ rows: [SaveOverviewRow]) -> String {
        rows.map { $0.id.uuidString + $0.folder.path }.joined(separator: "|") + "#\(revision)"
    }

    private func measure(_ rows: [SaveOverviewRow]) async {
        guard preview == nil else { return }
        let apps = Dictionary(uniqueKeysWithValues: library.games.map { ($0.id, $0.appPath) })
        let player = player
        let done = await Task.detached(priority: .utility) {
            rows.map { SavesOverview.measured($0, appPath: apps[$0.id] ?? "", player: player) }
        }.value
        guard !Task.isCancelled else { return }
        measured = Dictionary(uniqueKeysWithValues: done.map { ($0.id, $0) })
    }
}
