import Foundation

/// The wording of the version and last-played line, shared by every view and by the host and the demo that fill it:
/// "Version 1.0.0", "Played today", "Played yesterday", "Played 3 days ago", joined as "Version 1.0.0 · Played today".
public enum ShellFormat {
    /// Active UI locale, following `ShellStrings.captureBundle` during visual QA or `.autoupdatingCurrent` in the app.
    public static var activeLocale: Locale {
        if let code = ShellStrings.captureBundle?.bundleURL.deletingPathExtension().lastPathComponent, !code.isEmpty {
            return Locale(identifier: code)
        }
        return .autoupdatingCurrent
    }

    /// "Version 1.0.0", empty for an empty version.
    public static func version(_ version: String) -> String {
        version.isEmpty ? "" : ShellStrings.text("Version \(version)")
    }

    /// Play time in hours and minutes ("2 hr, 5 min"), at least one minute once anything was played.
    public static func duration(_ seconds: Double, locale: Locale = activeLocale) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .short
        let clamped = max(seconds, 60)
        formatter.allowedUnits = clamped >= 3600 ? [.hour, .minute] : [.minute]
        return formatter.string(from: clamped) ?? ""
    }

    /// Zero minutes formatted by the system in `locale` ("0 min", "0分钟", "0分").
    public static func zeroMinutes(locale: Locale = activeLocale) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .default
        formatter.allowedUnits = [.minute]
        return formatter.string(from: 0) ?? "0m"
    }

    /// Localized label for a short session under 60 seconds.
    public static func underOneMinute() -> String {
        ShellStrings.text("Under a minute")
    }

    /// Summary line for a game's detail page ("14 hr, 25 min · Played 18 times").
    public static func playSummary(duration: String, sessions: Int) -> String {
        ShellStrings.text("\(duration) · Played \(sessions) times")
    }

    /// "Played today", "Played yesterday" or "Played <relative date>", by calendar days, not by 24 hour spans.
    public static func played(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return ShellStrings.text("Played today")
        case 1: return ShellStrings.text("Played yesterday")
        default:
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.unitsStyle = .full
            formatter.dateTimeStyle = .numeric
            let relative = formatter.localizedString(for: calendar.startOfDay(for: date), relativeTo: calendar.startOfDay(for: now))
            return ShellStrings.text("Played \(relative)")
        }
    }

    /// The parts that are not empty, joined by a middle dot.
    public static func metaLine(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "Version 1.0.0 · Played today": the version line with optional play time and last-played date when there is one.
    public static func versionLine(version v: String, playTime: String? = nil, lastPlayed: Date?, now: Date = Date(),
                                   calendar: Calendar = .current, locale: Locale = .current) -> String {
        metaLine(version(v), playTime, lastPlayed.map { played($0, now: now, calendar: calendar, locale: locale) })
    }
}
