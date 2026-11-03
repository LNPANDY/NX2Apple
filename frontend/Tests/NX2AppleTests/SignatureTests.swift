import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The provisioning-profile expiry a free Apple ID's install has to show (7 days), and the re-sign command that renews
/// it: parsing, the day count, the wording, and the xcodebuild parameters (the install's, plus the app's own bundle ID).
final class SignatureTests: XCTestCase {
    private func profile(expires: Date?) throws -> Data {
        var plist: [String: Any] = ["Name": "iOS Team Provisioning Profile: org.nxnative.test", "TeamIdentifier": ["TEAM123456"]]
        if let expires { plist["ExpirationDate"] = expires }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    func testTheProfilePlistYieldsItsExpirationDate() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(AppSignature.expiration(fromProfile: try profile(expires: date)), date)
        XCTAssertNil(AppSignature.expiration(fromProfile: try profile(expires: nil)))
        XCTAssertNil(AppSignature.expiration(fromProfile: Data("not a plist".utf8)))
    }

    /// The app without a profile (a Mac app, or an app the launcher did not build) has no date rather than an error.
    func testAnAppWithoutAProfileHasNoExpiry() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("no-profile-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        XCTAssertNil(AppSignature.expiration(ofApp: app.path))
    }

    /// Whole calendar days: the day the profile stops working is the day iOS refuses to start the app.
    func testDaysLeftAreCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 23, minute: 30)))
        let tomorrowMorning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 1)))
        let inThree = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 9)))
        XCTAssertEqual(AppSignature.daysLeft(to: tomorrowMorning, now: now), 1)
        XCTAssertEqual(AppSignature.daysLeft(to: inThree, now: now), 3)
        XCTAssertEqual(AppSignature.daysLeft(to: yesterday, now: now), -1)
        XCTAssertEqual(AppSignature.daysLeft(to: now, now: now), 0)
    }

    func testTwoDaysOrFewerIsUrgent() throws {
        let now = Date()
        let day: TimeInterval = 24 * 3600
        XCTAssertTrue(AppSignature.isUrgent(now.addingTimeInterval(2 * day), now: now))
        XCTAssertFalse(AppSignature.isUrgent(now.addingTimeInterval(6 * day), now: now))
    }

    /// The hero's wording, in both languages, for a future, today's and a past date.
    func testTheExpiryWording() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12)))
        let inThree = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 9)))
        let yesterdayText = AppSignature.describe(yesterday, { L10n.string($0, .en) }, now: now, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(yesterdayText.contains("expired"), yesterdayText)
        let future = AppSignature.describe(inThree, { L10n.string($0, .en) }, now: now, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(future.contains("3 days left"), future)
        let today = AppSignature.describe(now, { L10n.string($0, .en) }, now: now, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(today.contains("today"), today)
        let zh = AppSignature.describe(inThree, { L10n.string($0, .zh) }, now: now, locale: Locale(identifier: "zh_CN"))
        XCTAssertTrue(zh.contains("剩 3 天"), zh)
    }
}
