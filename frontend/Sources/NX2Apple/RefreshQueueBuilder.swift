import Foundation
import NXCore
import NXModel

/// Shared helper that constructs target-locked queue entries for single-game and batch refresh flows.
@MainActor enum RefreshQueueBuilder {
    static func makeEntry(
        game: LibraryGame,
        target: String,
        fastRefresh: Bool,
        rebuildsShaders: Bool = false,
        externalImgPath: String? = nil,
        batch: UUID,
        stores: LauncherStores,
        libraryFolder: String
    ) -> QueueEntry {
        let normalizedTarget = BuildTarget.normalized(target)
        let isMac = normalizedTarget == BuildTarget.mac
        let outDir = ToolsAge.resolvedOutputDirectory(for: game, libraryFolder: libraryFolder)
        let exportsOneGame = stores.build.exportsOneGame
        let exportsFramework = stores.build.exportsFramework
        let exportsIPA = stores.deviceStore.exportIPA
        let installDevice = stores.deviceStore.installDevice
        let packageAfter = !isMac && !exportsOneGame && !exportsFramework
        let entryExportIPA: Bool? = isMac ? nil : exportsIPA
        let entryExportFramework: Bool? = (!isMac && exportsIPA) ? (exportsFramework ? true : false) : nil
        let destName: String? = (isMac || exportsIPA || installDevice.isEmpty)
            ? nil
            : stores.deviceStore.deviceName(installDevice)

        var entry = QueueEntry(
            gameID: game.id,
            titleID: game.titleID,
            name: game.name,
            target: normalizedTarget,
            inputs: game.inputs.filter { $0.key != GameLibrary.folderInput },
            gameFolder: game.inputs[GameLibrary.folderInput]?.first,
            outputDirectory: outDir,
            engineID: stores.engineSync.selection.engineID,
            batch: batch,
            packageAfter: packageAfter,
            exportIPA: entryExportIPA,
            exportFramework: entryExportFramework,
            destinationName: destName,
            autoFetchCheats: stores.build.autoFetchCheats
        )
        entry.fastRefresh = fastRefresh
        entry.rebuildsShaders = fastRefresh && rebuildsShaders
        entry.upstream = .nxnative
        entry.locksTarget = true
        entry.existingAppPath = isMac ? game.nxnativeMacBuildForRefresh?.appPath : nil
        entry.externalImgPath = externalImgPath
        entry.archivePath = game.archivePath.isEmpty ? nil : game.archivePath
        return entry
    }

    static func orderedEntries(_ entries: [QueueEntry]) -> [QueueEntry] {
        let pureFast = entries.filter { $0.fastRefresh && !$0.rebuildsShaders }
        let seedRebuild = entries.filter { $0.fastRefresh && $0.rebuildsShaders }
        let full = entries.filter { !$0.fastRefresh }
        return pureFast + seedRebuild + full
    }

    static func refreshPlatforms(for game: LibraryGame, shellRoot: String) -> (hasMac: Bool, hasIOS: Bool) {
        let hasMac = game.nxnativeMacBuildForRefresh != nil
        let hasIOS = game.hasIOSBuild(shellRoot: shellRoot)
        if hasMac || hasIOS {
            return (hasMac, hasIOS)
        }
        guard game.sortedMacBuilds.isEmpty else {
            return (false, false)
        }
        return game.lastTarget == BuildTarget.mac ? (true, false) : (false, true)
    }

    static func singleGameEntries(
        for game: LibraryGame,
        assessment: GameRefreshAssessment?,
        externalIOSImgPath: String?,
        stores: LauncherStores,
        libraryFolder: String,
        targets: Set<String>? = nil,
        externalMacImgPath: String? = nil,
        forceFullRebuildTargets: Set<String> = [],
        allowTargetsWithoutExistingBuild: Bool = false
    ) -> [QueueEntry] {
        let batch = UUID()
        var entries: [QueueEntry] = []
        let normalizedTargets: Set<String>? = targets.map { Set($0.map(BuildTarget.normalized)) }
        let normalizedForceFull = Set(forceFullRebuildTargets.map(BuildTarget.normalized))
        let hasMac = game.nxnativeMacBuildForRefresh != nil
        let hasIOS = game.hasIOSBuild(shellRoot: stores.build.shellCachePath)
        let wantsMac = (hasMac || (allowTargetsWithoutExistingBuild && normalizedTargets != nil))
            && (normalizedTargets?.contains(BuildTarget.mac) ?? true)
        let wantsIOS = (hasIOS || (allowTargetsWithoutExistingBuild && normalizedTargets != nil))
            && (normalizedTargets?.contains(BuildTarget.ios) ?? true)

        if wantsMac {
            let forceFullMac = normalizedForceFull.contains(BuildTarget.mac)
            let useMacExternalImg = hasMac ? nil : externalMacImgPath
            let useSeedMac = !forceFullMac && (assessment?.canSeedRefreshMac == true || (useMacExternalImg != nil && assessment?.hasUsableSeed == true))
            let rebuildMac = useSeedMac && (assessment?.needsShaderRebuildMac == true || !hasMac)
            if useSeedMac || assessment?.missingOriginalPackage != true {
                entries.append(makeEntry(
                    game: game,
                    target: BuildTarget.mac,
                    fastRefresh: useSeedMac,
                    rebuildsShaders: rebuildMac,
                    externalImgPath: useMacExternalImg,
                    batch: batch,
                    stores: stores,
                    libraryFolder: libraryFolder
                ))
            }
        }

        if wantsIOS {
            let forceFullIOS = normalizedForceFull.contains(BuildTarget.ios)
            let useSeedIOS = !forceFullIOS && ((assessment?.canSeedRefreshIOS == true) || externalIOSImgPath != nil)
            let rebuildIOS = useSeedIOS && ((assessment?.needsShaderRebuildIOS == true) || (externalIOSImgPath != nil && assessment?.canFastRefreshIOS != true))
            if useSeedIOS || assessment?.missingOriginalPackage != true {
                entries.append(makeEntry(
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
        }

        if !hasMac && !hasIOS && entries.isEmpty && normalizedTargets == nil {
            guard game.sortedMacBuilds.isEmpty else { return [] }
            let m = stores.build
            if !game.inputs["base", default: []].isEmpty || game.inputs[GameLibrary.folderInput] != nil {
                var fallbackEntry = QueueEntry(
                    game: game,
                    engineID: stores.engineSync.selection.engineID,
                    target: m.target,
                    batch: batch,
                    packageAfter: m.target != BuildTarget.mac && !m.exportsOneGame && !m.exportsFramework,
                    exportIPA: (m.target != BuildTarget.mac && m.exportsShell) ? true : nil,
                    exportFramework: m.exportsFramework ? true : nil,
                    autoFetchCheats: m.autoFetchCheats
                )
                fallbackEntry.upstream = .nxnative
                entries.append(fallbackEntry)
            }
        }

        return orderedEntries(entries)
    }
}
