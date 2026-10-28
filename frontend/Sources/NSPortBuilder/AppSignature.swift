import Foundation

/// The provisioning profile an installed app was signed with, and when it expires: a free Apple ID's profile lasts 7
/// days, so a game installed with one stops starting unless the same app is signed again. The launcher can only tell
/// when to re-sign if it reads that date from the app the signature is in.
///
/// An App Store or paid-team profile lives a year, so the date is usually far away and nothing is shown as urgent.
enum AppSignature {
    static let profileName = "embedded.mobileprovision"

    /// `ExpirationDate` of the app's embedded.mobileprovision, read through `security cms -D` (the profile is a
    /// CMS-wrapped property list); nil when the app carries no profile or it cannot be read.
    static func expiration(ofApp app: String) -> Date? {
        let profile = app + "/" + profileName
        guard FileManager.default.fileExists(atPath: profile) else { return nil }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["cms", "-D", "-i", profile]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return expiration(fromProfile: data)
    }

    /// The profile plist's ExpirationDate. Split out so the parse is tested without a signed app.
    static func expiration(fromProfile data: Data) -> Date? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    /// Whole days from today to the date, counted in calendar days (0 = today, negative = past): the day the profile
    /// stops working is the day iOS refuses to start the app, not 24 hours after the last start.
    static func daysLeft(to date: Date, now: Date = Date()) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// Two days or fewer: re-sign before the next game session rather than after the game stops starting.
    static func isUrgent(_ date: Date, now: Date = Date()) -> Bool { daysLeft(to: date, now: now) <= 2 }

    /// The hero's line: the date and the days left, in the app's language.
    static func describe(_ date: Date, _ t: (String) -> String, now: Date = Date(), locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = locale
        let day = formatter.string(from: date)
        let days = daysLeft(to: date, now: now)
        if days < 0 { return String(format: t("dev.expiryPast"), day, -days) }
        if days == 0 { return String(format: t("dev.expiryToday"), day) }
        return String(format: t("dev.expiry"), day, days)
    }

    /// The compact form beside a game's status ("3 days left", "expired"): a card has no room for the date.
    static func short(_ date: Date, _ t: (String) -> String, now: Date = Date()) -> String {
        let days = daysLeft(to: date, now: now)
        if days < 0 { return t("dev.expiryExpiredShort") }
        if days == 0 { return t("dev.expiryTodayShort") }
        return String(format: t("dev.expiryShort"), days)
    }
}
