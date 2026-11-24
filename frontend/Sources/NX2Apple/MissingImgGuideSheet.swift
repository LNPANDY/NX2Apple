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
    @EnvironmentObject private var pad: PadFocus
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
        return stores.build.refreshBuildsRoot
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
                .padding(.horizontal, DSSheetInsets.horizontal)
                .padding(.top, DSSheetInsets.vertical)
                .padding(.bottom, DSSheetInsets.gap)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DSSheetInsets.gap) {
                        optionOneCard
                        optionTwoCard
                    }
                    .padding(.horizontal, DSSheetInsets.horizontal)
                    .padding(.top, DS.Space.xxs)
                    .padding(.bottom, DSSheetInsets.gap)
                }
                .onChange(of: pad.focused) { id in
                    if let id, ["imgGuide.choose", "imgGuide.folder", "imgGuide.pull"].contains(id) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            footerSection
                .padding(.horizontal, DSSheetInsets.horizontal)
                .padding(.top, DSSheetInsets.gap)
                .padding(.bottom, DSSheetInsets.vertical)
        }
        .frame(width: 680)
        .frame(maxHeight: min(720, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
        .fixedSize(horizontal: false, vertical: true)
        .dsSheetSurface()
        .background(PadKeyboardInput(focus: pad, scope: "imgGuide", back: cancelGuide))
        .environment(\.padRingStyle, .hug)
        .padScope("imgGuide", pad)
        .onAppear {
            sheetClosed = false
            pad.scope = "imgGuide"
            _ = devices.refresh()
            if pad.visible {
                DispatchQueue.main.async { pad.show(default: "imgGuide.choose") }
            }
        }
        .onDisappear {
            cancelAsyncOperations(closing: true)
        }
    }

    private var headerSection: some View {
        DSSheetHeader(title: loc.t("imgGuide.title"), message: String(format: loc.t("imgGuide.subtitle"), gameDisplayName))
    }

    /// A line under an option when its step failed: the error symbol and the reason.
    private func failure(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Image(systemName: "xmark.octagon.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.statusError).accessibilityHidden(true)
            Text(text).font(DS.Font.callout).foregroundStyle(DS.Color.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// An option's card: its title, what it does and its buttons, no symbol tile of its own.
    private func optionCard<Content: View>(_ title: String, note: String, @ViewBuilder _ content: () -> Content) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(title).font(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).fixedSize(horizontal: false, vertical: true)
                    Text(note).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
        }
    }

    private var optionOneCard: some View {
        optionCard(loc.t("imgGuide.opt1Title"), note: loc.t("imgGuide.opt1Note")) {
            Button {
                pickExistingImg()
            } label: {
                HStack(spacing: DS.Space.xs) {
                    if validatingImg { ProgressView().controlSize(.small).tint(DS.Color.accentOn) }
                    Text(loc.t("imgGuide.chooseImgBtn"))
                }
                .font(DS.Font.bodyStrong)
                .padding(.horizontal, DS.Space.m)
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy)
            .padTarget("imgGuide.choose", scope: "imgGuide", focusColor: DS.Color.accentOn, enabled: !isBusy) { pickExistingImg() }

            if let error = imgValidationError { failure(error) }
        }
    }

    private var optionTwoCard: some View {
        let device = connectedDevice
        return optionCard(loc.t("imgGuide.opt2Title"), note: loc.t("imgGuide.opt2Note")) {
            optionTwoContent(device: device)
        }
    }

    @ViewBuilder private func optionTwoContent(device: AppleDevice?) -> some View {

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
                HStack(spacing: DS.Space.xs) {
                    ProgressView().controlSize(.small)
                    Text(String(format: loc.t("imgGuide.pulling"), pullingName))
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if device == nil {
                Text(loc.t("imgGuide.pullNoDevice"))
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = pullError { failure(error) }
    }

    private var openGamesFolderButton: some View {
        Button {
            openDefaultGamesFolder()
        } label: {
            Label(loc.t("imgGuide.openFolderBtn"), systemImage: "folder")
        }
        .buttonStyle(DSRowButtonStyle())
        .help(defaultGamesDisplayPath)
        .padTarget("imgGuide.folder", scope: "imgGuide", activate: openDefaultGamesFolder)
    }

    private func pullFromIPhoneButton(device: AppleDevice?) -> some View {
        Button {
            if let device {
                startPullFromDevice(device)
            }
        } label: {
            Label(loc.t("imgGuide.pullIPhoneBtn"), systemImage: "iphone.and.arrow.forward")
        }
        .buttonStyle(DSRowButtonStyle())
        .disabled(device == nil || isBusy)
        .padTarget("imgGuide.pull", scope: "imgGuide", enabled: device != nil && !isBusy) {
            if let device { startPullFromDevice(device) }
        }
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if assessment.missingOriginalPackage { DSInlineWarning(loc.t("imgGuide.noNspHint")) }
            DSSheetButtonRow {
                Button {
                    cancelAsyncOperations(closing: true)
                    onFallbackFullRebuild()
                } label: {
                    Text(loc.t("imgGuide.fullNspBtn"))
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(assessment.missingOriginalPackage || isBusy)
                .padTarget("imgGuide.full", scope: "imgGuide", enabled: !assessment.missingOriginalPackage && !isBusy) {
                    cancelAsyncOperations(closing: true)
                    onFallbackFullRebuild()
                }

            } buttons: {
                Button(loc.t("batchRefresh.cancel"), action: cancelGuide)
                .buttonStyle(DSSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padTarget("imgGuide.cancel", scope: "imgGuide", activate: cancelGuide)
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
                    let reason = err.localizedReason(loc.t)
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

    private func cancelGuide() {
        cancelAsyncOperations(closing: true)
        close()
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
        buildEditorOpen: Binding<Bool>,
        editingBuildResult: Binding<Bool>,
        buildStep: Binding<Int>,
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
                        buildEditorOpen.wrappedValue = false
                        editingBuildResult.wrappedValue = false
                        buildStep.wrappedValue = 0
                        if !stores.build.running && stores.build.canStartBuildOrQueue {
                            stores.build.startBuildOrQueue()
                        }
                    },
                    close: { batchOpen.wrappedValue = false },
                    recoverImage: { context in
                        batchOpen.wrappedValue = false
                        DispatchQueue.main.async { imgGuide.wrappedValue = context }
                    }
                )
                .environmentObject(stores.localizer)
                .environmentObject(pad)
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
                            page: page,
                            buildEditorOpen: buildEditorOpen,
                            editingBuildResult: editingBuildResult,
                            buildStep: buildStep
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
                            page: page,
                            buildEditorOpen: buildEditorOpen,
                            editingBuildResult: editingBuildResult,
                            buildStep: buildStep
                        )
                    },
                    close: { imgGuide.wrappedValue = nil }
                )
                .environmentObject(stores.localizer)
                .environmentObject(pad)
            }
            .onChange(of: batchOpen.wrappedValue) { open in
                pad.scope = open ? "batchRefresh" : scope()
            }
            .onChange(of: imgGuide.wrappedValue?.id) { id in
                pad.scope = id != nil ? "imgGuide" : scope()
            }
            .sheet(item: Binding(
                get: { stores.build.refreshCompletionSummary },
                set: { if $0 == nil { stores.build.refreshCompletionSummary = nil } }
            )) { summary in
                RefreshCompletionSheet(
                    summary: summary,
                    revealItem: { path in stores.build.revealItem(URL(fileURLWithPath: path)) },
                    onViewQueue: {
                        stores.build.refreshCompletionSummary = nil
                        page.wrappedValue = .builds
                        buildEditorOpen.wrappedValue = false
                        editingBuildResult.wrappedValue = false
                    },
                    close: { stores.build.refreshCompletionSummary = nil }
                )
                .environmentObject(stores.localizer)
                .environmentObject(pad)
            }
            .onChange(of: stores.build.refreshCompletionSummary?.id) { id in
                pad.scope = id != nil ? "refreshDone" : scope()
            }
    }
}

@MainActor private func enqueueSingleFromImgGuide(
    context: MissingImgGuideContext,
    externalIOSImgPath: String?,
    forceFullIOSRebuild: Bool,
    stores: LauncherStores,
    libraryFolder: String,
    page: Binding<LauncherPage>,
    buildEditorOpen: Binding<Bool>,
    editingBuildResult: Binding<Bool>,
    buildStep: Binding<Int>
) {
    let game = context.game
    let assessment = context.assessment
    let batch = UUID()
    var entries: [QueueEntry] = []

    if game.isReady {
        let useSeedMac = assessment.canSeedRefreshMac
        let rebuildMac = assessment.needsShaderRebuildMac
        if useSeedMac || !assessment.missingOriginalPackage {
            entries.append(RefreshQueueBuilder.makeEntry(
                game: game,
                target: BuildTarget.mac,
                fastRefresh: useSeedMac,
                rebuildsShaders: rebuildMac,
                externalImgPath: nil,
                batch: batch,
                stores: stores,
                libraryFolder: libraryFolder
            ))
        }
    }

    let useSeedIOS = !forceFullIOSRebuild && (assessment.canSeedRefreshIOS || externalIOSImgPath != nil)
    let rebuildIOS = useSeedIOS && (assessment.needsShaderRebuildIOS || !assessment.canFastRefreshIOS)
    if useSeedIOS || !assessment.missingOriginalPackage {
        entries.append(RefreshQueueBuilder.makeEntry(
            game: game,
            target: BuildTarget.ios,
            fastRefresh: useSeedIOS,
            rebuildsShaders: rebuildIOS,
            externalImgPath: externalIOSImgPath,
            batch: batch,
            stores: stores,
            libraryFolder: libraryFolder
        ))
    }

    let ordered = RefreshQueueBuilder.orderedEntries(entries)
    guard !ordered.isEmpty else { return }
    if !stores.build.running {
        stores.build.clearUnstartedDraft()
        stores.queue.prepareForRefreshBatch()
    }
    stores.queue.enqueue(ordered)
    page.wrappedValue = .builds
    buildEditorOpen.wrappedValue = false
    editingBuildResult.wrappedValue = false
    buildStep.wrappedValue = 0
    if !stores.build.running && stores.build.canStartBuildOrQueue {
        stores.build.startBuildOrQueue()
    }
}
