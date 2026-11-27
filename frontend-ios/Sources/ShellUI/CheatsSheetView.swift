import SwiftUI

private struct ShellOpenCheatsKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: ((GameTile) -> Void)? = nil
}

extension EnvironmentValues {
    var shellOpenCheats: ((GameTile) -> Void)? {
        get { self[ShellOpenCheatsKey.self] }
        set { self[ShellOpenCheatsKey.self] = newValue }
    }
}

/// Complete iOS Cheats center sheet: Build ID, 30s crash guard alert, `.txt` import with build-mismatch guard,
/// four-tier compatibility triage card, desktop fast-bake share guidance, and live toggles with key-combo pills.
public struct CheatsSheetView: View {
    public let initialSnapshot: GameCheatsSnapshot
    public var actions: ShellActions
    public var onClose: () -> Void

    @State private var snapshot: GameCheatsSnapshot
    @State private var importing = false
    @State private var fetching = false
    @State private var deleting = false
    @State private var showDeleteConfirm = false
    @State private var lastFetchReceipt: GameCheatFetchReceipt?
    @State private var statusMessage: (text: String, isWarning: Bool)?
    @State private var pendingMismatch: PendingMismatch?
    @State private var opGeneration: UInt64 = 0

    private struct PendingMismatch: Identifiable {
        let id = UUID()
        let fileBuildID: String?
        let expectedBuildID: String
        let fileName: String
        let token: String
    }

    public init(snapshot: GameCheatsSnapshot, actions: ShellActions, onClose: @escaping () -> Void) {
        self.initialSnapshot = snapshot
        self.actions = actions
        self.onClose = onClose
        _snapshot = State(initialValue: snapshot)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let fuseAlert = snapshot.fuseAlert {
                    fuseAlertBanner(fuseAlert)
                }

                headerCard

                if let receipt = effectiveFetchReceipt {
                    CheatsFetchStatusCard(receipt: receipt)
                }

                if let statusMessage {
                    statusBanner(statusMessage.text, isWarning: statusMessage.isWarning)
                }

                if snapshot.hasCurrentFile && snapshot.totalActiveCount > 0 {
                    triageGuidanceCard
                }

                if !snapshot.hasCurrentFile {
                    emptyStateCard
                } else {
                    entriesCard
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(ShellPalette.background)
        .task(id: initialSnapshot.gameID) {
            await loadSnapshotAsync()
        }
        .onDisappear {
            opGeneration &+= 1
        }
        .onChange(of: initialSnapshot) { _, updated in
            if updated.gameID != snapshot.gameID {
                opGeneration &+= 1
                pendingMismatch = nil
                statusMessage = nil
                lastFetchReceipt = nil
                importing = false
                fetching = false
                deleting = false
                showDeleteConfirm = false
                snapshot = updated
            }
        }
        .alert(
            ShellStrings.text("Delete cheat file?"),
            isPresented: $showDeleteConfirm
        ) {
            Button(ShellStrings.text("Delete"), role: .destructive) {
                deleteCurrentCheatFile()
            }
            Button(ShellStrings.text("Cancel"), role: .cancel) {}
        } message: {
            Text(ShellStrings.text("This removes the current cheat file and its saved switches. Bundled cheats will not be restored automatically."))
        }
        .alert(
            ShellStrings.text("Build ID does not match"),
            isPresented: Binding(
                get: { pendingMismatch != nil },
                set: { if !$0 { cancelMismatch() } }
            ),
            presenting: pendingMismatch
        ) { mismatch in
            Button(ShellStrings.text("Import for this build")) {
                confirmMismatch(mismatch)
            }
            Button(ShellStrings.text("Cancel"), role: .cancel) {
                cancelMismatch()
            }
        } message: { mismatch in
            if let fileBuild = mismatch.fileBuildID {
                Text(ShellStrings.text("\(mismatch.fileName) is named for build \(fileBuild), but this game is build \(mismatch.expectedBuildID). Importing it saves a copy for the current build."))
            } else {
                Text(ShellStrings.text("\(mismatch.fileName) has no build ID in its name. Importing it saves a copy for build \(mismatch.expectedBuildID)."))
            }
        }
    }

    // MARK: - Banners & Cards

    private func fuseAlertBanner(_ alert: GameCheatFuseAlert) -> some View {
        let detailText: String = alert.disabledMaster
            ? ShellStrings.text("The last run ended within 30 seconds, so cheats were switched off for this game.")
            : ShellStrings.text("The last run ended within 30 seconds, so these cheats were turned off: \(alert.disabledItems.joined(separator: ", "))")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ShellPalette.attention)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ShellStrings.text("Crash guard disabled cheats"))
                        .shellType(ShellType.cardTitle)
                        .foregroundStyle(.white)
                    Text(detailText)
                        .shellType(ShellType.note)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                dismissFuseAlert()
            } label: {
                Text(ShellStrings.text("Got it")).frame(maxWidth: .infinity)
            }
            .buttonStyle(ShellButtonStyle(fills: true))
            .accessibilityIdentifier("cheats.fuseDismiss")
            .shellTarget("cht.fuseDismiss") {
                dismissFuseAlert()
            }
        }
        .padding(16)
        .background(ShellPalette.attention.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ShellPalette.attention.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ShellStrings.text("Build ID"))
                        .shellType(ShellType.sectionCaps)
                        .foregroundStyle(ShellPalette.cream.opacity(0.72))
                    Text(snapshot.buildID ?? ShellStrings.text("Unknown"))
                        .font(.system(size: 15, weight: .semibold, design: snapshot.buildID == nil ? .default : .monospaced))
                        .foregroundStyle(snapshot.buildID == nil ? Color.white.opacity(0.55) : Color.white)
                        .accessibilityIdentifier("cheats.buildID")
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ShellPalette.ready)
                        .accessibilityHidden(true)
                    Text(ShellStrings.text("30s crash guard"))
                        .shellText(12, .semibold, relativeTo: .caption)
                        .foregroundStyle(.white.opacity(0.82))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.08), in: Capsule())
            }

            Rectangle().fill(ShellPalette.hairline).frame(height: 1)

            Toggle(isOn: Binding(
                get: { snapshot.masterOn },
                set: { newValue in toggleMaster(newValue) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ShellStrings.text("Run cheats in the game"))
                        .shellType(ShellType.settingLabel)
                    Text(ShellStrings.text("Switches save immediately and apply on the next launch."))
                        .shellType(ShellType.note)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(NativeCreamToggleStyle())
            .accessibilityIdentifier("cheats.masterToggle")
            .shellTarget("cht.master") { toggleMaster(!snapshot.masterOn) }

            Rectangle().fill(ShellPalette.hairline).frame(height: 1)

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    let canFetch = !fetching && !importing && !deleting && actions.onFetchCheats != nil && snapshot.buildID != nil
                    Button {
                        Task { await fetchCheats() }
                    } label: {
                        HStack(spacing: 6) {
                            if fetching {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "icloud.and.arrow.down")
                            }
                            Text(ShellStrings.text("Fetch online"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ShellButtonStyle(fills: true))
                    .disabled(!canFetch)
                    .accessibilityIdentifier("cheats.fetch")
                    .shellTarget("cht.fetch", enabled: canFetch) {
                        Task { await fetchCheats() }
                    }

                    let canImport = !importing && !fetching && !deleting && actions.onImportCheatFile != nil
                    Button {
                        Task { await importCheatFile() }
                    } label: {
                        HStack(spacing: 6) {
                            if importing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                            }
                            Text(ShellStrings.text("Import .txt…"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ShellButtonStyle(fills: true))
                    .disabled(!canImport)
                    .accessibilityIdentifier("cheats.import")
                    .shellTarget("cht.import", enabled: canImport) {
                        Task { await importCheatFile() }
                    }
                }

                if snapshot.hasCurrentFile && (snapshot.exportFileURL != nil || actions.onDeleteCheatFile != nil || actions.onDeleteCheatFileAsync != nil) {
                    HStack(spacing: 10) {
                        if let exportURL = snapshot.exportFileURL {
                            ShareLink(item: exportURL) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                    Text(ShellStrings.text("Share .txt"))
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(ShellButtonStyle(fills: true))
                            .accessibilityIdentifier("cheats.share")
                        }

                        if actions.onDeleteCheatFile != nil || actions.onDeleteCheatFileAsync != nil {
                            let canDelete = !deleting && !fetching && !importing
                            Button {
                                showDeleteConfirm = true
                            } label: {
                                HStack(spacing: 6) {
                                    if deleting {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "trash")
                                    }
                                    Text(ShellStrings.text("Delete"))
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(ShellButtonStyle(fills: true, destructive: true))
                            .disabled(!canDelete)
                            .accessibilityIdentifier("cheats.delete")
                            .shellTarget("cht.delete", enabled: canDelete) {
                                showDeleteConfirm = true
                            }
                        }
                    }
                }
            }
        }
        .shellCard()
    }

    private func statusBanner(_ text: String, isWarning: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isWarning ? ShellPalette.attention : ShellPalette.ready)
                .accessibilityHidden(true)
            Text(text)
                .shellType(ShellType.note)
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isWarning ? ShellPalette.attention : ShellPalette.ready).opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder((isWarning ? ShellPalette.attention : ShellPalette.ready).opacity(0.35), lineWidth: 1))
        .accessibilityIdentifier("cheats.statusBanner")
    }

    private var effectiveFetchReceipt: GameCheatFetchReceipt? {
        lastFetchReceipt ?? snapshot.fetchReceipt
    }

    private var triageGuidanceCard: some View {
        let needsBake = snapshot.codeNeedsBakeCount
        let unsafeCount = snapshot.unsafeCodeCount
        let readyCount = snapshot.readyOnIOSCount
        let accentColor: Color = unsafeCount > 0 ? DeleteStyle.red : (needsBake > 0 ? Color.orange : ShellPalette.ready)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: (needsBake > 0 || unsafeCount > 0) ? "wand.and.stars" : "checkmark.seal.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .accessibilityHidden(true)
                Text((needsBake > 0 || unsafeCount > 0) ? ShellStrings.text("iOS compatibility summary") : ShellStrings.text("All cheats ready on iPhone"))
                    .shellType(ShellType.cardTitle)
                    .foregroundStyle(.white)
            }

            CheatsTagFlowLayout(spacing: 8) {
                if snapshot.dataReadyCount > 0 {
                    capabilityStatChip(
                        color: ShellPalette.ready,
                        symbol: "checkmark.circle.fill",
                        label: ShellStrings.text("\(snapshot.dataReadyCount) direct on iPhone")
                    )
                }
                if snapshot.codeBakedCount > 0 {
                    capabilityStatChip(
                        color: Color.cyan,
                        symbol: "cpu.fill",
                        label: ShellStrings.text("\(snapshot.codeBakedCount) code baked")
                    )
                }
                if snapshot.codeNeedsBakeCount > 0 {
                    capabilityStatChip(
                        color: Color.orange,
                        symbol: "bolt.circle.fill",
                        label: ShellStrings.text("\(snapshot.codeNeedsBakeCount) need builder bake")
                    )
                }
                if snapshot.unsafeCodeCount > 0 {
                    capabilityStatChip(
                        color: DeleteStyle.red,
                        symbol: "shield.slash.fill",
                        label: ShellStrings.text("\(snapshot.unsafeCodeCount) safety blocked")
                    )
                }
                if snapshot.fixedAddressCount > 0 {
                    capabilityStatChip(
                        color: ShellPalette.attention,
                        symbol: "exclamationmark.triangle.fill",
                        label: ShellStrings.text("\(snapshot.fixedAddressCount) fixed offset")
                    )
                }
            }

            if needsBake > 0 {
                Text(ShellStrings.text("\(readyCount) cheats are ready right now on iPhone. \(needsBake) code cheats need one fast bake on the desktop builder before they can be switched on here."))
                    .shellType(ShellType.note)
                    .foregroundStyle(.white.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cheats.triageNeedsBakeText")

                if let exportURL = snapshot.exportFileURL {
                    ShareLink(item: exportURL) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                            Text(ShellStrings.text("Share .txt to computer for fast bake"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ShellButtonStyle(fills: true))
                    .accessibilityIdentifier("cheats.shareForBake")
                }
            } else if unsafeCount > 0 {
                Text(ShellStrings.text("\(unsafeCount) cheats were blocked by static safety checks and stay disabled on iPhone."))
                    .shellType(ShellType.note)
                    .foregroundStyle(.white.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cheats.triageUnsafeText")
            } else {
                Text(ShellStrings.text("Every cheat in this file can be toggled directly on iPhone and applies the next time you launch the game."))
                    .shellType(ShellType.note)
                    .foregroundStyle(.white.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cheats.triageReadyText")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accentColor.opacity(0.36), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func capabilityStatChip(color: Color, symbol: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(label)
                .shellText(12, .semibold, relativeTo: .caption)
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(ShellPalette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.42), lineWidth: 1))
    }

    private var emptyStateCard: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(ShellPalette.cream.opacity(0.72))
                .accessibilityHidden(true)
            Text(ShellStrings.text("No cheats imported yet"))
                .shellType(ShellType.cardTitle)
            Text(emptyHintText)
                .shellType(ShellType.note)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !snapshot.otherBuildIDs.isEmpty {
                Text(ShellStrings.text("Found files for other builds: \(snapshot.otherBuildIDs.joined(separator: ", "))"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .shellCard()
        .accessibilityElement(children: .contain)
    }

    private var emptyHintText: String {
        if let buildID = snapshot.buildID {
            return ShellStrings.text("Tap Import .txt above to load \(buildID).txt from Files. Memory cheats work immediately on iPhone, and code cheats can be baked once on your computer.")
        }
        return ShellStrings.text("Tap Import .txt above to load an Atmosphere cheat file from Files.")
    }

    private var entriesCard: some View {
        let visible = snapshot.visibleEntries
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                let startsSection = !entry.section.isEmpty && (index == 0 || visible[index - 1].section != entry.section)
                if startsSection {
                    Text(entry.section.uppercased())
                        .shellType(ShellType.sectionCaps)
                        .foregroundStyle(ShellPalette.cream.opacity(0.72))
                        .padding(.top, index == 0 ? 0 : 14)
                        .padding(.bottom, 6)
                        .accessibilityIdentifier("cheats.section.\(entry.section)")
                } else if index > 0 {
                    Rectangle().fill(ShellPalette.hairline).frame(height: 1).padding(.vertical, 6)
                }
                cheatRow(entry)
            }
        }
        .shellCard()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func cheatRow(_ entry: GameCheatEntry) -> some View {
        if entry.isLabel {
            Text(entry.name)
                .shellType(ShellType.note)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else if entry.isMaster {
            HStack(alignment: .center, spacing: 10) {
                entryTitleColumn(entry)
                Spacer(minLength: 8)
                if entry.isBroken {
                    malformedPill
                } else {
                    Text(ShellStrings.text("Always on"))
                        .shellText(12, .semibold, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.08), in: Capsule())
                }
            }
            .padding(.vertical, 4)
        } else {
            HStack(alignment: .center, spacing: 12) {
                entryTitleColumn(entry)
                Spacer(minLength: 8)
                if entry.isBroken {
                    malformedPill
                } else if entry.isOnce {
                    Text(ShellStrings.text("One-shot"))
                        .shellText(11.5, .semibold, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                } else if entry.isUnsafeCode {
                    Button {
                        let reason = entry.unsafeCodeReason ?? ""
                        let msg = reason.isEmpty
                            ? ShellStrings.text("This cheat was blocked by static safety checks and cannot be enabled.")
                            : reason
                        statusMessage = (msg, true)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "shield.slash.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text(ShellStrings.text("Blocked"))
                                .shellText(11.5, .semibold, relativeTo: .caption)
                        }
                        .foregroundStyle(DeleteStyle.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(DeleteStyle.red.opacity(0.14), in: Capsule())
                        .overlay(Capsule().strokeBorder(DeleteStyle.red.opacity(0.42), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cheats.unsafe.\(entry.key)")
                } else if entry.capability == .codeNeedsBake {
                    Button {
                        statusMessage = (ShellStrings.text("Share this .txt file to your computer and run fast bake once to unlock code cheats on iPhone."), true)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text(ShellStrings.text("Needs builder"))
                                .shellText(11.5, .semibold, relativeTo: .caption)
                        }
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.38), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cheats.locked.\(entry.key)")
                } else {
                    let toggleBinding = Binding(
                        get: { entry.enabled },
                        set: { newValue in toggleEntry(entry.key, newValue) }
                    )
                    Toggle("", isOn: toggleBinding)
                        .labelsHidden()
                        .toggleStyle(NativeCreamToggleStyle())
                        .accessibilityLabel(entry.name)
                        .accessibilityIdentifier("cheats.toggle.\(entry.key)")
                        .shellTarget("cht.row.\(entry.key)") { toggleEntry(entry.key, !entry.enabled) }
                }
            }
            .padding(.vertical, 4)
            .opacity((entry.capability == .codeNeedsBake || entry.isUnsafeCode) ? 0.78 : 1.0)
        }
    }

    private var malformedPill: some View {
        Text(ShellStrings.text("Malformed"))
            .shellText(11.5, .semibold, relativeTo: .caption)
            .foregroundStyle(ShellPalette.attention)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(ShellPalette.attention.opacity(0.14), in: Capsule())
    }

    private func entryTitleColumn(_ entry: GameCheatEntry) -> some View {
        let showFixedAddress = !entry.isBroken && !entry.isOnce && (entry.hasFixedAddress || entry.capability == .fixedHeapWarning)
        let showCapability = !entry.isBroken && !entry.isOnce && !entry.isUnsafeCode && !(entry.capability == .fixedHeapWarning && showFixedAddress)
        let triggerCombo = entry.isBroken ? nil : entry.triggerCombo
        return VStack(alignment: .leading, spacing: 5) {
            Text(entry.name)
                .shellType(ShellType.settingLabel)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            if showCapability || entry.isUnsafeCode || showFixedAddress || triggerCombo != nil {
                CheatsTagFlowLayout(spacing: 6) {
                    if entry.isUnsafeCode {
                        HStack(spacing: 4) {
                            Image(systemName: "shield.slash.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(DeleteStyle.red)
                                .accessibilityHidden(true)
                            Text(ShellStrings.text("Safety blocked"))
                                .shellText(11.5, .semibold, relativeTo: .caption)
                                .foregroundStyle(DeleteStyle.red)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(DeleteStyle.red.opacity(0.14), in: Capsule())
                        .overlay(Capsule().strokeBorder(DeleteStyle.red.opacity(0.42), lineWidth: 1))
                    } else if showCapability {
                        rowCapabilityBadge(entry.capability)
                    }

                    if showFixedAddress {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(ShellPalette.attention)
                                .accessibilityHidden(true)
                            Text(ShellStrings.text("Fixed address · may break"))
                                .shellText(11.5, .semibold, relativeTo: .caption)
                                .foregroundStyle(ShellPalette.attention)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ShellPalette.attention.opacity(0.14), in: Capsule())
                        .overlay(Capsule().strokeBorder(ShellPalette.attention.opacity(0.42), lineWidth: 1))
                        .accessibilityIdentifier("cheats.fixedAddress.\(entry.key)")
                    }

                    if let combo = triggerCombo {
                        HStack(spacing: 4) {
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(ShellPalette.cream)
                                .accessibilityHidden(true)
                            Text(ShellStrings.text("Hold \(combo)"))
                                .shellText(11.5, .semibold, relativeTo: .caption)
                                .foregroundStyle(ShellPalette.cream)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ShellPalette.cream.opacity(0.14), in: Capsule())
                        .accessibilityIdentifier("cheats.key.\(entry.key)")
                    }
                }
            }

            if let reason = entry.unsafeCodeReason {
                Text(reason.isEmpty ? ShellStrings.text("Blocked by static safety check during code baking.") : reason)
                    .shellText(11.5, .regular, relativeTo: .caption)
                    .foregroundStyle(DeleteStyle.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cheats.unsafeReason.\(entry.key)")
            }

            if showFixedAddress {
                Text(ShellStrings.text("Address may shift after restart. Use the in-game Memory Scanner if needed."))
                    .shellText(11.5, .regular, relativeTo: .caption)
                    .foregroundStyle(ShellPalette.attention.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rowCapabilityBadge(_ capability: CheatCapability) -> some View {
        let style: (color: Color, symbol: String, label: String) = {
            switch capability {
            case .dataReady:
                return (ShellPalette.ready, "circle.fill", ShellStrings.text("Direct on iPhone"))
            case .codeBaked:
                return (Color.cyan, "cpu.fill", ShellStrings.text("Code baked"))
            case .codeNeedsBake:
                return (Color.orange, "bolt.circle.fill", ShellStrings.text("Needs builder bake"))
            case .fixedHeapWarning:
                return (ShellPalette.attention, "exclamationmark.triangle.fill", ShellStrings.text("Fixed offset"))
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: style.symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(style.color)
                .accessibilityHidden(true)
            Text(style.label)
                .shellText(11.5, .medium, relativeTo: .caption)
                .foregroundStyle(style.color.opacity(0.95))
        }
    }

    // MARK: - Actions

    private func nextGeneration() -> UInt64 {
        opGeneration &+= 1
        return opGeneration
    }

    private func loadSnapshotAsync() async {
        let targetID = snapshot.gameID
        let gen = nextGeneration()
        if let asyncLoader = actions.onLoadCheatsAsync {
            let refreshed = await asyncLoader(targetID)
            guard !Task.isCancelled, opGeneration == gen, snapshot.gameID == targetID else { return }
            snapshot = refreshed
        } else if let refreshed = actions.onLoadCheats?(targetID) {
            guard opGeneration == gen, snapshot.gameID == targetID else { return }
            snapshot = refreshed
        }
    }

    private func toggleMaster(_ on: Bool) {
        let targetID = snapshot.gameID
        let gen = nextGeneration()
        snapshot.masterOn = on
        if let asyncToggle = actions.onToggleCheatMasterAsync {
            Task {
                let refreshed = await asyncToggle(targetID, on)
                guard opGeneration == gen, snapshot.gameID == targetID else { return }
                snapshot = refreshed
            }
        } else if let refreshed = actions.onToggleCheatMaster?(targetID, on) {
            guard opGeneration == gen, snapshot.gameID == targetID else { return }
            snapshot = refreshed
        }
    }

    private func toggleEntry(_ key: String, _ on: Bool) {
        let targetID = snapshot.gameID
        let gen = nextGeneration()
        if let idx = snapshot.entries.firstIndex(where: { $0.key == key }) {
            snapshot.entries[idx].enabled = on
        }
        if let asyncToggle = actions.onToggleCheatEntryAsync {
            Task {
                let refreshed = await asyncToggle(targetID, key, on)
                guard opGeneration == gen, snapshot.gameID == targetID else { return }
                snapshot = refreshed
            }
        } else if let refreshed = actions.onToggleCheatEntry?(targetID, key, on) {
            guard opGeneration == gen, snapshot.gameID == targetID else { return }
            snapshot = refreshed
        }
    }

    private func dismissFuseAlert() {
        let targetID = snapshot.gameID
        let gen = nextGeneration()
        snapshot.fuseAlert = nil
        if let asyncDismiss = actions.onDismissCheatFuseAlertAsync {
            Task {
                let refreshed = await asyncDismiss(targetID)
                guard opGeneration == gen, snapshot.gameID == targetID else { return }
                snapshot = refreshed
            }
        } else if let refreshed = actions.onDismissCheatFuseAlert?(targetID) {
            guard opGeneration == gen, snapshot.gameID == targetID else { return }
            snapshot = refreshed
        }
    }

    private func importCheatFile() async {
        guard let importer = actions.onImportCheatFile else { return }
        let targetID = snapshot.gameID
        let gen = nextGeneration()
        importing = true
        let outcome = await importer(targetID)
        guard !Task.isCancelled, opGeneration == gen, snapshot.gameID == targetID else { return }
        importing = false
        handleImportOutcome(outcome)
    }

    private func fetchCheats() async {
        guard let fetcher = actions.onFetchCheats else { return }
        let targetID = snapshot.gameID
        let gen = nextGeneration()
        fetching = true
        let outcome = await fetcher(targetID)
        guard !Task.isCancelled, opGeneration == gen, snapshot.gameID == targetID else { return }
        fetching = false
        switch outcome {
        case .completed(let updated, let receipt):
            snapshot = updated
            lastFetchReceipt = receipt
            switch receipt.status {
            case "found":
                statusMessage = (ShellStrings.text("Fetched \(receipt.entryCount) cheats from online sources."), false)
            case "preserved_user":
                statusMessage = (ShellStrings.text("Your own cheat file was kept instead of overwriting it."), true)
            case "not_found":
                statusMessage = (ShellStrings.text("No matching cheats exist in the online database for this build."), false)
            case "offline":
                statusMessage = (ShellStrings.text("Offline, could not check online"), true)
            default:
                statusMessage = (ShellStrings.text("Online fetch unavailable"), true)
            }
        case .failed(let message):
            if !message.isEmpty {
                statusMessage = (message, true)
            }
        }
    }

    private func deleteCurrentCheatFile() {
        let targetID = snapshot.gameID
        let gen = nextGeneration()
        if let asyncDelete = actions.onDeleteCheatFileAsync {
            deleting = true
            Task {
                let updated = await asyncDelete(targetID)
                guard opGeneration == gen, snapshot.gameID == targetID else { return }
                deleting = false
                snapshot = updated
                lastFetchReceipt = nil
                statusMessage = (ShellStrings.text("Deleted cheat file. Bundled cheats will not be restored automatically."), false)
            }
        } else if let updated = actions.onDeleteCheatFile?(targetID) {
            guard opGeneration == gen, snapshot.gameID == targetID else { return }
            snapshot = updated
            lastFetchReceipt = nil
            statusMessage = (ShellStrings.text("Deleted cheat file. Bundled cheats will not be restored automatically."), false)
        }
    }

    private func confirmMismatch(_ mismatch: PendingMismatch) {
        let targetID = snapshot.gameID
        let gen = nextGeneration()
        pendingMismatch = nil
        if let asyncConfirm = actions.onConfirmMismatchCheatImportAsync {
            importing = true
            Task {
                let outcome = await asyncConfirm(targetID, mismatch.token)
                guard opGeneration == gen, snapshot.gameID == targetID else { return }
                importing = false
                handleImportOutcome(outcome)
            }
        } else if let outcome = actions.onConfirmMismatchCheatImport?(targetID, mismatch.token) {
            guard opGeneration == gen, snapshot.gameID == targetID else { return }
            handleImportOutcome(outcome)
        }
    }

    private func cancelMismatch() {
        if pendingMismatch != nil {
            pendingMismatch = nil
            actions.onCancelMismatchCheatImport?(snapshot.gameID)
        }
    }

    private func handleImportOutcome(_ outcome: CheatImportOutcome) {
        switch outcome {
        case .imported(let updated, _, let count):
            snapshot = updated
            statusMessage = (ShellStrings.text("Imported \(count) cheats."), false)
        case .buildMismatch(let fileBuildID, let expectedBuildID, let fileName, let token):
            pendingMismatch = PendingMismatch(
                fileBuildID: fileBuildID,
                expectedBuildID: expectedBuildID,
                fileName: fileName,
                token: token
            )
        case .cancelled:
            break
        case .failed(let message):
            statusMessage = (message, true)
        }
    }
}
