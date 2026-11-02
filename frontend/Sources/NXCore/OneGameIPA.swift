import Foundation

/// One game's own IPA with its game data inside (LNPANDY/NX2Apple#540), the second kind of the export next to the shared app. It is
/// the engine's one-game app as build_ipa_from_nsp.py makes it without `--shell-framework`: the RomFS goes to `<App>/romfs` (or
/// `romfs.img`) and the add-on content to `<App>/aoc`, which the app reads when its Documents hold no image (dm/ios main.m). The
/// fork's build_ipa.sh leaves the game data out by default (patch 0004, the slim IPA), so `DM_FULL_ROMFS=1` asks for it. pack_ipa.py
/// writes zip64 records when a file, an offset or the count passes the 32-bit fields. The bundle ID is the script's default,
/// `org.nxnative.<title ID>`: its own app, apart from the shared app and its saves.
package enum OneGameIPA {
    /// `<folder>/<title ID>.ipa`, next to the game's build folder.
    package static func path(folder: String, titleID: String) -> String { folder + "/" + titleID + ".ipa" }

    /// The script's arguments for the IPA, in place of the shared app's `--shell-framework`.
    package static func arguments(ipa: String) -> [String] { ["--platform", "ios", "--romfs", "bundle", "-o", ipa] }

    /// What build_ipa.sh needs to pack the game data into the IPA.
    package static let environment = ["DM_FULL_ROMFS": "1"]
}
