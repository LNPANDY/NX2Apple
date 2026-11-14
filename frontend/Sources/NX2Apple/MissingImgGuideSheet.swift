import AppKit
import SwiftUI
import NXCore
import NXLauncher
import NXModel

/// Context identifying the game and refresh assessment for the missing `.img` guide sheet.
struct MissingImgGuideContext: Identifiable, Equatable {
    let game: LibraryGame
    let assessment: GameRefreshAssessment
    var id: UUID { game.id }
}

/// Guided modal shown when an iOS game needs a shader recompile (Path B) and has a build seed,
/// but its `.img` archive is not currently in `<outDir>/games/` or on a configured external drive.
struct MissingImgGuideSheet: View {
    let context: MissingImgGuideContext
    let stores: LauncherStores
    @ObservedObject var devices: DeviceStore
    let libraryFolder: String
    var chooseImgURL: (() -> URL?)? = nil
    let onResolvedImg: (String) -> Void
    let onFallbackFullRebuild: () -> Void
    let close: () -> Void

    @EnvironmentObject var loc: Localizer
    @State private var validatingImg = false
    @State private var imgValidationError: String?
    @State private var validationGeneration = 0

    @State private var pullingDeviceName: String?
    @State private var pullError: String?
    @State private var pullGeneration = 0
    @State private var pullCancelFlag: LockedFlag?
    @State private var sheetClosed = false

    private var game: LibraryGame { context.game }
    private var assessment: GameRefreshAssessment { context.assessment }

    private var gameDisplayName: String {
        game.displayName(loc.lang)
    }

    private var resolvedOutDir: String {
        let dir = ToolsAge.resolvedOutputDirectory(for: game, libraryFolder: libraryFolder)
        if !dir.isEmpty { return dir }
        if !stores.build.outDir.isEmpty { return stores.build.outDir }
        return (BuildSeedCache.defaultRoot(home: stores.build.home) as NSString).deletingLastPathComponent + "/refresh-builds"
    }

    private var defaultGamesDirectory: String {
        (resolvedOutDir as NSString).appendingPathComponent("games")
    }

    private var defaultGamesDisplayPath: String {
        let path = (defaultGamesDirectory as NSString).abbreviatingWithTildeInPath
        return path.hasSuffix("/") ? path : path + "/"
    }

    private var connectedDevice: AppleDevice? {
        if !game.installedDevice.isEmpty,
           let match = devices.devices.first(where: { $0.id == game.installedDevice && $0.reachable }) {
            return match
        }
        if !devices.installDevice.isEmpty,
           let match = devices.devices.first(where: { $0.id == devices.installDevice && $0.reachable }) {
            return match
        }
        return devices.devices.first(where: \.reachable)
    }

    private var isBusy: Bool {
        validatingImg || pullingDeviceName != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    optionOneCard
                    optionTwoCard
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 20)
            }

            Divider().opacity(0.3)

            footerSection
                .padding(.horizontal, 30)
                .padding(.vertical, 16)
        }
        .frame(width: 680)
        .frame(maxHeight: min(720, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
        .background(LauncherPalette.background)
        .launcherAppearance()
        .tint(LauncherPalette.accent)
        .onAppear {
            sheetClosed = false
            _ = devices.refresh()
        }
        .onDisappear {
            cancelAsyncOperations(closing: true)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "externaldrive.fill.badge.timemachine")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LauncherPalette.ready)
                    .frame(width: 38, height: 38)
                    .background(LauncherPalette.ready.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 6) {
                    Text(loc.t("imgGuide.title"))
                        .font(.manrope(22, .heavy))
                        .tracking(-0.4)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: loc.t("imgGuide.subtitle"), gameDisplayName))
                        .font(.manrope(13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var optionOneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "1.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LauncherPalette.ready)
                Text(loc.t("imgGuide.opt1Title"))
                    .font(.manrope(14.5, .bold))
                    .foregroundStyle(LauncherPalette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(loc.t("imgGuide.opt1Note"))
                .font(.manrope(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    pickExistingImg()
                } label: {
                    HStack(spacing: 7) {
                        if validatingImg {
                            ProgressView()
                                .controlSize(.small)
                                .tint(LauncherPalette.onCream)
                        } else {
                            Image(systemName: "doc.badge.gearshape")
                        }
                        Text(loc.t("imgGuide.chooseImgBtn"))
                    }
                    .font(.manrope(13.5, .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                }
                .buttonStyle(LauncherActionButtonStyle())
                .disabled(isBusy)
                .opacity(isBusy ? 0.55 : 1)
            }

            if let error = imgValidationError {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(LauncherPalette.danger)
                    Text(error)
                        .font(.manrope(12.5))
                        .foregroundStyle(LauncherPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.selectedBorder.opacity(0.45)))
    }

    private var optionTwoCard: some View {
        let device = connectedDevice
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "2.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LauncherPalette.accent)
                Text(loc.t("imgGuide.opt2Title"))
                    .font(.manrope(14.5, .bold))
                    .foregroundStyle(LauncherPalette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(String(format: loc.t("imgGuide.opt2Note"), defaultGamesDisplayPath))
                .font(.mono(12))
                .foregroundStyle(LauncherPalette.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LauncherPalette.well, in: RoundedRectangle(cornerRadius: 8))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    openGamesFolderButton
                    pullFromIPhoneButton(device: device)
                }
                VStack(alignment: .leading, spacing: 8) {
                    openGamesFolderButton
                    pullFromIPhoneButton(device: device)
                }
            }

            if let pullingName = pullingDeviceName {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(format: loc.t("imgGuide.pulling"), pullingName))
                        .font(.manrope(12.5))
                        .foregroundStyle(LauncherPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if device == nil {
                Text(loc.t("imgGuide.pullNoDevice"))
                    .font(.manrope(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = pullError {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(LauncherPalette.danger)
                    Text(error)
                        .font(.manrope(12.5))
                        .foregroundStyle(LauncherPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
    }

    private var openGamesFolderButton: some View {
        Button {
            openDefaultGamesFolder()
        } label: {
            Label(loc.t("imgGuide.openFolderBtn"), systemImage: "folder")
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
    }

    private func pullFromIPhoneButton(device: AppleDevice?) -> some View {
        Button {
            if let device {
                startPullFromDevice(device)
            }
        } label: {
            Label(loc.t("imgGuide.pullIPhoneBtn"), systemImage: "iphone.and.arrow.forward")
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
        .disabled(device == nil || isBusy)
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if assessment.missingOriginalPackage {
                Text(loc.t("imgGuide.noNspHint"))
                    .font(.manrope(12))
                    .foregroundStyle(LauncherPalette.building)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button {
                    cancelAsyncOperations(closing: true)
                    onFallbackFullRebuild()
                } label: {
                    Text(loc.t("imgGuide.fullNspBtn"))
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .disabled(assessment.missingOriginalPackage || isBusy)

                Spacer(minLength: 8)

                Button(loc.t("batchRefresh.cancel")) {
                    cancelAsyncOperations(closing: true)
                    close()
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func pickExistingImg() {
        let pickedURL: URL?
        if let chooseImgURL {
            pickedURL = chooseImgURL()
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedFileTypes = ["img"]
            if !devices.driveFolder.isEmpty {
                panel.directoryURL = URL(fileURLWithPath: devices.driveFolder)
            }
            pickedURL = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url = pickedURL else { return }

        pullCancelFlag?.set(true)
        pullCancelFlag = nil
        pullGeneration &+= 1
        pullingDeviceName = nil

        validationGeneration &+= 1
        let gen = validationGeneration
        validatingImg = true
        imgValidationError = nil

        let chosenPath = url.path
        let expectedIdentity = assessment.expectedRomfsIdentity
        let displayName = gameDisplayName

        DispatchQueue.global(qos: .userInitiated).async {
            let matches: Bool
            if let expectedIdentity, !expectedIdentity.isEmpty {
                matches = RomfsImageIdentity.matches(imagePath: chosenPath, expectedIdentityLine: expectedIdentity)
            } else {
                matches = RomfsImageIdentity.computeIdentity(of: chosenPath) != nil
            }
            DispatchQueue.main.async {
                guard gen == validationGeneration, !sheetClosed else { return }
                validatingImg = false
                if matches {
                    sheetClosed = true
                    onResolvedImg(chosenPath)
                } else {
                    imgValidationError = String(format: loc.t("imgGuide.invalidImg"), displayName)
                }
            }
        }
    }

    private func openDefaultGamesFolder() {
        let targetDir = defaultGamesDirectory
        try? FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: targetDir))
    }

    private func startPullFromDevice(_ device: AppleDevice) {
        validationGeneration &+= 1
        validatingImg = false
        imgValidationError = nil

        pullCancelFlag?.set(true)
        let cancelFlag = LockedFlag()
        pullCancelFlag = cancelFlag
        pullGeneration &+= 1
        let gen = pullGeneration
        pullingDeviceName = device.name
        pullError = nil

        let udid = device.id
        let shellCachePath = stores.build.shellCachePath
        let tid = game.titleID
        let rawName = game.name
        let outDir = resolvedOutDir
        let expected = assessment.expectedRomfsIdentity
        let xcrun = devices.xcrun
        let runner = stores.runner

        DispatchQueue.global(qos: .userInitiated).async {
            let bundleID = ShellLibrary.load(root: shellCachePath).bundleID
            let control = DeviceControl.xcrun(xcrun, queryTimeout: 15, copyTimeout: 900, runner: runner)
            let puller = DeviceImgPuller(control: control)
            let result = puller.pullImage(
                device: udid,
                bundleID: bundleID,
                titleID: tid,
                gameName: rawName,
                outDir: outDir,
                expectedIdentity: expected,
                isCancelled: { cancelFlag.value }
            )
            DispatchQueue.main.async {
                guard gen == pullGeneration, !cancelFlag.value, !sheetClosed else { return }
                pullingDeviceName = nil
                pullCancelFlag = nil
                switch result {
                case .success(let pulledPath):
                    sheetClosed = true
                    onResolvedImg(pulledPath)
                case .failure(let err):
                    if err == .cancelled { return }
                    let reason = err.errorDescription ?? String(describing: err)
                    pullError = String(format: loc.t("imgGuide.pullFailed"), reason)
                }
            }
        }
    }

    private func cancelAsyncOperations(closing: Bool) {
        if closing {
            sheetClosed = true
        }
        validationGeneration &+= 1
        validatingImg = false
        pullCancelFlag?.set(true)
        pullCancelFlag = nil
        pullGeneration &+= 1
        pullingDeviceName = nil
    }
}

extension View {
    /// Attaches the batch refresh and missing `.img` guide sheets, keeping `LauncherView.swift` concise.
    func refreshSheetsWiring(
        batchOpen: Binding<Bool>,
        imgGuide: Binding<MissingImgGuideContext?>,
        stores: LauncherStores,
        library: GameLibrary,
        toolsAge: ToolsAge,
        page: Binding<LauncherPage>,
        pad: PadFocus,
        scope: @escaping () -> String
    ) -> some View {
        self
            .sheet(isPresented: batchOpen) {
                BatchRefreshSheet(
                    library: library,
                    toolsAge: toolsAge,
                    stores: stores,
                    onConfirmed: {
                        batchOpen.wrappedValue = false
                        page.wrappedValue = .builds
                        if !stores.build.running && stores.build.canStartBuildOrQueue {
                            stores.build.startBuildOrQueue()
                        }
                    },
                    close: { batchOpen.wrappedValue = false }
                )
                .environmentObject(stores.localizer)
            }
            .sheet(item: imgGuide) { context in
                MissingImgGuideSheet(
                    context: context,
                    stores: stores,
                    devices: stores.deviceStore,
                    libraryFolder: library.folder,
                    onResolvedImg: { imgPath in
                        imgGuide.wrappedValue = nil
                        enqueueSingleFromImgGuide(
                            context: context,
                            externalIOSImgPath: imgPath,
                            forceFullIOSRebuild: false,
                            stores: stores,
                            libraryFolder: library.folder,
                            page: page
                        )
                    },
                    onFallbackFullRebuild: {
                        imgGuide.wrappedValue = nil
                        enqueueSingleFromImgGuide(
                            context: context,
                            externalIOSImgPath: nil,
                            forceFullIOSRebuild: true,
                            stores: stores,
                            libraryFolder: library.folder,
                            page: page
                        )
                    },
                    close: { imgGuide.wrappedValue = nil }
                )
                .environmentObject(stores.localizer)
            }
            .onChange(of: batchOpen.wrappedValue) { open in
                pad.scope = open ? "batchRefresh" : scope()
            }
            .onChange(of: imgGuide.wrappedValue?.id) { id in
                pad.scope = id != nil ? "imgGuide" : scope()
            }
    }
}

@MainActor private func enqueueSingleFromImgGuide(
    context: MissingImgGuideContext,
    externalIOSImgPath: String?,
    forceFullIOSRebuild: Bool,
    stores: LauncherStores,
    libraryFolder: String,
    page: Binding<LauncherPage>
) {
    let game = context.game
    let assessment = context.assessment
    let batch = UUID()
    var entries: [QueueEntry] = []

    if game.isReady {
        let canFastMac = assessment.canFastRefreshMac
        if canFastMac || !assessment.missingOriginalPackage {
            entries.append(RefreshQueueBuilder.makeEntry(
                game: game,
                target: BuildTarget.mac,
                fastRefresh: canFastMac,
                externalImgPath: nil,
                batch: batch,
                stores: stores,
                libraryFolder: libraryFolder
            ))
        }
    }

    let fastIOS = !forceFullIOSRebuild && (assessment.canFastRefreshIOS || externalIOSImgPath != nil)
    if fastIOS || !assessment.missingOriginalPackage {
        entries.append(RefreshQueueBuilder.makeEntry(
            game: game,
            target: BuildTarget.ios,
            fastRefresh: fastIOS,
            externalImgPath: externalIOSImgPath,
            batch: batch,
            stores: stores,
            libraryFolder: libraryFolder
        ))
    }

    let ordered = RefreshQueueBuilder.orderedEntries(entries)
    guard !ordered.isEmpty else { return }
    stores.queue.enqueue(ordered)
    page.wrappedValue = .builds
    if !stores.build.running && stores.build.canStartBuildOrQueue {
        stores.build.startBuildOrQueue()
    }
}
