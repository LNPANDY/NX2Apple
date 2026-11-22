import SwiftUI

/// Nintendo 3DS-style Activity Log view for iPhone and iPad (#1161).
/// Purely presentation-only over `ActivityLogSnapshot` so `ShellUI` performs zero file I/O. Built from the shell's type roles,
/// cards and segmented control: two columns of totals and the panels stacked on a phone, the totals in one row and the chart
/// beside the calendar where the width allows.
public struct ActivityLogView: View {
    public enum SortOrder: String, CaseIterable, Sendable {
        case mostPlayed
        case mostSessions
        case recent
    }

    public let snapshot: ActivityLogSnapshot
    public var onSelectGame: (String) -> Void
    public var onClose: () -> Void
    @Environment(\.shellNativeBars) private var nativeBars
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sort: SortOrder = .mostPlayed
    @State private var monthOffset = 0
    @State private var expandedID: String?

    /// The width from which the totals sit in one row and the chart beside the calendar.
    static let wideWidth: CGFloat = 640
    private static let chartHeight: CGFloat = 96
    private static let coverSize = CGSize(width: 64, height: 36)
    private static let secondary = Color.white.opacity(0.62)
    private static let tertiary = Color.white.opacity(0.4)

    public init(
        snapshot: ActivityLogSnapshot,
        initialExpandedID: String? = nil,
        onSelectGame: @escaping (String) -> Void = { _ in },
        onClose: @escaping () -> Void = {}
    ) {
        self.snapshot = snapshot
        self.onSelectGame = onSelectGame
        self.onClose = onClose
        _expandedID = State(initialValue: initialExpandedID)
    }

    private var sortedEntries: [ActivityGameEntry] {
        snapshot.entries.sorted { l, r in
            switch sort {
            case .mostPlayed:
                if l.seconds != r.seconds { return l.seconds > r.seconds }
                if l.sessions != r.sessions { return l.sessions > r.sessions }
            case .mostSessions:
                if l.sessions != r.sessions { return l.sessions > r.sessions }
                if l.seconds != r.seconds { return l.seconds > r.seconds }
            case .recent:
                let lt = l.lastPlayedDate.timeIntervalSinceReferenceDate
                let rt = r.lastPlayedDate.timeIntervalSinceReferenceDate
                if lt != rt { return lt > rt }
            }
            return l.id < r.id
        }
    }

    public var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= Self.wideWidth
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !nativeBars { header }
                    if snapshot.entries.isEmpty {
                        emptyState
                    } else {
                        summary(wide: wide)
                        if wide {
                            HStack(alignment: .top, spacing: 12) {
                                dailyChartCard(fills: true).frame(maxHeight: .infinity)
                                monthCalendarCard.frame(width: 300)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            dailyChartCard(fills: false)
                            monthCalendarCard
                        }
                        gamesListSection
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 20)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity)
            }
        }
        .background(ShellPalette.background)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("activityLog.view")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ShellStrings.text("Activity log"))
                .shellType(ShellType.pageTitle)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(ShellStrings.text("Done"), action: onClose)
                .buttonStyle(PrimaryPillStyle())
                .accessibilityIdentifier("activityLog.close")
                .shellTarget("act.close", action: onClose)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Self.secondary)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(ShellStrings.text("No play history yet"))
                .shellType(ShellType.cardTitle)
            Text(ShellStrings.text("Start any game to track play time, sessions and active days here."))
                .shellType(ShellType.body)
                .foregroundStyle(Self.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .shellCard()
    }

    // MARK: Totals

    @ViewBuilder private func summary(wide: Bool) -> some View {
        let tiles = [
            (ShellStrings.text("Total time"), snapshot.totalTime, "clock"),
            (ShellStrings.text("Play sessions"), snapshot.totalSessions.formatted(), "play.circle"),
            (ShellStrings.text("Days played"), snapshot.activeDaysCount.formatted(), "calendar"),
            (ShellStrings.text("Games played"), snapshot.gamesPlayedCount.formatted(), "gamecontroller"),
        ]
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: wide ? 4 : 2), spacing: 12) {
            ForEach(tiles, id: \.0) { tile in metricTile(title: tile.0, value: tile.1, symbol: tile.2) }
        }
    }

    private func metricTile(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title).lineLimit(1).minimumScaleFactor(0.85)
            } icon: {
                Image(systemName: symbol)
            }
            .shellType(ShellType.status)
            .foregroundStyle(Self.secondary)
            Text(value)
                .shellText(22, .bold, relativeTo: .title2)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shellCard(padding: 16)
        .accessibilityElement(children: .combine)
    }

    // MARK: Last 14 days

    /// `fills`: beside the calendar the bars take the card's height, so both cards end on one line.
    private func dailyChartCard(fills: Bool) -> some View {
        let peak = max(snapshot.recentDays.map(\.seconds).max() ?? 0, 600)
        let today = snapshot.recentDays.last?.id
        return VStack(alignment: .leading, spacing: 14) {
            Text(ShellStrings.text("Last 14 days"))
                .shellType(ShellType.cardTitle)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 6) {
                GeometryReader { bars in
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(snapshot.recentDays) { bar in
                            let played = bar.seconds > 0
                            RoundedRectangle(cornerRadius: 3)
                                .fill(played ? ShellPalette.cream : ShellPalette.hairline)
                                .frame(height: played ? max(4, CGFloat(bar.seconds / peak) * bars.size.height) : 2)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                .accessibilityElement()
                                .accessibilityLabel(bar.label)
                                .accessibilityValue(played ? ShellFormat.duration(bar.seconds) : "")
                        }
                    }
                }
                .frame(minHeight: Self.chartHeight, maxHeight: fills ? .infinity : Self.chartHeight)
                Rectangle().fill(ShellPalette.hairline).frame(height: 1)
                HStack(spacing: 5) {
                    ForEach(snapshot.recentDays) { bar in
                        Text(bar.label)
                            .shellText(11, bar.id == today ? .semibold : .regular, relativeTo: .caption2)
                            .monospacedDigit()
                            .foregroundStyle(bar.id == today ? .white : Self.tertiary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
        .shellCard(padding: 16)
    }

    // MARK: Calendar

    private var monthCalendarCard: some View {
        let activeLocale = ShellFormat.activeLocale
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = activeLocale
        let baseMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: snapshot.referenceDate)) ?? snapshot.referenceDate
        let monthStart = calendar.date(byAdding: .month, value: monthOffset, to: baseMonth) ?? baseMonth
        let monthTitle: String = {
            let f = DateFormatter()
            f.locale = activeLocale
            f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return f.string(from: monthStart)
        }()
        let range = calendar.range(of: .day, in: .month, for: monthStart) ?? 1..<31
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        let symbols = weekdaySymbols(calendar: calendar, locale: activeLocale)
        let todayKey = Self.dayKey(snapshot.referenceDate, calendar: calendar)
        let canGoForward = monthOffset < 0
        let back = { monthOffset -= 1 }
        let forward = { if monthOffset < 0 { monthOffset += 1 } }
        // One kind of cell per id prefix: the weekday letters, the blanks before the first and the days share one grid.
        let cells: [(id: String, day: Int?)] = (0..<leading).map { ("blank.\($0)", nil) } + range.map { ("day.\($0)", $0) }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Text(monthTitle)
                    .shellType(ShellType.cardTitle)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                monthButton("chevron.left", label: ShellStrings.text("Previous month"), target: "act.month.prev", enabled: true, action: back)
                monthButton("chevron.right", label: ShellStrings.text("Next month"), target: "act.month.next", enabled: canGoForward, action: forward)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, sym in
                    Text(sym)
                        .shellText(11, .semibold, relativeTo: .caption2)
                        .foregroundStyle(Self.tertiary)
                        .accessibilityHidden(true)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(cells, id: \.id) { cell in
                    if let day = cell.day {
                        let cellDate = calendar.date(byAdding: .day, value: day - 1, to: monthStart) ?? monthStart
                        let key = Self.dayKey(cellDate, calendar: calendar)
                        let active = snapshot.activeDayKeys.contains(key)
                        let today = key == todayKey
                        Text(day.formatted())
                            .shellText(13, active ? .bold : .regular, relativeTo: .footnote)
                            .monospacedDigit()
                            .foregroundStyle(active ? .black : (today ? .white : Self.secondary))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(active ? ShellPalette.cream : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(today && !active ? Self.secondary : .clear, lineWidth: 1))
                            .accessibilityLabel(cellDate.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: activeLocale)))
                            .accessibilityValue(active ? ShellStrings.text("Days played") : "")
                    } else {
                        Color.clear.frame(minHeight: 30).accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shellCard(padding: 16)
    }

    private func monthButton(_ symbol: String, label: String, target: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .white : Self.tertiary)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .shellTarget(target, enabled: enabled, action: action)
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    private func weekdaySymbols(calendar: Calendar, locale: Locale) -> [String] {
        let f = DateFormatter()
        f.locale = locale
        let raw = f.veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        guard raw.count == 7 else { return ["S", "M", "T", "W", "T", "F", "S"] }
        let start = max(0, min(6, calendar.firstWeekday - 1))
        return Array(raw[start...]) + Array(raw[..<start])
    }

    // MARK: Games

    private func sortLabel(_ order: SortOrder) -> String {
        switch order {
        case .mostPlayed: ShellStrings.text("Most played")
        case .mostSessions: ShellStrings.text("Times played")
        case .recent: ShellStrings.text("Recent")
        }
    }

    private func cycleSort() {
        let all = SortOrder.allCases
        sort = all[((all.firstIndex(of: sort) ?? 0) + 1) % all.count]
    }

    private var sortControl: some View {
        NativeCreamSegmentedControl(options: SortOrder.allCases.map { SettingOption(id: $0.rawValue, verbatimLabel: sortLabel($0)) },
                                    value: sort.rawValue,
                                    accessibilityLabel: ShellStrings.text("Play history"),
                                    accessibilityIdentifier: "activityLog.sort") { sort = SortOrder(rawValue: $0) ?? .mostPlayed }
            .shellTarget("act.sort", action: cycleSort)
    }

    private var gamesListSection: some View {
        let entries = sortedEntries
        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    SectionHeading(title: ShellStrings.text("Play history"))
                    Spacer(minLength: 8)
                    sortControl.frame(width: 360)
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: ShellStrings.text("Play history"))
                    sortControl
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                    entryRow(rank: index + 1, item: item)
                    if index + 1 < entries.count {
                        Rectangle().fill(ShellPalette.hairline).frame(height: 1)
                            .padding(.leading, 16 + 20 + 12 + Self.coverSize.width + 12)
                    }
                }
            }
            .background(ShellPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ShellPalette.hairline, lineWidth: 1))
        }
    }

    private func entryRow(rank: Int, item: ActivityGameEntry) -> some View {
        let expanded = expandedID == item.id
        let summary = ShellFormat.metaLine(
            ShellStrings.text("Played \(item.sessions) times"),
            ShellStrings.text("Average \(item.averageTime)"),
            ShellStrings.text("\(item.daysPlayed) days")
        )
        let toggle = {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { expandedID = expanded ? nil : item.id }
        }
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    Text(rank.formatted())
                        .shellType(ShellType.status)
                        .monospacedDigit()
                        .foregroundStyle(Self.tertiary)
                        .frame(width: 20, alignment: .trailing)
                    Group {
                        if let tile = item.game {
                            CoverView(game: tile, radius: 6)
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.06))
                                .overlay(Image(systemName: "gamecontroller").foregroundStyle(Self.tertiary))
                        }
                    }
                    .frame(width: Self.coverSize.width, height: Self.coverSize.height)
                    .saturation(item.isInstalled ? 1 : 0)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.title).shellType(ShellType.cardTitle).lineLimit(2)
                            if !item.isInstalled { RemovedBadge() }
                        }
                        Text(summary)
                            .shellType(ShellType.meta)
                            .foregroundStyle(Self.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(item.totalTime)
                        .shellType(ShellType.button)
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Self.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(item.totalTime)
            .shellTarget("act.row.\(item.id)", action: toggle)

            if expanded {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) { details(item) ; Spacer(minLength: 8); showButton(item) }
                    VStack(alignment: .leading, spacing: 10) { details(item); showButton(item) }
                }
                .padding(.leading, 16 + 20 + 12 + Self.coverSize.width + 12)
                .padding(.trailing, 16).padding(.bottom, 14)
                .transition(.opacity)
            }
        }
    }

    private func details(_ item: ActivityGameEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ShellStrings.text("First played \(item.firstPlayed)"))
            Text(ShellStrings.text("Last played \(item.lastPlayed)"))
        }
        .shellType(ShellType.note)
        .foregroundStyle(Self.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func showButton(_ item: ActivityGameEntry) -> some View {
        if item.isInstalled {
            GameSettingsGlassButton(title: ShellStrings.text("Show in library")) { onSelectGame(item.id) }
                .fixedSize()
                .shellTarget("act.show.\(item.id)") { onSelectGame(item.id) }
        }
    }
}

/// "Removed" beside a title: the look of `ConsoleBadge`, a quiet property, not a state colour.
private struct RemovedBadge: View {
    var body: some View {
        Text(ShellStrings.text("Removed")).shellText(11, .semibold, relativeTo: .caption)
            .foregroundStyle(.white.opacity(0.72)).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.32), lineWidth: 1))
    }
}
