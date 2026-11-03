import SwiftUI
import NXCore
import NXModel

/// Settings, "Controls": the key layout, the merge of all controllers into player 1, the controllers list and the console prompt.
/// It observes no store: the layout's numbers and switches come from the app as values and bindings.
package struct ControlsCard: View {
    let controlChanges: Int
    let padMerge: Binding<Bool>   // "All controllers are player 1" (ControlLayout.padMerge)
    let consolePrompt: Binding<Bool>
    let startInConsole: Binding<Bool>   // "Start in console mode" (#336)
    let onOpenControls: () -> Void
    let onOpenControllers: () -> Void   // the Controllers sheet (the console mode's list, with the player-mode setting)
    let onOpenHomeSettings: (() -> Void)?   // the system's Home button settings (#336): nil before macOS 27, where the Home button cannot quit a game
    @EnvironmentObject var loc: Localizer

    package init(controlChanges: Int, padMerge: Binding<Bool>, consolePrompt: Binding<Bool>,
                 startInConsole: Binding<Bool>, onOpenControls: @escaping () -> Void, onOpenControllers: @escaping () -> Void,
                 onOpenHomeSettings: (() -> Void)? = nil) {
        self.controlChanges = controlChanges
        self.padMerge = padMerge
        self.consolePrompt = consolePrompt
        self.startInConsole = startInConsole
        self.onOpenControls = onOpenControls
        self.onOpenControllers = onOpenControllers
        self.onOpenHomeSettings = onOpenHomeSettings
    }

    package var body: some View {
        CardGroup(loc.t("section.controls"), footnote: loc.t("controls.settingsHint")) {
            CardRow(loc.t("controls.row"), detail: controlChanges == 0 ? loc.t("controls.defaultLayout") : String(format: loc.t("controls.changes"), controlChanges)) {
                Button(loc.t("controls.customize"), action: onOpenControls)
                    .padTarget("set.controls", scope: "main") { onOpenControls() }
            }
            CardDivider()
            CardRow(loc.t("console.mergeAll"), detail: loc.t("console.mergeNote")) {
                Toggle("", isOn: padMerge).labelsHidden().toggleStyle(LauncherSwitchStyle())
                    .padTarget("set.padMerge", scope: "main") { padMerge.wrappedValue.toggle() }
            }
            CardDivider()
            CardRow(loc.t("console.controllers"), detail: loc.t("console.controllersRowNote")) {
                Button(loc.t("console.controllersOpen"), action: onOpenControllers)
                    .padTarget("set.controllers", scope: "main") { onOpenControllers() }
            }
            CardDivider()
            CardRow(loc.t("console.promptSetting"), detail: loc.t("console.promptSettingNote")) {
                Toggle("", isOn: consolePrompt).labelsHidden().toggleStyle(LauncherSwitchStyle())
                    .padTarget("set.consolePrompt", scope: "main") { consolePrompt.wrappedValue.toggle() }
            }
            CardDivider()
            CardRow(loc.t("console.startInConsole"), detail: loc.t("console.startInConsoleNote")) {
                Toggle("", isOn: startInConsole).labelsHidden().toggleStyle(LauncherSwitchStyle())
                    .padTarget("set.consoleStart", scope: "main") { startInConsole.wrappedValue.toggle() }
            }
            CardDivider()
            CardRow(loc.t("controls.homeQuit"), detail: loc.t(onOpenHomeSettings == nil ? "controls.homeQuitOld" : "controls.homeQuitNote")) {
                if let onOpenHomeSettings {
                    Button(loc.t("console.homeHint.open"), action: onOpenHomeSettings)
                        .padTarget("set.homeQuit", scope: "main") { onOpenHomeSettings() }
                }
            }
        }
    }
}
