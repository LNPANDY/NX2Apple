import SwiftUI
import NXCore
import NXLauncher

/// Where each game's save stands with the cloud, for console mode's Cloud saves page. Read only: the same files the desktop's Cloud
/// saves section reads (GameCloudSaves, CloudSaveSync), so nothing here syncs, writes or asks the network. A game syncs itself when it
/// starts and quits (dm/host/save_sync.c), so what is known is the folder it syncs through, the save that folder holds, and what the
/// game's last session wrote to its log.
enum ConsoleSaveStatus: String, CaseIterable, Equatable {
    /// Cloud saves are off for the game (no DM_SAVE_SYNC line, no `cloudSaves.folder`).
    case off
    /// The folder it syncs through does not exist on this Mac.
    case missingFolder
    /// On, but the game has no log: it was never played on this Mac.
    case notPlayed
    /// The last session ended in step with the cloud, sent its save, or brought a newer one in.
    case synced
    /// The last session has a newer save than the cloud that was not sent yet (no send followed, or the cloud could not be reached).
    case pending
    /// The last session's log has a [RED] save sync line.
    case failed
    /// No save on this Mac or in the cloud yet.
    case noSave
    /// The last session did not sync (it was off then, or the game never mounted its save).
    case notSynced

    var key: String { "console.saves.status." + rawValue }
    var symbol: String {
        switch self {
        case .off: return "icloud.slash"
        case .missingFolder: return "questionmark.folder"
        case .notPlayed, .noSave: return "icloud"
        case .synced: return "checkmark.icloud"
        case .pending: return "arrow.clockwise.icloud"
        case .failed: return "exclamationmark.icloud"
        case .notSynced: return "icloud.slash"
        }
    }
    var tint: Color {
        switch self {
        case .synced: return Color(red: 0.25, green: 0.84, blue: 0.47)
        case .pending, .missingFolder: return CloudSavesCard.attention
        case .failed: return Color(red: 1, green: 0.42, blue: 0.40)
        case .off, .notPlayed, .noSave, .notSynced: return Color.white.opacity(0.45)
        }
    }
}

struct ConsoleSaveRow: Identifiable, Equatable {
    /// Which time `updated` is.
    enum UpdatedFrom: String, Equatable {
        /// The modification time of the cloud folder's `save.dmsync` for the game: when a device last sent its save to the cloud.
        case cloudSave
        /// The modification time of the game's newest log: when its last session on this Mac ended (or last wrote).
        case lastSession
        var key: String { "console.saves.updated." + rawValue }
    }
    /// ConsoleGame.id: the library game's UUID.
    var id: String
    var title: String
    var status: ConsoleSaveStatus
    /// The cloud save's time when the folder holds one, else the last session's, nil when neither is known.
    var updated: Date?
    var updatedFrom: UpdatedFrom?
    /// The device a newer save came from (synced by bringing it in), shown as "From …".
    var device: String?
    /// The log's own words: why a sync failed, or why it was off in that session.
    var detail: String?
}

enum ConsoleCloudSaves {
    /// Keys of the menu row that opens the page (ConsoleView's menu).
    static let menuKey = "console.menu.saves"
    static let menuNoteKey = "console.menu.savesNote"

    /// What a row needs from the library, so the files can be read off the main thread.
    struct Input {
        var id: String
        var title: String
        var titleID: String
        var appPath: String
    }

    /// The games this Mac can play (a complete Mac app): only those sync here. An iPhone-only build or a game not built yet has no
    /// save on this Mac to show. In the library's order.
    @MainActor static func inputs(library: GameLibrary) -> [Input] {
        library.games.filter { $0.isReady && !$0.appPath.isEmpty }
            .map { Input(id: $0.id.uuidString, title: $0.name, titleID: $0.titleID, appPath: $0.appPath) }
    }

    /// Every row, read now on the main thread. The reads are small files (env.txt, the save's attributes, the newest log), but a
    /// large library or a long log is better read with `rows(_:)` off the main thread.
    @MainActor static func rows(library: GameLibrary) -> [ConsoleSaveRow] { rows(inputs(library: library)) }

    /// The rows for the inputs; safe to call on any thread (it only reads files and the game's preferences domain).
    static func rows(_ inputs: [Input]) -> [ConsoleSaveRow] {
        inputs.map { row(id: $0.id, title: $0.title, saves: GameCloudSaves(titleID: $0.titleID, appPath: $0.appPath)) }
    }

    /// One game's row from its cloud saves setting, its folder and its last session's log.
    static func row(id: String, title: String, saves: GameCloudSaves) -> ConsoleSaveRow {
        var row = ConsoleSaveRow(id: id, title: title, status: .off)
        let setting = saves.setting
        guard let folder = setting.folder else { return row }
        let check = CloudSaveSync.check(folder: folder, titleID: saves.titleID)
        if check == .missing { row.status = .missingFolder; return row }
        let last = saves.lastSession()
        if case .hasSave(let date?) = check { row.updated = date; row.updatedFrom = .cloudSave }
        else if let date = last?.date { row.updated = date; row.updatedFrom = .lastSession }
        guard let last else { row.status = .notPlayed; return row }
        switch last.state {
        case nil: row.status = .notSynced
        case .inStep, .sent: row.status = .synced
        case .broughtIn(let device): row.status = .synced; row.device = device.isEmpty ? nil : device
        case .waitingToSend, .offline: row.status = .pending
        case .waitingForChoice: row.status = .notSynced   // both changed, neither replaced the other: the launcher asks at the next start (#957)
        case .failed(let why): row.status = .failed; row.detail = why
        case .off(let why): row.status = .notSynced; row.detail = why
        case .nothingYet: row.status = .noSave
        }
        return row
    }

    /// Newest first, the games without a time last, each group in the library's order.
    static func sorted(_ rows: [ConsoleSaveRow]) -> [ConsoleSaveRow] {
        rows.enumerated().sorted { a, b in
            switch (a.element.updated, b.element.updated) {
            case let (x?, y?): return x != y ? x > y : a.offset < b.offset
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }
}

/// Console mode's Cloud saves page: every game this Mac plays, with where its save stands and when it was last updated. A full screen
/// over the home screen. The rows take the focus so a controller can scroll through them, A does nothing on them, B (and the close
/// button) leaves.
@MainActor struct ConsoleCloudSavesPage: View {
    let rows: [ConsoleSaveRow]
    let lang: Lang
    let compact: Bool
    let close: () -> Void
    var now = Date()
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let scope = "console.saves"
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var inset: CGFloat { compact ? 24 : 64 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsolePageHeader(title: t("console.saves.title"), note: t("console.saves.note"), compact: compact, closeLabel: t("console.close"),
                              closeID: "console.saves.close", scope: Self.scope, close: close)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: compact ? 12 : 14) {
                        if rows.isEmpty {
                            message(t("console.saves.empty"))
                        } else {
                            if rows.allSatisfy({ $0.status == .off }) { message(t("console.saves.allOff")) }
                            ForEach(ConsoleCloudSaves.sorted(rows)) { row in rowView(row) }
                        }
                    }
                    .padding(.horizontal, inset).padding(.top, 8).padding(.bottom, compact ? 24 : 48)
                    .frame(maxWidth: 1100 + 2 * inset, alignment: .leading)   // lined up with the title, as the other pages are
                    }.consoleScrollContent()
                }
                .consoleScrollFade()
                .onChange(of: pad.focused) { id in
                    guard let id, id.hasPrefix("console.saves.row.") else { return }
                    withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LauncherPalette.background)
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.manrope(compact ? 16 : 20)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
            .padding(compact ? 18 : 22).frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private func statusLine(_ row: ConsoleSaveRow) -> String {
        var parts = [t(row.status.key)]
        if let device = row.device { parts.append(String(format: t("console.saves.fromDevice"), device)) }
        if let detail = row.detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: " \u{00b7} ")
    }

    private func rowView(_ row: ConsoleSaveRow) -> some View {
        let id = "console.saves.row." + row.id
        return HStack(alignment: .center, spacing: compact ? 14 : 20) {
            Image(systemName: row.status.symbol).font(.system(size: compact ? 22 : 28, weight: .medium))
                .foregroundStyle(row.status.tint).frame(width: compact ? 36 : 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(row.title).font(.manrope(compact ? 18 : 23, .semibold)).lineLimit(2)
                Text(statusLine(row)).font(.manrope(compact ? 14 : 17, .medium))
                    .foregroundStyle(row.status == .synced ? LauncherPalette.cream : row.status.tint)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                if let date = row.updated {
                    Text(relative(date)).font(.manrope(compact ? 15 : 19, .semibold)).monospacedDigit()
                    Text(absolute(date)).font(.manrope(compact ? 12 : 14)).foregroundStyle(LauncherPalette.secondaryText).monospacedDigit()
                    if let from = row.updatedFrom { Text(t(from.key)).font(.manrope(compact ? 11 : 13)).foregroundStyle(.white.opacity(0.4)) }
                } else {
                    Text("\u{2014}").font(.manrope(compact ? 15 : 19, .semibold)).foregroundStyle(.white.opacity(0.35))
                }
            }
            .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, compact ? 16 : 22).padding(.vertical, compact ? 14 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .padTarget(id, scope: Self.scope, radius: 16)
        .id(id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue(statusLine(row) + (row.updated.map { ", " + absolute($0) } ?? ""))
    }

    /// In the launcher's language, not the Mac's.
    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: lang.code)
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }

    private func absolute(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: lang.code)
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
