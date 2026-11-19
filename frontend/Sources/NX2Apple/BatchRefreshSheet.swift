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

        var showsMissingImgHint: Bool {
            hasIOS && assessment.hasUsableSeed && assessment.needsMissingImgGuideIOS && externalIOSImgPath == nil
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
    var recoverImage: (MissingImgGuideContext) -> Void = { _ in }

    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @State private var selected: Set<PlatformSelection> = []
    @State private var didSeedSelection = false
    @State private var externalDriveImages: [UUID: String] = [:]
    @State private var icons: [UUID: NSImage] = [:]
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
            var hasIOS = game.hasIOSBuild(shellRoot: stores.build.shellCachePath)
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

    func candidateTargetsForTesting() -> [(id: UUID, hasMac: Bool, hasIOS: Bool)] {
        rows.map { (id: $0.id, hasMac: $0.hasMac, hasIOS: $0.hasIOS) }
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

    private var firstPadTarget: String {
        rows.first(where: { !$0.enabledTargets.isEmpty }).map { "batchRefresh.game.\($0.id.uuidString)" } ?? "batchRefresh.cancel"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.horizontal, DSSheetInsets.horizontal)
                .padding(.top, DSSheetInsets.vertical)
                .padding(.bottom, DSSheetInsets.gap)

            ScrollViewReader { proxy in
                ScrollView {
                    if rows.isEmpty {
                        Text(loc.t("batchRefresh.empty"))
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DSSheetInsets.horizontal)
                            .padding(.vertical, DS.Space.l)
                    } else {
                        VStack(alignment: .leading, spacing: DS.Space.l) {
                            if !fastRows.isEmpty {
                                groupSection(
                                    title: loc.t("batchRefresh.groupFast"),
                                    symbol: "bolt.fill",
                                    items: fastRows
                                )
                            }
                            if !fullRows.isEmpty {
                                groupSection(
                                    title: loc.t("batchRefresh.groupFull"),
                                    symbol: "arrow.triangle.2.circlepath",
                                    items: fullRows
                                )
                            }
                        }
                        .padding(.horizontal, DSSheetInsets.horizontal)
                        .padding(.top, DS.Space.xxs)
                        .padding(.bottom, DSSheetInsets.gap)
                    }
                }
                .onChange(of: pad.focused) { id in
                    if let id, id.hasPrefix("batchRefresh.game.") || id.hasPrefix("batchRefresh.platform.") || id.hasPrefix("batchRefresh.recover.") {
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
        .dsSheetSurface()
        .background(PadKeyboardInput(focus: pad, scope: "batchRefresh", back: close))
        .environment(\.padRingStyle, .hug)
        .padScope("batchRefresh", pad)
        .onAppear {
            pad.scope = "batchRefresh"
            icons = Dictionary(uniqueKeysWithValues: library.games.compactMap { game in
                GameLibrary.appIcon(for: game, banners: library.artworkDirectory).map { (game.id, $0) }
            })
            seedSelectionIfNeeded()
            scanExternalDriveIfNeeded()
            if pad.visible {
                let target = firstPadTarget
                DispatchQueue.main.async { pad.show(default: target) }
            }
        }
        .onDisappear {
            driveScanGeneration &+= 1
        }
    }

    private var headerSection: some View {
        DSSheetHeader(title: loc.t("batchRefresh.title"), message: loc.t("batchRefresh.subtitle"))
            .help(String(format: loc.t("batchRefresh.versionBadge"), baseVersion))
    }

    /// A group of games (fast refresh, full rebuild): its symbol and title as the section header over one card of rows.
    private func groupSection(title: String, symbol: String, items: [CandidateRow]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Color.symbolDefault)
                Text(title)
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            .padding(.leading, DS.Space.xxs)
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            DSSection("") {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { DSRowDivider() }
                    candidateRowView(row)
                }
            }
        }
    }

    private func candidateRowView(_ row: CandidateRow) -> some View {
        let enabled = row.enabledTargets
        let checkedTargets = enabled.filter { selected.contains(PlatformSelection(gameID: row.id, target: $0)) }
        let allOn = !enabled.isEmpty && checkedTargets.count == enabled.count
        let partialOn = !checkedTargets.isEmpty && !allOn
        let checkSymbol = allOn ? "checkmark.square.fill" : (partialOn ? "minus.square.fill" : "square")

        return HStack(alignment: .center, spacing: DS.Space.s) {
            Button { toggleRow(row) } label: {
                HStack(alignment: .center, spacing: DS.Space.s) {
                    Image(systemName: checkSymbol)
                        .font(.system(size: 17))
                        .foregroundStyle((allOn || partialOn) ? DS.Color.symbolAccent : DS.Color.symbolDefault)
                        .opacity(enabled.isEmpty ? 0.35 : 1)
                    Group {
                        if let icon = icons[row.id] { Image(nsImage: icon).resizable().scaledToFill() }
                        else {
                            Image(systemName: "gamecontroller.fill").foregroundStyle(DS.Color.symbolDefault)
                                .frame(maxWidth: .infinity, maxHeight: .infinity).background(DS.Color.surfaceRaised)
                        }
                    }.frame(width: DS.Control.thumbnail, height: DS.Control.thumbnail).clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        HStack(spacing: DS.Space.xs) {
                            Text(row.game.displayName(loc.lang))
                                .font(DS.Font.bodyStrong)
                                .foregroundStyle(DS.Color.textPrimary)
                                .lineLimit(2).multilineTextAlignment(.leading)
                                .help(row.assessment.hasSpecificUpdate ? String(format: loc.t("library.refresh.badgeVersion"), row.assessment.versionLabel) : "")

                        }
                        if row.showsMissingImgHint {
                            warning(loc.t("batchRefresh.missingImg"))
                        } else if row.showsMissingPackageHint {
                            warning(loc.t("batchRefresh.missingPackage"))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(enabled.isEmpty)


            VStack(alignment: .trailing, spacing: 8) {
              HStack(spacing: 8) {
                if row.hasMac {
                    platformTogglePill(
                        label: loc.t("batchRefresh.platformMac"),
                        symbol: "desktopcomputer",
                        id: "batchRefresh.platform.mac.\(row.id.uuidString)",
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
                        id: "batchRefresh.platform.ios.\(row.id.uuidString)",
                        isOn: !row.disabledIOS && selected.contains(PlatformSelection(gameID: row.id, target: BuildTarget.ios)),
                        isFast: row.canFastIOS,
                        disabled: row.disabledIOS
                    ) {
                        togglePlatform(gameID: row.id, target: BuildTarget.ios)
                    }
                }
              }
              if row.showsMissingImgHint {
                Button(loc.t("imgGuide.chooseImgBtn")) { recoverImage(.init(game: row.game, assessment: row.assessment)) }
                    .buttonStyle(DSRowButtonStyle())
                    .padTarget("batchRefresh.recover." + row.id.uuidString, scope: "batchRefresh") {
                        recoverImage(.init(game: row.game, assessment: row.assessment))
                    }
              }
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .frame(minHeight: 56)
        .padTarget("batchRefresh.game.\(row.id.uuidString)", scope: "batchRefresh", radius: DS.Radius.chip, enabled: !enabled.isEmpty) { toggleRow(row) }
    }

    /// Why a game cannot be refreshed fast: the warning symbol and the text in the row's secondary style.
    private func warning(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xxs) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Color.statusWarning)
                .accessibilityHidden(true)
            Text(text).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func platformTogglePill(
        label: String,
        symbol: String,
        id: String,
        isOn: Bool,
        isFast: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xxs) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isOn ? DS.Color.symbolAccent : DS.Color.symbolDefault)
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Color.symbolDefault)
                Text(label)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                if isFast {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.Color.symbolDefault)
                }
            }
            .padding(.horizontal, DS.Space.s)
            .frame(height: 30)
            .background(DS.Color.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? DS.Color.accent : DS.Color.separator))
            .opacity(disabled ? 0.4 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .padTarget(id, scope: "batchRefresh", enabled: !disabled, activate: action)
    }

    private var footerSection: some View {
        let summaryText = Text(String(format: loc.t("batchRefresh.summary"), selectedFastCount, selectedFullCount))
            .font(DS.Font.callout)
            .foregroundStyle(DS.Color.textSecondary)
            .lineLimit(1)

        return ViewThatFits(in: .horizontal) {
            DSSheetButtonRow { summaryText } buttons: { footerButtons }
            VStack(alignment: .leading, spacing: DS.Space.s) {
                summaryText
                HStack(spacing: DS.Space.s) {
                    Spacer(minLength: 0)
                    footerButtons
                }
            }
        }
    }

    private var footerButtons: some View {
        HStack(spacing: DS.Space.s) {
            Button(loc.t("batchRefresh.cancel"), action: close)
                .buttonStyle(DSSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padTarget("batchRefresh.cancel", scope: "batchRefresh", activate: close)

            if selectedFullCount > 0 && selectedFastCount > 0 {
            Button(String(format: loc.t("batchRefresh.onlyFast"), selectedFastCount)) {
                confirm(onlyFast: true)
            }
            .buttonStyle(DSSecondaryButtonStyle())
            .disabled(selectedFastCount == 0)
            .padTarget("batchRefresh.onlyFast", scope: "batchRefresh", enabled: selectedFastCount > 0) {
                confirm(onlyFast: true)
            }
            }

            DSSheetPrimaryButton(String(format: loc.t("batchRefresh.allSelected"), totalSelectedCount)) {
                confirm(onlyFast: false)
            }
            .disabled(totalSelectedCount == 0)
            .padTarget("batchRefresh.confirm", scope: "batchRefresh", enabled: totalSelectedCount > 0) {
                confirm(onlyFast: false)
            }
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
