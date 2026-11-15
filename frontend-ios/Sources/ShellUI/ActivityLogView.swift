import SwiftUI

/// Nintendo 3DS-style Activity Log view for iPhone and iPad (#1161).
/// Purely presentation-only over `ActivityLogSnapshot` so `ShellUI` performs zero file I/O.
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
    @State private var sort: SortOrder = .mostPlayed
    @State private var monthOffset = 0
    @State private var expandedID: String?

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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !nativeBars {
                    HStack {
                        Text(ShellStrings.text("Activity log"))
                            .shellText(26, .heavy, relativeTo: .title)
                            .tracking(-0.6)
                        Spacer()
                        Button(ShellStrings.text("Done"), action: onClose)
                            .buttonStyle(.borderedProminent)
                            .tint(ShellPalette.cream)
                            .foregroundStyle(.black)
                            .accessibilityIdentifier("activityLog.close")
                            .shellTarget("act.close", action: onClose)
                    }
                }
                if snapshot.entries.isEmpty {
                    emptyState
                } else {
                    summaryGrid
                    dailyChartCard
                    monthCalendarCard
                    gamesListSection
                }
            }
            .padding(20)
        }
        .background(ShellPalette.background)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("activityLog.view")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(ShellPalette.cream)
            Text(ShellStrings.text("No play history yet"))
                .shellText(18, .bold)
            Text(ShellStrings.text("Start any game to track play time, sessions and active days here."))
                .shellText(14)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            metricTile(title: ShellStrings.text("Total time"), value: snapshot.totalTime, symbol: "clock.fill")
            metricTile(title: ShellStrings.text("Play sessions"), value: "\(snapshot.totalSessions)", symbol: "play.circle.fill")
            metricTile(title: ShellStrings.text("Days played"), value: "\(snapshot.activeDaysCount)", symbol: "calendar")
            metricTile(title: ShellStrings.text("Games played"), value: "\(snapshot.gamesPlayedCount)", symbol: "gamecontroller.fill")
        }
    }

    private func metricTile(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ShellPalette.cream)
                Text(title)
                    .shellText(12, .medium)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Text(value)
                .shellText(20, .bold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.10)))
    }

    private var dailyChartCard: some View {
        let peak = max(snapshot.recentDays.map(\.seconds).max() ?? 0, 600)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ShellStrings.text("Last 14 days"))
                    .shellText(14, .bold)
                Spacer()
                if let maxSeconds = snapshot.recentDays.map(\.seconds).max(), maxSeconds >= 60 {
                    Text(ShellFormat.duration(maxSeconds))
                        .shellText(12)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(snapshot.recentDays) { bar in
                    VStack(spacing: 5) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(bar.seconds > 0 ? ShellPalette.cream : .white.opacity(0.10))
                            .frame(height: bar.seconds > 0 ? max(6, CGFloat(bar.seconds / peak) * 80) : 4)
                        Text(bar.label)
                            .shellText(10, .medium)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 106)
                }
            }
            .frame(height: 106)
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.10)))
    }

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

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(monthTitle).shellText(14, .bold)
                Spacer()
                Button { monthOffset -= 1 } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ShellStrings.text("Previous month"))
                .shellTarget("act.month.prev") { monthOffset -= 1 }
                Button { if monthOffset < 0 { monthOffset += 1 } } label: {
                    Image(systemName: "chevron.right").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(monthOffset >= 0)
                .opacity(monthOffset >= 0 ? 0.35 : 1)
                .accessibilityLabel(ShellStrings.text("Next month"))
                .shellTarget("act.month.next", enabled: monthOffset < 0) { if monthOffset < 0 { monthOffset += 1 } }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, sym in
                    Text(sym).shellText(10, .semibold).foregroundStyle(.white.opacity(0.55))
                }
                ForEach(0..<leading, id: \.self) { idx in
                    Color.clear.frame(height: 24).id("cal-lead-\(idx)")
                }
                ForEach(Array(range), id: \.self) { day in
                    let cellDate = calendar.date(byAdding: .day, value: day - 1, to: monthStart) ?? monthStart
                    let comps = calendar.dateComponents([.year, .month, .day], from: cellDate)
                    let key = String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
                    let active = snapshot.activeDayKeys.contains(key)
                    Text("\(day)")
                        .shellText(11, active ? .bold : .regular)
                        .foregroundStyle(active ? .black : .white.opacity(0.72))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(active ? ShellPalette.cream : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.10)))
    }

    private func weekdaySymbols(calendar: Calendar, locale: Locale) -> [String] {
        let f = DateFormatter()
        f.locale = locale
        let raw = f.veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        guard raw.count == 7 else { return ["S", "M", "T", "W", "T", "F", "S"] }
        let start = max(0, min(6, calendar.firstWeekday - 1))
        return Array(raw[start...]) + Array(raw[..<start])
    }

    private var sortBar: some View {
        HStack(spacing: 4) {
            sortButton(.mostPlayed, title: ShellStrings.text("Most played"))
            sortButton(.mostSessions, title: ShellStrings.text("Most played count"))
            sortButton(.recent, title: ShellStrings.text("Recent"))
        }
        .padding(3)
        .background(.white.opacity(0.07), in: Capsule())
    }

    private var gamesListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(ShellStrings.text("Play history")).shellText(15, .bold)
                    Spacer()
                    sortBar
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(ShellStrings.text("Play history")).shellText(15, .bold)
                    sortBar
                }
            }
            VStack(spacing: 10) {
                ForEach(Array(sortedEntries.enumerated()), id: \.element.id) { index, item in
                    entryCard(rank: index + 1, item: item)
                }
            }
        }
    }

    private func sortButton(_ option: SortOrder, title: String) -> some View {
        Button { sort = option } label: {
            Text(title)
                .shellText(11.5, sort == option ? .bold : .medium)
                .foregroundStyle(sort == option ? .black : .white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(sort == option ? ShellPalette.cream : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .shellTarget("act.sort.\(option.rawValue)") { sort = option }
    }

    private func entryCard(rank: Int, item: ActivityGameEntry) -> some View {
        let expanded = expandedID == item.id
        let summary = ShellFormat.metaLine(
            ShellStrings.text("Played \(item.sessions) times"),
            ShellStrings.text("Average \(item.averageTime)"),
            ShellStrings.text("\(item.daysPlayed) days")
        )
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                expandedID = expanded ? nil : item.id
            } label: {
                HStack(spacing: 12) {
                    Text("\(rank)")
                        .shellText(12, .bold)
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 18, alignment: .trailing)
                    if let tile = item.game {
                        CoverView(game: tile, radius: 7).frame(width: 68, height: 38)
                    } else {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.white.opacity(0.06))
                            .frame(width: 68, height: 38)
                            .overlay(Image(systemName: "gamecontroller").foregroundStyle(.white.opacity(0.45)))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.title).shellText(14.5, .semibold).lineLimit(1)
                            if !item.isInstalled {
                                Text(ShellStrings.text("Removed"))
                                    .shellText(10.5, .medium)
                                    .foregroundStyle(.white.opacity(0.65))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.white.opacity(0.08), in: Capsule())
                            }
                        }
                        Text(summary)
                            .shellText(12)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Text(item.totalTime)
                        .shellText(14, .bold)
                        .foregroundStyle(ShellPalette.cream)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shellTarget("act.row.\(item.id)") { expandedID = expanded ? nil : item.id }

            if expanded {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ShellStrings.text("First played \(item.firstPlayed)"))
                            .shellText(12).foregroundStyle(.white.opacity(0.65))
                        Text(ShellStrings.text("Last played \(item.lastPlayed)"))
                            .shellText(12).foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    if item.isInstalled {
                        GameSettingsGlassButton(title: ShellStrings.text("Show in library")) {
                            onSelectGame(item.id)
                        }
                        .frame(width: 156)
                        .shellTarget("act.show.\(item.id)") { onSelectGame(item.id) }
                    }
                }
                .padding(.leading, 30)
            }
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.10)))
    }
}
