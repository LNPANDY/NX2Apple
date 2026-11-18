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
        CardGroup(loc.t("section.keys"), help: ("set.keys.help", loc.t("keys.settingsHint"))) {
            HStack(spacing: 14) {
                Image(systemName: build.savedKeysExist ? "key.fill" : "key.slash.fill")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(missing ? LauncherPalette.building : LauncherPalette.secondaryText)
                    .frame(width: 52, height: 52)
                    .background(LauncherPalette.ink(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t("data.keys")).font(.manrope(14, .semibold))
                    Text(detail).font(.manrope(12.5)).foregroundStyle(missing ? LauncherPalette.building : LauncherPalette.secondaryText)
                        .lineLimit(2).truncationMode(.middle).help(path)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    if !path.isEmpty {
                        Button(loc.t("keys.remove")) { build.forgetSavedKeys() }
                            .buttonStyle(LauncherSecondaryButtonStyle())
                            .padTarget("set.keysRemove", scope: "main") { build.forgetSavedKeys() }
                    }
                    Button(loc.t(path.isEmpty ? "data.choose" : "data.change")) { build.chooseSavedKeys() }
                        .buttonStyle(LauncherSecondaryButtonStyle())
                        .padTarget("set.keys", scope: "main") { build.chooseSavedKeys() }
                }
            }.padding(18)
        }
    }
}
