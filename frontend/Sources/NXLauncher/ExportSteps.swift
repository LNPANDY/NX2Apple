import SwiftUI
import NXCore
import NXModel

/// The export of the shared app as an IPA, in three steps (LNPANDY/NX2Apple#416): export it, install it with another tool, send the
/// game data. Shown by the Install card when its switch says "Export as IPA". Observes the build store (the steps' state) and the
/// device store (the device and the place the data goes to).
package struct ExportSteps: View {
    @ObservedObject var build: BuildStore
    @ObservedObject var devices: DeviceStore
    @EnvironmentObject var loc: Localizer

    package init(build: BuildStore, devices: DeviceStore) {
        self.build = build
        self.devices = devices
    }

    private var exported: Bool { !build.exportedIPAPath.isEmpty }
    private var sentDone: Bool {
        switch build.send { case .sent, .copied: return true; default: return false }
    }
    private var toDrive: Bool { devices.sendWhere == SendWhere.drive }
    private var gameName: String { ((build.basePath as NSString).lastPathComponent as NSString).deletingPathExtension }

    package var body: some View {
        VStack(spacing: 0) {
            step(1, done: exported, title: loc.t("shell.step1Title"),
                 sub: exported ? String(format: loc.t("shell.step1Done"), build.exportedIPAText) : loc.t("shell.step1Sub")) {
                if exported {
                    Button(loc.t("shell.showInFinder")) { revealInFinder(build.exportedIPAPath) }
                } else {
                    Button(loc.t("shell.step1Button")) { build.startBuild() }.disabled(!build.canBuild || build.running)
                }
            }
            CardDivider()
            step(2, done: sentDone, title: loc.t("shell.step2Title"), sub: loc.t("shell.step2Sub")) { EmptyView() }
            CardDivider()
            step(3, done: sentDone, title: loc.t("shell.step3Title"), sub: loc.t("shell.step3Sub")) {
                LauncherSegmented(options: [(SendWhere.device, loc.t("shell.whereDevice")), (SendWhere.drive, loc.t("shell.whereDrive"))],
                                  selection: devices.sendWhere) { devices.sendWhere = $0; build.refreshDrive() }
            }
            VStack(alignment: .leading, spacing: 10) {
                if toDrive { driveBody } else { deviceBody }
            }
            .padding(.leading, 49).padding(.trailing, 18).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!exported && !sentDone)
            .opacity(exported || sentDone ? 1 : 0.5)
        }
    }

    // MARK: A step

    private func step<Trailing: View>(_ number: Int, done: Bool, title: String, sub: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(done ? LauncherPalette.ready : Color.white.opacity(0.10)).frame(width: 25, height: 25)
                if done { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.black) }
                else { Text("\(number)").font(.manrope(12.5, .semibold)).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.manrope(14, .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(sub).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing().launcherRowControls()
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .frame(minHeight: 52)
    }

    // MARK: To the device

    private var connectionText: String {
        guard let d = devices.devices.first(where: { $0.id == devices.installDevice }) else { return "" }
        return d.wired ? "USB" : d.overNetwork ? "Wi-Fi" : ""
    }

    @ViewBuilder private var deviceBody: some View {
        let options = [(value: "", label: loc.t("dev.none"))] + devices.devices.map { (value: $0.id, label: $0.name) }
        HStack(spacing: 10) {
            LauncherDropdown(options: options, selection: devices.installDevice, label: loc.t("dev.target")) { devices.installDevice = $0 }
                .frame(width: 220)
            if !connectionText.isEmpty { Text(connectionText).font(.mono(12)).foregroundStyle(.secondary) }
            Button(loc.t("dev.refresh")) { _ = devices.refresh() }.buttonStyle(.plain).font(.manrope(13)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { build.sendGameData() } label: { Label(loc.t("shell.sendButton"), systemImage: "arrow.up.circle") }
                .buttonStyle(LauncherSecondaryButtonStyle()).disabled(!build.canSendToDevice).frame(width: LauncherControl.width)
        }
        deviceStatus
    }

    @ViewBuilder private var deviceStatus: some View {
        switch build.send {
        case .sending(let done, let total, let note):
            progress(String(format: loc.t("shell.sendProgress"), gameName, ShellInstall.sizeText(done), ShellInstall.sizeText(total)) +
                     (note.isEmpty ? "" : " " + note), done: done, total: total)
        case .sent:
            note(loc.t("shell.sendDone"), LauncherPalette.ready)
        case .appNotFound:
            note(loc.t("shell.sendNoApp"), LauncherPalette.building)
        case .chooseApp(let apps):
            note(loc.t("shell.sendSeveral"), LauncherPalette.building)
            ForEach(apps, id: \.bundle) { app in
                Button(app.name.isEmpty ? app.bundle : app.name + " · " + app.bundle) { build.sendGameData(bundle: app.bundle) }
                    .buttonStyle(LauncherSecondaryButtonStyle())
            }
        case .refused(let detail):
            note(loc.t("shell.sendRefused"), LauncherPalette.building)
            HStack(spacing: 12) {
                Button(loc.t("shell.sendShowData")) { build.showGameDataInFinder() }.buttonStyle(LauncherSecondaryButtonStyle())
                Text(loc.t("shell.sendFinderSteps")).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(loc.t("shell.sendDetails")) {
                Text(detail).font(.mono(11.5)).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.font(.manrope(12.5))
        case .failed(let text):
            note(text, LauncherPalette.building)
        case .idle, .copying, .copied:
            EmptyView()
        }
    }

    // MARK: To a drive or folder

    @ViewBuilder private var driveBody: some View {
        HStack(spacing: 10) {
            Text(devices.driveFolder.isEmpty ? loc.t("shell.driveNone") : build.shortPath(devices.driveFolder))
                .font(devices.driveFolder.isEmpty ? .manrope(13) : .mono(12)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: 300, alignment: .leading)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            Button(loc.t("shell.driveChoose")) { build.chooseDriveFolder() }.buttonStyle(LauncherSecondaryButtonStyle())
                .frame(width: LauncherControl.width)
            Spacer(minLength: 8)
            Button(loc.t("shell.driveCopy")) { build.copyToDrive() }
                .buttonStyle(LauncherSecondaryButtonStyle()).disabled(!build.canCopyToDrive).frame(width: LauncherControl.width)
        }
        driveStatus
    }

    private var gameDataRow: String { L10n.string("ios.ui.gameData", loc.lang) }

    @ViewBuilder private var driveStatus: some View {
        if case .copying(let done, let total) = build.send {
            progress(String(format: loc.t("shell.driveProgress"), gameName, ShellInstall.sizeText(done), ShellInstall.sizeText(total)), done: done, total: total)
            Button(loc.t("btn.stop")) { build.stopDriveCopy() }.buttonStyle(LauncherSecondaryButtonStyle())
        } else if case .copied(let folder) = build.send {
            note(String(format: loc.t("shell.driveDone"), build.shortPath((folder as NSString).deletingLastPathComponent), gameDataRow), LauncherPalette.ready)
        } else if case .failed(let text) = build.send {
            note(text, LauncherPalette.building)
        } else if let state = build.drive {
            switch state.problem {
            case .fat32: note(loc.t("shell.driveFat32"), .red)
            case .readOnly: note(loc.t("shell.driveReadOnly"), .red)
            case .noSpace(let needed, let free):
                note(String(format: loc.t("shell.driveNoSpace"), ShellInstall.sizeText(needed), ShellInstall.sizeText(free)), .red)
            case nil:
                if let volume = state.volume {
                    Text(String(format: loc.t("shell.driveNote"), ShellInstall.sizeText(state.needed), ShellInstall.sizeText(volume.freeBytes),
                                DriveCopy.fileSystemName(volume.fileSystem), gameDataRow))
                        .font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Pieces

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text).font(.manrope(12.5)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    private func progress(_ text: String, done: Int64, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: total > 0 ? Double(done) / Double(total) : 0).progressViewStyle(.linear).tint(LauncherPalette.cream)
            Text(text).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
