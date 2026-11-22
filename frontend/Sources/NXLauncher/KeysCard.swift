import SwiftUI
import NXCore
import NXModel

/// Settings, "Keys" (LNPANDY/NX2Apple#996): the prod.keys chosen once for every game, with Choose and Remove. A build whose keys row
/// is empty, or names a file that is gone, takes this file. Choosing keys on the Builds page or in the guided setup saves them here
/// too. Observes the build store, which keeps the file (BuildStore+SavedKeys.swift).
package struct KeysCard: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer

    package init(build: BuildStore) { self.build = build }

    package var body: some View {
        let path = build.savedKeys
        let missing = !path.isEmpty && !build.savedKeysExist
        let detail = path.isEmpty ? loc.t("keys.unset") : missing ? String(format: loc.t("keys.missing"), build.shortPath(path)) : build.shortPath(path)
        // A DSRow as every Settings row (#1458): the status dot in the 20 pt slot (not chosen: warning, chosen: success, gone: error
        // with the row's message), Choose or Change in the control column, Remove in the "…" beside it. No icon tile.
        CardGroup(loc.t("section.keys")) {
            CardRow(loc.t("data.keys"), detail: missing ? "" : detail,
                    dot: path.isEmpty ? DSTone.warning.color : missing ? DSTone.error.color : DSTone.success.color,
                    help: path, info: ("set.keys.help", loc.t("keys.settingsHint")), message: missing ? .error(detail) : nil) {
                if !path.isEmpty {
                    DSOverflowMenu(label: loc.t("keys.remove"), options: [("remove", loc.t("keys.remove"))], padID: "set.keysRemove",
                                   destructiveValues: ["remove"]) { _ in build.forgetSavedKeys() }
                }
                Button(loc.t(path.isEmpty ? "data.choose" : "data.change")) { build.chooseSavedKeys() }
                    .buttonStyle(DSRowButtonStyle())
                    .padTarget("set.keys", scope: "main") { build.chooseSavedKeys() }
            }
        }
    }
}
