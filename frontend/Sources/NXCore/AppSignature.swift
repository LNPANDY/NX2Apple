import Foundation

/// The provisioning profile an installed app was signed with, and when it expires: a free Apple ID's profile lasts 7
/// days, so a game installed with one stops starting unless the same app is signed again. The launcher can only tell
/// when to re-sign if it reads that date from the app the signature is in.
///
/// An App Store or paid-team profile lives a year, so the date is usually far away and nothing is shown as urgent.
package enum AppSignature {
    package static let profileName = "embedded.mobileprovision"

    /// `ExpirationDate` of the app's embedded.mobileprovision, read from the profile's embedded XML plist (or through
    /// `security cms -D` as a fallback); nil when the app carries no profile or it cannot be read.
    package static func expiration(ofApp app: String, runner: ProcessRunner = SystemProcessRunner()) -> Date? {
        let profile = app + "/" + profileName
        return plist(ofProfile: profile, runner: runner)?["ExpirationDate"] as? Date
    }

    /// The profile expiries of several installed games (`(id, iosAppPath)`), reading each distinct app bundle once so a
    /// shared `DmShell.app` runs `security cms` once and gives every game in the shell the same date.
    package static func expirations(ofApps apps: [(UUID, String)], runner: ProcessRunner = SystemProcessRunner()) -> [UUID: Date] {
        var byPath: [String: Date?] = [:]
        var found: [UUID: Date] = [:]
        for (id, path) in apps {
            let date: Date?
            if let cached = byPath[path] { date = cached }
            else {
                date = expiration(ofApp: path, runner: runner)
                byPath[path] = date
            }
            if let date { found[id] = date }
        }
        return found
    }

    /// The profile plist's ExpirationDate. Split out so the parse is tested without a signed app.
    package static func expiration(fromProfile data: Data) -> Date? {
        plist(fromProfile: data)?["ExpirationDate"] as? Date
    }

    /// Decodes the property list of a provisioning profile, whether `data` is already the decoded XML plist (`security cms -D`)
    /// or the raw CMS-wrapped `.mobileprovision` file containing an embedded `<?xml ... </plist>` payload.
    package static func plist(fromProfile data: Data) -> [String: Any]? {
        if let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            return dict
        }
        let xmlStart = Data("<?xml".utf8), xmlEnd = Data("</plist>".utf8)
        guard let start = data.range(of: xmlStart),
              let end = data.range(of: xmlEnd, in: start.lowerBound..<data.endIndex) else { return nil }
        let slice = data.subdata(in: start.lowerBound..<end.upperBound)
        return (try? PropertyListSerialization.propertyList(from: slice, options: [], format: nil)) as? [String: Any]
    }

    /// Reads the property list of a `.mobileprovision` file on disk, falling back to `security cms -D` when needed.
    package static func plist(ofProfile path: String, runner: ProcessRunner = SystemProcessRunner()) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let dict = plist(fromProfile: data) {
            return dict
        }
        guard let out = runner.output("/usr/bin/security", ["cms", "-D", "-i", path]) else { return nil }
        return plist(fromProfile: Data(out.utf8))
    }

    /// Directories where Xcode caches downloaded team provisioning profiles.
    package static func profileDirectories(home: String = NSHomeDirectory()) -> [String] {
        [
            home + "/Library/Developer/Xcode/UserData/Provisioning Profiles",
            home + "/Library/MobileDevice/Provisioning Profiles",
        ]
    }

    /// Whether a cached provisioning profile plist belongs to the app being re-signed (`bundleID` / `team` or the app's current profile UUID).
    package static func profileMatches(_ plist: [String: Any], bundleID: String, team: String, embeddedUUID: String? = nil) -> Bool {
        if let uuid = plist["UUID"] as? String, !uuid.isEmpty, uuid == embeddedUUID { return true }
        guard !bundleID.isEmpty else { return false }
        let profileTeams = (plist["TeamIdentifier"] as? [String]) ?? []
        if !team.isEmpty {
            guard profileTeams.contains(team) else { return false }
        }
        let suffix = ".\(team)"
        let base = (!team.isEmpty && bundleID.hasSuffix(suffix))
            ? String(bundleID.dropLast(suffix.count))
            : bundleID
        let candidates: Set<String> = team.isEmpty ? [bundleID] : [base, "\(base).\(team)"]
        let teamsToCheck = !team.isEmpty ? [team] : profileTeams
        guard let entitlements = plist["Entitlements"] as? [String: Any],
              let appID = entitlements["application-identifier"] as? String else {
            return false
        }
        for candidate in candidates {
            if teamsToCheck.isEmpty, appID == candidate { return true }
            for t in teamsToCheck where appID == "\(t).\(candidate)" { return true }
        }
        return false
    }

    /// Holds cached `.mobileprovision` files moved aside before `xcodebuild -allowProvisioningUpdates` so Xcode requests a fresh 7-day
    /// profile from Apple instead of reusing a still-unexpired local profile. Restores them automatically if signing fails or stops.
    package final class StagedProfiles: @unchecked Sendable {
        private let app: String
        private let directory: URL
        private let moved: [(original: String, staged: String)]
        private var settled = false

        init(app: String, directory: URL, moved: [(original: String, staged: String)]) {
            self.app = app
            self.directory = directory
            self.moved = moved
        }

        deinit {
            if !settled { rollback() }
        }

        /// Call as soon as `xcodebuild` succeeds: discards the old cached profiles once `DmShell.app` has its newly signed binary,
        /// `embedded.mobileprovision` and `_CodeSignature` (or restores the staged ones in test stand-ins that do not write new ones).
        /// Committing before `devicectl install` ensures a later install failure never overwrites the newly signed Mach-O binary's
        /// matching profile and `_CodeSignature` with the old ones.
        package func commit() {
            guard !settled else { return }
            settled = true
            let fm = FileManager.default
            for path in [app + "/" + AppSignature.profileName, app + "/_CodeSignature"] {
                if !fm.fileExists(atPath: path),
                   let saved = moved.first(where: { $0.original == path }) {
                    try? fm.moveItem(atPath: saved.staged, toPath: saved.original)
                }
            }
            try? fm.removeItem(at: directory)
        }

        /// Call when `xcodebuild` itself fails or is stopped before signing completes: puts every staged profile and `_CodeSignature`
        /// back where it was so a failed signing step never loses the existing working signature on disk.
        package func rollback() {
            guard !settled else { return }
            settled = true
            let fm = FileManager.default
            for item in moved {
                guard fm.fileExists(atPath: item.staged) else { continue }
                try? fm.createDirectory(atPath: (item.original as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                if fm.fileExists(atPath: item.original) {
                    try? fm.removeItem(atPath: item.original)
                }
                try? fm.moveItem(atPath: item.staged, toPath: item.original)
            }
            try? fm.removeItem(at: directory)
        }
    }

    /// Moves the app's `embedded.mobileprovision`, `_CodeSignature`, and any matching cached `.mobileprovision` files in Xcode's
    /// profile directories into a temporary staging folder so `xcodebuild -allowProvisioningUpdates` requests and embeds a fresh
    /// 7-day provisioning profile rather than keeping a cached profile that has not expired yet.
    package static func stageProfilesForResign(app: String, bundleID: String, team: String, home: String = NSHomeDirectory(),
                                               runner: ProcessRunner = SystemProcessRunner()) -> StagedProfiles {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("nspb-resign-profiles-" + UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var moved: [(original: String, staged: String)] = []

        let embedded = app + "/" + profileName
        let embeddedUUID = plist(ofProfile: embedded, runner: runner)?["UUID"] as? String
        if fm.fileExists(atPath: embedded) {
            let dest = staging.appendingPathComponent("embedded.mobileprovision").path
            if (try? fm.moveItem(atPath: embedded, toPath: dest)) != nil {
                moved.append((original: embedded, staged: dest))
            }
        }
        let codeSig = app + "/_CodeSignature"
        if fm.fileExists(atPath: codeSig) {
            let dest = staging.appendingPathComponent("_CodeSignature").path
            if (try? fm.moveItem(atPath: codeSig, toPath: dest)) != nil {
                moved.append((original: codeSig, staged: dest))
            }
        }

        for (dirIndex, dir) in profileDirectories(home: home).enumerated() {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".mobileprovision") || name.hasSuffix(".provisionprofile") {
                let full = dir + "/" + name
                guard let dict = plist(ofProfile: full, runner: runner),
                      profileMatches(dict, bundleID: bundleID, team: team, embeddedUUID: embeddedUUID) else { continue }
                let dest = staging.appendingPathComponent("\(dirIndex)-\(name)").path
                if (try? fm.moveItem(atPath: full, toPath: dest)) != nil {
                    moved.append((original: full, staged: dest))
                }
            }
        }
        return StagedProfiles(app: app, directory: staging, moved: moved)
    }

    /// Whole days from today to the date, counted in calendar days (0 = today, negative = past): the day the profile
    /// stops working is the day iOS refuses to start the app, not 24 hours after the last start.
    package static func daysLeft(to date: Date, now: Date = Date()) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// Two days or fewer: re-sign before the next game session rather than after the game stops starting.
    package static func isUrgent(_ date: Date, now: Date = Date()) -> Bool { daysLeft(to: date, now: now) <= 2 }

    /// The hero's line: the date and the days left, in the app's language.
    package static func describe(_ date: Date, _ t: (String) -> String, now: Date = Date(), locale: Locale = .current) -> String {
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

    /// When a free Apple ID hits the 10-App-ID rolling 7-day cap and all 10 active 7-day App IDs for `team` are cached on this
    /// Mac, returns the formatted date on which the oldest one expires; nil when fewer than 10 distinct App IDs are present locally.
    package static func oldestFreeAppIDExpiry(forTeam team: String, lang: Lang = .en, home: String = NSHomeDirectory(),
                                              now: Date = Date(), runner: ProcessRunner = SystemProcessRunner()) -> String? {
        guard !team.isEmpty else { return nil }
        let fm = FileManager.default
        let nowRef = now.timeIntervalSinceReferenceDate
        var byAppID: [String: Date] = [:]
        for dir in profileDirectories(home: home) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".mobileprovision") || name.hasSuffix(".provisionprofile") {
                guard let dict = plist(ofProfile: dir + "/" + name, runner: runner),
                      let teams = dict["TeamIdentifier"] as? [String], teams.contains(team),
                      let exp = dict["ExpirationDate"] as? Date,
                      exp.timeIntervalSinceReferenceDate > nowRef,
                      let entitlements = dict["Entitlements"] as? [String: Any],
                      let appID = entitlements["application-identifier"] as? String,
                      !appID.isEmpty, !appID.hasSuffix(".*") else { continue }
                if let created = dict["CreationDate"] as? Date {
                    let span = exp.timeIntervalSince(created)
                    guard span >= 3 * 86_400 && span <= 8 * 86_400 else { continue }
                }
                if let existing = byAppID[appID] {
                    if exp.timeIntervalSinceReferenceDate < existing.timeIntervalSinceReferenceDate { byAppID[appID] = exp }
                } else {
                    byAppID[appID] = exp
                }
            }
        }
        guard byAppID.count >= 10,
              let oldest = byAppID.values.min(by: { $0.timeIntervalSinceReferenceDate < $1.timeIntervalSinceReferenceDate }) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: lang.code)
        return formatter.string(from: oldest)
    }
}
