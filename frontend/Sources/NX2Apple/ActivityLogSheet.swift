import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Nintendo 3DS-style Activity Log sheet (#1161): library totals, 14-day play chart, monthly played-days calendar and per-game
/// play history that stays intact even after a game is removed from the library.
struct ActivityLogSheet: View {
    enum SortOrder: String, CaseIterable {
        case mostPlayed
        case mostSessions
        case recent
    }

    @ObservedObject var store: PlaySessionStore
    let owned: (String) -> LibraryGame?
    let cover: (LibraryGame) -> NSImage?
    let showInLibrary: (UUID) -> Void
    let now: Date
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    @Environment(\.dismiss) private var dismiss
    @State private var sort: SortOrder = .mostPlayed
    @State private var monthOffset = 0
    @State private var expandedID: String?

    init(
        store: PlaySessionStore,
        owned: @escaping (String) -> LibraryGame?,
        cover: @escaping (LibraryGame) -> NSImage?,
        showInLibrary: @escaping (UUID) -> Void,
        now: Date = Date(),
        initialExpandedID: String? = nil
    ) {
        self.store = store
        self.owned = owned
        self.cover = cover
        self.showInLibrary = showInLibrary
        self.now = now
        _expandedID = State(initialValue: initialExpandedID)
    }

    private func sortLabel(_ option: SortOrder) -> String {
        switch option {
        case .mostPlayed: loc.t("activity.sort.time")
        case .mostSessions: loc.t("activity.sort.sessions")
        case .recent: loc.t("activity.sort.recent")
        }
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = ConsoleTimes.locale(loc.lang)
        return c
    }

    private var entries: [(id: String, record: PlayRecord, game: LibraryGame?)] {
        let items = store.sessions.records.compactMap { key, record -> (id: String, record: PlayRecord, game: LibraryGame?)? in
            guard record.sessions > 0 else { return nil }
            return (key, record, owned(key))
        }
        return items.sorted { l, r in
            switch sort {
            case .mostPlayed:
                if l.record.seconds != r.record.seconds { return l.record.seconds > r.record.seconds }
                if l.record.sessions != r.record.sessions { return l.record.sessions > r.record.sessions }
            case .mostSessions:
                if l.record.sessions != r.record.sessions { return l.record.sessions > r.record.sessions }
                if l.record.seconds != r.record.seconds { return l.record.seconds > r.record.seconds }
            case .recent:
                let lt = l.record.lastPlayed.timeIntervalSinceReferenceDate
                let rt = r.record.lastPlayed.timeIntervalSinceReferenceDate
                if lt != rt { return lt > rt }
            }
            return l.id < r.id
        }
    }

    var body: some View {
        let sessions = store.sessions
        let activeDays = sessions.activeDays(calendar: calendar)
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        summaryStrip(sessions: sessions, activeDayCount: activeDays.count)
                        activityPanels(dailyTotals: sessions.dailyTotals, activeDays: activeDays)
                        gamesSection
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 20)
                }
            }
            Divider().opacity(0.3)
            footer
        }
        .padScope("activity", focus)
        .frame(width: 740)
        .frame(maxHeight: LauncherSheet.maxHeight(screen: NSScreen.main?.visibleFrame.height ?? 820))
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .launcherAppearance()
        .tint(LauncherPalette.accent)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t("activity.title")).font(.manrope(26, .heavy)).tracking(-0.6)
                Text(loc.t("activity.subtitle")).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 30).padding(.top, 26).padding(.bottom, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(LauncherPalette.cream)
            Text(loc.t("activity.emptyTitle")).font(.manrope(16, .bold))
            Text(loc.t("activity.emptyNote"))
                .font(.manrope(13))
                .foregroundStyle(LauncherPalette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(.horizontal, 30)
    }

    private func summaryStrip(sessions: PlaySessions, activeDayCount: Int) -> some View {
        let totalLabel = sessions.totalSeconds >= 60
            ? ConsoleTimes.duration(sessions.totalSeconds, lang: loc.lang)
            : loc.t("activity.underMinute")
        return HStack(spacing: 10) {
            statCard(title: loc.t("activity.totalTime"), value: totalLabel, symbol: "clock.fill")
            statCard(title: loc.t("activity.totalSessions"), value: "\(sessions.totalSessions)", symbol: "play.circle.fill")
            statCard(title: loc.t("activity.daysPlayed"), value: "\(activeDayCount)", symbol: "calendar")
            statCard(title: loc.t("activity.gamesPlayed"), value: "\(sessions.gamesPlayedCount)", symbol: "gamecontroller.fill")
        }
    }

    private func statCard(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(LauncherPalette.cream)
                Text(title).font(.manrope(11.5, .medium)).foregroundStyle(LauncherPalette.secondaryText).lineLimit(1)
            }
            Text(value).font(.manrope(18, .bold)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LauncherPalette.cardBorder))
    }

    private func activityPanels(dailyTotals: [String: Double], activeDays: Set<String>) -> some View {
        HStack(alignment: .top, spacing: 14) {
            recentDaysChart(dailyTotals: dailyTotals)
            monthCalendarCard(dailyTotals: dailyTotals, activeDays: activeDays)
        }
    }

    private func recentDaysChart(dailyTotals: [String: Double]) -> some View {
        let days: [(key: String, label: String, seconds: Double)] = (0..<14).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            let key = PlaySessions.dayKey(for: date, calendar: calendar)
            let dayNum = calendar.component(.day, from: date)
            return (key, "\(dayNum)", dailyTotals[key] ?? 0)
        }
        let peak = max(days.map(\.seconds).max() ?? 0, 600)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(loc.t("activity.last14Days")).font(.manrope(13, .bold))
                Spacer()
                if let maxVal = days.map(\.seconds).max(), maxVal >= 60 {
                    Text(ConsoleTimes.duration(maxVal, lang: loc.lang))
                        .font(.manrope(11.5)).foregroundStyle(LauncherPalette.secondaryText)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(days, id: \.key) { item in
                    VStack(spacing: 5) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(item.seconds > 0 ? LauncherPalette.cream : LauncherPalette.ink(0.08))
                            .frame(height: item.seconds > 0 ? max(6, CGFloat(item.seconds / peak) * 86) : 4)
                        Text(item.label)
                            .font(.manrope(9.5, .medium))
                            .foregroundStyle(LauncherPalette.secondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 112)
                }
            }
            .frame(height: 112)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LauncherPalette.cardBorder))
    }

    private func monthCalendarCard(dailyTotals: [String: Double], activeDays: Set<String>) -> some View {
        let baseMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let monthStart = calendar.date(byAdding: .month, value: monthOffset, to: baseMonth) ?? baseMonth
        let monthTitle: String = {
            let f = DateFormatter()
            f.locale = ConsoleTimes.locale(loc.lang)
            f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return f.string(from: monthStart)
        }()
        let range = calendar.range(of: .day, in: .month, for: monthStart) ?? 1..<31
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        let symbols = orderedVeryShortWeekdaySymbols()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(monthTitle).font(.manrope(13, .bold)).lineLimit(1)
                Spacer()
                Button { monthOffset -= 1 } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).launcherHover()
                .accessibilityLabel(loc.t("activity.previousMonth"))
                .padTarget("activity.month.prev", scope: "activity", radius: 6) { monthOffset -= 1 }
                Button { if monthOffset < 0 { monthOffset += 1 } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).disabled(monthOffset >= 0).opacity(monthOffset >= 0 ? 0.35 : 1)
                .accessibilityLabel(loc.t("activity.nextMonth"))
                .padTarget("activity.month.next", scope: "activity", radius: 6) { if monthOffset < 0 { monthOffset += 1 } }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, sym in
                    Text(sym).font(.manrope(9.5, .semibold)).foregroundStyle(LauncherPalette.secondaryText)
                }
                ForEach(0..<leading, id: \.self) { idx in
                    Color.clear.frame(height: 18).id("lead-\(idx)")
                }
                ForEach(Array(range), id: \.self) { day in
                    let cellDate = calendar.date(byAdding: .day, value: day - 1, to: monthStart) ?? monthStart
                    let key = PlaySessions.dayKey(for: cellDate, calendar: calendar)
                    let played = activeDays.contains(key) || (dailyTotals[key] ?? 0) > 0
                    Text("\(day)")
                        .font(.manrope(10, played ? .bold : .regular))
                        .foregroundStyle(played ? LauncherPalette.background : LauncherPalette.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 18)
                        .background(played ? LauncherPalette.cream : LauncherPalette.ink(0.05), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(14)
        .frame(width: 256, alignment: .topLeading)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LauncherPalette.cardBorder))
    }

    private func orderedVeryShortWeekdaySymbols() -> [String] {
        let f = DateFormatter()
        f.locale = ConsoleTimes.locale(loc.lang)
        let raw = f.veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        guard raw.count == 7 else { return raw }
        let start = max(0, min(6, calendar.firstWeekday - 1))
        return Array(raw[start...]) + Array(raw[..<start])
    }

    private var gamesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(loc.t("activity.gamesHeading")).font(.manrope(14, .bold))
                Spacer()
                HStack(spacing: 4) {
                    ForEach(SortOrder.allCases, id: \.self) { option in
                        Button { sort = option } label: {
                            Text(sortLabel(option))
                                .font(.manrope(11.5, sort == option ? .bold : .medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(sort == option ? LauncherPalette.ink(0.14) : .clear, in: Capsule())
                        }
                        .buttonStyle(.plain).launcherHover()
                        .padTarget("activity.sort." + option.rawValue, scope: "activity", radius: 12) { sort = option }
                    }
                }
                .padding(3)
                .background(LauncherPalette.menuFill, in: Capsule())
                .overlay(Capsule().strokeBorder(LauncherPalette.cardBorder))
            }
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                    gameRow(rank: index + 1, id: item.id, record: item.record, game: item.game)
                    if index + 1 < entries.count {
                        Divider().opacity(0.25).padding(.leading, 134)
                    }
                }
            }
            .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LauncherPalette.cardBorder))
        }
    }

    private func gameRow(rank: Int, id: String, record: PlayRecord, game: LibraryGame?) -> some View {
        let displayTitle = game?.displayName(loc.lang) ?? record.title ?? id
        let expanded = expandedID == id
        let timeLabel = record.seconds >= 60 ? ConsoleTimes.duration(record.seconds, lang: loc.lang) : loc.t("activity.underMinute")
        let avgLabel = record.averageSeconds >= 60 ? ConsoleTimes.duration(record.averageSeconds, lang: loc.lang) : loc.t("activity.underMinute")
        let daysCount = record.playedDays(calendar: calendar).count
        let subtitle = [
            String(format: loc.t("activity.sessionCount"), record.sessions),
            String(format: loc.t("activity.averageSession"), avgLabel),
            String(format: loc.t("activity.dayCount"), daysCount)
        ].joined(separator: " · ")
        let toggle = { expandedID = expanded ? nil : id }

        return VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 14) {
                    Text("\(rank)")
                        .font(.manrope(12, .bold))
                        .foregroundStyle(LauncherPalette.secondaryText)
                        .frame(width: 18, alignment: .trailing)
                    ZStack {
                        LauncherPalette.background
                        if let game, let img = cover(game) {
                            Image(nsImage: img).resizable().scaledToFill()
                        } else {
                            Image(systemName: "gamecontroller")
                                .font(.system(size: 16, weight: .light))
                                .foregroundStyle(LauncherPalette.secondaryText)
                        }
                    }
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LauncherPalette.cardBorder))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(displayTitle).font(.manrope(14, .semibold)).lineLimit(1)
                            if game == nil {
                                Text(loc.t("activity.removed"))
                                    .font(.manrope(10.5, .medium))
                                    .foregroundStyle(LauncherPalette.secondaryText)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(LauncherPalette.ink(0.07), in: Capsule())
                            }
                        }
                        Text(subtitle).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText).lineLimit(1)
                    }
                    Spacer(minLength: 10)
                    Text(timeLabel).font(.manrope(14, .bold)).foregroundStyle(LauncherPalette.cream)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LauncherPalette.secondaryText)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).launcherHover()
            .padTarget("activity.row." + id, scope: "activity", radius: 6, activate: toggle)
            if expanded {
                HStack(spacing: 18) {
                    Text(String(format: loc.t("activity.firstPlayed"), ConsoleTimes.absolute(record.firstPlayed, lang: loc.lang)))
                        .font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText)
                    Text(String(format: loc.t("activity.lastPlayed"), ConsoleTimes.absolute(record.lastPlayed, lang: loc.lang)))
                        .font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText)
                    Spacer()
                    if let game {
                        Button(loc.t("supported.show")) {
                            showInLibrary(game.id)
                            dismiss()
                        }
                        .buttonStyle(LauncherSecondaryButtonStyle())
                        .padTarget("activity.show." + id, scope: "activity") {
                            showInLibrary(game.id)
                            dismiss()
                        }
                    }
                }
                .padding(.leading, 142).padding(.trailing, 14).padding(.bottom, 12)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(loc.t("activity.persistenceNote"))
                .font(.manrope(12))
                .foregroundStyle(LauncherPalette.secondaryText)
            Spacer()
            Button(loc.t("free.done")) { dismiss() }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padTarget("activity.close", scope: "activity") { dismiss() }
        }
        .padding(.horizontal, 30).padding(.vertical, 14)
    }
}
