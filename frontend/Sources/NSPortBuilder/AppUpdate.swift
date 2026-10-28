import Foundation
import CryptoKit

// The launcher's self-update, the parts that decide what may be installed and when. BuildModel drives it
// (checkAppUpdate, stageAppUpdate, installStagedUpdate); everything here works on paths it is given, so the
// tests run it on bundles in a temporary folder, never on the running app or the network.
//
// The rules:
//   - What is installed is what GitHub says the release is: the zip's SHA-256 matches the asset's `digest`
//     ("sha256:<hex>", in the release API since 2025), and the app inside it carries the running app's bundle
//     identifier, an executable and the release's version. An automatic install also needs the digest to be
//     there; the Update button, pressed by hand, still installs a release without one (older releases have none).
//   - Only a released copy replaces itself: a launcher built from the repository (swift run, a bundle assembled in
//     frontend/, an Xcode build) keeps the developer's build in place.
//   - Never while a build runs: the swap ends with a relaunch (exit), and a build is a process group of the app's.

enum AppUpdate {
    /// The latest release, as the check found it.
    struct Release: Equatable {
        let tag: String
        let url: String
        let digest: String?   // "sha256:<hex>"; nil when the API gave none
        /// The release body, shown by the update sheet before anything is downloaded: "a new version
        /// is out" alone told a user nothing about what they would get.
        var notes: String = ""
    }

    /// A release downloaded, verified and unpacked, waiting to be swapped in.
    struct Staged: Equatable {
        let release: Release
        let app: URL
    }

    // ---- What was downloaded ----

    enum DigestCheck: Equatable { case match, mismatch, missing }

    /// The SHA-256 of a file, as lowercase hex, read in pieces (the zip is tens of megabytes).
    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The file against the asset's digest. A digest in any other algorithm, or none, counts as missing: there is
    /// nothing to compare with, which an automatic install refuses.
    static func checkDigest(_ file: URL, expected: String?) -> DigestCheck {
        guard let expected, expected.lowercased().hasPrefix("sha256:") else { return .missing }
        let want = expected.dropFirst("sha256:".count).trimmingCharacters(in: .whitespaces).lowercased()
        guard want.count == 64, let have = sha256(of: file) else { return want.isEmpty ? .missing : .mismatch }
        return have == want ? .match : .mismatch
    }

    enum BundleProblem: Error, Equatable { case noInfo, wrongIdentifier, noExecutable, wrongVersion }

    /// Whether `app` is an NX2Apple launcher of the release `tag`: the running app's bundle identifier (a zip of
    /// something else must not take its place), an executable where its Info.plist says, and the release's version
    /// (the release workflow writes the tag into the plist; another number would be a different build).
    static func bundleProblem(_ app: URL, expectedID: String, tag: String) -> BundleProblem? {
        let contents = app.appendingPathComponent("Contents")
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return .noInfo }
        guard !expectedID.isEmpty, info["CFBundleIdentifier"] as? String == expectedID else { return .wrongIdentifier }
        guard let exe = info["CFBundleExecutable"] as? String, !exe.isEmpty, !exe.contains("/"),
              FileManager.default.isExecutableFile(atPath: contents.appendingPathComponent("MacOS/" + exe).path)
        else { return .noExecutable }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard info["CFBundleShortVersionString"] as? String == version else { return .wrongVersion }
        return nil
    }

    // ---- What the running macOS can open ----

    /// "26.6" or "26.6.1" as an OS version; nil for anything else.
    static func parseOSVersion(_ s: String) -> OperatingSystemVersion? {
        let n = s.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(n.count), n.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return OperatingSystemVersion(majorVersion: n[0]!, minorVersion: n.count > 1 ? n[1]! : 0, patchVersion: n.count > 2 ? n[2]! : 0)
    }

    /// `a` is older than `b`, field by field (major, minor, patch).
    static func isOlder(_ a: OperatingSystemVersion, than b: OperatingSystemVersion) -> Bool {
        (a.majorVersion, a.minorVersion, a.patchVersion) < (b.majorVersion, b.minorVersion, b.patchVersion)
    }

    static func describe(_ v: OperatingSystemVersion) -> String {
        v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The staged app's `LSMinimumSystemVersion`, as written ("26.6"), when it is above `running`: the release cannot be
    /// opened on this Mac, so it must not replace the launcher that can. nil when it opens here, or names no minimum
    /// (macOS then applies none) or one that cannot be read (the release workflow writes it; an unreadable value is
    /// not a reason to keep a Mac from updating).
    static func minimumOSAbove(_ running: OperatingSystemVersion, app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let text = info["LSMinimumSystemVersion"] as? String, let min = parseOSVersion(text)
        else { return nil }
        return isOlder(running, than: min) ? describe(min) : nil
    }

    // ---- What may replace itself ----

    enum Installability: Equatable {
        case ok
        case developer   // built from the repository: never replaces itself
        case readOnly    // a released copy that cannot be replaced where it is (translocated, or a folder without write access)
    }

    /// Whether the launcher at `bundle` may replace itself. A released copy is an `.app` whose Info.plist has a bundle
    /// identifier and, as its version, this binary's own release number (the release workflow stops when the two
    /// differ), and which is not where a developer's build sits: in SwiftPM's .build, Xcode's DerivedData, or beside
    /// the Package.swift it was built from (frontend/NX2Apple.app, which the README's own recipe makes). `swift run`
    /// runs a bare executable with no bundle at all.
    static func installability(_ bundle: URL, appVersion: String) -> Installability {
        let path = bundle.standardizedFileURL.path
        guard bundle.pathExtension == "app" else { return .developer }
        let parts = bundle.standardizedFileURL.pathComponents
        if parts.contains(".build") || parts.contains("DerivedData") { return .developer }
        let parent = bundle.standardizedFileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.appendingPathComponent("Package.swift").path) { return .developer }
        guard isReleaseVersion(appVersion),
              let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String, !id.isEmpty,
              info["CFBundleShortVersionString"] as? String == appVersion
        else { return .developer }
        // Gatekeeper runs a quarantined app opened from Downloads from a read-only copy: the swap cannot reach the real one
        if path.contains("/AppTranslocation/") { return .readOnly }
        if !FileManager.default.isWritableFile(atPath: parent.path) { return .readOnly }
        return .ok
    }

    /// "1.2.3": digits and dots, nothing else (a dev build might say "dev", "0.0.0-local" or nothing).
    static func isReleaseVersion(_ v: String) -> Bool {
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    // ---- When ----

    enum InstallError: Error, Equatable { case buildRunning, failed(String) }

    /// Swap `staged` in at `current`: copied in beside it first (from there on every step stays on one volume), then
    /// exchanged with it in one replace, so a failure anywhere leaves a working app at `current`. The old bundle goes
    /// to the Trash (`trashOld`; the tests remove it instead), and the new one loses the quarantine flag, so its first
    /// launch shows no Gatekeeper prompt (the release is ad-hoc signed, not notarized).
    ///
    /// Refused while a build runs: the caller relaunches (or the app is quitting), and either ends the build's process group.
    /// Where the staged release goes: its own bundle name when it differs from the running copy's,
    /// else the current URL.
    ///
    /// The two-name case is a rename era (nxnative → NS Port Builder → NX2Apple). Replacing in place
    /// would keep the old folder's name for ever: the app inside is the new version, but the
    /// Finder, the Dock and /Applications keep saying the old name, which read as "the update did
    /// not happen" (a 0.4.6 install updated to 0.4.8 and still saw NS Port Builder). Under the new
    /// name the old bundle is removed; the Dock entry pointing at it goes stale once, which a log
    /// line names — the alternative was the old name for ever.
    static func installTarget(for staged: URL, current: URL) -> URL {
        staged.lastPathComponent == current.lastPathComponent
            ? current
            : current.deletingLastPathComponent().appendingPathComponent(staged.lastPathComponent)
    }

    /// Install the staged app and return where it ended up (the caller relaunches that path).
    static func install(_ staged: URL, over current: URL, buildRunning: Bool, trashOld: Bool = true) throws -> URL {
        guard !buildRunning else { throw InstallError.buildRunning }
        let fm = FileManager.default
        let dir = current.deletingLastPathComponent()
        let target = installTarget(for: staged, current: current)
        if target != current {
            // A rename: place the staged bundle under its own name, then retire the old-named one.
            // The running copy is trashed last — on macOS a running executable survives the removal
            // of its bundle (the kernel holds the vnode), and the quit-time path runs this as the
            // app is exiting anyway.
            try? fm.removeItem(at: target)
            try fm.copyItem(at: staged, to: target)
            clearQuarantine(target)
            if trashOld { try? fm.trashItem(at: current, resultingItemURL: nil) }
            return target
        }
        let name = current.deletingPathExtension().lastPathComponent
        let incoming = dir.appendingPathComponent(name + " (new).app")
        let backupName = name + " (old).app"
        try? fm.removeItem(at: incoming)
        try? fm.removeItem(at: dir.appendingPathComponent(backupName))
        do {
            try fm.copyItem(at: staged, to: incoming)
            let placed = try fm.replaceItemAt(current, withItemAt: incoming, backupItemName: backupName, options: [.withoutDeletingBackupItem])
            let backup = dir.appendingPathComponent(backupName)
            if fm.fileExists(atPath: backup.path) {
                if trashOld { try? fm.trashItem(at: backup, resultingItemURL: nil) } else { try? fm.removeItem(at: backup) }
            }
            clearQuarantine(placed ?? current)
            return current
        } catch {
            try? fm.removeItem(at: incoming)
            throw InstallError.failed(error.localizedDescription)
        }
    }

    private static func clearQuarantine(_ app: URL) {
        let x = Process()
        x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        x.arguments = ["-dr", "com.apple.quarantine", app.path]
        try? x.run(); x.waitUntilExit()
    }
}
