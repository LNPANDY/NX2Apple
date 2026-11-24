import Foundation

/// One game's own IPA with its game data inside (LNPANDY/NX2Apple#540), the second kind of the export next to the shared app. It is
/// the engine's one-game app as build_ipa_from_nsp.py makes it without `--shell-framework`: the RomFS goes to `<App>/romfs` (or
/// `romfs.img`) and the add-on content to `<App>/aoc`, which the app reads when its Documents hold no image (dm/ios main.m). The
/// fork's build_ipa.sh leaves the game data out by default (patch 0004, the slim IPA), so `DM_FULL_ROMFS=1` asks for it. pack_ipa.py
/// writes zip64 records when a file, an offset or the count passes the 32-bit fields. The bundle ID is the script's default
/// without a team suffix, `org.nxnative.<title ID>`: its own app, apart from the shared app and its saves.
package enum OneGameIPA {
    /// `<folder>/<title ID>.ipa` for `nxnative`, or `<folder>/<title ID>-<engine>.ipa` for other engines.
    package static func path(folder: String, titleID: String, upstream: EngineUpstreamKind = .nxnative) -> String {
        let base = folder + "/" + titleID
        return upstream == .nxnative ? (base + ".ipa") : (base + "-\(upstream.rawValue).ipa")
    }

    /// Team-scoped bundle ID (`org.nxnative.<tid>.<teamID>` or `org.nxnative.<tid>.<variant>.<teamID>`)
    /// when driving an external `nxnative` fork without NX2Apple's private patches.
    package static func personalBundleID(titleID: String, teamID: String, upstream: EngineUpstreamKind = .nxnative) -> String? {
        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let team = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tid.isEmpty, !team.isEmpty, team != "0000000000" else { return nil }
        if upstream.isNxnativeVariant {
            return "org.nxnative.\(tid).\(upstream.rawValue).\(team)"
        }
        return "org.nxnative.\(tid).\(team)"
    }

    /// The script's arguments for the IPA, in place of the shared app's `--shell-framework`.
    package static func arguments(ipa: String, bundleID: String? = nil) -> [String] {
        var args = ["--platform", "ios", "--romfs", "bundle", "-o", ipa]
        if let bundleID, !bundleID.isEmpty {
            args += ["--bundle-id", bundleID]
        }
        return args
    }

    /// What build_ipa.sh needs to pack the game data into the IPA.
    package static let environment = ["DM_FULL_ROMFS": "1"]
}
