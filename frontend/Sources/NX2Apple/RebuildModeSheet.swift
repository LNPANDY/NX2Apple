import SwiftUI
import NXCore
import NXLauncher
import NXModel

/// Target scope choices when refreshing or rebuilding a dual-platform game.
enum RefreshTargetScope: String, CaseIterable {
    case both
    case macOnly
    case iosOnly

    var targets: Set<String> {
        switch self {
        case .both: return [BuildTarget.mac, BuildTarget.ios]
        case .macOnly: return [BuildTarget.mac]
        case .iosOnly: return [BuildTarget.ios]
        }
    }

    static func dropdownOptions(labels t: (String) -> String) -> [(value: String, label: String)] {
        [
            (RefreshTargetScope.both.rawValue, t("library.refresh.scopeBoth")),
            (RefreshTargetScope.macOnly.rawValue, t("library.refresh.scopeMacOnly")),
            (RefreshTargetScope.iosOnly.rawValue, t("library.refresh.scopeIOSOnly"))
        ]
    }
}

/// Sheet shown from "Build again / Rebuild with current tools" when a game has a build seed or reusable `.img`.
struct RebuildModeSheet: View {
    let game: LibraryGame
    let assessment: GameRefreshAssessment?
    let stores: LauncherStores
    let libraryFolder: String
    let onRebuildWithSeed: (Set<String>, String?) -> Void
    let onChooseImg: (Set<String>) -> Void
    let onRebuildFromPackage: (String?) -> Void
    let close: () -> Void

    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus

    @State private var selectedScope: RefreshTargetScope = .both
    @State private var probing = true
    @State private var probeGeneration = 0
    @State private var hasUsableSeed = false
    @State private var macAppImgPath: String?
    @State private var archiveImgPath: String?
    @State private var driveImgPath: String?

    private var platforms: (hasMac: Bool, hasIOS: Bool) {
        RefreshQueueBuilder.refreshPlatforms(for: game, shellRoot: stores.build.shellCachePath)
    }

    private var isDualPlatform: Bool {
        platforms.hasMac && platforms.hasIOS
    }

    private var effectiveTargets: Set<String> {
        if isDualPlatform {
            return selectedScope.targets
        }
        var result: Set<String> = []
        if platforms.hasMac { result.insert(BuildTarget.mac) }
        if platforms.hasIOS { result.insert(BuildTarget.ios) }
        return result.isEmpty ? [game.lastTarget == BuildTarget.mac ? BuildTarget.mac : BuildTarget.ios] : result
    }

    private var preferredPackageTarget: String? {
        guard isDualPlatform else { return nil }
        switch selectedScope {
        case .macOnly: return BuildTarget.mac
        case .iosOnly, .both: return BuildTarget.ios
        }
    }

    private var bestReusableImgPath: String? {
        archiveImgPath ?? macAppImgPath ?? driveImgPath
    }

    private var seedReadyForSelectedTargets: Bool {
        guard hasUsableSeed else { return false }
        let targets = effectiveTargets
        if targets == [BuildTarget.mac] {
            return game.nxnativeMacBuildForRefresh != nil || bestReusableImgPath != nil
        }
        return bestReusableImgPath != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSheetHeader(
                title: loc.t("rebuildMode.title"),
                message: String(format: loc.t("rebuildMode.subtitle"), game.displayName(loc.lang))
            )
            .padding(.horizontal, DSSheetInsets.horizontal)
            .padding(.top, DSSheetInsets.vertical)
            .padding(.bottom, DSSheetInsets.gap)

            ScrollView {
                VStack(alignment: .leading, spacing: DSSheetInsets.gap) {
                    if isDualPlatform {
                        platformSelectorCard
                    }
                    seedAndImgCard
                    originalPackageCard
                    autoFetchCheatsCard
                }
                .padding(.horizontal, DSSheetInsets.horizontal)
                .padding(.top, DS.Space.xxs)
                .padding(.bottom, DSSheetInsets.gap)
            }

            footerSection
                .padding(.horizontal, DSSheetInsets.horizontal)
                .padding(.top, DSSheetInsets.gap)
                .padding(.bottom, DSSheetInsets.vertical)
        }
        .frame(width: 620)
        .frame(maxHeight: min(680, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
        .fixedSize(horizontal: false, vertical: true)
        .dsSheetSurface()
        .background(PadKeyboardInput(focus: pad, scope: "rebuildMode", back: close))
        .environment(\.padRingStyle, .hug)
        .padScope("rebuildMode", pad)
        .onAppear {
            pad.scope = "rebuildMode"
            probeRebuildResources()
            if pad.visible {
                DispatchQueue.main.async { pad.show(default: "rebuildMode.seedPrimary") }
            }
        }
        .onDisappear {
            probeGeneration &+= 1
        }
    }

    private var platformSelectorCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(loc.t("rebuildMode.targetTitle"))
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.textPrimary)
                LauncherSegmented(
                    options: RefreshTargetScope.dropdownOptions(labels: loc.t),
                    selection: selectedScope.rawValue,
                    size: 13,
                    semibold: true
                ) { raw in
                    if let scope = RefreshTargetScope(rawValue: raw) {
                        selectedScope = scope
                    }
                }
                .padTarget("rebuildMode.target", scope: "rebuildMode", activate: {
                    cycleTargetScope(by: 1)
                }, adjust: { delta in
                    cycleTargetScope(by: delta >= 0 ? 1 : -1)
                })
            }
        }
    }

    private var seedAndImgCard: some View {
        let targets = effectiveTargets
        let canDirectSeed = seedReadyForSelectedTargets
        let imgSourceNote: String = {
            if macAppImgPath != nil && archiveImgPath == nil && targets.contains(BuildTarget.ios) {
                return loc.t("rebuildMode.reuseMacImgNote")
            }
            if bestReusableImgPath != nil {
                return loc.t("rebuildMode.foundImgNote")
            }
            return loc.t("rebuildMode.needImgNote")
        }()

        return DSCard {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(loc.t("rebuildMode.seedTitle"))
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(DS.Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(probing ? loc.t("rebuildMode.checking") : imgSourceNote)
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.s) {
                        seedPrimaryButton(canDirectSeed: canDirectSeed, targets: targets)
                        chooseImgButton(targets: targets)
                    }
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        seedPrimaryButton(canDirectSeed: canDirectSeed, targets: targets)
                        chooseImgButton(targets: targets)
                    }
                }
            }
        }
    }

    @ViewBuilder private func seedPrimaryButton(canDirectSeed: Bool, targets: Set<String>) -> some View {
        let action = {
            guard !probing else { return }
            if canDirectSeed {
                onRebuildWithSeed(targets, bestReusableImgPath)
            } else {
                onChooseImg(targets)
            }
        }
        let labelKey: String = {
            if canDirectSeed {
                if macAppImgPath != nil && archiveImgPath == nil && targets.contains(BuildTarget.ios) {
                    return "rebuildMode.useMacImgBtn"
                }
                return "rebuildMode.useSeedBtn"
            }
            return "imgGuide.chooseImgBtn"
        }()

        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                if probing { ProgressView().controlSize(.small).tint(DS.Color.accentOn) }
                Text(loc.t(labelKey))
            }
            .font(DS.Font.bodyStrong)
            .padding(.horizontal, DS.Space.m)
        }
        .buttonStyle(DSPrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(probing)
        .padTarget("rebuildMode.seedPrimary", scope: "rebuildMode", focusColor: DS.Color.accentOn, enabled: !probing, activate: action)
    }

    private func chooseImgButton(targets: Set<String>) -> some View {
        Button {
            onChooseImg(targets)
        } label: {
            Label(loc.t("rebuildMode.pickImgBtn"), systemImage: "doc.badge.plus")
        }
        .buttonStyle(DSRowButtonStyle())
        .disabled(probing)
        .padTarget("rebuildMode.pickImg", scope: "rebuildMode", enabled: !probing) {
            onChooseImg(targets)
        }
    }

    private var originalPackageCard: some View {
        let hasSources = !game.inputs["base", default: []].isEmpty || game.inputs[GameLibrary.folderInput] != nil
        return DSCard {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(loc.t("rebuildMode.packageTitle"))
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(DS.Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(loc.t(hasSources ? "rebuildMode.packageNote" : "rebuildMode.packageMissingNote"))
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    onRebuildFromPackage(preferredPackageTarget)
                } label: {
                    Label(loc.t("rebuildMode.packageBtn"), systemImage: "folder.badge.gearshape")
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .padTarget("rebuildMode.package", scope: "rebuildMode") {
                    onRebuildFromPackage(preferredPackageTarget)
                }
            }
        }
    }

    private var footerSection: some View {
        DSSheetButtonRow { EmptyView() } buttons: {
            Button(loc.t("batchRefresh.cancel"), action: close)
                .buttonStyle(DSSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padTarget("rebuildMode.cancel", scope: "rebuildMode", activate: close)
        }
    }

    private var autoFetchCheatsCard: some View {
        let binding = Binding<Bool>(
            get: { stores.build.autoFetchCheats },
            set: { stores.build.autoFetchCheats = $0 }
        )
        return DSCard {
            HStack(alignment: .center, spacing: DS.Space.s) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(loc.t("opt.autoFetchCheats"))
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(DS.Color.textPrimary)
                    Text(loc.t("opt.autoFetchCheats.note"))
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.s)
                Toggle(loc.t("opt.autoFetchCheats"), isOn: binding)
                    .toggleStyle(LauncherSwitchStyle())
                    .labelsHidden()
                    .padTarget("rebuildMode.autoFetchCheats", scope: "rebuildMode", activate: { binding.wrappedValue.toggle() }, adjust: { _ in binding.wrappedValue.toggle() })
            }
        }
    }

    private func cycleTargetScope(by step: Int) {
        let all = RefreshTargetScope.allCases
        guard let idx = all.firstIndex(of: selectedScope) else { return }
        selectedScope = all[(idx + step + all.count) % all.count]
    }

    private func probeRebuildResources() {
        probeGeneration &+= 1
        let gen = probeGeneration
        probing = true
        let gameSnapshot = game
        let outDir = ToolsAge.resolvedOutputDirectory(for: game, libraryFolder: libraryFolder)
        let effectiveOutDir = !outDir.isEmpty ? outDir : (!stores.build.outDir.isEmpty ? stores.build.outDir : stores.build.refreshBuildsRoot)
        let seedRoot = stores.build.seedCacheRoot
        let repoPath = stores.repo.path
        let driveFolder = stores.deviceStore.driveFolder
        let expectedIdentity = assessment?.expectedRomfsIdentity

        DispatchQueue.global(qos: .userInitiated).async {
            let inspection = BuildSeedCache.inspect(titleID: gameSnapshot.titleID, seedRoot: seedRoot, repoPath: repoPath)
            let seedOK = inspection.isUsable
            let identity = expectedIdentity ?? inspection.record?.romfsIdentity

            let macCandidate = MissingImgGuideSheet.matchingMacAppRomfsPath(for: gameSnapshot, expectedIdentity: identity)

            var directArchiveImg: String?
            if !gameSnapshot.archivePath.isEmpty,
               let primary = RomFSArchive.primaryImagePath(in: gameSnapshot.archivePath) {
                if let identity, !identity.isEmpty {
                    if RomfsImageIdentity.matches(imagePath: primary, expectedIdentityLine: identity) {
                        directArchiveImg = primary
                    }
                } else {
                    directArchiveImg = primary
                }
            }
            if directArchiveImg == nil {
                for cand in RomFSArchive.reusableImages(
                    root: effectiveOutDir,
                    key: gameSnapshot.titleID,
                    workDir: nil,
                    macAppPath: nil
                ) {
                    if let identity, !identity.isEmpty {
                        if RomfsImageIdentity.matches(imagePath: cand, expectedIdentityLine: identity) {
                            directArchiveImg = cand
                            break
                        }
                    } else if RomfsImageIdentity.computeIdentity(of: cand) != nil {
                        directArchiveImg = cand
                        break
                    }
                }
            }

            var driveCandidate: String?
            if directArchiveImg == nil, macCandidate == nil, !driveFolder.isEmpty {
                driveCandidate = RomfsImageIdentity.scanExternalDriveForMatchingImage(
                    driveFolder: driveFolder,
                    titleID: gameSnapshot.titleID,
                    expectedIdentity: identity
                )
            }

            DispatchQueue.main.async {
                guard gen == probeGeneration else { return }
                probing = false
                hasUsableSeed = seedOK
                macAppImgPath = macCandidate
                archiveImgPath = directArchiveImg
                driveImgPath = driveCandidate
            }
        }
    }
}
