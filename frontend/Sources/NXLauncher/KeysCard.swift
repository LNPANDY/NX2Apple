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
        CardGroup(loc.t("section.keys"), footnote: loc.t("keys.settingsHint")) {
            CardRow(loc.t("data.keys"), detail: detail, dot: path.isEmpty || missing ? LauncherPalette.unbuilt : LauncherPalette.ready, help: path) {
                if !path.isEmpty {
                    Button(loc.t("keys.remove")) { build.forgetSavedKeys() }.buttonStyle(.plain)
                        .font(.manrope(13)).foregroundStyle(.secondary)
                        .padTarget("set.keysRemove", scope: "main") { build.forgetSavedKeys() }
                }
                Button(loc.t(path.isEmpty ? "data.choose" : "data.change")) { build.chooseSavedKeys() }
                    .padTarget("set.keys", scope: "main") { build.chooseSavedKeys() }
            }
        }
    }
}
