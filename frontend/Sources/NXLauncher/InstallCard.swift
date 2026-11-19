import SwiftUI
import NXCore
import NXModel

/// Where an iPhone build goes: signed and installed on a paired device ("Install on device"), or exported as an unsigned IPA for
/// another tool to sign, with the game data sent afterwards ("Export as IPA", ExportSteps). Shown for the iPhone target only. Observes the
/// device store, and the build store for the target and whether a build runs.
package struct InstallCard: View {
    @ObservedObject var devices: DeviceStore
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer
    @Environment(\.launcherSectionTitleFont) private var titleFont

    @State private var selectDeviceGamesOpen = false
    @State private var signingHelpOpen = false
    @State private var recentDevice: String?
    let forQueue: Bool
    let showLocked: Bool

    package init(devices: DeviceStore, build: BuildStore, showLocked: Bool = true, forQueue: Bool = false) {
        self.showLocked = showLocked
        self.forQueue = forQueue
        self.devices = devices
        self.build = build
    }

    package var body: some View {
        if build.target != BuildTarget.mac || forQueue, !build.running || sending || showLocked { card.disabled(build.running && !sending) }
    }

    /// The copy of the game data runs on the build store's `running` flag too, and its own buttons must stay usable (Stop).
    private var sending: Bool {
        switch build.send { case .sending, .copying: return true; default: return false }
    }

    private var card: some View {
        let teams = devices.teams.map { (value: $0.id, label: $0.label(personalTeam: loc.t("dev.personalTeam"))) }
        let needsCertificate = devices.teams.first { $0.id == devices.signingTeam }.map { !$0.hasCertificate } ?? false
        let footnote = devices.exportIPA ? ""
            : devices.installDevice.isEmpty ? "" : (needsCertificate ? loc.t("dev.teamNoCert") + " " : "") + loc.t("dev.note")
        let modeLabels = [loc.t("shell.modeInstall"), loc.t("shell.modeExport")]
        let modeSwitch = LauncherSegmented(options: [("install", modeLabels[0]), ("export", modeLabels[1])],
                                           selection: devices.exportIPA ? "export" : "install") { devices.exportIPA = $0 == "export" }
            .frame(width: ExportGrid.segmentedWidth(for: modeLabels))
            .disabled(build.running)
            .padTarget("set.build.install.mode", scope: "main", enabled: !build.running, activate: { if !build.running { devices.exportIPA.toggle() } }, adjust: { _ in if !build.running { devices.exportIPA.toggle() } })
        return VStack(alignment: .leading, spacing: 10) {
            // The two ways, a switch of their own: exporting is never chosen for the player (#416)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text(loc.t(forQueue ? "queue.iosOptions" : "dev.section")).font(titleFont)
                        .foregroundStyle(LauncherPalette.secondaryText).padding(.leading, 2)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    modeSwitch
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(loc.t(forQueue ? "queue.iosOptions" : "dev.section")).font(titleFont)
                        .foregroundStyle(LauncherPalette.secondaryText).padding(.leading, 2)
                    modeSwitch
                }
            }
            CardGroup("") {
                if devices.exportIPA {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) {
                            appKindCard("shared").frame(minWidth: 210)
                            appKindCard("one").frame(minWidth: 210)
                            appKindCard("framework").frame(minWidth: 210)
                        }.fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 12) {
                            appKindCard("shared")
                            appKindCard("one")
                            appKindCard("framework")
                        }
                    }.padding(18)
                    CardDivider()
                    if !forQueue { ExportSteps(build: build, devices: devices) }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(loc.t("flow.chooseDevice")).font(.manrope(16, .semibold))
                            Spacer()
                            RefreshDevicesButton(devices: devices)
                        }
                        if devices.checked && devices.devices.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "iphone.and.ipad").font(.system(size: 28)).accessibilityHidden(true)
                                Text(loc.t("flow.pairDevice")).font(.manrope(13))
                                Button(loc.t("flow.openXcode")) { openXcode() }
                                    .padTarget("set.build.install.xcode", scope: "main", activate: { openXcode() })
                            }.frame(maxWidth: .infinity).padding(20).accessibilityHint(loc.t("dev.noDevices"))
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                                ForEach(devices.devices) { device in
                                    Button { devices.installDevice = device.id } label: {
                                        VStack(alignment: .leading, spacing: 10) {
                                            HStack {
                                                if recentDevice == device.id {
                                                    Text(loc.t("flow.recent")).font(.manrope(10, .semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                                                        .background(LauncherPalette.surface, in: Capsule())
                                                        .overlay(Capsule().strokeBorder(LauncherPalette.cardBorder, lineWidth: 1))
                                                }
                                                Spacer()
                                                Image(systemName: device.model.lowercased().contains("ipad") ? "ipad" : "iphone").font(.system(size: 24))
                                            }
                                            Spacer(minLength: 0)
                                            Text(device.name).font(.manrope(14, .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                            if !device.reachable { Text(loc.t("dev.notConnected")).font(.manrope(11)).foregroundStyle(.secondary) }
                                        }.padding(16).frame(height: 136, alignment: .topLeading)
                                            .background(devices.installDevice == device.id ? LauncherPalette.selectedFill : LauncherPalette.selectableFill, in: RoundedRectangle(cornerRadius: 14))
                                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(devices.installDevice == device.id ? LauncherPalette.selectedBorder : LauncherPalette.selectableBorder, lineWidth: devices.installDevice == device.id ? 1.5 : 1))
                                            .contentShape(RoundedRectangle(cornerRadius: 14))
                                    }.buttonStyle(.plain).disabled(build.running)
                                        .accessibilityAddTraits(devices.installDevice == device.id ? .isSelected : [])
                                        .padTarget("set.build.install.device." + device.id, scope: "main", radius: 14, enabled: !build.running, activate: { if !build.running { devices.installDevice = device.id } })
                                }
                            }
                        }
                    }.padding(18)
                    if !devices.installDevice.isEmpty {
                        CardDivider()
                        if teams.isEmpty {
                            CardRow(loc.t("dev.team"), detail: loc.t("flow.signingRequired"), dot: LauncherPalette.building) { EmptyView() }
                        } else {
                            CardRow(loc.t("dev.team")) {
                                LauncherDropdown(options: teams, selection: devices.signingTeam, label: loc.t("dev.team")) { devices.signingTeam = $0 }
                                    .disabled(build.running)
                                    .padTarget("set.build.install.team", scope: "main", enabled: !build.running, activate: { stepTeam(1, options: teams) }, adjust: { stepTeam($0, options: teams) })
                            }
                        }
                    }
                    if !devices.installDevice.isEmpty {
                        CardDivider()
                        CardDisclosure(loc.t("flow.signingHelp"), isOpen: signingHelpOpen) { signingHelpOpen.toggle() }
                            .padTarget("set.build.install.help", scope: "main", enabled: !build.running, activate: { signingHelpOpen.toggle() })
                        if signingHelpOpen {
                            VStack(alignment: .leading, spacing: 12) {
                                if teams.isEmpty { Text(loc.t("dev.noTeam")) }
                                if !footnote.isEmpty { Text(footnote) }
                            }.font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                        }
                    }
                    if !forQueue && !build.builtShellGames().isEmpty {
                        CardDivider()
                        CardRow(loc.t("shell.builtTitle"), detail: loc.t("shell.installBuiltNote")) {
                            Button(String(format: loc.t("shell.installBuilt"), build.builtShellGames().count)) { build.installBuiltGames() }
                                .buttonStyle(LauncherSecondaryButtonStyle())
                                .disabled(!build.canInstallBuiltGames)
                                .help(loc.t("shell.installBuiltNote"))
                                .padTarget("set.build.install.built", scope: "main", enabled: build.canInstallBuiltGames) { if build.canInstallBuiltGames { build.installBuiltGames() } }
                        }
                        if !build.sharedAppDataSources().isEmpty {
                            CardDivider()
                            CardRow(loc.t("shell.step3Title"), detail: loc.t("shell.sendAllNote")) {
                                Button(loc.t("shell.selectGamesButton")) { selectDeviceGamesOpen = true }
                                    .buttonStyle(LauncherSecondaryButtonStyle()).disabled(!build.canSendAllGameData)
                                    .help(loc.t("shell.selectGamesDeviceNote"))
                                    .padTarget("set.build.install.selectGames", scope: "main", enabled: build.canSendAllGameData) { if build.canSendAllGameData { selectDeviceGamesOpen = true } }
                                Button(loc.t("shell.sendAllButton")) { build.sendAllGameData() }
                                    .buttonStyle(LauncherSecondaryButtonStyle())
                                    .disabled(!build.canSendAllGameData)
                                    .help(loc.t("shell.sendAllNote"))
                                    .padTarget("set.build.install.sendAll", scope: "main", enabled: build.canSendAllGameData) { if build.canSendAllGameData { build.sendAllGameData() } }
                            }
                        }
                    }
                }
                if forQueue {
                    CardDivider()
                    CardRow(loc.t("opt.bc"), detail: loc.t("opt.bc.note")) {
                        Toggle(loc.t("opt.bc"), isOn: $build.bcOnCPU).toggleStyle(LauncherSwitchStyle()).labelsHidden().disabled(build.running)
                            .padTarget("set.build.bc", scope: "main", enabled: !build.running,
                                       activate: { if !build.running { build.bcOnCPU.toggle() } },
                                       adjust: { _ in if !build.running { build.bcOnCPU.toggle() } })
                    }
                }
            }
        }
        .onAppear {
            if recentDevice == nil { recentDevice = devices.installDevice }
            if !devices.checked { _ = devices.refresh() }
        }
        .sheet(isPresented: $selectDeviceGamesOpen) {
            SendSelectedSheet(mode: .device, build: build) { selectDeviceGamesOpen = false }.environmentObject(loc)
        }
    }

    private func appKindCard(_ kind: String) -> some View {
        let oneGame = kind == "one", framework = kind == "framework"
        let selected = kind == (devices.exportOneGame ? "one" : devices.exportFramework ? "framework" : "shared")
        return Button { pickKind(kind) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Spacer()
                    if oneGame || framework {
                        Image(systemName: framework ? "shippingbox.fill" : "app.fill").font(.system(size: 26, weight: .light))
                            .foregroundStyle(selected ? LauncherPalette.accent : .secondary)
                    } else { LauncherBrandMark().accessibilityHidden(true) }
                }.frame(height: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t(framework ? "shell.ipaFramework" : oneGame ? "shell.choiceSingle" : "shell.choiceLauncher")).font(.manrope(16, .semibold))
                    Text(loc.t(framework ? "shell.ipaFrameworkNote" : oneGame ? "shell.choiceSingleNote" : "shell.choiceLauncherNote"))
                        .font(.manrope(12.5)).foregroundStyle(LauncherPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? LauncherPalette.selectedFill : LauncherPalette.selectableFill, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? LauncherPalette.selectedBorder : LauncherPalette.selectableBorder, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).disabled(build.running)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .padTarget("set.build.install.kind." + kind, scope: "main", radius: 14, enabled: !build.running,
                       activate: { if !build.running { pickKind(kind) } })
    }

    private func openXcode() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") { NSWorkspace.shared.open(url) }
    }

    private func stepTeam(_ by: Int, options: [(value: String, label: String)]) {
        guard !build.running, !options.isEmpty else { return }
        let index = options.firstIndex { $0.value == devices.signingTeam } ?? 0
        devices.signingTeam = options[(index + by + options.count) % options.count].value
    }

    /// The other kind of IPA: the IPA of the last export is not the one this choice makes, so step 1 starts again.
    private func pickKind(_ kind: String) {
        let oneGame = kind == "one", framework = kind == "framework"
        guard oneGame != devices.exportOneGame || framework != devices.exportFramework else { return }
        devices.exportOneGame = oneGame
        devices.exportFramework = framework
        build.exportedIPAPath = ""
        build.send = .idle
    }
}
