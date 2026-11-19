import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The build wizard's navigation, at the top of its content column (LauncherView.buildWizardBar), leaving the hero for game metadata.
struct BuildHeaderControls: View {
    @ObservedObject var build: BuildStore
    let onBack: () -> Void
    let onInstallExisting: () -> Void
    let onExport: () -> Void
    let onCancel: () -> Void
    @Binding var logOpen: Bool
    let onShowSteps: () -> Void
    var onEdit: () -> Void = {}
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.launcherDropdownHost) private var dropdowns
    @State private var menuID = UUID()

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) { Label(loc.t("nav.builds"), systemImage: "chevron.left") }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .padTarget("builds.back", scope: "main", activate: onBack)
            Button(action: openOptions) {
                Image(systemName: "ellipsis")
            }.buttonStyle(LauncherIconButtonStyle())
                .accessibilityLabel(loc.t("flow.options"))
                .anchorPreference(key: LauncherDropdownAnchorKey.self, value: .bounds) { [menuID: $0] }
                .padTarget("set.build.options", scope: "main", activate: openOptions)
        }
    }

    private func openOptions() {
        if build.running {
            dropdowns?.request = LauncherDropdownRequest(id: menuID,
                options: [("logs", loc.t(logOpen ? "log.hide" : "log.show")), ("steps", loc.t("prog.showAllSteps"))], selection: "", label: loc.t("flow.options")) { choice in
                    dropdowns?.close(); pad.scope = "main"
                    if pad.visible { pad.focused = "set.build.options" }
                    if choice == "logs" { logOpen.toggle() } else { onShowSteps() }
                }
            return
        }
        let resultOptions = build.completionStatus == nil ? [] : [("edit", loc.t("result.edit")), ("logs", loc.t(logOpen ? "log.hide" : "log.show")), ("steps", loc.t("prog.showAllSteps"))] + (build.canStartBuildOrQueue ? [("rebuild", loc.t("result.rebuild"))] : [])
        dropdowns?.request = LauncherDropdownRequest(id: menuID,
            options: resultOptions + [("folder", loc.t("flow.changeFolder")), ("keys", loc.t("flow.updateKeys")),
                      ("install", loc.t("flow.installExisting")), ("export", loc.t("shell.modeExport"))] + (build.done || build.completionStatus != nil ? [] : [("cancel", loc.t("flow.cancel"))]),
            selection: "", label: loc.t("flow.options"), destructiveValues: ["cancel"]) { choice in
                dropdowns?.close()
                pad.scope = "main"
                if pad.visible { pad.focused = "set.build.options" }
                switch choice {
                case "cancel": onCancel()
                case "edit": onEdit()
                case "logs": logOpen.toggle()
                case "steps": onShowSteps()
                case "rebuild": if build.canStartBuildOrQueue { build.startBuildOrQueue() }
                case "keys": build.pickFiles(kind: .keys)
                case "install": onEdit(); onInstallExisting()
                case "export": onEdit(); onExport()
                default: onEdit(); FilesCard.pickFolder(build)
                }
            }
    }
}
