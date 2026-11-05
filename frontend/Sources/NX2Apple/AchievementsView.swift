import SwiftUI
import NXCore
import NXLauncher

/// The goals for the selected game. The player marks one when they have done it. The game is not read.
struct AchievementsView: View {
    let game: LibraryGame
    var support: URL? = nil
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    @Environment(\.dismiss) private var dismiss
    @State private var progress = AchievementProgress()
    @State private var query = ""
    @State private var onlyOpen = false
    @State private var saveFailed = false
    /// A hidden goal that was just marked, so its name stays on screen for this filter.
    @State private var revealed: String?

    private var file: URL {
        AchievementProgress.file(in: support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NS Port Builder"))
    }

    private var list: AchievementList? { AchievementCatalog.bundled()[game.titleID.uppercased()] }

    private var shown: [Achievement] {
        guard let list else { return [] }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = progress.unlocked(titleID: game.titleID)
        return list.achievements.filter { item in
            let on = done.contains(item.id)
            if item.id == revealed { return true }
            if onlyOpen && on { return false }
            if needle.isEmpty { return true }
            let title = item.hidden && !on ? loc.t("achievements.hidden") : item.name
            let detail = item.hidden && !on ? "" : item.detail
            return title.localizedStandardContains(needle) || detail.localizedStandardContains(needle)
        }
    }

    /// The empty line. A finished list is not a failed search.
    private var emptyKey: String {
        if list == nil || list?.achievements.isEmpty == true { return "achievements.empty" }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if onlyOpen && needle.isEmpty { return "achievements.allDone" }
        return "achievements.noMatch"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text(loc.t("achievements.note")).font(.manrope(13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 22)
            search
            if saveFailed {
                Text(loc.t("achievements.saveFailed")).font(.manrope(12)).foregroundStyle(.red)
                    .padding(.horizontal, 22).padding(.top, 8)
            }
            Divider().padding(.top, 14)
            ScrollViewReader { proxy in
                ScrollView {
                    if shown.isEmpty {
                        Text(loc.t(emptyKey))
                            .font(.manrope(14)).foregroundStyle(.secondary).padding(22)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(shown, id: \.id) { item in row(item).id("achievements." + item.id) }
                        }
                    }
                }
                .onChange(of: focus.focused) { id in
                    guard let id, id.hasPrefix("achievements.") else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(LauncherPalette.background)
        .padScope("achievements", focus)
        .onAppear {
            progress = AchievementProgress.load(file: file)
            saveFailed = progress.unreadable
            DispatchQueue.main.async { if focus.visible { focus.show(default: "achievements.done") } }
        }
        .onChange(of: query) { _ in revealed = nil }
        .onChange(of: onlyOpen) { _ in revealed = nil }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t("achievements.title")).font(.manrope(22, .bold))
                Text(game.name).font(.manrope(14)).foregroundStyle(.secondary)
            }
            Spacer()
            if let list, !list.achievements.isEmpty, !progress.unreadable {
                let done = progress.marked(titleID: game.titleID, ids: list.achievements.map(\.id))
                VStack(alignment: .trailing, spacing: 6) {
                    Text(String(format: loc.t("achievements.progress"), done, list.achievements.count))
                        .font(.manrope(13, .semibold)).monospacedDigit()
                    ProgressView(value: Double(done), total: Double(list.achievements.count))
                        .progressViewStyle(.linear).tint(LauncherPalette.ready).frame(width: 120)
                }
            }
            Button(loc.t("achievements.reset")) { clear() }
                .font(.manrope(13)).buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(progress.unlocked(titleID: game.titleID).isEmpty || progress.unreadable)
            Button(action: { dismiss() }) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(loc.t("achievements.close"))
                .padTarget("achievements.done", scope: "achievements", radius: 16) { dismiss() }
        }
        .padding(22)
    }

    private var search: some View {
        HStack(spacing: 10) {
            TextField(loc.t("achievements.search"), text: $query)
                .textFieldStyle(.roundedBorder).font(.manrope(13))
            Button(loc.t(onlyOpen ? "achievements.all" : "achievements.open")) { onlyOpen.toggle() }
                .font(.manrope(13)).buttonStyle(.plain).foregroundStyle(LauncherPalette.cream)
                .padTarget("achievements.filter", scope: "achievements") { onlyOpen.toggle() }
        }
        .padding(.horizontal, 22).padding(.top, 12)
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
        .padTarget("achievements." + item.id, scope: "achievements") { toggle(item.id) }
    }

    private func toggle(_ id: String) {
        let wasHidden = list?.achievements.first { $0.id == id }?.hidden == true
        let wasOn = progress.unlocked(titleID: game.titleID).contains(id)
        var next = progress
        next.toggle(titleID: game.titleID, id: id)
        if wasHidden && !wasOn { revealed = id }
        store(next)
    }

    private func clear() {
        if progress.unreadable || progress.unlocked(titleID: game.titleID).isEmpty { return }
        var next = progress
        next.done[game.titleID.uppercased()] = []
        store(next)
    }

    private func store(_ next: AchievementProgress) {
        do {
            try next.write(file: file)
            progress = next
            saveFailed = false
        } catch {
            saveFailed = true
        }
    }
}
