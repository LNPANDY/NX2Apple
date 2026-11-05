import SwiftUI
import NXCore
import NXLauncher

/// The goals for the selected game. The player marks one when they have done it. The game is not read.
struct AchievementsView: View {
    let game: LibraryGame
    var support: URL? = nil
    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    @State private var progress = AchievementProgress()

    private var file: URL {
        AchievementProgress.file(in: support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NS Port Builder"))
    }

    private var list: AchievementList? { AchievementCatalog.bundled()[game.titleID.uppercased()] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t("achievements.title")).font(.manrope(22, .bold))
                    Text(game.name).font(.manrope(14)).foregroundStyle(.secondary)
                }
                Spacer()
                if let list {
                    Text(String(format: loc.t("achievements.progress"), progress.unlocked(titleID: game.titleID).intersection(Set(list.achievements.map(\.id))).count, list.achievements.count))
                        .font(.manrope(13, .semibold)).monospacedDigit()
                }
                Button(loc.t("achievements.reset")) { clear() }
                    .font(.manrope(13)).buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(progress.unlocked(titleID: game.titleID).isEmpty)
                Button(action: { dismiss() }) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(22)
            Text(loc.t("achievements.note")).font(.manrope(13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 22)
            Divider().padding(.top, 14)
            ScrollView {
                if let list, !list.achievements.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(list.achievements, id: \.id) { item in row(item) }
                    }
                } else {
                    Text(loc.t("achievements.empty")).font(.manrope(14)).foregroundStyle(.secondary).padding(22)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(LauncherPalette.background)
        .onAppear { progress = AchievementProgress.load(file: file) }
    }

    private func row(_ item: Achievement) -> some View {
        let on = progress.unlocked(titleID: game.titleID).contains(item.id)
        let title = item.hidden && !on ? loc.t("achievements.hidden") : item.name
        let detail = item.hidden && !on ? "" : item.detail
        return Button { toggle(item.id) } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundStyle(on ? LauncherPalette.ready : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.manrope(15, .semibold)).foregroundStyle(LauncherPalette.cream)
                    if !detail.isEmpty { Text(detail).font(.manrope(12)).foregroundStyle(.secondary).multilineTextAlignment(.leading) }
                }
                Spacer(minLength: 8)
                Text(loc.t(on ? "achievements.unlocked" : "achievements.locked")).font(.manrope(11, .medium))
                    .foregroundStyle(on ? LauncherPalette.ready : .secondary)
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(loc.t(on ? "achievements.unlocked" : "achievements.locked"))
    }

    private func toggle(_ id: String) {
        progress.toggle(titleID: game.titleID, id: id)
        try? progress.write(file: file)
    }

    private func clear() {
        progress.done[game.titleID.uppercased()] = []
        try? progress.write(file: file)
    }
}
