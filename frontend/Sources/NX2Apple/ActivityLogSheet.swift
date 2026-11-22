import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Nintendo 3DS-style Activity Log sheet (#1161): library totals, 14-day play chart, monthly played-days calendar and per-game
/// play history that stays intact even after a game is removed from the library. Built from the design system's sheet, cards,
/// segmented control and tags (frontend/README.md, "Design tokens and components").
struct ActivityLogSheet: View {
    enum SortOrder: String, CaseIterable {
        case mostPlayed
        case mostSessions
        case recent
    }

    /// The sheet's width: the chart and the calendar side by side, the game list under them.
    static let width: CGFloat = 760
    /// The calendar's column beside the chart.
    private static let calendarWidth: CGFloat = 252
    private static let chartHeight: CGFloat = 104
    private static let coverSize = CGSize(width: 72, height: DS.Control.thumbnail)

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

    private func duration(_ seconds: Double) -> String {
        seconds >= 60 ? ConsoleTimes.duration(seconds, lang: loc.lang) : loc.t("activity.underMinute")
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
        let rows = entries
        Group {
            if rows.isEmpty {
                DSSheet(width: Self.width, title: loc.t("activity.title"), message: loc.t("activity.subtitle")) {
                    emptyState
                } buttons: {
                    doneButton
                }
            } else {
                DSScrollingSheet(width: Self.width, height: 780, title: loc.t("activity.title"), message: loc.t("activity.subtitle"),
                                 scrollTarget: focus.focused) {
                    summaryStrip(sessions: sessions, activeDayCount: activeDays.count)
                    HStack(alignment: .top, spacing: DS.Space.s) {
                        recentDaysChart(dailyTotals: sessions.dailyTotals).frame(maxHeight: .infinity)
                        monthCalendar(dailyTotals: sessions.dailyTotals, activeDays: activeDays)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    gamesSection(rows)
                } leading: {
                    Text(loc.t("activity.persistenceNote"))
                        .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } buttons: {
                    doneButton
                }
            }
        }
        .padScope("activity", focus)
    }

    private var doneButton: some View {
        DSSheetPrimaryButton(loc.t("free.done")) { dismiss() }
            .keyboardShortcut(.cancelAction)
            .padTarget("activity.close", scope: "activity") { dismiss() }
    }

    private var emptyState: some View {
        DSCard(padding: DS.Space.l) {
            VStack(spacing: DS.Space.xs) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(DS.Color.symbolDefault)
                    .padding(.bottom, DS.Space.xxs)
                Text(loc.t("activity.emptyTitle")).font(DS.Font.headline)
                Text(loc.t("activity.emptyNote"))
                    .font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.l)
        }
    }

    // MARK: Totals

    private func summaryStrip(sessions: PlaySessions, activeDayCount: Int) -> some View {
        HStack(spacing: DS.Space.s) {
            stat(loc.t("activity.totalTime"), value: duration(sessions.totalSeconds), symbol: "clock")
            stat(loc.t("activity.totalSessions"), value: sessions.totalSessions.formatted(), symbol: "play.circle")
            stat(loc.t("activity.daysPlayed"), value: activeDayCount.formatted(), symbol: "calendar")
            stat(loc.t("activity.gamesPlayed"), value: sessions.gamesPlayedCount.formatted(), symbol: "gamecontroller")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func stat(_ title: String, value: String, symbol: String) -> some View {
        DSCard(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Label {
                    Text(title).lineLimit(1).minimumScaleFactor(0.85)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(DS.Color.symbolDefault)
                }
                .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                Text(value)
                    .font(DS.Font.title).tracking(DS.Font.titleTracking).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Last 14 days

    private func recentDaysChart(dailyTotals: [String: Double]) -> some View {
        let days: [(key: String, date: Date, seconds: Double)] = (0..<14).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            let key = PlaySessions.dayKey(for: date, calendar: calendar)
            return (key, date, dailyTotals[key] ?? 0)
        }
        let peak = max(days.map(\.seconds).max() ?? 0, 600)
        let todayKey = PlaySessions.dayKey(for: now, calendar: calendar)
        return DSCard(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(loc.t("activity.last14Days")).font(DS.Font.bodyStrong).accessibilityAddTraits(.isHeader)
                VStack(spacing: DS.Space.xxs) {
                    GeometryReader { bars in
                        HStack(alignment: .bottom, spacing: DS.Space.xxs) {
                            ForEach(days, id: \.key) { day in
                                let played = day.seconds > 0
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(played ? DS.Color.accent : DS.Color.separator)
                                    .frame(height: played ? max(4, CGFloat(day.seconds / peak) * bars.size.height) : 2)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                    .help(played ? duration(day.seconds) : "")
                                    .accessibilityElement()
                                    .accessibilityLabel(day.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: calendar.locale ?? .current)))
                                    .accessibilityValue(played ? duration(day.seconds) : "")
                            }
                        }
                    }
                    .frame(minHeight: Self.chartHeight, maxHeight: .infinity)
                    Rectangle().fill(DS.Color.separator).frame(height: 1)
                    HStack(spacing: DS.Space.xxs) {
                        ForEach(days, id: \.key) { day in
                            Text(calendar.component(.day, from: day.date).formatted())
                                .font(DS.Font.footnote).monospacedDigit()
                                .foregroundStyle(day.key == todayKey ? DS.Color.textPrimary : DS.Color.textTertiary)
                                .fontWeight(day.key == todayKey ? .semibold : .regular)
                                .lineLimit(1).fixedSize()
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Calendar

    private func monthCalendar(dailyTotals: [String: Double], activeDays: Set<String>) -> some View {
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
        let todayKey = PlaySessions.dayKey(for: now, calendar: calendar)
        let canGoForward = monthOffset < 0
        let back = { monthOffset -= 1 }
        let forward = { if monthOffset < 0 { monthOffset += 1 } }

        return DSCard(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.xxs) {
                    Text(monthTitle).font(DS.Font.bodyStrong).lineLimit(1).minimumScaleFactor(0.85)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: DS.Space.xs)
                    Button(action: back) { Image(systemName: "chevron.left") }
                        .buttonStyle(DSIconButtonStyle(size: 26))
                        .help(loc.t("activity.previousMonth")).accessibilityLabel(loc.t("activity.previousMonth"))
                        .padTarget("activity.month.prev", scope: "activity", activate: back)
                    Button(action: forward) { Image(systemName: "chevron.right") }
                        .buttonStyle(DSIconButtonStyle(size: 26))
                        .disabled(!canGoForward)
                        .help(loc.t("activity.nextMonth")).accessibilityLabel(loc.t("activity.nextMonth"))
                        .padTarget("activity.month.next", scope: "activity", enabled: canGoForward, activate: forward)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.xxs), count: 7), spacing: DS.Space.xxs) {
                    ForEach(Array(symbols.enumerated()), id: \.offset) { _, sym in
                        Text(sym).font(DS.Font.footnote).foregroundStyle(DS.Color.textTertiary).accessibilityHidden(true)
                    }
                }
                // the blanks before the first and the days in one grid with ids of their own: shared Int ids drop cells
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.xxs), count: 7), spacing: DS.Space.xxs) {
                    ForEach(0..<leading, id: \.self) { idx in
                        Color.clear.frame(height: 22).id("lead-\(idx)").accessibilityHidden(true)
                    }
                    ForEach(Array(range).map { "day-\($0)" }, id: \.self) { dayID in
                        let day = Int(dayID.dropFirst(4)) ?? 1
                        let cellDate = calendar.date(byAdding: .day, value: day - 1, to: monthStart) ?? monthStart
                        let key = PlaySessions.dayKey(for: cellDate, calendar: calendar)
                        let seconds = dailyTotals[key] ?? 0
                        let played = activeDays.contains(key) || seconds > 0
                        let today = key == todayKey
                        Text(day.formatted())
                            .font(DS.Font.callout).fontWeight(played ? .bold : .regular).monospacedDigit()
                            .foregroundStyle(played ? DS.Color.accentOn : (today ? DS.Color.textPrimary : DS.Color.textSecondary))
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .background(played ? DS.Color.accent : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip)
                                .strokeBorder(today && !played ? DS.Color.textSecondary : .clear, lineWidth: 1))
                            .help(seconds > 0 ? duration(seconds) : "")
                            .accessibilityLabel(cellDate.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: calendar.locale ?? .current)))
                            .accessibilityValue(seconds > 0 ? duration(seconds) : "")
                    }
                }
            }
        }
        .frame(width: Self.calendarWidth)
    }

    private func orderedVeryShortWeekdaySymbols() -> [String] {
        let f = DateFormatter()
        f.locale = ConsoleTimes.locale(loc.lang)
        let raw = f.veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        guard raw.count == 7 else { return raw }
        let start = max(0, min(6, calendar.firstWeekday - 1))
        return Array(raw[start...]) + Array(raw[..<start])
    }

    // MARK: Games

    private func gamesSection(_ rows: [(id: String, record: PlayRecord, game: LibraryGame?)]) -> some View {
        let options = SortOrder.allCases.map { ($0.rawValue, sortLabel($0)) }
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text(loc.t("activity.gamesHeading")).font(DS.Font.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: DS.Space.xs)
                LauncherSegmented(options: options, selection: sort.rawValue) { sort = SortOrder(rawValue: $0) ?? .mostPlayed }
                    .compactFrame(minWidth: 300)
                    .padTarget("activity.sort", scope: "activity",
                               activate: { sort = next(sort, by: 1) },
                               adjust: { sort = next(sort, by: $0) })
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(loc.t("activity.gamesHeading"))
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    gameRow(rank: index + 1, id: item.id, record: item.record, game: item.game)
                    if index + 1 < rows.count {
                        Rectangle().fill(DS.Color.separator).frame(height: 1)
                            .padding(.leading, DS.Space.m + 20 + DS.Space.s + Self.coverSize.width + DS.Space.s)
                    }
                }
            }
            .padding(.vertical, DS.Space.xxs)
            .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(LauncherPalette.cardBorder))
        }
    }

    private func next(_ order: SortOrder, by step: Int) -> SortOrder {
        let all = SortOrder.allCases
        let index = all.firstIndex(of: order) ?? 0
        return all[(index + step % all.count + all.count) % all.count]
    }

    private func gameRow(rank: Int, id: String, record: PlayRecord, game: LibraryGame?) -> some View {
        let displayTitle = game?.displayName(loc.lang) ?? record.title ?? id
        let expanded = expandedID == id
        let daysCount = record.playedDays(calendar: calendar).count
        let subtitle = [
            String(format: loc.t("activity.sessionCount"), record.sessions),
            String(format: loc.t("activity.averageSession"), duration(record.averageSeconds)),
            String(format: loc.t("activity.dayCount"), daysCount)
        ].joined(separator: " \u{00b7} ")
        let toggle = { expandedID = expanded ? nil : id }
        let show = { if let game { showInLibrary(game.id); dismiss() } }

        return VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: DS.Space.s) {
                    Text(rank.formatted())
                        .font(DS.Font.callout).monospacedDigit()
                        .foregroundStyle(DS.Color.textTertiary)
                        .frame(width: 20, alignment: .trailing)
                    ZStack {
                        DS.Color.surfaceRaised
                        if let game, let img = cover(game) {
                            Image(nsImage: img).resizable().scaledToFill()
                        } else {
                            Image(systemName: "gamecontroller")
                                .font(.system(size: 14, weight: .light))
                                .foregroundStyle(DS.Color.symbolDefault)
                        }
                    }
                    .frame(width: Self.coverSize.width, height: Self.coverSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.separator))
                    .saturation(game == nil ? 0 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DS.Space.xs) {
                            Text(displayTitle).font(DS.Font.bodyStrong).lineLimit(1)
                            if game == nil { DSTag(loc.t("activity.removed")) }
                        }
                        Text(subtitle).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: DS.Space.xs)
                    Text(duration(record.seconds))
                        .font(DS.Font.bodyStrong).monospacedDigit()
                        .foregroundStyle(DS.Color.textPrimary)
                        .lineLimit(1).fixedSize()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Color.symbolDefault)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dsRowHover(radius: DS.Radius.chip)
            .padding(.horizontal, DS.Space.xxs)
            .accessibilityValue(duration(record.seconds))
            .padTarget("activity.row." + id, scope: "activity", activate: toggle)
            .id("activity.row." + id)
            if expanded {
                HStack(alignment: .center, spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: loc.t("activity.firstPlayed"), ConsoleTimes.absolute(record.firstPlayed, lang: loc.lang)))
                        Text(String(format: loc.t("activity.lastPlayed"), ConsoleTimes.absolute(record.lastPlayed, lang: loc.lang)))
                    }
                    .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    Spacer(minLength: DS.Space.xs)
                    if game != nil {
                        Button(loc.t("supported.show"), action: show)
                            .buttonStyle(DSRowButtonStyle())
                            .padTarget("activity.show." + id, scope: "activity", activate: show)
                            .id("activity.show." + id)
                    }
                }
                .padding(.leading, DS.Space.m + DS.Space.xxs + 20 + DS.Space.s + Self.coverSize.width + DS.Space.s)
                .padding(.trailing, DS.Space.m + DS.Space.xxs).padding(.bottom, DS.Space.s).padding(.top, DS.Space.xxs)
                .transition(.opacity)
            }
        }
    }
}
