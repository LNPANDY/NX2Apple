import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The provisioning-profile expiry a free Apple ID's install has to show (7 days), and the re-sign command that renews
/// it: parsing, the day count, the wording, and the xcodebuild parameters (the install's, plus the app's own bundle ID).
final class SignatureTests: IsolatedDefaultsTestCase {
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

    func testExpirationsDeduplicatesSharedShellAppLookups() throws {
        final class CountingRunner: ProcessRunner {
            let xml: String
            var count = 0
            init(xml: String) { self.xml = xml }
            func capture(_ launch: ProcessLaunch) -> ProcessResult {
                if launch.executable == "/usr/bin/security" { count += 1 }
                return ProcessResult(status: 0, out: xml)
            }
            func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { false }
            func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult { .failedToStart("unused") }
            func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess { fatalError("unused") }
        }
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("shared-shell-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        try Data("cms-envelope".utf8).write(to: app.appendingPathComponent("embedded.mobileprovision"))

        let expected = Date(timeIntervalSince1970: 1_795_000_000)
        let xml = try String(decoding: profile(expires: expected), as: UTF8.self)
        let runner = CountingRunner(xml: xml)

        let g1 = UUID()
        let g2 = UUID()
        let g3 = UUID()
        let found = AppSignature.expirations(
            ofApps: [(g1, app.path), (g2, app.path), (g3, app.appendingPathComponent("missing.app").path)],
            runner: runner
        )
        XCTAssertEqual(found[g1], expected)
        XCTAssertEqual(found[g2], expected)
        XCTAssertNil(found[g3])
        XCTAssertEqual(runner.count, 1, "games sharing one DmShell.app should invoke security cms only once")
    }

    private func teamProfileData(uuid: String, name: String, appID: String, team: String, expires: Date, cmsWrapped: Bool = false) throws -> Data {
        let plist: [String: Any] = [
            "UUID": uuid,
            "Name": name,
            "TeamIdentifier": [team],
            "Entitlements": ["application-identifier": appID],
            "ExpirationDate": expires,
        ]
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        guard cmsWrapped else { return xml }
        var wrapped = Data([0x30, 0x82, 0x01, 0x00, 0x06, 0x09])
        wrapped.append(xml)
        wrapped.append(Data([0x31, 0x00, 0x00]))
        return wrapped
    }

    func testStageProfilesForResignRemovesStaleCachedProfilesAndRestoresOnRollback() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("resign-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        let xcodeProfiles = home + "/Library/Developer/Xcode/UserData/Provisioning Profiles"
        let legacyProfiles = home + "/Library/MobileDevice/Provisioning Profiles"
        let app = root.appendingPathComponent("DmShell.app").path
        try fm.createDirectory(atPath: xcodeProfiles, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: legacyProfiles, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: app + "/_CodeSignature", withIntermediateDirectories: true)
        try Data("sig".utf8).write(to: URL(fileURLWithPath: app + "/_CodeSignature/CodeResources"))

        let oldExpiry = Date(timeIntervalSince1970: 1_794_000_000)
        let newExpiry = Date(timeIntervalSince1970: 1_794_604_800)
        let matching = try teamProfileData(
            uuid: "OLD-UUID-1",
            name: "iOS Team Provisioning Profile: org.nxnative.shell.TEAM123456",
            appID: "TEAM123456.org.nxnative.shell.TEAM123456",
            team: "TEAM123456",
            expires: oldExpiry,
            cmsWrapped: true
        )
        let unrelated = try teamProfileData(
            uuid: "OTHER-UUID-2",
            name: "iOS Team Provisioning Profile: com.example.other",
            appID: "TEAM123456.com.example.other",
            team: "TEAM123456",
            expires: oldExpiry,
            cmsWrapped: true
        )
        let matchingBase = try teamProfileData(
            uuid: "OLD-UUID-BASE",
            name: "iOS Team Provisioning Profile: org.nxnative.shell",
            appID: "TEAM123456.org.nxnative.shell",
            team: "TEAM123456",
            expires: oldExpiry,
            cmsWrapped: true
        )
        let unrelatedSuffix = try teamProfileData(
            uuid: "OTHER-SUFFIX-UUID",
            name: "iOS Team Provisioning Profile: com.example.org.nxnative.shell",
            appID: "TEAM123456.com.example.org.nxnative.shell",
            team: "TEAM123456",
            expires: oldExpiry,
            cmsWrapped: true
        )
        let otherTeam = try teamProfileData(
            uuid: "OTHER-TEAM-UUID",
            name: "iOS Team Provisioning Profile: org.nxnative.shell",
            appID: "OTHERTEAM9.org.nxnative.shell",
            team: "OTHERTEAM9",
            expires: oldExpiry,
            cmsWrapped: true
        )
        let missingTeamSameName = try PropertyListSerialization.data(
            fromPropertyList: [
                "UUID": "MISSING-TEAM-UUID",
                "Name": "iOS Team Provisioning Profile: org.nxnative.shell",
                "Entitlements": ["application-identifier": "OTHERTEAM9.org.nxnative.shell"],
                "ExpirationDate": oldExpiry,
            ],
            format: .xml,
            options: 0
        )
        let nameOnlyNoEntitlements = try PropertyListSerialization.data(
            fromPropertyList: [
                "UUID": "NAME-ONLY-UUID",
                "Name": "iOS Team Provisioning Profile: org.nxnative.shell",
                "TeamIdentifier": ["TEAM123456"],
                "ExpirationDate": oldExpiry,
            ],
            format: .xml,
            options: 0
        )
        let cachedMatch = xcodeProfiles + "/OLD-UUID-1.mobileprovision"
        let legacyMatch = legacyProfiles + "/OLD-UUID-BASE.mobileprovision"
        let cachedOther = xcodeProfiles + "/OTHER-UUID-2.mobileprovision"
        let cachedSuffix = xcodeProfiles + "/OTHER-SUFFIX-UUID.mobileprovision"
        let cachedOtherTeam = xcodeProfiles + "/OTHER-TEAM-UUID.mobileprovision"
        let cachedMissingTeam = xcodeProfiles + "/MISSING-TEAM-UUID.mobileprovision"
        let cachedNameOnly = xcodeProfiles + "/NAME-ONLY-UUID.mobileprovision"
        let embedded = app + "/embedded.mobileprovision"
        try matching.write(to: URL(fileURLWithPath: cachedMatch))
        try matchingBase.write(to: URL(fileURLWithPath: legacyMatch))
        try unrelated.write(to: URL(fileURLWithPath: cachedOther))
        try unrelatedSuffix.write(to: URL(fileURLWithPath: cachedSuffix))
        try otherTeam.write(to: URL(fileURLWithPath: cachedOtherTeam))
        try missingTeamSameName.write(to: URL(fileURLWithPath: cachedMissingTeam))
        try nameOnlyNoEntitlements.write(to: URL(fileURLWithPath: cachedNameOnly))
        try matching.write(to: URL(fileURLWithPath: embedded))

        // 1. Rollback path (e.g. offline xcodebuild failure): every moved profile and _CodeSignature is restored intact.
        let stagedFail = AppSignature.stageProfilesForResign(
            app: app, bundleID: "org.nxnative.shell.TEAM123456", team: "TEAM123456", home: home
        )
        XCTAssertFalse(fm.fileExists(atPath: cachedMatch))
        XCTAssertFalse(fm.fileExists(atPath: legacyMatch), "base bundleID profile must also be staged when bundleID already carries .TEAM suffix")
        XCTAssertFalse(fm.fileExists(atPath: embedded))
        XCTAssertFalse(fm.fileExists(atPath: app + "/_CodeSignature"))
        XCTAssertTrue(fm.fileExists(atPath: cachedOther), "unrelated app profiles must never be touched")
        XCTAssertTrue(fm.fileExists(atPath: cachedSuffix), "another app whose bundleID merely ends with .org.nxnative.shell must never be touched")
        XCTAssertTrue(fm.fileExists(atPath: cachedOtherTeam), "another team's profile must never be touched")
        XCTAssertTrue(fm.fileExists(atPath: cachedMissingTeam), "a profile without TeamIdentifier must never be matched by Name")
        XCTAssertTrue(fm.fileExists(atPath: cachedNameOnly), "a profile without Entitlements.application-identifier must never be matched by Name")

        stagedFail.rollback()
        XCTAssertTrue(fm.fileExists(atPath: cachedMatch))
        XCTAssertTrue(fm.fileExists(atPath: legacyMatch))
        XCTAssertTrue(fm.fileExists(atPath: embedded))
        XCTAssertTrue(fm.fileExists(atPath: app + "/_CodeSignature/CodeResources"), "_CodeSignature must be restored on rollback")
        XCTAssertEqual(AppSignature.expiration(ofApp: app), oldExpiry)

        // 2. Commit path after xcodebuild writes a new 7-day profile: stale cached profiles are discarded and the new 7-day expiry wins.
        let stagedOK = AppSignature.stageProfilesForResign(
            app: app, bundleID: "org.nxnative.shell.TEAM123456", team: "TEAM123456", home: home
        )
        let renewed = try teamProfileData(
            uuid: "NEW-UUID-7DAY",
            name: "iOS Team Provisioning Profile: org.nxnative.shell.TEAM123456",
            appID: "TEAM123456.org.nxnative.shell.TEAM123456",
            team: "TEAM123456",
            expires: newExpiry,
            cmsWrapped: true
        )
        try renewed.write(to: URL(fileURLWithPath: embedded))
        stagedOK.commit()
        XCTAssertFalse(fm.fileExists(atPath: cachedMatch))
        XCTAssertFalse(fm.fileExists(atPath: legacyMatch))
        XCTAssertTrue(fm.fileExists(atPath: cachedOther))
        XCTAssertTrue(fm.fileExists(atPath: cachedSuffix))
        XCTAssertTrue(fm.fileExists(atPath: cachedOtherTeam))
        XCTAssertTrue(fm.fileExists(atPath: cachedMissingTeam))
        XCTAssertTrue(fm.fileExists(atPath: cachedNameOnly))
        XCTAssertTrue(fm.fileExists(atPath: app + "/_CodeSignature/CodeResources"))
        XCTAssertEqual(AppSignature.expiration(ofApp: app), newExpiry)
    }

    @MainActor func testSignatureTrackerDropsOutOfOrderAndClearedGenerations() throws {
        final class ScriptedRunner: ProcessRunner, @unchecked Sendable {
            let xml: String
            let onCapture: (() -> Void)?
            init(xml: String, onCapture: (() -> Void)? = nil) {
                self.xml = xml
                self.onCapture = onCapture
            }
            func capture(_ launch: ProcessLaunch) -> ProcessResult {
                onCapture?()
                return ProcessResult(status: 0, out: xml)
            }
            func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { false }
            func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult { .failedToStart("unused") }
            func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess { fatalError("unused") }
        }

        let app = FileManager.default.temporaryDirectory.appendingPathComponent("sig-gen-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        try Data("cms-envelope".utf8).write(to: app.appendingPathComponent("embedded.mobileprovision"))

        let oldDate = Date(timeIntervalSince1970: 1_790_000_000)
        let renewedDate = Date(timeIntervalSince1970: 1_790_604_800)
        let oldXML = try String(decoding: profile(expires: oldDate), as: UTF8.self)
        let renewedXML = try String(decoding: profile(expires: renewedDate), as: UTF8.self)

        let enteredSlow = DispatchSemaphore(value: 0)
        let releaseSlow = DispatchSemaphore(value: 0)
        let slowFinished = DispatchSemaphore(value: 0)
        let slowRunner = ScriptedRunner(xml: oldXML) {
            enteredSlow.signal()
            releaseSlow.wait()
            slowFinished.signal()
        }
        let fastRunner = ScriptedRunner(xml: renewedXML)

        let gameID = UUID()
        var game = LibraryGame(titleID: "0100CD801CE5E000", name: "Balatro")
        game.id = gameID
        game.iosAppPath = app.path
        game.installedDevice = "UDID-1"
        try Data("{}".utf8).write(to: app.appendingPathComponent("Info.plist"))

        let tracker = SignatureTracker()
        tracker.refresh(games: [game], runner: slowRunner)
        XCTAssertEqual(enteredSlow.wait(timeout: .now() + 5), .success)

        // Newer refresh after re-sign finishes first and publishes renewedDate.
        tracker.refresh(games: [game], runner: fastRunner)
        let deadline = Date().addingTimeInterval(5)
        while tracker.expiry[gameID] != renewedDate && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(tracker.expiry[gameID], renewedDate)

        // Now let the older in-flight security cms read finish and verify it does not overwrite renewedDate.
        releaseSlow.signal()
        XCTAssertEqual(slowFinished.wait(timeout: .now() + 5), .success)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(tracker.expiry[gameID], renewedDate, "older signature read must not overwrite newer expiry")

        // Clearing installed apps while a background read is in flight must keep expiry empty after the read finishes.
        let enteredClearRace = DispatchSemaphore(value: 0)
        let releaseClearRace = DispatchSemaphore(value: 0)
        let clearRaceRunner = ScriptedRunner(xml: oldXML) {
            enteredClearRace.signal()
            releaseClearRace.wait()
        }
        tracker.refresh(games: [game], runner: clearRaceRunner)
        XCTAssertEqual(enteredClearRace.wait(timeout: .now() + 5), .success)
        tracker.refresh(games: [], runner: fastRunner)
        XCTAssertEqual(tracker.expiry, [:])
        releaseClearRace.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(tracker.expiry, [:], "in-flight read before emptying apps must not repopulate expiry")
    }
}
