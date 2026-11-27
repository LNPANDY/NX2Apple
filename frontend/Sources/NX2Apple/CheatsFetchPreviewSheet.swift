import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Online cheat preview payload passed to `CheatsFetchPreviewSheet`.
struct CheatOnlinePreview: Identifiable, Sendable {
    let id = UUID()
    let titleID: String
    let buildID: String
    let localText: String
    let onlineText: String
    let sources: [String]
    let entryCount: Int
    let diff: CheatDiffSummary

    static func build(
        titleID: String,
        buildID: String,
        folder: URL,
        onlineText: String,
        sources: [String],
        entryCount: Int,
        rxEnd: UInt64?,
        trampolines: CheatTrampolineMetadata?
    ) -> CheatOnlinePreview {
        let localText: String = {
            if let existing = CheatFetcher.existingCheatFile(buildID: buildID, in: folder),
               let data = try? Data(contentsOf: existing) {
                return String(decoding: data, as: UTF8.self)
            }
            return ""
        }()
        let diff = CheatFetcher.diffSummary(
            localText: localText,
            onlineText: onlineText,
            rxEnd: rxEnd,
            trampolines: trampolines,
            buildID: buildID
        )
        return CheatOnlinePreview(
            titleID: titleID,
            buildID: buildID,
            localText: localText,
            onlineText: onlineText,
            sources: sources,
            entryCount: entryCount,
            diff: diff
        )
    }
}

/// Sheet presenting a structured comparison between the player's local `<BID>.txt` and the fetched online cheats.
struct CheatsFetchPreviewSheet: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus

    let preview: CheatOnlinePreview
    let onKeepLocal: () -> Void
    let onMergeAdded: () -> Void
    let onReplaceWithOnline: () -> Void

    @State private var mode: String
    @State private var expandedIDs: Set<String>

    init(
        preview: CheatOnlinePreview,
        initialMode: String = "list",
        initialExpandedIDs: Set<String> = [],
        onKeepLocal: @escaping () -> Void,
        onMergeAdded: @escaping () -> Void,
        onReplaceWithOnline: @escaping () -> Void
    ) {
        self.preview = preview
        self.onKeepLocal = onKeepLocal
        self.onMergeAdded = onMergeAdded
        self.onReplaceWithOnline = onReplaceWithOnline
        _mode = State(initialValue: initialMode)
        _expandedIDs = State(initialValue: initialExpandedIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSheetHeader(
                title: loc.t("cheats.preview.title"),
                message: String(format: loc.t("cheats.preview.subtitle"), preview.buildID)
            )
            .padding(.horizontal, DSSheetInsets.horizontal)
            .padding(.top, DSSheetInsets.vertical)
            .padding(.bottom, DSSheetInsets.gap)

            VStack(alignment: .leading, spacing: DSSheetInsets.gap) {
                summaryCard

                HStack(alignment: .center, spacing: DS.Space.s) {
                    LauncherSegmented(
                        options: [
                            ("list", loc.t("cheats.preview.modeList")),
                            ("raw", loc.t("cheats.preview.modeRaw")),
                        ],
                        selection: mode,
                        size: 13,
                        semibold: true
                    ) { mode = $0 }
                    .compactFrame(minWidth: 196)
                    Spacer(minLength: 0)
                }

                contentArea
            }
            .padding(.horizontal, DSSheetInsets.horizontal)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(String(format: loc.t("cheats.preview.backupHint"), preview.buildID + ".txt"))
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                DSSheetButtonRow {
                    Button(loc.t("cheats.preview.keepLocal")) { onKeepLocal() }
                        .buttonStyle(LauncherSecondaryButtonStyle())
                        .fixedSize(horizontal: true, vertical: false)
                        .padTarget("cheatsPreview.keep", scope: "cheatsPreview") { onKeepLocal() }
                } buttons: {
                    if preview.diff.addedCount > 0 {
                        Button(String(format: loc.t("cheats.preview.mergeAdded"), preview.diff.addedCount)) {
                            onMergeAdded()
                        }
                        .buttonStyle(LauncherSecondaryButtonStyle())
                        .fixedSize(horizontal: true, vertical: false)
                        .padTarget("cheatsPreview.merge", scope: "cheatsPreview") { onMergeAdded() }
                    }
                    DSSheetPrimaryButton(loc.t("cheats.preview.replaceOnline"), action: onReplaceWithOnline)
                        .padTarget("cheatsPreview.replace", scope: "cheatsPreview", focusColor: DS.Color.accentOn) {
                            onReplaceWithOnline()
                        }
                }
            }
            .padding(.horizontal, DSSheetInsets.horizontal)
            .padding(.top, DSSheetInsets.gap)
            .padding(.bottom, DSSheetInsets.vertical)
        }
        .padScope("cheatsPreview", focus)
        .frame(width: 640, height: 720)
        .dsSheetSurface()
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .center, spacing: DS.Space.xs) {
                if !preview.sources.isEmpty {
                    Text(String(format: loc.t("cheats.preview.sources"), preview.sources.joined(separator: " + ")))
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: DS.Space.xs)
                Text(String(format: loc.t("cheats.preview.countsSummary"), preview.diff.localCount, preview.diff.onlineCount))
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
            }

            DSFlowRow(spacing: DS.Space.xs) {
                diffBadge(
                    symbol: "plus.circle.fill",
                    symbolColor: DS.Color.statusReady,
                    text: String(format: loc.t("cheats.preview.badgeAdded"), preview.diff.addedCount),
                    highlight: preview.diff.addedCount > 0
                )
                diffBadge(
                    symbol: "equal.circle.fill",
                    symbolColor: DS.Color.symbolDefault,
                    text: String(format: loc.t("cheats.preview.badgeSameName"), preview.diff.sameNameCount),
                    highlight: false
                )
                if preview.diff.localOnlyCount > 0 {
                    diffBadge(
                        symbol: "doc.text.fill",
                        symbolColor: DS.Color.statusWarning,
                        text: String(format: loc.t("cheats.preview.badgeLocalOnly"), preview.diff.localOnlyCount),
                        highlight: false
                    )
                }
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .strokeBorder(DS.Color.separator, lineWidth: 1)
        )
    }

    private func diffBadge(symbol: String, symbolColor: Color, text: String, highlight: Bool) -> some View {
        HStack(spacing: DS.Space.xxs) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Font.footnote)
                .foregroundStyle(highlight ? DS.Color.textPrimary : DS.Color.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, DS.Space.xs)
        .padding(.vertical, DS.Space.xxs)
        .background(highlight ? DS.Color.statusReady.opacity(0.14) : DS.Color.surface, in: DSPill())
        .overlay(DSPill().strokeBorder(highlight ? DS.Color.statusReady.opacity(0.4) : DS.Color.separator, lineWidth: 1))
    }

    @ViewBuilder private var contentArea: some View {
        if mode == "raw" {
            ScrollView {
                Text(preview.onlineText)
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(DS.Space.m)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Color.background, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .strokeBorder(DS.Color.separator, lineWidth: 1)
            )
        } else if preview.diff.entries.isEmpty {
            VStack(spacing: DS.Space.xs) {
                Text(loc.t("cheats.preview.emptyList"))
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .strokeBorder(DS.Color.separator, lineWidth: 1)
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(preview.diff.entries.enumerated()), id: \.element.id) { index, entry in
                        let firstInSection = index == 0 || preview.diff.entries[index - 1].section != entry.section
                        if firstInSection && !entry.section.isEmpty {
                            Text(entry.section)
                                .font(DS.Font.footnote)
                                .foregroundStyle(DS.Color.textSecondary)
                                .padding(.horizontal, DS.Space.m)
                                .padding(.top, DS.Space.s)
                                .padding(.bottom, DS.Space.xxs)
                        }
                        entryRow(entry)
                        if index < preview.diff.entries.count - 1 {
                            DS.Color.separator.frame(height: 1).padding(.leading, DS.Space.m)
                        }
                    }
                }
                .padding(.vertical, DS.Space.xxs)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .strokeBorder(DS.Color.separator, lineWidth: 1)
            )
        }
    }

    private func entryRow(_ entry: CheatDiffEntry) -> some View {
        let isExpanded = expandedIDs.contains(entry.id)
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button {
                if isExpanded {
                    expandedIDs.remove(entry.id)
                } else {
                    expandedIDs.insert(entry.id)
                }
            } label: {
                HStack(alignment: .top, spacing: DS.Space.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Color.symbolDefault)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 14, height: 18)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        HStack(alignment: .center, spacing: DS.Space.xs) {
                            statusTag(entry.status)
                            if entry.isMaster {
                                DSTag(loc.t("cheats.preview.tagMaster"), emphasized: true)
                            }
                            Text(entry.name)
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Color.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if !entry.isBroken, let combo = entry.triggerCombo {
                                CheatTriggerKeyPill(combo: combo)
                            }
                            Spacer(minLength: 0)
                        }

                        if entry.isBroken {
                            Text(loc.t("cheats.broken"))
                                .font(DS.Font.callout)
                                .foregroundStyle(DS.Color.textSecondary)
                        } else {
                            HStack(spacing: DS.Space.xs) {
                                if entry.hasFixedAddress || entry.capability == .fixedHeapWarning {
                                    CheatFixedAddressPill()
                                }
                                if entry.capability != .fixedHeapWarning {
                                    CheatCapabilityTag(capability: entry.capability)
                                }
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(entry.rawBlock)
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(DS.Space.s)
                    .background(DS.Color.background, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.chip)
                            .strokeBorder(DS.Color.separator, lineWidth: 1)
                    )
                    .padding(.leading, 22)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.xs)
    }

    private func statusTag(_ status: CheatDiffEntryStatus) -> some View {
        let isAdded = status == .added
        return Text(loc.t(isAdded ? "cheats.preview.tagAdded" : "cheats.preview.tagSameName"))
            .font(DS.Font.footnote)
            .foregroundStyle(isAdded ? DS.Color.statusReady : DS.Color.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, 2)
            .background(isAdded ? DS.Color.statusReady.opacity(0.14) : DS.Color.surface, in: DSPill())
            .overlay(DSPill().strokeBorder(isAdded ? DS.Color.statusReady.opacity(0.4) : DS.Color.separator, lineWidth: 1))
    }
}
