import CoreText
import SwiftUI
import NXCore
import NXModel

/// The export of the shared app as an IPA, in three steps (LNPANDY/NX2Apple#416): export it, install it with another tool, send the
/// game data. Shown by the Install card when its switch says "Export as IPA". One game's own IPA (#540) holds its game data, so it has
/// the first two steps only. Observes the build store (the steps' state) and the
/// device store (the device and the place the data goes to).
///
/// The grid (ExportGrid): a step's number sits where a card row's dot sits, and everything that belongs to the step (its title, text,
/// controls, progress and notes) starts on one axis to the right of it. Each step has at most one action, a row button in the card's
/// right column, so the actions of all steps end on one edge. A control and its own small button (the device and Refresh, the folder
/// and Choose folder) form one group that fills the room up to the action.
package struct ExportSteps: View {
    @ObservedObject var build: BuildStore
    @ObservedObject var devices: DeviceStore
    @EnvironmentObject var loc: Localizer
    @State private var detailsOpen = false
    @State private var selectSheetMode: SendSelectedSheet.Mode?

    let resultOnly: Bool

    package init(build: BuildStore, devices: DeviceStore, resultOnly: Bool = false) {
        self.resultOnly = resultOnly
        self.build = build
        self.devices = devices
    }

    private var exported: Bool { !build.exportedIPAPath.isEmpty }
    private var sentDone: Bool {
        switch build.send { case .sent, .copied: return true; default: return false }
    }
    private var copying: Bool { if case .copying = build.send { return true } else { return false } }
    /// Step 3 waits for step 1: until the IPA exists its controls are shown, but all of them quieter and inert.
    private var inert: Bool { !exported && !sentDone && !(resultOnly && build.completionStatus == .needsData) }
    private var toDrive: Bool { devices.sendWhere == SendWhere.drive }
    private var gameName: String { build.gameName }
    private var oneGame: Bool { resultOnly ? build.completedOneGameIPA : devices.exportOneGame }

    private var frameworkOnly: Bool { resultOnly ? build.completedFramework : !oneGame && devices.exportFramework }

    package var body: some View {
        let exportBuiltCount = !oneGame && !frameworkOnly && !build.running && build.exportsShell && !build.exportsOneGame && !build.exportsFramework ? build.builtShellGames().count : 0
        let step1Title = frameworkOnly ? "shell.frameworkStep1Title" : "shell.step1Title"
        let step1Done = oneGame ? "shell.oneGameDone" : frameworkOnly ? "shell.frameworkStep1Done" : "shell.step1Done"
        let step1Sub = oneGame ? "shell.oneGameSub" : frameworkOnly ? "shell.frameworkStep1Sub" : "shell.step1Sub"
        let step2Title = frameworkOnly ? "shell.frameworkStep2Title" : "shell.step2Title"
        let step2Sub = oneGame ? "shell.oneGameStep2Sub" : frameworkOnly ? "shell.frameworkStep2Sub" : "shell.step2Sub"
        return VStack(spacing: 0) {
            if !resultOnly {
                step(1, exported ? .done : .current, title: loc.t(step1Title),
                     sub: exported ? String(format: loc.t(step1Done), build.exportedIPAText)
                                   : loc.t(step1Sub)) {
                    if exported {
                        HStack(spacing: ExportGrid.gap) {
                            if exportBuiltCount > 0 {
                                action(String(format: loc.t("shell.exportBuilt"), exportBuiltCount), id: "existing", enabled: true) { build.exportBuiltGames() }
                                    .help(loc.t("shell.exportBuiltNote"))
                            }
                            action(loc.t("shell.showInFinder"), id: "reveal") { revealInFinder(build.exportedIPAPath) }
                        }
                    } else {
                        HStack(spacing: ExportGrid.gap) {
                            if exportBuiltCount > 0 {   // #994: the IPA of the frameworks already built, no game is built again
                                action(String(format: loc.t("shell.exportBuilt"), exportBuiltCount), id: "existing", enabled: true) { build.exportBuiltGames() }
                                    .help(loc.t("shell.exportBuiltNote"))
                            }
                            action(loc.t("shell.step1Button"), id: "build", enabled: build.canStartBuildOrQueue && !build.running) { build.startBuildOrQueue() }
                        }
                    }
                }
                CardDivider()
            }
            if !resultOnly || exported {
                step(resultOnly ? 1 : 2, sentDone ? .done : exported ? .current : .upcoming, title: loc.t(step2Title),
                     sub: loc.t(step2Sub)) { EmptyView() }
            }
            if !oneGame { if !resultOnly || exported { CardDivider() }; sendStep }
        }
        .sheet(item: $selectSheetMode) { mode in
            SendSelectedSheet(mode: mode, build: build) { selectSheetMode = nil }.environmentObject(loc)
        }
    }

    /// Step 3, the game data to the device or a drive: only for the shared app, whose IPA leaves the data out.
    private var sendStep: some View {
        let whereLabels = [loc.t("shell.whereDevice"), loc.t("shell.whereDrive")]
        return VStack(alignment: .leading, spacing: 0) {
            step(resultOnly ? (exported ? 2 : 1) : 3, sentDone ? .done : exported || !inert ? .current : .upcoming, title: loc.t("shell.step3Title"), sub: loc.t("shell.step3Sub")) {
                LauncherSegmented(options: [(SendWhere.device, whereLabels[0]), (SendWhere.drive, whereLabels[1])],
                                  selection: devices.sendWhere) { devices.sendWhere = $0; build.refreshDrive() }
                    .frame(width: ExportGrid.segmentedWidth(for: whereLabels))
                    .opacity(inert ? ExportGrid.quiet : 1)
                    .disabled(build.running)
                    .padTarget("set.build.export.where", scope: "main", enabled: !inert && !build.running, activate: { changeDestination() }, adjust: { _ in changeDestination() })
            }
            VStack(alignment: .leading, spacing: ExportGrid.noteGap) {
                if build.needsReplaceOldImgReminder && !sentDone {
                    let imgName = build.updatedImgPath.isEmpty ? "romfs.img" : (build.updatedImgPath as NSString).lastPathComponent
                    note(.warning, String(format: loc.t("imgGuide.replaceOldImgBody"), imgName))
                }
                if toDrive { driveRow; driveStatus } else { deviceRow; deviceStatus }
            }
            .padding(.leading, ExportGrid.axis).padding(.trailing, ExportGrid.inset).padding(.bottom, ExportGrid.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.18), value: statusKind)
        }
        .disabled(inert)
    }

    private func changeDestination() {
        guard !build.running else { return }
        devices.sendWhere = toDrive ? SendWhere.device : SendWhere.drive
        build.refreshDrive()
    }

    private func stepDevice(_ by: Int) {
        guard !build.running, !deviceOptions.isEmpty else { return }
        let index = deviceOptions.firstIndex { $0.value == devices.installDevice } ?? 0
        devices.installDevice = deviceOptions[(index + by + deviceOptions.count) % deviceOptions.count].value
    }

    // MARK: A step

    private enum Phase { case upcoming, current, done }

    private func step<Trailing: View>(_ number: Int, _ phase: Phase, title: String, sub: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: ExportGrid.gutter) {
            ZStack {
                Circle().fill(phase == .done ? LauncherPalette.ready : LauncherPalette.ink(phase == .current ? 0.12 : 0.06))
                if phase == .done { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(LauncherPalette.onCream) }
                else { Text("\(number)").font(.manrope(12.5, .semibold)).foregroundStyle(phase == .current ? .primary : .tertiary) }
            }
            .frame(width: ExportGrid.badge, height: ExportGrid.badge)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.manrope(14, .semibold)).foregroundStyle(phase == .upcoming ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sub).font(.manrope(12.5)).foregroundStyle(phase == .upcoming ? .tertiary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: ExportGrid.gap)
            trailing().launcherRowControls()
        }
        .padding(.horizontal, ExportGrid.inset).padding(.vertical, 13)
        .frame(minHeight: 52)
    }

    /// The one action of a step, in the card's right column: as wide and as high as every row button of the launcher.
    @ViewBuilder private func action(_ title: String, id: String, accent: Color? = nil, enabled: Bool = true, _ perform: @escaping () -> Void) -> some View {
        let button = Button(title, action: perform)
        if resultOnly && build.completionStatus == .needsData && (id == "send" || id == "copy") {
            Button(action: perform) { Text(title).font(.manrope(13, .semibold)).padding(.horizontal, 18).frame(height: LauncherControl.height) }.buttonStyle(LauncherActionButtonStyle()).disabled(!enabled).launcherRowControls()
                .padTarget("set.build.export." + id, scope: "main", focusColor: LauncherPalette.onCream, enabled: enabled) { if enabled { perform() } }
        } else {
        button.buttonStyle(LauncherSecondaryButtonStyle(accent: accent))
            .disabled(!enabled)
            .launcherRowControls()
            .padTarget("set.build.export." + id, scope: "main", enabled: enabled) { if enabled { perform() } }
        }
    }

    // MARK: To the device

    /// The device with its connection, so USB or Wi-Fi is part of the choice and not a word beside it.
    private var deviceOptions: [(value: String, label: String)] {
        [(value: "", label: loc.t("dev.none"))] + devices.devices.map { d in
            let link = !d.reachable ? " (" + loc.t("dev.notConnected") + ")" : d.wired ? " · USB" : d.overNetwork ? " · Wi-Fi" : ""
            return (value: d.id, label: d.name + link)
        }
    }

    private var deviceRow: some View {
        VStack(alignment: .leading, spacing: ExportGrid.tight) {
            HStack(spacing: ExportGrid.tight) {
                LauncherDropdown(options: deviceOptions, selection: devices.installDevice, label: loc.t("dev.target"),
                                 style: .button, fill: true, leading: true) { devices.installDevice = $0 }
                    .disabled(build.running)
                    .padTarget("set.build.export.device", scope: "main", enabled: !inert && !build.running, activate: { stepDevice(1) }, adjust: stepDevice)
                RefreshDevicesButton(devices: devices)
            }
            HStack(spacing: ExportGrid.gap) {
                Spacer(minLength: 0)
                action(loc.t("shell.sendButton"), id: "send", enabled: build.canSendToDevice) { build.sendGameData() }
                action(loc.t("shell.selectGamesButton"), id: "sendAll", enabled: build.canSendAllGameData) { selectSheetMode = .device }
                    .help(loc.t("shell.sendAllNote"))
            }
        }
    }

    @ViewBuilder private var deviceStatus: some View {
        switch build.send {
        case .sending(let done, let total, let note):
            progress(String(format: loc.t("shell.sendProgress"), gameName, ShellInstall.sizeText(done), ShellInstall.sizeText(total)) +
                     (note.isEmpty ? "" : " " + note), done: done, total: total)
        case .sent:
            note(.done, loc.t("shell.sendDone"))
        case .appNotFound:
            note(.warning, loc.t("shell.sendNoApp")) { finderWay(detail: nil) }
        case .chooseApp(let apps):
            note(.warning, loc.t("shell.sendSeveral")) {
                ForEach(apps, id: \.bundle) { app in
                    Button(app.name.isEmpty ? app.bundle : app.name + " · " + app.bundle) { build.sendGameData(bundle: app.bundle) }
                        .buttonStyle(LauncherSecondaryButtonStyle())
                        .disabled(build.running)
                    .padTarget("set.build.export.app." + app.bundle, scope: "main", enabled: !build.running) { if !build.running { build.sendGameData(bundle: app.bundle) } }
                }
            }
        case .refused(let detail):
            note(.warning, loc.t("shell.sendRefused")) { finderWay(detail: detail) }
        case .failed(let text):
            note(.warning, text)
        case .idle, .copying, .copied:
            EmptyView()
        }
    }

    /// The second way, offered only after the copy to the device did not work (#491): one button that opens a Finder window with the
    /// game's folder selected and then shows the three steps of the drag. devicectl's own words stay behind Details.
    @ViewBuilder private func finderWay(detail: String?) -> some View {
        let words = detail.flatMap { $0.isEmpty ? nil : $0 }
        HStack(spacing: 16) {
            Button(loc.t("shell.sendFinder")) { withAnimation(.easeInOut(duration: 0.18)) { build.copyWithFinder(oneGame: oneGame) } }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .disabled(build.running)
                    .padTarget("set.build.export.finder", scope: "main", enabled: !build.running) { if !build.running { build.copyWithFinder(oneGame: oneGame) } }
            if words != nil {
                Button { withAnimation(.easeInOut(duration: 0.18)) { detailsOpen.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text(loc.t("shell.sendDetails")).font(.manrope(12.5, .medium))
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(detailsOpen ? 90 : 0))
                    }
                    .foregroundStyle(LauncherPalette.secondaryText).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(detailsOpen ? .isSelected : [])
                .padTarget("set.build.export.details", scope: "main") { detailsOpen.toggle() }
            }
        }
        if build.finderShown { FinderCopySteps(archive: build.archivePath) }
        if detailsOpen, let words {
            Text(words).font(.mono(11.5)).foregroundStyle(LauncherPalette.secondaryText).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ExportGrid.well, in: RoundedRectangle(cornerRadius: 9))
        }
    }

    // MARK: To a drive or folder

    private var driveRow: some View {
        VStack(alignment: .leading, spacing: ExportGrid.tight) {
            HStack(spacing: ExportGrid.tight) {
                // The folder, drawn as a field: the same height and text inset as the device's dropdown in the other mode.
                let none = devices.driveFolder.isEmpty
                Text(none ? loc.t("shell.driveNone") : build.shortPath(devices.driveFolder))
                    .font(none ? .manrope(13) : .mono(12)).foregroundStyle(none ? .tertiary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 15)
                    .frame(minWidth: 200, maxWidth: .infinity, minHeight: LauncherControl.height, maxHeight: LauncherControl.height, alignment: .leading)
                    .background(ExportGrid.well, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(LauncherPalette.ink(0.08)))
                    .opacity(inert ? ExportGrid.quiet : 1)
                    .help(devices.driveFolder)
                Button(loc.t("shell.driveChoose")) { build.chooseDriveFolder() }.buttonStyle(LauncherSecondaryButtonStyle()).fixedSize()
                    .disabled(build.running)
                    .padTarget("set.build.export.folder", scope: "main", enabled: !inert && !build.running) { if !build.running { build.chooseDriveFolder() } }
            }
            HStack(spacing: ExportGrid.gap) {
                Spacer(minLength: 0)
                if copying {
                    action(loc.t("btn.stop"), id: "stop", accent: LauncherPalette.building) { build.stopDriveCopy() }
                } else {
                    action(loc.t("shell.driveCopy"), id: "copy", enabled: build.canCopyToDrive) { build.copyToDrive() }
                    if !build.sharedAppDataSources().isEmpty {
                        action(loc.t("shell.selectGamesButton"), id: "selectDrive", enabled: build.canSelectGamesForDrive) { selectSheetMode = .drive }
                            .help(loc.t("shell.selectGamesDriveNote"))
                    }
                }
            }
        }
    }

    private var gameDataRow: String { L10n.string("ios.ui.gameData", loc.lang) }

    @ViewBuilder private var driveStatus: some View {
        if case .copying(let done, let total) = build.send {
            progress(String(format: loc.t("shell.driveProgress"), build.driveBatchLabel.isEmpty ? gameName : build.driveBatchLabel, ShellInstall.sizeText(done), ShellInstall.sizeText(total)), done: done, total: total)
        } else if case .copied(let folder) = build.send {
            note(.done, String(format: loc.t("shell.driveDone"), build.shortPath((folder as NSString).deletingLastPathComponent), gameDataRow))
        } else if case .failed(let text) = build.send {
            note(.warning, text)
        } else if let state = build.drive {
            switch state.problem {
            case .fat32: note(.blocked, loc.t("shell.driveFat32"))
            case .readOnly: note(.blocked, loc.t("shell.driveReadOnly"))
            case .noSpace(let needed, let free):
                note(.blocked, String(format: loc.t("shell.driveNoSpace"), ShellInstall.sizeText(needed), ShellInstall.sizeText(free)))
            case nil:
                if let volume = state.volume {
                    note(.info, String(format: loc.t("shell.driveNote"), ShellInstall.sizeText(state.needed), ShellInstall.sizeText(volume.freeBytes),
                                       DriveCopy.fileSystemName(volume.fileSystem), gameDataRow))
                }
            }
        }
    }

    // MARK: Notes and progress

    /// What changes the shape of the status area, without the numbers of a running copy (they animate in the bar itself).
    private var statusKind: String {
        let send: String
        switch build.send {
        case .idle: send = "idle"
        case .sending: send = "sending"
        case .sent: send = "sent"
        case .appNotFound: send = "noApp"
        case .chooseApp: send = "choose"
        case .refused: send = "refused"
        case .failed: send = "failed"
        case .copying: send = "copying"
        case .copied: send = "copied"
        }
        return devices.sendWhere + send + (build.drive.map { "\($0.problem == nil)" } ?? "") + "\(detailsOpen)\(build.finderShown)"
    }

    private enum NoteKind { case done, info, warning, blocked }

    /// The launcher's note under a row (as the key check's line): a small symbol, then the text. A good or neutral note is in the
    /// secondary colour, a warning in amber, a problem that stops the copy in red. More lines of the same note go under its text.
    private func note<More: View>(_ kind: NoteKind, _ text: String, @ViewBuilder more: () -> More = { EmptyView() }) -> some View {
        let (symbol, color): (String, Color) = {
            switch kind {
            case .done: return ("checkmark.circle.fill", LauncherPalette.ready)
            case .info: return ("info.circle", .secondary)
            case .warning: return ("exclamationmark.triangle.fill", LauncherPalette.building)
            case .blocked: return ("exclamationmark.triangle.fill", .red)
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).frame(width: 13)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.manrope(12.5)).foregroundStyle(kind == .done || kind == .info ? Color.secondary : color)
                    .fixedSize(horizontal: false, vertical: true)
                more()
            }
            Spacer(minLength: 0)
        }
    }

    private func progress(_ text: String, done: Int64, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LauncherProgressBar(value: total > 0 ? Double(done) / Double(total) : 0, height: 6)
                .frame(height: 6).accessibilityLabel(text)
            Text(text).font(.manrope(12.5)).monospacedDigit().foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

/// Looks for devices again: an icon button beside the device's dropdown, named for VoiceOver and in its tooltip. While the list is
/// read it turns into a small spinner. Never as wide as a row's buttons, so it stays a small companion of the dropdown.
struct RefreshDevicesButton: View {
    @ObservedObject var devices: DeviceStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        Button { _ = devices.refresh() } label: {
            ZStack {
                if devices.checked { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)) }
                else { ProgressView().controlSize(.small).scaleEffect(0.8) }
            }
            .frame(width: 14, height: 18)
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
        .environment(\.launcherControlWidth, nil)
        .help(loc.t("dev.refresh")).accessibilityLabel(loc.t("dev.refresh"))
        .padTarget("set.build.devices.refresh", scope: "main", enabled: devices.checked) { _ = devices.refresh() }
    }
}

/// The measures of the export's steps. The edges and the row height are CardRow's, so the steps sit in the card like its other rows.
enum ExportGrid {
    static let inset: CGFloat = 18      // the card's edge to the number, and to the right column
    static let badge: CGFloat = 25      // the step's number
    static let gutter: CGFloat = 12     // the number to the step's text
    static let axis: CGFloat = inset + badge + gutter   // 55: where a step's title, text, controls, progress and notes start
    static let gap: CGFloat = 12        // a control group to the action
    static let tight: CGFloat = 8       // a control to its own small button
    static let noteGap: CGFloat = 12    // the controls to the notes under them
    static let switchWidth: CGFloat = 330   // fallback default
    static let quiet: Double = 0.45     // step 3 before there is an IPA, as a switched-off launcher switch
    static let well = LauncherPalette.well   // a field's inside: the folder, devicectl's own text

    /// Adaptive equal-share width for two-option export switches so long translations (French/German) fit on one line.
    static func segmentedWidth(for labels: [String], minWidth: CGFloat = 260, maxWidth: CGFloat = 440) -> CGFloat {
        guard !labels.isEmpty else { return minWidth }
        let maxLabel: CGFloat
        if let ct = Typography.manropeFont(size: 12.5, weight: .bold) {
            maxLabel = labels.map { label in
                let attr = NSAttributedString(string: label, attributes: [kCTFontAttributeName as NSAttributedString.Key: ct])
                return ceil(CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(attr), []).width) + 2
            }.max() ?? 0
        } else {
            maxLabel = CGFloat(labels.map(\.count).max() ?? 0) * 8.2
        }
        let count = CGFloat(labels.count)
        let needed = ceil((maxLabel + 24) * count + 6 + 2 * max(0, count - 1))
        return min(max(minWidth, needed), maxWidth)
    }
}

/// Shared manual-transfer instructions for the export and automatic-install failure cards.
struct FinderCopySteps: View {
    let archive: String
    @EnvironmentObject var loc: Localizer

    /// The drag in three steps, numbered as the export's own steps but smaller, in a well under the button. The folder is the one the
    /// Finder window shows selected. Step 3 names the shell's own button, in the language the shell shows it.
    var body: some View {
        let folder = (archive as NSString).lastPathComponent
        let choose = L10n.string("ios.ui.chooseGameData", loc.lang).trimmingCharacters(in: CharacterSet(charactersIn: "….  "))
        let lines = [loc.t("shell.sendFinderStep1"), String(format: loc.t("shell.sendFinderStep2"), folder),
                     String(format: loc.t("shell.sendFinderStep3"), choose, folder)]
        return VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)").font(.manrope(11, .semibold)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 18, height: 18).background(Circle().fill(LauncherPalette.ink(0.08)))
                    Text(line).font(.manrope(12.5)).foregroundStyle(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ExportGrid.well, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

}
