import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The Cheats sheet (#97): a game's cheat files, an on / off switch per cheat, an import by drop or pick, and a copy to the
/// iPhone or iPad the game was installed on. The files and what the switches write are CheatFiles.swift (the contract of
/// docs/frontends.md "Cheats"), so this is only the view. It never touches a running game: the host reads the files when it
/// starts (or on its own Reload cheats).
struct CheatsView: View {
    @ObservedObject var m: BuildStore
    @EnvironmentObject var loc: Localizer
    @ObservedObject var library: GameLibrary
    let gameID: UUID
    var devicectl: DeviceControl? = nil   // tests and the visual QA hand in a stand-in
    var support: URL? = nil               // the Application Support folder; tests use a temporary one
    var cheatFetchTransport: CheatFetchTransport = URLSessionCheatFetchTransport()
    var dropped = false                   // the drop highlight drawn from the start (visual QA)
    var onStartedFastBake: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var focus: PadFocus

    @State private var files: [CheatFiles.Found] = []
    @State private var cheats: [CheatFiles.Cheat] = []
    @State private var on: Set<String> = []
    @State private var master = true
    @State private var safeMode = false
    @State private var tripped: CheatFiles.TrippedReceipt?
    @State private var fetchReceipt: CheatFetchReceipt?
    @State private var busy = false
    @State private var fetchingOnline = false
    @State private var result: (text: String, ok: Bool)?
    @State private var fixupsMetadata = CheatMainFixupsMetadata()
    @State private var trampolinesMetadata: CheatTrampolineMetadata?
    @State private var bundle = ""
    @State private var hasUsableSeed = false
    @State private var supportsFastBakeTools = false
    @State private var loadGeneration: UInt64 = 0
    @State private var actionGeneration: UInt64 = 0

    private struct RefreshPayload: Sendable {
        var files: [CheatFiles.Found]
        var master: Bool
        var safeMode: Bool
        var tripped: CheatFiles.TrippedReceipt?
        var fetchReceipt: CheatFetchReceipt?
        var fixups: CheatMainFixupsMetadata
        var trampolines: CheatTrampolineMetadata?
        var cheats: [CheatFiles.Cheat]
        var on: Set<String>
        var bundle: String
        var hasUsableSeed: Bool
        var supportsFastBakeTools: Bool
    }

    private var game: LibraryGame? { library.games.first { $0.id == gameID } }
    private var deviceName: String { game.map { m.devices.deviceName($0.installedDevice) } ?? "iPhone" }

    private var cheatFiles: CheatFiles? {
        guard let game else { return nil }
        return support.map { CheatFiles(titleID: game.titleID, support: $0) } ?? CheatFiles(titleID: game.titleID)
    }

    private var buildID: String? { fixupsMetadata.buildID ?? trampolinesMetadata?.buildID }
    private var current: CheatFiles.Found? { buildID.flatMap { id in files.first { $0.buildID == id } } }
    private var canCopy: Bool { !busy && (game?.onDevice ?? false) && !bundle.isEmpty && !files.isEmpty }
    private var canFetchOnline: Bool {
        guard !busy, !fetchingOnline, let game else { return false }
        return CheatFetcher.normalizedHex16(game.titleID) != nil
            && buildID.flatMap({ CheatFetcher.normalizedHex16($0, allow32: true) }) != nil
    }
    private var capabilitySummary: CheatsCapabilitySummary { CheatsCapabilitySummary(cheats: cheats) }
    private var showsIOSGuidance: Bool { game?.cheatsNeedIOSNote ?? false }
    private var canFastBake: Bool {
        guard !busy, !m.running, showsIOSGuidance, current != nil, capabilitySummary.codeNeedsBake > 0 else { return false }
        return hasUsableSeed && supportsFastBakeTools
    }
    private var fastBakeDisabledReason: String? {
        guard showsIOSGuidance, current != nil, capabilitySummary.codeNeedsBake > 0 else { return nil }
        if m.running { return loc.t("cheats.fastBakeBusy") }
        if !supportsFastBakeTools {
            return loc.t("cheats.fastBakeToolsOld")
        }
        if !hasUsableSeed { return loc.t("cheats.fastBakeNoSeed") }
        return nil
    }
    private var shown: [CheatFiles.Cheat] {
        cheats.filter { !$0.pairOff && !($0.kind == .label && ($0.name.isEmpty || $0.isSectionMarker)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSheetHeader(title: loc.t("cheats.title"), message: game?.displayName(loc.lang) ?? "")
                .padding(.horizontal, DSSheetInsets.horizontal).padding(.top, DSSheetInsets.vertical).padding(.bottom, DSSheetInsets.gap)
            VStack(alignment: .leading, spacing: DSSheetInsets.gap) {
                if let tripped { fuseTrippedBanner(tripped) }
                buildCard
                CheatsFetchCard(
                    receipt: fetchReceipt,
                    hasBuildID: buildID != nil,
                    fetching: fetchingOnline
                )
                if current != nil, capabilitySummary.totalActive > 0 {
                    CheatsOverviewCard(
                        summary: capabilitySummary,
                        showsIOSGuidance: showsIOSGuidance,
                        canFastBake: canFastBake,
                        fastBakeDisabledReason: fastBakeDisabledReason,
                        onFastBake: startFastBakeCheats
                    )
                } else if showsIOSGuidance {
                    iosNoteCard
                }
                if files.isEmpty { emptyCard } else { listCard }
                actions
                if busy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(loc.t("cheats.copying")).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
                    }
                } else if let result {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(result.ok ? DS.Color.statusSuccess : DS.Color.statusWarning).accessibilityHidden(true)
                        Text(result.text).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, DSSheetInsets.horizontal)
            Spacer(minLength: 0)
            HStack(spacing: DS.Space.s) {
                Text(loc.t("cheats.note") + ((game?.onDevice ?? false) ? " " + String(format: loc.t("cheats.noteDevice"), deviceName) : "")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.xs)
                DSSheetPrimaryButton(loc.t("launch.done")) { dismiss() }.disabled(busy)
                .padTarget("cheats.done", scope: "cheats", focusColor: DS.Color.accentOn, enabled: !busy) { if !busy { dismiss() } }
            }
            .padding(.horizontal, DSSheetInsets.horizontal).padding(.top, DSSheetInsets.gap).padding(.bottom, DSSheetInsets.vertical)
        }
        .padScope("cheats", focus)
        .frame(width: 640, height: 800)
        .dsSheetSurface()
        .modifier(GameFilesDrop(enabled: !busy, label: loc.t("cheats.dropHint"), targeted: dropped) { importPaths($0) })
        .onAppear(perform: refresh)
        .onDisappear {
            loadGeneration &+= 1
            actionGeneration &+= 1
        }
    }

    // ---- the cards ----

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        DSSection("", content)
    }

    /// Prominent banner shown after the 30-second anti-crash fuse automatically disabled suspect cheats.
    private func fuseTrippedBanner(_ receipt: CheatFiles.TrippedReceipt) -> some View {
        let detail = receipt.disabledMaster
            ? loc.t("cheats.fuseTrippedMaster")
            : String(format: loc.t("cheats.fuseTrippedItems"), receipt.disabled.joined(separator: ", "))
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.Color.statusWarning)
                .frame(width: 26)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(loc.t("cheats.fuseTrippedTitle"))
                    .font(DS.Font.body.weight(.semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                Text(detail)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(loc.t("cheats.fuseDismiss")) { dismissTripped() }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
                .padTarget("cheats.fuseDismiss", scope: "cheats") { dismissTripped() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DS.Color.statusWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(DS.Color.statusWarning.opacity(0.42), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// The build the game is, and the master switch.
    private var buildCard: some View {
        card {
            HStack(spacing: 14) {
                Image(systemName: "number").font(.system(size: 16, weight: .light)).foregroundStyle(DS.Color.symbolDefault).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.t("cheats.buildLabel")).font(DS.Font.body)
                    Text(buildID ?? loc.t("cheats.buildUnknown")).font(buildID == nil ? DS.Font.callout : DS.Font.mono)
                        .foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            DS.Color.separator.frame(height: 1).padding(.leading, DS.Space.m)
            HStack(spacing: 14) {
                Image(systemName: "power").font(.system(size: 16, weight: .light)).foregroundStyle(DS.Color.symbolDefault).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.t("cheats.master")).font(DS.Font.body)
                    if safeMode { DSInlineWarning(loc.t("cheats.safeMode")) }
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(get: { master }, set: { setMaster($0) })).toggleStyle(CheatSwitchStyle()).labelsHidden()
                    .accessibilityLabel(loc.t("cheats.master"))
                    .padTarget("cheats.master", scope: "cheats") { setMaster(!master) }
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
        }
    }

    /// Code cheats do not run on iPhone or iPad, data cheats do: said once, calmly, with the switches left usable for a Mac build.
    private var iosNoteCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "info.circle").font(.system(size: 16, weight: .light)).foregroundStyle(LauncherPalette.secondaryText).frame(width: 26)
            Text(loc.t("cheats.iosNote")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(LauncherPalette.ink(0.04), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private var emptyCard: some View {
        card {
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 26, weight: .light)).foregroundStyle(LauncherPalette.secondaryText)
                Text(loc.t("cheats.empty")).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 150).padding(18)
        }
    }

    /// The files by build, the ones for another build marked, and the cheats of the build the game is.
    private var listCard: some View {
        card {
            ForEach(files) { file in
                fileRow(file)
                DS.Color.separator.frame(height: 1).padding(.leading, DS.Space.m)
            }
            if current == nil {
                Text(buildID == nil ? loc.t("cheats.noBuildFile") : String(format: loc.t("cheats.noFileForBuild"), buildID ?? ""))
                    .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) { ForEach(Array(shown.enumerated()), id: \.element.id) { cheatRow($0.element, index: $0.offset) } }
                        .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func fileRow(_ file: CheatFiles.Found) -> some View {
        let isCurrent = file.buildID == buildID
        return HStack(spacing: 12) {
            Image(systemName: "doc.text").font(.system(size: 15, weight: .light)).foregroundStyle(DS.Color.symbolDefault).frame(width: 26)
            Text(file.buildID + ".txt").font(DS.Font.mono)
            Spacer(minLength: 8)
            DSTag(isCurrent ? loc.t("cheats.thisBuild") : loc.t("cheats.otherBuild"), emphasized: isCurrent)
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .opacity(isCurrent ? 1 : 0.6)
        .help(isCurrent ? "" : loc.t("cheats.otherHint"))
    }

    @ViewBuilder private func cheatRow(_ cheat: CheatFiles.Cheat, index: Int) -> some View {
        let first = index == 0 || shown[index - 1].section != cheat.section
        if first && !cheat.section.isEmpty {
            Text(cheat.section).font(DS.Font.footnote).foregroundStyle(DS.Color.textSecondary)
                .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 4)
        }
        switch cheat.kind {
        case .label where cheat.isSectionMarker || cheat.name.hasPrefix("--Section"):
            EmptyView()
        case .label:
            Text(cheat.name).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).padding(.horizontal, 18).padding(.vertical, 5)
        case .master:
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: DS.Space.xs) {
                        Text(cheat.name).font(DS.Font.body).lineLimit(2)
                        if !cheat.broken, let combo = cheat.triggerCombo {
                            CheatTriggerKeyPill(combo: combo)
                        }
                    }
                    if cheat.broken {
                        brokenCheatLabel
                    } else if cheat.capability == .unsafeCode {
                        CheatSafetyBlockedBadge(detail: cheat.safetyDetail)
                    } else {
                        HStack(spacing: DS.Space.xs) {
                            if cheat.hasFixedAddress || cheat.capability == .fixedHeapWarning {
                                CheatFixedAddressPill()
                            }
                            if cheat.capability != .fixedHeapWarning {
                                CheatCapabilityTag(capability: cheat.capability)
                            }
                        }
                        if cheat.hasFixedAddress || cheat.capability == .fixedHeapWarning {
                            fixedAddressHintLabel
                        }
                    }
                }
                Spacer(minLength: 8)
                if !cheat.broken {
                    Text(loc.t("cheats.alwaysOn")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 6)
        case .cheat:
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: DS.Space.xs) {
                        Text(cheat.name).font(DS.Font.body).lineLimit(2)
                        if !cheat.broken, let combo = cheat.triggerCombo {
                            CheatTriggerKeyPill(combo: combo)
                        }
                    }
                    if cheat.broken {
                        brokenCheatLabel
                    } else if cheat.once {
                        Text(loc.t("cheats.once")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    } else if cheat.capability == .unsafeCode {
                        CheatSafetyBlockedBadge(detail: cheat.safetyDetail)
                    } else {
                        HStack(spacing: DS.Space.xs) {
                            if cheat.hasFixedAddress || cheat.capability == .fixedHeapWarning {
                                CheatFixedAddressPill()
                            }
                            if cheat.capability != .fixedHeapWarning {
                                CheatCapabilityTag(capability: cheat.capability)
                            }
                        }
                        if cheat.hasFixedAddress || cheat.capability == .fixedHeapWarning {
                            fixedAddressHintLabel
                        }
                    }
                }
                Spacer(minLength: 8)
                if cheat.switchable {
                    Toggle("", isOn: Binding(get: { on.contains(cheat.key) }, set: { set(cheat, $0) })).toggleStyle(CheatSwitchStyle()).labelsHidden()
                        .accessibilityLabel(cheat.name)
                        .padTarget("cheats.row.\(cheat.key)", scope: "cheats") { set(cheat, !on.contains(cheat.key)) }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 5)
        }
    }

    private var brokenCheatLabel: some View {
        Label(loc.t("cheats.broken"), systemImage: "exclamationmark.triangle.fill")
            .font(DS.Font.callout)
            .foregroundStyle(DS.Color.textSecondary)
            .labelStyle(CheatWarningLabel())
    }

    private var fixedAddressHintLabel: some View {
        Text(loc.t("cheats.fixedAddressHint"))
            .font(DS.Font.footnote)
            .foregroundStyle(DS.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Fetch online, import, the folder, and the copy to the device.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                fetchButton
                importButton
                folderButton
                Spacer(minLength: 8)
                copyDeviceButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    fetchButton
                    importButton
                    folderButton
                    Spacer(minLength: 0)
                }
                if game?.onDevice ?? false {
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        copyDeviceButton
                    }
                }
            }
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
    }

    private var fetchButton: some View {
        Button(loc.t("cheats.fetchOnline")) { fetchOnlineCheats() }.disabled(!canFetchOnline)
            .fixedSize(horizontal: true, vertical: false)
            .padTarget("cheats.fetch", scope: "cheats", enabled: canFetchOnline) { if canFetchOnline { fetchOnlineCheats() } }
    }

    private var importButton: some View {
        Button(loc.t("cheats.import")) { pick() }.disabled(busy || fetchingOnline)
            .fixedSize(horizontal: true, vertical: false)
            .padTarget("cheats.import", scope: "cheats", enabled: !busy && !fetchingOnline) { if !busy && !fetchingOnline { pick() } }
    }

    private var folderButton: some View {
        Button(loc.t("cheats.showFolder")) { showFolder() }
            .fixedSize(horizontal: true, vertical: false)
            .padTarget("cheats.folder", scope: "cheats") { showFolder() }
    }

    @ViewBuilder private var copyDeviceButton: some View {
        if game?.onDevice ?? false {
            Button(String(format: loc.t("cheats.toDevice"), deviceName)) { copyToDevice() }.disabled(!canCopy || fetchingOnline)
                .fixedSize(horizontal: true, vertical: false)
                .padTarget("cheats.toDevice", scope: "cheats", enabled: canCopy && !fetchingOnline) { if canCopy && !fetchingOnline { copyToDevice() } }
        }
    }

    // ---- what the controls do ----

    private func refresh() {
        guard let cheatFiles, let game else { return }
        loadGeneration &+= 1
        let gen = loadGeneration
        let targetID = game.id
        let titleID = game.titleID
        let appPath = game.appPath
        let iosAppPath = game.iosAppPath
        let shellRoot = m.shellRoot
        let seedRoot = m.seedCacheRoot
        let repoPath = m.repo.path
        let isRunning = CheatsView.running(game: game)

        Task.detached(priority: .userInitiated) {
            if !isRunning {
                cheatFiles.recoverIfArmed()
            }
            let found = cheatFiles.found()
            let masterOn = cheatFiles.masterOn
            let isSafeMode = cheatFiles.safeMode
            let trippedReceipt = cheatFiles.readTripped()
            let savedFetchReceipt = cheatFiles.readFetchReceipt()
            let fixups = CheatFiles.mainFixupsMetadata(
                appPath: appPath,
                iosAppPath: iosAppPath,
                titleID: titleID,
                shellRoot: shellRoot
            )
            let trampolines = CheatFiles.trampolinesMetadata(
                appPath: appPath,
                iosAppPath: iosAppPath,
                titleID: titleID,
                shellRoot: shellRoot
            )
            let activeBuildID = fixups.buildID ?? trampolines?.buildID
            let matched = activeBuildID.flatMap { id in found.first { $0.buildID == id } }
            let parsedCheats: [CheatFiles.Cheat]
            let enabledKeys: Set<String>
            if let file = matched {
                parsedCheats = cheatFiles.cheats(of: file, rxEnd: fixups.mainRxEnd, trampolines: trampolines) ?? []
                enabledKeys = cheatFiles.enabled(file.buildID)
            } else {
                parsedCheats = []
                enabledKeys = []
            }
            let bundleID = iosAppPath.isEmpty
                ? ""
                : (NSDictionary(contentsOfFile: iosAppPath + "/Info.plist")?["CFBundleIdentifier"] as? String ?? "")
            let seedUsable = BuildSeedCache.inspect(titleID: titleID, seedRoot: seedRoot, repoPath: repoPath).isUsable
            let toolsSupported = RepoLayout.supportsBuildSeed(repoPath) && RepoLayout.supportsCheatDir(repoPath)
            let payload = RefreshPayload(
                files: found,
                master: masterOn,
                safeMode: isSafeMode,
                tripped: trippedReceipt,
                fetchReceipt: savedFetchReceipt,
                fixups: fixups,
                trampolines: trampolines,
                cheats: parsedCheats,
                on: enabledKeys,
                bundle: bundleID,
                hasUsableSeed: seedUsable,
                supportsFastBakeTools: toolsSupported
            )
            await MainActor.run {
                guard loadGeneration == gen, self.game?.id == targetID else { return }
                files = payload.files
                master = payload.master
                safeMode = payload.safeMode
                tripped = payload.tripped
                fetchReceipt = payload.fetchReceipt
                fixupsMetadata = payload.fixups
                trampolinesMetadata = payload.trampolines
                cheats = payload.cheats
                on = payload.on
                bundle = payload.bundle
                hasUsableSeed = payload.hasUsableSeed
                supportsFastBakeTools = payload.supportsFastBakeTools
            }
        }
    }

    private func fetchOnlineCheats() {
        guard canFetchOnline, let cheatFiles, let game, let bid = buildID else { return }
        actionGeneration &+= 1
        let gen = actionGeneration
        let targetID = game.id
        let titleID = game.titleID
        let folder = cheatFiles.folder
        let transport = cheatFetchTransport
        fetchingOnline = true
        result = nil
        Task.detached(priority: .userInitiated) {
            let outcome = await CheatFetcher.fetch(
                titleID: titleID,
                buildID: bid,
                into: folder,
                transport: transport
            )
            await MainActor.run {
                guard actionGeneration == gen, self.game?.id == targetID else { return }
                fetchingOnline = false
                fetchReceipt = outcome.receipt
                refresh()
                switch outcome.receipt.statusKind {
                case .fetched:
                    result = (String(format: loc.t("cheats.fetch.done"), outcome.receipt.entryCount), true)
                case .preservedUser:
                    result = (loc.t("cheats.fetch.statusPreserved"), true)
                case .notFound:
                    result = (loc.t("cheats.fetch.statusNotFound"), false)
                case .offline, .none:
                    result = (loc.t("cheats.fetch.statusOffline"), false)
                }
            }
        }
    }

    private func startFastBakeCheats() {
        guard canFastBake, let game, let cheatFiles else { return }
        m.startFastRefresh(
            titleID: game.titleID,
            targetName: BuildTarget.ios,
            gameName: game.name,
            existingMacAppPath: game.nxnativeMacBuildForRefresh?.appPath,
            cheatsDir: cheatFiles.folder.path
        )
        onStartedFastBake?()
        dismiss()
    }

    private func dismissTripped() {
        cheatFiles?.clearTripped()
        tripped = nil
    }

    private func set(_ cheat: CheatFiles.Cheat, _ value: Bool) {
        guard let cheatFiles, let file = current else { return }
        var next = on
        if value { next.insert(cheat.key) } else { next.remove(cheat.key) }
        do {
            try cheatFiles.writeEnabled(file.buildID, cheats: cheats, on: next)
            on = next
            result = game.flatMap { CheatsView.running(game: $0) ? (String(format: loc.t("cheats.running"), $0.displayName(loc.lang)), false) : nil }
        } catch { result = (String(format: loc.t("cheats.writeFailed"), error.localizedDescription), false) }
    }

    private func setMaster(_ value: Bool) {
        guard let cheatFiles else { return }
        do { try cheatFiles.setMaster(value); master = value } catch { result = (String(format: loc.t("cheats.writeFailed"), error.localizedDescription), false) }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = loc.t("cheats.pickMessage")
        if panel.runModal() == .OK { importPaths(panel.urls.map(\.path)) }
    }

    private func importPaths(_ paths: [String]) {
        guard let cheatFiles, let game else { return }
        actionGeneration &+= 1
        let gen = actionGeneration
        let targetID = game.id
        let urls = paths.map { URL(fileURLWithPath: $0) }
        busy = true
        result = nil
        Task.detached(priority: .userInitiated) {
            let outcomeResult: Result<CheatFiles.ImportResult, Error>
            do {
                outcomeResult = .success(try cheatFiles.importFiles(from: urls))
            } catch {
                outcomeResult = .failure(error)
            }
            await MainActor.run {
                guard actionGeneration == gen, self.game?.id == targetID else { return }
                busy = false
                switch outcomeResult {
                case .success(let outcome):
                    refresh()
                    result = Self.importMessage(outcome, loc: loc)
                case .failure(let error):
                    result = (String(format: loc.t("cheats.writeFailed"), error.localizedDescription), false)
                }
            }
        }
    }

    /// What an import says: how many files came in, and the ones without a build ID or exceeding 4 MB.
    static func importMessage(_ r: CheatFiles.ImportResult, loc: Localizer) -> (String, Bool) {
        var parts: [String] = []
        if !r.imported.isEmpty { parts.append(String(format: loc.t("cheats.imported"), r.imported.count)) }
        if !r.skipped.isEmpty { parts.append(String(format: loc.t("cheats.notNamed"), r.skipped.prefix(3).joined(separator: ", "))) }
        if !r.tooLarge.isEmpty { parts.append(String(format: loc.t("cheats.tooLarge"), r.tooLarge.prefix(3).joined(separator: ", "))) }
        if parts.isEmpty { return (loc.t("cheats.nothingFound"), false) }
        return (parts.joined(separator: " "), !r.imported.isEmpty)
    }

    private func showFolder() {
        guard let cheatFiles else { return }
        try? FileManager.default.createDirectory(at: cheatFiles.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(cheatFiles.folder)
    }

    private func copyToDevice() {
        guard let cheatFiles, let game else { return }
        actionGeneration &+= 1
        let gen = actionGeneration
        let targetID = game.id
        let targetDeviceName = deviceName
        let transfer = CheatTransfer(files: cheatFiles, device: game.installedDevice, bundle: bundle, devicectl: devicectl ?? .xcrun(m.devices.xcrun))
        busy = true; result = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: (String, Bool)
            do { try transfer.toDevice(); outcome = (String(format: loc.t("cheats.copied"), targetDeviceName), true) }
            catch CheatTransfer.Failure.noFiles { outcome = (loc.t("cheats.empty"), false) }
            catch CheatTransfer.Failure.device(let line) { outcome = (String(format: loc.t("cheats.copyFailed"), line), false) }
            catch { outcome = (String(format: loc.t("cheats.copyFailed"), error.localizedDescription), false) }
            DispatchQueue.main.async {
                guard actionGeneration == gen, self.game?.id == targetID else { return }
                busy = false; result = outcome; focus.focused = "cheats.done"
            }
        }
    }

    static func running(game: LibraryGame) -> Bool { SaveTransfer.runningOnMac(titleID: game.titleID) }
}

extension View {
    /// The Cheats sheet of the game `id` names, with the controller's scope following it (the launcher's other sheets do the same inline).
    func cheatsSheet(
        for id: Binding<UUID?>,
        m: BuildStore,
        library: GameLibrary,
        pad: PadFocus,
        restoreScope: @escaping () -> String,
        onStartedFastBake: (() -> Void)? = nil
    ) -> some View {
        sheet(isPresented: Binding(get: { id.wrappedValue != nil }, set: { if !$0 { id.wrappedValue = nil } })) {
            if let game = id.wrappedValue {
                CheatsView(m: m, library: library, gameID: game, onStartedFastBake: onStartedFastBake)
                    .environmentObject(pad)
            }
        }
        .onChange(of: id.wrappedValue) { open in pad.scope = open != nil ? "cheats" : restoreScope() }
    }
}

/// An on / off switch that reads the same in a window that is not key (the system's drops its colour there): cream when on, a dim track when off.
struct CheatSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? LauncherPalette.switchOnTrack : LauncherPalette.ink(0.16))
                .frame(width: 40, height: 23)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(configuration.isOn ? Color.black.opacity(0.85) : LauncherPalette.switchOffKnob).frame(width: 17, height: 17).padding(3)
                }
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "1" : "0")
    }
}

/// A cheat that may not work: the warning symbol in its colour, the text in the row's secondary style.
private struct CheatWarningLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xxs) {
            configuration.icon.font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Color.statusWarning).accessibilityHidden(true)
            configuration.title
        }
    }
}
