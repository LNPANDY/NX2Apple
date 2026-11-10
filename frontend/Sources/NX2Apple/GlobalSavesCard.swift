import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Settings > Library > Cloud saves: the one-time setup for every game (#864), and the folder that holds every game's save (#1041).
/// A game's own choice, made in its options, wins over both and is shown there as its own.
struct GlobalSavesCard: View {
    @ObservedObject var settings: SaveSettingsStore
    var chooseFolder: (URL?) -> URL? = CloudSavesCard.openPanel
    var home = NSHomeDirectory()
    @EnvironmentObject var loc: Localizer

    private var global: SaveGlobalSettings { settings.global }

    var body: some View {
        let _ = settings.revision
        CardGroup(loc.t("savesloc.globalGroup"), footnote: loc.t("savesloc.globalNote")) {
            CardRow(loc.t("cloud.title"), detail: cloudDetail, dot: global.cloudOn ? LauncherPalette.ready : LauncherPalette.unbuilt) {
                Button(loc.t(global.cloudOn ? "cloud.turnOff" : "savesloc.useICloud")) { toggleCloud() }
                    .padTarget("saves.global.cloud", scope: "main") { toggleCloud() }
                Button(loc.t("cloud.choose")) { chooseCloud() }
                    .padTarget("saves.global.choose", scope: "main") { chooseCloud() }
            }
            CardDivider()
            CardRow(loc.t("savesloc.globalFolder"), detail: global.saveRoot.map(SaveLocationText.shown) ?? loc.t("savesloc.usual"), help: global.saveRoot ?? "") {
                Button(loc.t("savesloc.change")) { chooseRoot() }
                    .padTarget("saves.global.root", scope: "main") { chooseRoot() }
                if global.saveRoot != nil {
                    Button(loc.t("savesloc.reset")) { resetRoot() }
                        .accessibilityLabel(loc.t("savesloc.resetGlobal"))
                        .padTarget("saves.global.reset", scope: "main") { resetRoot() }
                }
            }
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
    }

    private var cloudDetail: String {
        guard global.cloudOn, let folder = global.cloudFolder else { return loc.t("cloud.off") }
        return CloudSavesCard.shown(CloudSaveSync.folder(for: folder, home: home) ?? folder, home: home)
    }

    /// Turning it on without a folder chosen yet uses iCloud Drive, the folder the iPhone shell offers too.
    private func toggleCloud() {
        var value = global
        if value.cloudOn { value.cloudOn = false }
        else { value.cloudOn = true; value.cloudFolder = value.cloudFolder ?? "icloud" }
        settings.setGlobal(value)
    }

    private func chooseCloud() {
        let start = global.cloudFolder.flatMap { CloudSaveSync.folder(for: $0, home: home) }.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: home + "/Library/Mobile Documents/com~apple~CloudDocs")
        guard let url = chooseFolder(start) else { return }
        var value = global
        value.cloudFolder = url.path
        value.cloudOn = true
        settings.setGlobal(value)
    }

    /// Only the folder for games from now on: a save already in its place is not moved (the game's own Change copies one).
    private func chooseRoot() {
        guard let url = chooseFolder(global.saveRoot.map { URL(fileURLWithPath: $0) }) else { return }
        if SaveLocationVolume.cannotHold(url.path) { return }
        var value = global
        value.saveRoot = url.path
        settings.setGlobal(value)
    }

    private func resetRoot() {
        var value = global
        value.saveRoot = nil
        settings.setGlobal(value)
    }
}

enum SaveLocationVolume {
    /// A folder on a volume that answers no to clone and folder swap (exFAT, HFS+, FAT) is not offered as a save folder.
    static func cannotHold(_ path: String) -> Bool { VolumeSaves.holdsSaves(at: path) == false }
}
