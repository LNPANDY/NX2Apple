import Foundation
import Testing
@testable import ShellUI

@Suite struct FormatTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let en = Locale(identifier: "en_US")
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))! }
    private func ago(_ days: Int, hour: Int = 23) -> Date {
        calendar.date(byAdding: .day, value: -days, to: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!)!
    }

    @Test func versionHasItsWord() {
        #expect(ShellFormat.version("1.0.0") == "Version 1.0.0")
        #expect(ShellFormat.version("") == "")
    }

    @Test func playedIsCountedInCalendarDays() {
        #expect(ShellFormat.played(now, now: now, calendar: calendar, locale: en) == "Played today")
        #expect(ShellFormat.played(ago(0, hour: 0), now: now, calendar: calendar, locale: en) == "Played today")
        #expect(ShellFormat.played(ago(1), now: now, calendar: calendar, locale: en) == "Played yesterday")
        #expect(ShellFormat.played(ago(3), now: now, calendar: calendar, locale: en) == "Played 3 days ago")
        #expect(ShellFormat.played(ago(14), now: now, calendar: calendar, locale: en) == "Played 2 weeks ago")
        #expect(ShellFormat.played(now.addingTimeInterval(86_400 * 2), now: now, calendar: calendar, locale: en) == "Played today", "a clock set back never says tomorrow")
    }

    @Test func versionLineJoinsWithAMiddleDot() {
        #expect(ShellFormat.versionLine(version: "1.0.0", lastPlayed: nil, now: now, calendar: calendar, locale: en) == "Version 1.0.0")
        #expect(ShellFormat.versionLine(version: "1.0.0", lastPlayed: now, now: now, calendar: calendar, locale: en) == "Version 1.0.0 · Played today")
        #expect(ShellFormat.versionLine(version: "2.0.1", lastPlayed: ago(1), now: now, calendar: calendar, locale: en) == "Version 2.0.1 · Played yesterday")
        #expect(ShellFormat.metaLine("Version 1.0.0", nil) == "Version 1.0.0")
        #expect(ShellFormat.metaLine("", "Played today") == "Played today")
    }
}
