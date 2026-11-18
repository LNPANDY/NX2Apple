import AppKit
import SwiftUI
import NXCore
import NXModel

/// Settings, the app's own rows, in three parts the categories place (#678): `general` (language, appearance, notifications, return
/// after play), `updates` (the version, the self-update) and `maintenance` (the guided setup, the uninstaller, which Tools shows).
/// Observes the update store. The two switches that live in the app's defaults come as bindings, and what the uninstaller needs from the library
/// and the build store as a closure.
package struct AppCard: View {
    @ObservedObject var updates: AppUpdateStore
    let buildRunning: Bool
    let notify: Binding<Bool>
    let notifyAvailable: Bool   // false without an app bundle, e.g. under swift run
    let returnAfterPlay: Binding<Bool>
    let preflightAfterBuild: Binding<Bool>
    let onRunSetup: (() -> Void)?   // the guided first-run setup, again (nil where there is none)
    let uninstallPlan: () -> Uninstall.Plan
    let part: Part
    @AppStorage(LauncherAppearance.defaultsKey) private var appearance = LauncherAppearance.system.rawValue
    @AppStorage(GameDisplay.defaultsKey) private var gameDisplayUUID = ""
    @State private var screens = NSScreen.screens
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus

    package enum Part { case general, updates, maintenance }

    package init(updates: AppUpdateStore, buildRunning: Bool, notify: Binding<Bool>, notifyAvailable: Bool, returnAfterPlay: Binding<Bool>,
                 preflightAfterBuild: Binding<Bool>, onRunSetup: (() -> Void)?, uninstallPlan: @escaping () -> Uninstall.Plan, part: Part = .general) {
        self.part = part
        self.updates = updates
        self.buildRunning = buildRunning
        self.notify = notify
        self.notifyAvailable = notifyAvailable
        self.returnAfterPlay = returnAfterPlay
        self.preflightAfterBuild = preflightAfterBuild
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
        Group {
            switch part {
            case .general: general
            case .updates:
                updatesGroup.onChange(of: updates.phase) { phase in
                    guard let id = pad.focused, ["set.appCheck", "set.appUpdate", "set.appRestart"].contains(id) else { return }
                    pad.focused = phase == .checking ? "set.appCheck" : updates.busy ? "set.appUpdate" : updates.staged != nil ? "set.appRestart" : updates.update != nil && updates.installability == .ok ? "set.appUpdate" : "set.appCheck"
                }
            case .maintenance: maintenance
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }

    private var general: some View {
        CardGroup(loc.t("settings.general")) {
            // The interface language: the device default unless someone picks one here. Stored as
            // "" (follow) or a language code so a later system-language change still applies.
            CardRow(loc.t("settings.language"),
                detail: "", help: "") {
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
            CardRow(loc.t("settings.display"), info: ("set.display.help", loc.t("settings.display.help"))) {
                LauncherDropdown(options: displayOptions, selection: displaySelection,
                                 label: loc.t("settings.display"), style: .button) { gameDisplayUUID = $0 }
                    .padTarget("set.display", scope: "main", activate: { cycleDisplay(1) }, adjust: { cycleDisplay($0) })
            }
            CardDivider()
            // System, Light or Dark for the launcher's windows and sheets (LauncherAppearance)
            CardRow(loc.t("settings.appearance")) {
                LauncherSegmented(options: LauncherAppearance.allCases.map { ($0.rawValue, loc.t($0.labelKey)) }, selection: appearance) { appearance = $0 }
                    .compactFrame(minWidth: 276)
                    .accessibilityElement(children: .contain).accessibilityLabel(loc.t("settings.appearance"))
                    .padTarget("set.appearance", scope: "main", activate: { cycleAppearance(1) }, adjust: { cycleAppearance($0) })
            }
            CardDivider()
            // Build notifications (BuildNotifications.swift): none without an app bundle, e.g. under swift run
            CardRow(loc.t("settings.notify"), detail: loc.t(notifyAvailable ? "settings.notifyNote" : "settings.notifyUnbundled")) {
                Toggle(loc.t("settings.notify"), isOn: notify).toggleStyle(LauncherSwitchStyle()).labelsHidden().disabled(!notifyAvailable)
                    .padTarget("set.notify", scope: "main", enabled: notifyAvailable) { notify.wrappedValue.toggle() }
            }
            CardDivider()
            // The launcher back in front when a game it started quits (ReturnAfterPlay.swift)
            CardRow(loc.t("settings.returnAfterPlay"), info: ("set.returnAfterPlay.help", loc.t("settings.returnAfterPlayNote"))) {
                Toggle(loc.t("settings.returnAfterPlay"), isOn: returnAfterPlay).toggleStyle(LauncherSwitchStyle()).labelsHidden()
                    .padTarget("set.returnAfterPlay", scope: "main") { returnAfterPlay.wrappedValue.toggle() }
            }
            CardDivider()
            // A new Mac app's first start checked by macOS as the build's last stage (MacPreflight, #1005)
            CardRow(loc.t("settings.preflightAfterBuild"), detail: loc.t("settings.preflightAfterBuildNote")) {
                Toggle(loc.t("settings.preflightAfterBuild"), isOn: preflightAfterBuild).toggleStyle(LauncherSwitchStyle()).labelsHidden()
                    .padTarget("set.preflightAfterBuild", scope: "main") { preflightAfterBuild.wrappedValue.toggle() }
            }
        }
    }

    private var displayOptions: [(value: String, label: String)] {
        [(value: "", label: loc.t("settings.display.launcher"))] + screens.compactMap { screen in
            GameDisplay.uuid(of: screen).map { (value: $0, label: screen.localizedName) }
        }
    }
    private var displaySelection: String { displayOptions.contains { $0.value == gameDisplayUUID } ? gameDisplayUUID : "" }
    private func cycleDisplay(_ by: Int) {
        let options = displayOptions
        let index = options.firstIndex { $0.value == displaySelection } ?? 0
        gameDisplayUUID = options[(index + by + options.count) % options.count].value
    }

    private var updatesGroup: some View {
        CardGroup(loc.t("settings.updates")) {
            CardRow("NX2Apple", detail: String(format: loc.t("app.version"), updates.version),
                dot: updates.staged != nil ? LauncherPalette.ready : nil) {
                if updates.busy {
                    SettingsUpdateAction(updateBusyTitle, busy: true, action: {})
                        .padTarget(updates.phase == .checking ? "set.appCheck" : "set.appUpdate", scope: "main", activate: {})
                } else if updates.staged != nil {
                    // Downloaded and verified: it goes in when the app quits; this restarts into it now (not during a build)
                    SettingsUpdateAction(loc.t("app.restartNow"), prominent: true) { updates.restartNow() }.disabled(buildRunning)
                        .padTarget("set.appRestart", scope: "main", enabled: !buildRunning) { if !buildRunning { updates.restartNow() } }
                } else if updates.update != nil, updates.installability == .ok {
                    SettingsUpdateAction(loc.t(updates.retryAvailable ? "onboarding.retry" : "settings.update.install"), prominent: !updates.retryAvailable) { if updates.retryAvailable { updates.retryUpdate() } else { updates.performUpdate() } }.disabled(buildRunning)
                        .padTarget("set.appUpdate", scope: "main", enabled: !(updates.busy || buildRunning)) { if !(updates.busy || buildRunning) { if updates.retryAvailable { updates.retryUpdate() } else { updates.performUpdate() } } }
                } else {
                    SettingsUpdateAction(loc.t(updates.retryAvailable ? "onboarding.retry" : "repo.check")) { updates.checkForUpdate() }.disabled(updates.busy)
                        .padTarget("set.appCheck", scope: "main", enabled: !updates.busy) { if !updates.busy { updates.checkForUpdate() } }
                }
            }
            if !updates.busy && !updates.status.isEmpty { updateStatus(updates.status) }
            if buildRunning && (updates.staged != nil || updates.update != nil && updates.installability == .ok), updates.status != loc.t("app.waitForBuild") {
                updateStatus(loc.t("app.waitForBuild"))
            }
            CardDivider()
            // A launcher built from the repository never replaces itself (AppUpdate.installability): the switch says so and stays off
            CardRow(loc.t("app.auto"), detail: loc.t(updates.installability == .ok ? "app.autoNote" : updates.installability == .developer ? "app.autoDev" : "app.autoReadOnly")) {
                Toggle(loc.t("app.auto"), isOn: Binding(get: { updates.automatic && updates.installability == .ok }, set: { updates.automatic = $0 }))
                    .labelsHidden().toggleStyle(LauncherSwitchStyle()).disabled(updates.installability != .ok)
                    .padTarget("set.appAuto", scope: "main", enabled: updates.installability == .ok) { if updates.installability == .ok { updates.automatic.toggle() } }
            }
        }
    }

    private var updateBusyTitle: String {
        switch updates.phase {
        case .checking: return loc.t("settings.update.checking")
        case .preparing: return loc.t("settings.update.preparing")
        case .downloading:
            guard let value = updates.downloadProgress, value.isFinite else { return loc.t("settings.update.working") }
            return String(format: loc.t("settings.update.downloading"), Int((min(max(value, 0), 1) * 100).rounded()))
        case .idle: return loc.t("settings.update.working")
        }
    }
    private func updateStatus(_ text: String) -> some View {
        Text(text).font(.manrope(12.5)).foregroundStyle(updates.retryAvailable || updates.blocked != nil ? LauncherPalette.building : LauncherPalette.secondaryText)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 37).padding(.bottom, 14)
    }

    @ViewBuilder private var maintenance: some View {
        if let onRunSetup {
            CardGroup(loc.t("settings.setupGroup")) {
                CardRow(loc.t("settings.setup"), info: ("set.setup.help", loc.t("settings.setupNote"))) {
                    Button(loc.t("settings.setupBtn")) { onRunSetup() }
                        .padTarget("set.setup", scope: "main") { onRunSetup() }
                }
            }
        }
        if updates.installability == .ok {
            CardGroup(loc.t("settings.removalGroup")) {
                CardRow(loc.t("uninstall.title"), detail: loc.t("uninstall.note")) {
                    Button(loc.t("uninstall.button"), role: .destructive) { updates.uninstallPlan = uninstallPlan() }
                        .buttonStyle(LauncherSecondaryButtonStyle(accent: .red)).disabled(buildRunning)
                        .padTarget("set.uninstall", scope: "main", enabled: !buildRunning) { if !buildRunning { updates.uninstallPlan = uninstallPlan() } }
                }
            }
        }
    }

    private func cycleAppearance(_ by: Int) {
        let all = LauncherAppearance.allCases
        let at = all.firstIndex { $0.rawValue == appearance } ?? 0
        appearance = all[(at + by + all.count) % all.count].rawValue
    }

    /// The interface language one step on (a controller's left / right on the language list).
    private func cycleLanguage(_ by: Int) {
        let values = Self.languageCodes
        let at = values.firstIndex(of: Lang.saved?.code ?? "") ?? 0
        let v = values[(at + by + values.count) % values.count]
        loc.choose(v)
    }
}
