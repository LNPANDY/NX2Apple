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
            // The success is in the header (the badge on the icon, "Built for Mac"): here only what comes next, without a card,
            // a heading or a tile that says it again (#1458). Then the files the build made, as rows.
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DS.Space.s) { actions(status) }
                        VStack(alignment: .leading, spacing: DS.Space.s) { actions(status) }
                    }
                    if let note = note(status) { DSRowMessageView(note) }
                    if let openError { DSRowMessageView(.error(openError)).textSelection(.enabled) }
                }
                let files = artifacts(status)
                if !files.isEmpty {
                    CardGroup(loc.t("result.files")) {
                        VStack(spacing: 0) {
                            ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                                if index > 0 { CardDivider() }
                                CardRow(URL(fileURLWithPath: file.path).lastPathComponent,
                                        detail: (file.path as NSString).deletingLastPathComponent, help: file.path) {
                                    Button(loc.t("install.reveal")) { revealInFinder(file.path) }.buttonStyle(DSRowButtonStyle())
                                        .padTarget(file.id, scope: "main") { revealInFinder(file.path) }
                                }
                            }
                        }
                    }
                }
                if build.needsReplaceOldImgReminder {
                    DSCard { replaceOldImgRow }
                }
                if status == .installed || status == .needsData {
                    CardGroup("") { guide }
                }
            }
        }
        if build.completionStatus == nil && build.done && build.runningTarget != BuildTarget.mac && build.needsReplaceOldImgReminder && build.installedOn.isEmpty {
            DSCard { replaceOldImgRow }
        }
    }

    @ViewBuilder private var replaceOldImgRow: some View {
        let isMSL = QueueEntryImgStatus.isMSLFallback(build.updatedImgPath)
        let imgName = build.updatedImgPath.isEmpty ? "romfs.img" : (build.updatedImgPath as NSString).lastPathComponent
        let titleText = isMSL ? loc.t("imgGuide.mslUpdateTitle") : loc.t("imgGuide.replaceOldImgTitle")
        let bodyText = isMSL ? loc.t("imgGuide.mslUpdateBody") : String(format: loc.t("imgGuide.replaceOldImgBody"), imgName)
        HStack(alignment: .top, spacing: DS.Space.s) {
            Circle().fill(LauncherPalette.building).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(titleText).font(DS.Font.bodyStrong)
                Text(bodyText)
                    .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.xs)
            if !build.updatedImgPath.isEmpty {
                Button(loc.t("install.reveal")) { revealInFinder(build.updatedImgPath) }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .help(build.updatedImgPath)
                    .padTarget("set.build.done.replaceImg", scope: "main") { revealInFinder(build.updatedImgPath) }
            }
        }
    }
    /// What the header cannot say: where an exported IPA goes next, or that data is still missing. Nil for a plain success.
    private func note(_ status: BuildCompletionStatus) -> DSRowMessage? {
        switch status {
        case .mac: return nil
        case .installed:
            let base = String(format: loc.t("dev.installed"), devices.deviceName(build.installedOn))
            let detail = build.shellUpdatedOnDevice
                ? base + "\n" + loc.t("shell.updatedShell")
                : base
            return .success(detail)
        case .exported:
            return .info(build.completedFramework ? String(format: loc.t("shell.frameworkStep1Done"), build.exportedIPAText)
                         : loc.t(build.completedOneGameIPA ? "result.oneGameIPA" : "result.sharedIPA"))
        case .needsData: return .warning(loc.t("result.notReady"))
        }
    }
    /// The files the build made: the Mac app, the exported IPA or the archive, each a row with Reveal in Finder.
    private func artifacts(_ status: BuildCompletionStatus) -> [(path: String, id: String)] {
        switch status {
        case .mac: return build.macAppPath.isEmpty ? [] : [(build.macAppPath, "set.build.done.reveal")]
        case .exported: return build.exportedIPAPath.isEmpty ? [] : [(build.exportedIPAPath, "set.build.export.reveal")]
        default: return build.archivePath.isEmpty ? [] : [(build.archivePath, "set.build.done.archive")]
        }
    }
    @ViewBuilder private func actions(_ status: BuildCompletionStatus) -> some View {
        if status == .mac, let onPlayGame {
            Button(action: onPlayGame) {
                Label(loc.t("library.play"), systemImage: "play.fill").font(DS.Font.bodyStrong).padding(.horizontal, DS.Space.m + DS.Space.xxs)
                    .frame(height: DS.Control.height)
            }
                .buttonStyle(LauncherActionButtonStyle())
                .padTarget("set.build.done.play", scope: "main", focusColor: LauncherPalette.onCream, activate: onPlayGame)
        }
        if status == .installed || status == .needsData {
            let button = Button(String(format: loc.t("dev.open"), devices.deviceName(build.installedOn)), action: openDevice)
            if status == .installed {
                Button(action: openDevice) { Text(String(format: loc.t("dev.open"), devices.deviceName(build.installedOn))).font(DS.Font.bodyStrong).padding(.horizontal, 18).frame(height: LauncherControl.height) }.buttonStyle(LauncherActionButtonStyle())
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
    @ViewBuilder private var guide: some View {
        CardDisclosure(loc.t("dev.firstInstallGuide.title"), isOpen: trustGuideOpen) { trustGuideOpen.toggle() }
            .padTarget("set.build.done.guide", scope: "main", radius: trustGuideOpen ? 0 : DS.Radius.card) { trustGuideOpen.toggle() }
        if trustGuideOpen {
            CardDivider()
            CardDisclosureBody {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    guideStep("dev.firstInstallGuide.devModeTitle", "dev.firstInstallGuide.devModeBody")
                    guideStep("dev.firstInstallGuide.trustTitle", "dev.firstInstallGuide.trustBody")
                }
            }
        }
    }
    private func guideStep(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(loc.t(title)).font(DS.Font.bodyStrong)
            Text(loc.t(body)).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
