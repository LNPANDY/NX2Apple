import AppKit
import SwiftUI
import NXCore
import NXLauncher
import NXModel

/// Shared helper that constructs target-locked queue entries for single-game and batch refresh flows.
@MainActor enum RefreshQueueBuilder {
    static func makeEntry(
        game: LibraryGame,
        target: String,
        fastRefresh: Bool,
        externalImgPath: String? = nil,
        batch: UUID,
        stores: LauncherStores,
        libraryFolder: String
    ) -> QueueEntry {
        let normalizedTarget = BuildTarget.normalized(target)
        let isMac = normalizedTarget == BuildTarget.mac
        let outDir = ToolsAge.resolvedOutputDirectory(for: game, libraryFolder: libraryFolder)
        let exportsOneGame = stores.build.exportsOneGame
        let exportsIPA = stores.deviceStore.exportIPA
        let installDevice = stores.deviceStore.installDevice
        let packageAfter = !isMac && !exportsOneGame
        let entryExportIPA: Bool? = isMac ? nil : exportsIPA
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
            destinationName: destName
        )
        entry.fastRefresh = fastRefresh
        entry.locksTarget = true
        entry.existingAppPath = (isMac && !game.appPath.isEmpty) ? game.appPath : nil
        entry.externalImgPath = isMac ? nil : externalImgPath
        return entry
    }

    static func orderedEntries(_ entries: [QueueEntry]) -> [QueueEntry] {
        let fast = entries.filter(\.fastRefresh)
        let full = entries.filter { !$0.fastRefresh }
        return fast + full
    }
}

/// Batch refresh checklist sheet grouping refreshable built games into fast-refresh and full-rebuild sections,
/// with independent per-platform Mac and iPhone switches.
struct BatchRefreshSheet: View {
    struct PlatformSelection: Hashable {
        let gameID: UUID
        let target: String
    }

    private struct CandidateRow: Identifiable {
        let game: LibraryGame
        let assessment: GameRefreshAssessment
        let hasMac: Bool
        let hasIOS: Bool
        let canFastMac: Bool
        let canFastIOS: Bool
        let disabledMac: Bool
        let disabledIOS: Bool
        let externalIOSImgPath: String?

        var id: UUID { game.id }

        var isFastGroup: Bool {
            (hasMac && canFastMac) || (hasIOS && canFastIOS)
        }

        var showsMissingPackageHint: Bool {
            (hasMac && disabledMac) || (hasIOS && disabledIOS)
        }

        var enabledTargets: [String] {
            var list: [String] = []
            if hasMac && !disabledMac { list.append(BuildTarget.mac) }
            if hasIOS && !disabledIOS { list.append(BuildTarget.ios) }
            return list
        }
    }

    private struct PlannedItem {
        let game: LibraryGame
        let target: String
        let fastRefresh: Bool
        let externalImgPath: String?
    }

    @ObservedObject var library: GameLibrary
    @ObservedObject var toolsAge: ToolsAge
    let stores: LauncherStores
    var appVersion: String = AppUpdateStore.appVersion
    let onConfirmed: () -> Void
    let close: () -> Void

    @EnvironmentObject var loc: Localizer
    @State private var selected: Set<PlatformSelection> = []
    @State private var didSeedSelection = false
    @State private var externalDriveImages: [UUID: String] = [:]
    @State private var driveScanGeneration = 0

    private var baseVersion: String {
        GameUpdateCatalog.releaseBaseVersion(appVersion)
    }

    private var rows: [CandidateRow] {
        library.games.compactMap { game in
            let assessment: GameRefreshAssessment
            if let computed = toolsAge.assessments[game.id] {
                guard computed.heroState != .upToDate else { return nil }
                assessment = computed
            } else if toolsAge.older.contains(game.id) {
                let missingPkg = game.inputs[GameLibrary.folderInput] == nil && game.inputs["base", default: []].isEmpty
                assessment = GameRefreshAssessment(
                    heroState: .generalSync(fast: false),
                    hasSpecificUpdate: false,
                    versionLabel: baseVersion,
                    canFastRefreshMac: false,
                    canFastRefreshIOS: false,
                    needsMissingImgGuideIOS: false,
                    missingOriginalPackage: missingPkg,
                    expectedRomfsIdentity: nil
                )
            } else {
                return nil
            }

            var hasMac = game.isReady
            var hasIOS = game.hasIOSBuild
            if !hasMac && !hasIOS {
                if game.lastTarget == BuildTarget.mac {
                    hasMac = true
                } else {
                    hasIOS = true
                }
            }

            let extImg = externalDriveImages[game.id]
            let canFastMac = hasMac && assessment.canFastRefreshMac
            let canFastIOS = hasIOS && (assessment.canFastRefreshIOS || (assessment.needsMissingImgGuideIOS && extImg != nil))
            let disabledMac = hasMac && !canFastMac && assessment.missingOriginalPackage
            let disabledIOS = hasIOS && !canFastIOS && assessment.missingOriginalPackage

            return CandidateRow(
                game: game,
                assessment: assessment,
                hasMac: hasMac,
                hasIOS: hasIOS,
                canFastMac: canFastMac,
                canFastIOS: canFastIOS,
                disabledMac: disabledMac,
                disabledIOS: disabledIOS,
                externalIOSImgPath: extImg
            )
        }
    }

    private var fastRows: [CandidateRow] {
        rows.filter(\.isFastGroup)
    }

    private var fullRows: [CandidateRow] {
        rows.filter { !$0.isFastGroup }
    }

    private var plannedItems: [PlannedItem] {
        var list: [PlannedItem] = []
        for row in rows {
            if row.hasMac && !row.disabledMac && selected.contains(PlatformSelection(gameID: row.id, target: BuildTarget.mac)) {
                list.append(PlannedItem(
                    game: row.game,
                    target: BuildTarget.mac,
                    fastRefresh: row.canFastMac,
                    externalImgPath: nil
                ))
            }
            if row.hasIOS && !row.disabledIOS && selected.contains(PlatformSelection(gameID: row.id, target: BuildTarget.ios)) {
                list.append(PlannedItem(
                    game: row.game,
                    target: BuildTarget.ios,
                    fastRefresh: row.canFastIOS,
                    externalImgPath: row.externalIOSImgPath
                ))
            }
        }
        return list
    }

    private var selectedFastCount: Int {
        plannedItems.filter(\.fastRefresh).count
    }

    private var selectedFullCount: Int {
        plannedItems.filter { !$0.fastRefresh }.count
    }

    private var totalSelectedCount: Int {
        plannedItems.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 18)

            ScrollView {
                if rows.isEmpty {
                    Text(loc.t("batchRefresh.empty"))
                        .font(.manrope(14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 28)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        if !fastRows.isEmpty {
                            groupSection(
                                title: loc.t("batchRefresh.groupFast"),
                                symbol: "bolt.fill",
                                symbolColor: LauncherPalette.ready,
                                items: fastRows
                            )
                        }
                        if !fullRows.isEmpty {
                            groupSection(
                                title: loc.t("batchRefresh.groupFull"),
                                symbol: "arrow.triangle.2.circlepath",
                                symbolColor: LauncherPalette.notice,
                                items: fullRows
                            )
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 20)
                }
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
            seedSelectionIfNeeded()
            scanExternalDriveIfNeeded()
        }
        .onDisappear {
            driveScanGeneration &+= 1
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(loc.t("batchRefresh.title"))
                    .font(.manrope(26, .heavy))
                    .tracking(-0.5)
                Text(String(format: loc.t("batchRefresh.versionBadge"), baseVersion))
                    .font(.manrope(12, .bold))
                    .foregroundStyle(LauncherPalette.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(LauncherPalette.ink(0.08), in: Capsule())
                    .overlay(Capsule().strokeBorder(LauncherPalette.ink(0.16)))
            }
            Text(loc.t("batchRefresh.subtitle"))
                .font(.manrope(13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func groupSection(title: String, symbol: String, symbolColor: Color, items: [CandidateRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(symbolColor)
                Text(title)
                    .font(.manrope(13, .bold))
                    .foregroundStyle(LauncherPalette.secondaryText)
            }
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().opacity(0.25).padding(.leading, 16)
                    }
                    candidateRowView(row)
                }
            }
            .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LauncherPalette.cardBorder))
        }
    }

    private func candidateRowView(_ row: CandidateRow) -> some View {
        let enabled = row.enabledTargets
        let checkedTargets = enabled.filter { selected.contains(PlatformSelection(gameID: row.id, target: $0)) }
        let allOn = !enabled.isEmpty && checkedTargets.count == enabled.count
        let partialOn = !checkedTargets.isEmpty && !allOn
        let checkSymbol = allOn ? "checkmark.square.fill" : (partialOn ? "minus.square.fill" : "square")

        return HStack(alignment: .center, spacing: 12) {
            Button { toggleRow(row) } label: {
                HStack(alignment: .center, spacing: 11) {
                    Image(systemName: checkSymbol)
                        .font(.system(size: 17))
                        .foregroundStyle((allOn || partialOn) ? LauncherPalette.ready : .secondary)
                        .opacity(enabled.isEmpty ? 0.35 : 1)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(row.game.displayName(loc.lang))
                                .font(.manrope(14, .semibold))
                                .foregroundStyle(LauncherPalette.text)
                                .lineLimit(1)
                            if row.assessment.hasSpecificUpdate {
                                Text(String(format: loc.t("library.refresh.badgeVersion"), row.assessment.versionLabel))
                                    .font(.manrope(11, .semibold))
                                    .foregroundStyle(LauncherPalette.notice)
                                    .lineLimit(1)
                            }
                        }
                        if row.showsMissingPackageHint {
                            Text(loc.t("batchRefresh.missingPackage"))
                                .font(.manrope(11.5))
                                .foregroundStyle(LauncherPalette.building)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(enabled.isEmpty)

            HStack(spacing: 8) {
                if row.hasMac {
                    platformTogglePill(
                        label: loc.t("batchRefresh.platformMac"),
                        symbol: "desktopcomputer",
                        isOn: !row.disabledMac && selected.contains(PlatformSelection(gameID: row.id, target: BuildTarget.mac)),
                        isFast: row.canFastMac,
                        disabled: row.disabledMac
                    ) {
                        togglePlatform(gameID: row.id, target: BuildTarget.mac)
                    }
                }
                if row.hasIOS {
                    platformTogglePill(
                        label: loc.t("batchRefresh.platformIOS"),
                        symbol: "iphone",
                        isOn: !row.disabledIOS && selected.contains(PlatformSelection(gameID: row.id, target: BuildTarget.ios)),
                        isFast: row.canFastIOS,
                        disabled: row.disabledIOS
                    ) {
                        togglePlatform(gameID: row.id, target: BuildTarget.ios)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func platformTogglePill(
        label: String,
        symbol: String,
        isOn: Bool,
        isFast: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isOn ? LauncherPalette.ready : LauncherPalette.secondaryText)
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(LauncherPalette.secondaryText)
                Text(label)
                    .font(.manrope(12.5, .semibold))
                    .foregroundStyle(LauncherPalette.text)
                    .lineLimit(1)
                if isFast {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LauncherPalette.ready)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isOn ? LauncherPalette.selectedFill : LauncherPalette.ink(0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? LauncherPalette.selectedBorder : LauncherPalette.secondaryBorder))
            .opacity(disabled ? 0.4 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var footerSection: some View {
        let summaryText = Text(String(format: loc.t("batchRefresh.summary"), selectedFastCount, selectedFullCount))
            .font(.manrope(13, .medium))
            .foregroundStyle(LauncherPalette.secondaryText)
            .lineLimit(1)

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                summaryText
                Spacer(minLength: 10)
                footerButtons
            }
            VStack(alignment: .leading, spacing: 12) {
                summaryText
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    footerButtons
                }
            }
        }
    }

    private var footerButtons: some View {
        HStack(spacing: 10) {
            Button(loc.t("batchRefresh.cancel"), action: close)
                .buttonStyle(LauncherSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)

            Button(String(format: loc.t("batchRefresh.onlyFast"), selectedFastCount)) {
                confirm(onlyFast: true)
            }
            .buttonStyle(LauncherSecondaryButtonStyle())
            .disabled(selectedFastCount == 0)

            Button {
                confirm(onlyFast: false)
            } label: {
                Text(String(format: loc.t("batchRefresh.allSelected"), totalSelectedCount))
                    .font(.manrope(13.5, .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
            }
            .buttonStyle(LauncherActionButtonStyle())
            .disabled(totalSelectedCount == 0)
            .opacity(totalSelectedCount == 0 ? 0.45 : 1)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func seedSelectionIfNeeded() {
        guard !didSeedSelection else { return }
        didSeedSelection = true
        var initial: Set<PlatformSelection> = []
        for row in rows {
            for target in row.enabledTargets {
                initial.insert(PlatformSelection(gameID: row.id, target: target))
            }
        }
        selected = initial
    }

    private func scanExternalDriveIfNeeded() {
        let driveFolder = stores.deviceStore.driveFolder
        guard !driveFolder.isEmpty else { return }
        let pending = rows
            .filter { $0.hasIOS && $0.assessment.needsMissingImgGuideIOS && externalDriveImages[$0.id] == nil }
            .map { (id: $0.id, titleID: $0.game.titleID, expected: $0.assessment.expectedRomfsIdentity, wasDisabled: $0.disabledIOS) }
        guard !pending.isEmpty else { return }

        driveScanGeneration &+= 1
        let gen = driveScanGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            var matched: [(id: UUID, path: String, wasDisabled: Bool)] = []
            for item in pending {
                if let img = RomfsImageIdentity.scanExternalDriveForMatchingImage(
                    driveFolder: driveFolder,
                    titleID: item.titleID,
                    expectedIdentity: item.expected
                ) {
                    matched.append((item.id, img, item.wasDisabled))
                }
            }
            guard !matched.isEmpty else { return }
            DispatchQueue.main.async {
                guard gen == driveScanGeneration else { return }
                for hit in matched {
                    externalDriveImages[hit.id] = hit.path
                    if hit.wasDisabled {
                        selected.insert(PlatformSelection(gameID: hit.id, target: BuildTarget.ios))
                    }
                }
            }
        }
    }

    private func toggleRow(_ row: CandidateRow) {
        let enabled = row.enabledTargets
        guard !enabled.isEmpty else { return }
        let keys = enabled.map { PlatformSelection(gameID: row.id, target: $0) }
        if keys.allSatisfy({ selected.contains($0) }) {
            for key in keys { selected.remove(key) }
        } else {
            for key in keys { selected.insert(key) }
        }
    }

    private func togglePlatform(gameID: UUID, target: String) {
        let key = PlatformSelection(gameID: gameID, target: target)
        if selected.contains(key) {
            selected.remove(key)
        } else {
            selected.insert(key)
        }
    }

    private func confirm(onlyFast: Bool) {
        let chosen = onlyFast ? plannedItems.filter(\.fastRefresh) : plannedItems
        guard !chosen.isEmpty else { return }
        let batch = UUID()
        let rawEntries = chosen.map { item in
            RefreshQueueBuilder.makeEntry(
                game: item.game,
                target: item.target,
                fastRefresh: item.fastRefresh,
                externalImgPath: item.externalImgPath,
                batch: batch,
                stores: stores,
                libraryFolder: library.folder
            )
        }
        let ordered = RefreshQueueBuilder.orderedEntries(rawEntries)
        stores.queue.enqueue(ordered)
        onConfirmed()
    }
}
