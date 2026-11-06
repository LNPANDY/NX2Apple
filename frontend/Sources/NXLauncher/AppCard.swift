import SwiftUI
import NXCore
import NXModel

/// Settings, "NX2Apple": the language, notifications, the guided setup, the self-update and the uninstaller. Observes the update
/// store. The two switches that live in the app's defaults come as bindings, and what the uninstaller needs from the library
/// and the build store as a closure.
package struct AppCard: View {
    @ObservedObject var updates: AppUpdateStore
    let buildRunning: Bool
    let notify: Binding<Bool>
    let notifyAvailable: Bool   // false without an app bundle, e.g. under swift run
    let returnAfterPlay: Binding<Bool>
    let onRunSetup: (() -> Void)?   // the guided first-run setup, again (nil where there is none)
    let uninstallPlan: () -> Uninstall.Plan
    @EnvironmentObject var loc: Localizer

    package init(updates: AppUpdateStore, buildRunning: Bool, notify: Binding<Bool>, notifyAvailable: Bool, returnAfterPlay: Binding<Bool>,
                 onRunSetup: (() -> Void)?, uninstallPlan: @escaping () -> Uninstall.Plan) {
        self.updates = updates
        self.buildRunning = buildRunning
        self.notify = notify
        self.notifyAvailable = notifyAvailable
        self.returnAfterPlay = returnAfterPlay
        self.onRunSetup = onRunSetup
        self.uninstallPlan = uninstallPlan
    }

    /// The language picker's choices in order, "" being the system's. The rest is the language files in `frontend/l10n`, each shown
    /// by its own name (`Lang.name`, from `_language`: Svenska, Deutsch), so a new language is a new file and nothing here.
    package static let languageCodes = languageCodes(among: LocalizationFiles.languages())

    package static func languageCodes(among languages: [LocalizationFiles.Language]) -> [String] { [""] + languages.map(\.code) }

    /// What the picker shows for a choice: "system" follows the UI language, a language shows its own name.
    private func languageLabel(_ code: String) -> String {
        code.isEmpty ? loc.t("settings.language.system") : (Lang.find(code)?.name ?? code)
    }

    package var body: some View {
        CardGroup(loc.t("section.app"), footnote: updates.status) {
            // The interface language: the device default unless someone picks one here. Stored as
            // "" (follow) or a language code so a later system-language change still applies.
            CardRow(loc.t("settings.language"),
                detail: languageLabel(Lang.saved?.code ?? ""), dot: LauncherPalette.ready, help: "") {
                // The launcher's own list, drawn like the buttons beside it and as wide as they are.
                // The language names are in their own language (from the files), only "system" follows the UI.
                LauncherDropdown(options: Self.languageCodes.map { (value: $0, label: languageLabel($0)) },
                                 selection: Lang.saved?.code ?? "", label: loc.t("settings.language"),
                                 style: .button) { v in
                    loc.choose(v)
                }
                .padTarget("set.language", scope: "main", activate: { cycleLanguage(1) }, adjust: { cycleLanguage($0) })
            }
            CardDivider()
            // Build notifications (BuildNotifications.swift): none without an app bundle, e.g. under swift run
            CardRow(loc.t("settings.notify"), detail: loc.t(notifyAvailable ? "settings.notifyNote" : "settings.notifyUnbundled")) {
                Toggle("", isOn: notify).toggleStyle(LauncherSwitchStyle()).labelsHidden().disabled(!notifyAvailable)
                    .padTarget("set.notify", scope: "main") { notify.wrappedValue.toggle() }
            }
            CardDivider()
            if let onRunSetup {
                CardRow(loc.t("settings.setup"), detail: loc.t("settings.setupNote")) {
                    Button(loc.t("settings.setupBtn"), action: onRunSetup)
                        .padTarget("set.setup", scope: "main") { onRunSetup() }
                }
                CardDivider()
            }
            // The launcher back in front when a game it started quits (ReturnAfterPlay.swift)
            CardRow(loc.t("settings.returnAfterPlay"), detail: loc.t("settings.returnAfterPlayNote")) {
                Toggle("", isOn: returnAfterPlay).toggleStyle(LauncherSwitchStyle()).labelsHidden()
                    .padTarget("set.returnAfterPlay", scope: "main") { returnAfterPlay.wrappedValue.toggle() }
            }
            CardDivider()
            CardRow("NX2Apple", detail: String(format: loc.t("app.version"), updates.version),
                dot: updates.staged != nil ? LauncherPalette.ready : nil) {
                if updates.busy { ProgressView().controlSize(.small) }
                if updates.staged != nil {
                    // Downloaded and verified: it goes in when the app quits; this restarts into it now (not during a build)
                    Button(loc.t("app.restartNow")) { updates.restartNow() }.disabled(buildRunning)
                        .padTarget("set.appRestart", scope: "main") { if !buildRunning { updates.restartNow() } }
                } else if let u = updates.update, updates.installability == .ok {
                    let label = updates.downloadProgress.map {
                        "\(Int((min(max($0, 0), 1) * 100).rounded()))%"
                    } ?? String(format: loc.t("app.updateBtn"), u.tag)
                    Button(label) { updates.performUpdate() }.disabled(updates.busy || buildRunning)
                        .padTarget("set.appUpdate", scope: "main") { if !(updates.busy || buildRunning) { updates.performUpdate() } }
                } else {
                    Button(loc.t("repo.check")) { updates.checkForUpdate() }.disabled(updates.busy)
                        .padTarget("set.appCheck", scope: "main") { if !updates.busy { updates.checkForUpdate() } }
                }
            }
            CardDivider()
            if updates.installability == .ok {
                // The uninstaller (Uninstall.swift): state folders and the launcher's own checkout go; the
                // games folder and prod.keys stay; the app itself goes to the Trash.
                CardRow(loc.t("uninstall.title"), detail: loc.t("uninstall.note")) {
                    Button(loc.t("uninstall.button")) { updates.uninstallPlan = uninstallPlan() }
                    .disabled(buildRunning)
                    .padTarget("set.uninstall", scope: "main") { if !buildRunning { updates.uninstallPlan = uninstallPlan() } }
                }
                CardDivider()
            }
            // A launcher built from the repository never replaces itself (AppUpdate.installability): the switch says so and stays off
            CardRow(loc.t("app.auto"), detail: loc.t(updates.installability == .ok ? "app.autoNote" : updates.installability == .developer ? "app.autoDev" : "app.autoReadOnly")) {
                Toggle("", isOn: Binding(get: { updates.automatic && updates.installability == .ok }, set: { updates.automatic = $0 }))
                    .labelsHidden().toggleStyle(LauncherSwitchStyle()).disabled(updates.installability != .ok)
                    .padTarget("set.appAuto", scope: "main") { if updates.installability == .ok { updates.automatic.toggle() } }
            }
        }
    }

    /// The interface language one step on (a controller's left / right on the language list).
    private func cycleLanguage(_ by: Int) {
        let values = Self.languageCodes
        let at = values.firstIndex(of: Lang.saved?.code ?? "") ?? 0
        let v = values[(at + by + values.count) % values.count]
        loc.choose(v)
    }
}
