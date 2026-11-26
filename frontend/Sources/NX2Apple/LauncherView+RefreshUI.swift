import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Single-game and batch refresh UI controls, platform action labels, and seed/ROM guidance for LauncherView.
extension LauncherView {
    /// The games built with older tools that can be built again from the files the library holds.
    var olderToolsGames: [LibraryGame] {
        library.games.filter { toolsAge.older.contains($0.id) && !$0.inputs["base", default: []].isEmpty }
    }

    /// Whether a game has a pending engine or profile refresh.
    func gameNeedsRefresh(_ game: LibraryGame) -> Bool {
        if let assessment = toolsAge.assessments[game.id] {
            return assessment.heroState != .upToDate
        }
        return toolsAge.older.contains(game.id)
    }

    /// All built games in the library that currently have a pending refresh.
    var refreshableGames: [LibraryGame] {
        library.games.filter { item in
            if let assessment = toolsAge.assessments[item.id] {
                return assessment.heroState != .upToDate
            }
            return toolsAge.older.contains(item.id)
                && (item.nxnativeMacBuildForRefresh != nil || item.hasIOSBuild(shellRoot: stores.build.shellCachePath) || !item.inputs["base", default: []].isEmpty || item.inputs[GameLibrary.folderInput] != nil)
        }
    }

    var pendingBatchRefreshCount: Int {
        !toolsAge.assessments.isEmpty ? refreshableGames.count : olderToolsGames.count
    }

    func openBatchRefresh() {
        toolsAge.cancelSingleRefreshProbe()
        batchRefreshOpen = true
    }

    /// Scheme B: always-visible batch refresh entry in the collection header, placed immediately before Supported games.
    @ViewBuilder func collectionBatchRefreshButton(compact: Bool) -> some View {
        let count = pendingBatchRefreshCount
        let a11y = count > 0
            ? String(format: loc.t("library.refresh.batchBtn"), count)
            : loc.t("library.refresh.batchBtnIdle")
        Button(action: openBatchRefresh) {
            Group {
                if compact {
                    if count > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.horizontal.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DS.Color.statusWarning)   // refreshes are waiting: the symbol takes the status
                            Text("\(count)")
                                .font(DS.Font.callout.weight(.bold))
                                .monospacedDigit()
                        }
                    } else {
                        Image(systemName: "bolt.horizontal")
                            .font(.system(size: 13, weight: .semibold))
                    }
                } else {
                    if count > 0 {
                        Label { Text(a11y) } icon: {
                            Image(systemName: "square.stack.3d.up").foregroundStyle(DS.Color.statusWarning)
                        }
                    } else {
                        Label(a11y, systemImage: "square.stack.3d.up")
                    }
                }
            }
            .frame(height: LauncherControl.height - 18)
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
        .help(loc.t("batchRefresh.title"))
        .accessibilityLabel(a11y)
        .padTarget("hero.rebuildAll", scope: "main", radius: 100, activate: openBatchRefresh)
    }

    private static let heroRefreshDropdownID = UUID(uuidString: "A5E7FB6E-4FA4-4B1C-8001-000000000001")!

    /// Scheme A: high-contrast platform-aware single-game refresh CTA next to heroPrimary.
    @ViewBuilder func heroSingleRefreshButton(_ game: LibraryGame, compact: Bool) -> some View {
        let assessment = toolsAge.assessments[game.id]
        let (hasMac, hasIOS) = resolvedRefreshTargets(for: game)
        let isDual = hasMac && hasIOS
        let hasAnyFast = assessment.map {
            (hasMac && $0.canFastRefreshMac) || (hasIOS && $0.canFastRefreshIOS)
        } ?? false
        let hasAnyShaderRebuild = assessment.map {
            (hasMac && $0.needsShaderRebuildMac) || (hasIOS && $0.needsShaderRebuildIOS)
        } ?? false
        let isFast = hasAnyFast && !hasAnyShaderRebuild
        let title = singleRefreshButtonTitle(assessment: assessment, hasMac: hasMac, hasIOS: hasIOS, isFast: isFast)
        let symbol = isFast ? "bolt.fill" : "arrow.clockwise"
        let isProbing = toolsAge.singleRefreshProbingGameID != nil
        let isProbingThis = toolsAge.singleRefreshProbingGameID == game.id
        let perform = {
            guard !m.running, !isProbing else { return }
            if isDual {
                openHeroRefreshPlatformDropdown(for: game, title: title)
            } else {
                triggerSingleRefresh(game, targets: resolvedTargetSet(hasMac: hasMac, hasIOS: hasIOS))
            }
        }

        Button(action: perform) {
            HStack(spacing: 8) {
                if isProbingThis {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13.5, weight: .bold))
                }
                Text(title)
                    .font(.manrope(16, .semibold))
                    .lineLimit(1)
                if isDual {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10.5, weight: .bold))
                        .opacity(0.8)
                }
            }
        }
        .buttonStyle(LauncherSecondaryButtonStyle(height: LauncherHeroAction.height))
        .anchorPreference(key: LauncherDropdownAnchorKey.self, value: .bounds) {
            isDual ? [Self.heroRefreshDropdownID: $0] : [:]
        }
        .disabled(m.running || isProbing)
        .help(loc.t("library.olderToolsHelp"))
        .accessibilityLabel(title)
        .padTarget("hero.rebuild", scope: "main", radius: 24, activate: perform)
    }

    private func resolvedTargetSet(hasMac: Bool, hasIOS: Bool) -> Set<String>? {
        var targets: Set<String> = []
        if hasMac { targets.insert(BuildTarget.mac) }
        if hasIOS { targets.insert(BuildTarget.ios) }
        return targets.isEmpty ? nil : targets
    }

    private func openHeroRefreshPlatformDropdown(for game: LibraryGame, title: String) {
        dropdowns.request = LauncherDropdownRequest(
            id: Self.heroRefreshDropdownID,
            options: RefreshTargetScope.dropdownOptions(labels: loc.t),
            selection: RefreshTargetScope.both.rawValue,
            label: title
        ) { raw in
            dropdowns.close()
            padFocus.scope = currentPadScope
            let scope = RefreshTargetScope(rawValue: raw) ?? .both
            triggerSingleRefresh(game, targets: scope.targets)
        }
    }

    func resolvedRefreshTargets(for game: LibraryGame) -> (hasMac: Bool, hasIOS: Bool) {
        RefreshQueueBuilder.refreshPlatforms(for: game, shellRoot: stores.build.shellCachePath)
    }

    private func singleRefreshButtonTitle(
        assessment: GameRefreshAssessment?,
        hasMac: Bool,
        hasIOS: Bool,
        isFast: Bool
    ) -> String {
        guard assessment != nil else {
            return loc.t("library.rebuildShort")
        }
        if hasMac && hasIOS {
            return loc.t(isFast ? "library.refresh.singleFastBoth" : "library.refresh.singleRebuildBoth")
        }
        if hasMac {
            return loc.t(isFast ? "library.refresh.singleFastMac" : "library.refresh.singleRebuildMac")
        }
        return loc.t(isFast ? "library.refresh.singleFastIOS" : "library.refresh.singleRebuildIOS")
    }

    func heroRefreshNote(for game: LibraryGame) -> String? {
        if let assessment = toolsAge.assessments[game.id] {
            guard assessment.heroState != .upToDate else { return nil }
            let (hasMac, hasIOS) = resolvedRefreshTargets(for: game)
            let needsRebuild = (hasMac && assessment.needsShaderRebuildMac) || (hasIOS && assessment.needsShaderRebuildIOS)
            if !assessment.hasUsableSeed && assessment.missingOriginalPackage {
                return loc.t("library.refresh.noteNeedRomOnce")
            }
            if needsRebuild {
                return loc.t("library.refresh.noteShaderRebuild")
            }
            switch assessment.heroState {
            case .specificFast(let version):
                return String(format: loc.t("library.refresh.noteSpecificFast"), game.displayName(loc.lang), version)
            case .specificFull:
                return loc.t("library.refresh.noteSpecificFull")
            case .generalSync(let fast):
                return (!fast && !assessment.hasUsableSeed)
                    ? loc.t("library.refresh.noteSpecificFull")
                    : loc.t("library.refresh.noteGeneral")
            case .upToDate:
                return nil
            }
        }
        if toolsAge.older.contains(game.id) {
            return loc.t("library.olderToolsSafeNote")
        }
        return nil
    }

    func triggerSingleRefresh(_ game: LibraryGame, targets: Set<String>? = nil) {
        guard !stores.build.running else {
            page = .builds; buildEditorOpen = true
            return
        }
        guard toolsAge.singleRefreshProbingGameID == nil else { return }
        let normalizedTargets = targets.map { Set($0.map(BuildTarget.normalized)) }
        let wantsIOS = normalizedTargets?.contains(BuildTarget.ios) ?? true
        let assessment = toolsAge.assessments[game.id]
        if wantsIOS,
           game.hasIOSBuild(shellRoot: stores.build.shellCachePath) || normalizedTargets?.contains(BuildTarget.ios) == true,
           let assessment,
           assessment.needsMissingImgGuideIOS {
            let guideTargets = normalizedTargets ?? resolvedTargetSet(
                hasMac: game.nxnativeMacBuildForRefresh != nil,
                hasIOS: true
            ) ?? [BuildTarget.ios]
            let driveFolder = devices.driveFolder
            if !driveFolder.isEmpty {
                toolsAge.singleRefreshProbeGeneration &+= 1
                let probeGen = toolsAge.singleRefreshProbeGeneration
                let selectedSnapshot = library.selectedID
                let heroSnapshot = heroGame?.id
                toolsAge.singleRefreshProbingGameID = game.id
                let tid = game.titleID
                let expected = assessment.expectedRomfsIdentity
                DispatchQueue.global(qos: .userInitiated).async {
                    let foundImg = RomfsImageIdentity.scanExternalDriveForMatchingImage(
                        driveFolder: driveFolder,
                        titleID: tid,
                        expectedIdentity: expected
                    )
                    DispatchQueue.main.async {
                        guard probeGen == toolsAge.singleRefreshProbeGeneration else { return }
                        toolsAge.singleRefreshProbingGameID = nil
                        guard !stores.build.running,
                              page == .library,
                              library.selectedID == selectedSnapshot,
                              heroGame?.id == heroSnapshot,
                              library.games.contains(where: { $0.id == game.id }),
                              missingImgGuideFor == nil,
                              !batchRefreshOpen else { return }
                        if let foundImg {
                            enqueueSingleGameRefresh(
                                game,
                                assessment: assessment,
                                externalIOSImgPath: foundImg,
                                targets: normalizedTargets
                            )
                        } else {
                            missingImgGuideFor = MissingImgGuideContext(
                                game: game,
                                assessment: assessment,
                                targets: guideTargets
                            )
                        }
                    }
                }
            } else {
                missingImgGuideFor = MissingImgGuideContext(
                    game: game,
                    assessment: assessment,
                    targets: guideTargets
                )
            }
            return
        }
        enqueueSingleGameRefresh(game, assessment: assessment, externalIOSImgPath: nil, targets: normalizedTargets)
    }

    func enqueueSingleGameRefresh(
        _ game: LibraryGame,
        assessment: GameRefreshAssessment?,
        externalIOSImgPath: String?,
        targets: Set<String>? = nil,
        externalMacImgPath: String? = nil,
        allowTargetsWithoutExistingBuild: Bool = false
    ) {
        let ordered = RefreshQueueBuilder.singleGameEntries(
            for: game,
            assessment: assessment,
            externalIOSImgPath: externalIOSImgPath,
            stores: stores,
            libraryFolder: library.folder,
            targets: targets,
            externalMacImgPath: externalMacImgPath,
            allowTargetsWithoutExistingBuild: allowTargetsWithoutExistingBuild
        )
        guard !ordered.isEmpty else {
            configureBuild(game)
            return
        }
        if !m.running {
            m.clearUnstartedDraft()
            stores.queue.prepareForRefreshBatch()
        }
        stores.queue.enqueue(ordered)
        page = .builds; buildEditorOpen = false; editingBuildResult = false; buildStep = 0
        if !m.running && m.canStartBuildOrQueue {
            m.startBuildOrQueue()
        }
    }

    /// True when the game can be rebuilt via a cached build seed or an existing `.img` archive.
    func canRebuildGameFromSeedOrImg(_ game: LibraryGame) -> Bool {
        if toolsAge.assessments[game.id]?.hasUsableSeed == true {
            return true
        }
        if BuildSeedCache.inspect(titleID: game.titleID, seedRoot: m.seedCacheRoot, repoPath: m.repo.path).isUsable {
            return true
        }
        if let macApp = game.nxnativeMacBuildForRefresh?.appPath,
           FileManager.default.fileExists(atPath: (macApp as NSString).appendingPathComponent("Contents/Resources/romfs.img")) {
            return true
        }
        if !game.archivePath.isEmpty, RomFSArchive.primaryImagePath(in: game.archivePath) != nil {
            return true
        }
        let outDir = ToolsAge.resolvedOutputDirectory(for: game, libraryFolder: library.folder)
        let effectiveOutDir = !outDir.isEmpty ? outDir : (!m.outDir.isEmpty ? m.outDir : m.refreshBuildsRoot)
        return !RomFSArchive.reusableImages(
            root: effectiveOutDir,
            key: game.titleID,
            workDir: nil,
            macAppPath: game.nxnativeMacBuildForRefresh?.appPath
        ).isEmpty
    }

    /// Entry point for "Rebuild with current tools…": routes to the seed/`.img` mode sheet when usable seed or `.img` exists.
    func triggerLibraryRebuild(_ game: LibraryGame) {
        guard !m.running else {
            configureBuild(game)
            return
        }
        if canRebuildGameFromSeedOrImg(game) {
            rebuildSheetGame = game
        } else {
            configureBuild(game)
        }
    }

    func fallbackRebuildAssessment(for game: LibraryGame) -> GameRefreshAssessment {
        if let cached = toolsAge.assessments[game.id] {
            return cached
        }
        let outDir = ToolsAge.resolvedOutputDirectory(for: game, libraryFolder: library.folder)
        let effectiveOutDir = !outDir.isEmpty ? outDir : (!m.outDir.isEmpty ? m.outDir : m.refreshBuildsRoot)
        let hasReadable = ToolsAge.hasReadableSourceInputs(game)
        let macBuild = game.nxnativeMacBuildForRefresh
        return GameUpdateCatalog.assess(
            titleID: game.titleID,
            isMarkedOlder: toolsAge.older.contains(game.id),
            hasMacBuild: macBuild != nil,
            macAppPath: macBuild?.appPath ?? "",
            hasIOSBuild: game.hasIOSBuild(shellRoot: m.shellCachePath),
            hasReadableSourceInputs: hasReadable,
            outDir: effectiveOutDir,
            gameName: game.name,
            appVersion: AppUpdateStore.appVersion,
            gitSpecificChanged: false,
            seedRoot: m.seedCacheRoot,
            repoPath: m.repo.path
        )
    }

    func handleRebuildWithSeed(_ game: LibraryGame, targets: Set<String>, reusedImgPath: String?) {
        let assessment = fallbackRebuildAssessment(for: game)
        if targets.contains(BuildTarget.ios), reusedImgPath == nil, assessment.needsMissingImgGuideIOS {
            triggerSingleRefresh(game, targets: targets)
            return
        }
        enqueueSingleGameRefresh(
            game,
            assessment: assessment,
            externalIOSImgPath: reusedImgPath,
            targets: targets,
            externalMacImgPath: reusedImgPath,
            allowTargetsWithoutExistingBuild: true
        )
    }

    func handleRebuildChooseImg(_ game: LibraryGame, targets: Set<String>) {
        let assessment = fallbackRebuildAssessment(for: game)
        missingImgGuideFor = MissingImgGuideContext(game: game, assessment: assessment, targets: targets)
    }

    func handleRebuildFromPackage(_ game: LibraryGame, preferredTarget: String?) {
        configureBuild(game)
        if let preferredTarget, !m.isMacOnlyUpstreamSelected {
            m.target = BuildTarget.normalized(preferredTarget)
        }
    }
}
