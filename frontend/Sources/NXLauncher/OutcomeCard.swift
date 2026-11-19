import SwiftUI
import NXCore
import NXModel

/// Terminal build results. Unfinished signing and transfer work remains in the existing follow-up controls.
package struct OutcomeCard: View {
    @ObservedObject var build: BuildStore
    @ObservedObject var devices: DeviceStore
    let onViewGame: () -> Void
    let onPlayGame: (() -> Void)?
    @EnvironmentObject var loc: Localizer
    @State private var trustGuideOpen: Bool
    @State private var openError: String?

    package init(build: BuildStore, devices: DeviceStore, onViewGame: @escaping () -> Void,
                 trustGuideInitiallyOpen: Bool = false, onPlayGame: (() -> Void)? = nil) {
        self.build = build; self.devices = devices; self.onViewGame = onViewGame
        self.onPlayGame = onPlayGame; _trustGuideOpen = State(initialValue: trustGuideInitiallyOpen)
    }
    package var body: some View {
        if let status = build.completionStatus {
            VStack(alignment: .leading, spacing: 16) {
                Text(loc.t(status == .exported ? "result.exportComplete" : status == .needsData ? "result.remaining" : "result.complete"))
                    .font(.manrope(30, .bold))
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        Image(systemName: status == .needsData ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 24)).foregroundStyle(status == .needsData ? LauncherPalette.building : LauncherPalette.ready)
                            .frame(width: 52, height: 52).background(LauncherPalette.ink(0.08), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verdict(status)).font(.manrope(16, .semibold))
                            if status == .exported { Text(build.completedFramework ? String(format: loc.t("shell.frameworkStep1Done"), build.exportedIPAText) : loc.t(build.completedOneGameIPA ? "result.oneGameIPA" : "result.sharedIPA")).font(.manrope(13)).foregroundStyle(.secondary) }
                            if status == .needsData { Text(loc.t("result.notReady")).font(.manrope(13)).foregroundStyle(.secondary) }
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { actions(status) }
                        VStack(alignment: .leading, spacing: 12) { actions(status) }
                    }
                    if status == .mac { artifact(build.macAppPath, id: "set.build.done.reveal") }
                    if status == .exported {
                        Text(URL(fileURLWithPath: build.exportedIPAPath).lastPathComponent).font(.manrope(13)).foregroundStyle(.secondary).help(build.exportedIPAPath)
                    } else if status != .mac && !build.archivePath.isEmpty { artifact(build.archivePath, id: "set.build.done.archive") }
                    if let openError { Text(openError).font(.manrope(13)).foregroundStyle(LauncherPalette.building).textSelection(.enabled) }
                    if build.needsReplaceOldImgReminder {
                        Divider()
                        replaceOldImgRow
                    }
                    if status == .installed || status == .needsData { guide }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
            }
        }
        if build.completionStatus == nil && build.done && build.runningTarget != BuildTarget.mac && build.needsReplaceOldImgReminder && build.installedOn.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                replaceOldImgRow
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
        }
    }

    @ViewBuilder private var replaceOldImgRow: some View {
        let imgName = build.updatedImgPath.isEmpty ? "romfs.img" : (build.updatedImgPath as NSString).lastPathComponent
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(LauncherPalette.building).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t("imgGuide.replaceOldImgTitle")).font(.manrope(13, .semibold))
                Text(String(format: loc.t("imgGuide.replaceOldImgBody"), imgName))
                    .font(.manrope(12.5)).foregroundStyle(LauncherPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !build.updatedImgPath.isEmpty {
                Button(loc.t("install.reveal")) { revealInFinder(build.updatedImgPath) }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .help(build.updatedImgPath)
                    .padTarget("set.build.done.replaceImg", scope: "main") { revealInFinder(build.updatedImgPath) }
            }
        }
    }
    private func verdict(_ status: BuildCompletionStatus) -> String {
        switch status {
        case .mac: return loc.t("library.ready")
        case .installed: return String(format: loc.t("dev.installed"), devices.deviceName(build.installedOn))
        case .exported: return loc.t(build.completedFramework ? "shell.ipaFramework" : "result.ipaExported")
        case .needsData: return loc.t("result.dataNeeded")
        }
    }
    @ViewBuilder private func actions(_ status: BuildCompletionStatus) -> some View {
        if status == .mac, let onPlayGame {
            Button(action: onPlayGame) { Label(loc.t("library.play"), systemImage: "play.fill").padding(.horizontal, 18).frame(height: LauncherControl.height) }
                .buttonStyle(LauncherActionButtonStyle())
                .padTarget("set.build.done.play", scope: "main", focusColor: LauncherPalette.onCream, activate: onPlayGame)
        }
        if status == .exported {
            Button { revealInFinder(build.exportedIPAPath) } label: { Text(loc.t("install.reveal")).font(.manrope(13, .semibold)).padding(.horizontal, 18).frame(height: LauncherControl.height) }.buttonStyle(LauncherActionButtonStyle())
                .padTarget("set.build.export.reveal", scope: "main", focusColor: LauncherPalette.onCream) { revealInFinder(build.exportedIPAPath) }
        }
        if status == .installed || status == .needsData {
            let button = Button(String(format: loc.t("dev.open"), devices.deviceName(build.installedOn)), action: openDevice)
            if status == .installed {
                Button(action: openDevice) { Text(String(format: loc.t("dev.open"), devices.deviceName(build.installedOn))).font(.manrope(13, .semibold)).padding(.horizontal, 18).frame(height: LauncherControl.height) }.buttonStyle(LauncherActionButtonStyle())
                    .padTarget("set.build.done.device", scope: "main", focusColor: LauncherPalette.onCream, activate: openDevice)
            } else {
                button.buttonStyle(LauncherSecondaryButtonStyle())
                    .padTarget("set.build.done.device", scope: "main", activate: openDevice)
            }
        }
        Button(loc.t("result.library"), action: onViewGame).buttonStyle(LauncherSecondaryButtonStyle())
            .padTarget("set.build.done.library", scope: "main", activate: onViewGame)
    }
    private func openDevice() {
        build.openOnDevice(udid: build.installedOn, app: build.installedAppPath) { if let error = $0 { openError = error } }
    }
    private func artifact(_ path: String, id: String) -> some View {
        VStack(spacing: 16) {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.manrope(13)).lineLimit(2).help(path)
                Spacer(minLength: 8)
                Button(loc.t("install.reveal")) { revealInFinder(path) }.buttonStyle(LauncherSecondaryButtonStyle())
                    .padTarget(id, scope: "main") { revealInFinder(path) }
            }
        }
    }
    private var guide: some View {
        VStack(spacing: 14) {
            Divider()
            CardDisclosure(loc.t("dev.firstInstallGuide.title"), isOpen: trustGuideOpen) { trustGuideOpen.toggle() }
                .padTarget("set.build.done.guide", scope: "main") { trustGuideOpen.toggle() }
            if trustGuideOpen {
                VStack(alignment: .leading, spacing: 14) {
                    guideStep("dev.firstInstallGuide.devModeTitle", "dev.firstInstallGuide.devModeBody")
                    guideStep("dev.firstInstallGuide.trustTitle", "dev.firstInstallGuide.trustBody")
                }.padding(.horizontal, 18)
            }
        }
    }
    private func guideStep(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loc.t(title)).font(.manrope(13, .semibold))
            Text(loc.t(body)).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
