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
                && (item.isReady || item.hasIOSBuild(shellRoot: stores.build.shellCachePath) || !item.inputs["base", default: []].isEmpty || item.inputs[GameLibrary.folderInput] != nil)
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
                            Text("\(count)")
                                .font(.manrope(12, .bold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(LauncherPalette.notice)
                    } else {
                        Image(systemName: "bolt.horizontal")
                            .font(.system(size: 13, weight: .semibold))
                    }
                } else {
                    if count > 0 {
                        Label(a11y, systemImage: "square.stack.3d.up")
                            .foregroundStyle(LauncherPalette.notice)
                    } else {
                        Label(a11y, systemImage: "square.stack.3d.up")
                    }
                }
            }
            .frame(height: LauncherControl.height - 18)
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
        .overlay {
            if count > 0 {
                RoundedRectangle(cornerRadius: 9).strokeBorder(LauncherPalette.notice.opacity(0.45))
            }
        }
        .help(loc.t("batchRefresh.title"))
        .accessibilityLabel(a11y)
        .padTarget("hero.rebuildAll", scope: "main", radius: 9, activate: openBatchRefresh)
    }

    /// Scheme A: high-contrast platform-aware single-game refresh CTA next to heroPrimary.
    @ViewBuilder func heroSingleRefreshButton(_ game: LibraryGame, lightHero: Bool, compact: Bool) -> some View {
        let assessment = toolsAge.assessments[game.id]
        let (hasMac, hasIOS) = resolvedRefreshTargets(for: game)
        let isFast = assessment.map {
            (hasMac && $0.canFastRefreshMac) || (hasIOS && ($0.canFastRefreshIOS || $0.needsMissingImgGuideIOS))
        } ?? false
        let title = singleRefreshButtonTitle(assessment: assessment, hasMac: hasMac, hasIOS: hasIOS, isFast: isFast)
        let symbol = isFast ? "bolt.fill" : "arrow.clockwise"
        let accentColor = isFast ? LauncherPalette.ready : LauncherPalette.notice
        let versionText = assessment?.versionLabel ?? GameUpdateCatalog.releaseBaseVersion(AppUpdateStore.appVersion)
        let isProbing = toolsAge.singleRefreshProbingGameID != nil
        let isProbingThis = toolsAge.singleRefreshProbingGameID == game.id
        let perform = {
            guard !m.running, !isProbing else { return }
            triggerSingleRefresh(game)
        }

        Button(action: perform) {
            HStack(spacing: 8) {
                if isProbingThis {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(accentColor)
                }
                Text(title)
                    .font(.manrope(14.5, .bold))
                    .foregroundStyle(LauncherPalette.textStrong)
                    .lineLimit(1)
                if !compact && !versionText.isEmpty {
                    Text(versionText)
                        .font(.manrope(11.5, .bold))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(accentColor.opacity(lightHero ? 0.14 : 0.18), in: Capsule())
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, compact ? 16 : 20)
            .frame(height: 48)
            .background {
                Capsule().fill(lightHero ? Color.white.opacity(0.88) : Color.white.opacity(0.12))
            }
            .overlay(Capsule().strokeBorder(accentColor.opacity(lightHero ? 0.45 : 0.55), lineWidth: 1.2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .launcherHover(enabled: artworkEditor == nil && !isProbing)
        .disabled(m.running || isProbing)
        .help(loc.t("library.olderToolsHelp"))
        .accessibilityLabel(title)
        .padTarget("hero.rebuild", scope: "main", radius: 24, activate: perform)
    }

    func resolvedRefreshTargets(for game: LibraryGame) -> (hasMac: Bool, hasIOS: Bool) {
        let hasMac = game.isReady
        let hasIOS = game.hasIOSBuild(shellRoot: stores.build.shellCachePath)
        if hasMac || hasIOS {
            return (hasMac, hasIOS)
        }
        return game.lastTarget == BuildTarget.mac ? (true, false) : (false, true)
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
            if !assessment.hasUsableSeed && assessment.missingOriginalPackage {
                return loc.t("library.refresh.noteNeedRomOnce")
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

    func triggerSingleRefresh(_ game: LibraryGame) {
        guard !stores.build.running else {
            page = .builds
            return
        }
        guard toolsAge.singleRefreshProbingGameID == nil else { return }
        let assessment = toolsAge.assessments[game.id]
        if game.hasIOSBuild(shellRoot: stores.build.shellCachePath), let assessment, assessment.needsMissingImgGuideIOS {
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
                            enqueueSingleGameRefresh(game, assessment: assessment, externalIOSImgPath: foundImg)
                        } else {
                            missingImgGuideFor = MissingImgGuideContext(game: game, assessment: assessment)
                        }
                    }
                }
            } else {
                missingImgGuideFor = MissingImgGuideContext(game: game, assessment: assessment)
            }
            return
        }
        enqueueSingleGameRefresh(game, assessment: assessment, externalIOSImgPath: nil)
    }

    func enqueueSingleGameRefresh(_ game: LibraryGame, assessment: GameRefreshAssessment?, externalIOSImgPath: String?) {
        let batch = UUID()
        var entries: [QueueEntry] = []
        let hasMac = game.isReady
        let hasIOS = game.hasIOSBuild(shellRoot: stores.build.shellCachePath)

        if hasMac {
            let fastMac = assessment?.canFastRefreshMac ?? false
            if fastMac || assessment?.missingOriginalPackage != true {
                entries.append(RefreshQueueBuilder.makeEntry(
                    game: game,
                    target: BuildTarget.mac,
                    fastRefresh: fastMac,
                    externalImgPath: nil,
                    batch: batch,
                    stores: stores,
                    libraryFolder: library.folder
                ))
            }
        }

        if hasIOS {
            let fastIOS = (assessment?.canFastRefreshIOS ?? false) || externalIOSImgPath != nil
            if fastIOS || assessment?.missingOriginalPackage != true {
                entries.append(RefreshQueueBuilder.makeEntry(
                    game: game,
                    target: BuildTarget.ios,
                    fastRefresh: fastIOS,
                    externalImgPath: externalIOSImgPath,
                    batch: batch,
                    stores: stores,
                    libraryFolder: library.folder
                ))
            }
        }

        if !hasMac && !hasIOS {
            if !game.inputs["base", default: []].isEmpty || game.inputs[GameLibrary.folderInput] != nil {
                entries.append(QueueEntry(
                    game: game,
                    engineID: stores.engineSync.selection.engineID,
                    target: m.target,
                    batch: batch,
                    packageAfter: m.target != BuildTarget.mac && !m.exportsOneGame
                ))
            }
        }

        let ordered = RefreshQueueBuilder.orderedEntries(entries)
        guard !ordered.isEmpty else {
            configureBuild(game)
            return
        }
        stores.queue.enqueue(ordered)
        page = .builds
        if !m.running && m.canStartBuildOrQueue {
            m.startBuildOrQueue()
        }
    }
}
