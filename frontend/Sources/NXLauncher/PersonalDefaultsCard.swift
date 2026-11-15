import SwiftUI
import NXCore
import NXModel

/// Settings, General, "Defaults for new games" (#680): the usual game language, display mode and rumble. They go into a game the
/// library adds from now on, once, and never over a choice a game has. Nothing here changes a game that is already in the library.
package struct PersonalDefaultsCard: View {
    @State private var personal: PersonalDefaults
    private let defaults: UserDefaults
    @EnvironmentObject var loc: Localizer

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _personal = State(initialValue: PersonalDefaults.load(defaults))
    }

    private func languageLabel(_ code: String) -> String {
        guard !code.isEmpty else { return loc.t("settings.language.system") }
        let key = "launch.opt.DM_LANG." + code
        let text = loc.t(key)
        return text == key ? (RomFSLanguages.table.first { $0.code == code }?.label ?? code) : text
    }

    private var languageOptions: [(value: String, label: String)] {
        var options: [(value: String, label: String)] = [(value: "", label: languageLabel(""))]
        for language in RomFSLanguages.table { options.append((value: language.code, label: languageLabel(language.code))) }
        return options
    }

    private func store(_ value: String, _ env: String) {
        personal.set(value, for: env)
        personal.save(defaults)
    }

    package var body: some View {
        CardGroup(loc.t("defaults.title"), footnote: loc.t("defaults.note")) {
            CardRow(loc.t("launch.set.DM_LANG")) {
                LauncherDropdown(options: languageOptions,
                                 selection: personal.value(for: "DM_LANG") ?? "", label: loc.t("launch.set.DM_LANG"), style: .button) { store($0, "DM_LANG") }
                    .padTarget("set.defaultLanguage", scope: "main")
            }
            CardDivider()
            CardRow(loc.t("launch.set.DM_FULLSCREEN")) {
                LauncherSegmented(options: [("", loc.t("launch.display.window")), ("1", loc.t("launch.display.fullscreen"))],
                                  selection: personal.value(for: "DM_FULLSCREEN") ?? "") { store($0, "DM_FULLSCREEN") }
                    .compactFrame(minWidth: LauncherControl.width)
                    .accessibilityElement(children: .contain).accessibilityLabel(loc.t("launch.set.DM_FULLSCREEN"))
                    .padTarget("set.defaultDisplay", scope: "main",
                               activate: { store(personal.value(for: "DM_FULLSCREEN") == nil ? "1" : "", "DM_FULLSCREEN") },
                               adjust: { store($0 > 0 ? "1" : "", "DM_FULLSCREEN") })
            }
            CardDivider()
            // On is the tested default, so only "off" is a personal choice
            CardRow(loc.t("launch.set.DM_RUMBLE")) {
                Toggle(loc.t("launch.set.DM_RUMBLE"), isOn: Binding(get: { personal.value(for: "DM_RUMBLE") != "0" },
                                                                  set: { store($0 ? "" : "0", "DM_RUMBLE") }))
                    .labelsHidden().toggleStyle(LauncherSwitchStyle())
                    .padTarget("set.defaultRumble", scope: "main") { store(personal.value(for: "DM_RUMBLE") == "0" ? "" : "0", "DM_RUMBLE") }
            }
            if !personal.isEmpty {
                CardDivider()
                // Clears these three choices. A game's own settings and its "Reset to tested defaults" are separate things.
                CardRow(loc.t("defaults.resetRow"), detail: loc.t("defaults.resetNote")) {
                    Button(loc.t("defaults.reset")) { personal.reset(); personal.save(defaults) }
                        .accessibilityLabel(loc.t("defaults.resetRow"))
                        .padTarget("set.defaultsReset", scope: "main") { personal.reset(); personal.save(defaults) }
                }
            }
        }
    }
}

/// Settings, General, first row when a tool the build needs is missing: one attention line that opens Tools at the dependency rows.
package struct MissingToolRow: View {
    @ObservedObject var dependencies: DependencyStore
    let showTools: () -> Void
    @EnvironmentObject var loc: Localizer

    package init(dependencies: DependencyStore, showTools: @escaping () -> Void) { self.dependencies = dependencies; self.showTools = showTools }

    package var body: some View {
        if dependencies.checked && !dependencies.allPresent {
            VStack(spacing: 0) {
                CardRow(loc.t("settings.toolMissing"), dot: LauncherPalette.building) {
                    Button(loc.t("settings.showTools"), action: showTools)
                        .padTarget("set.showTools", scope: "main") { showTools() }
                }
            }
            .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.building.opacity(0.6)))
        }
    }
}
