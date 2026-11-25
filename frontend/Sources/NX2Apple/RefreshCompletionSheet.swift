import SwiftUI
import NXCore
import NXLauncher
import NXModel

/// In-app summary modal shown after a single or batch refresh completes, detailing per-game `.img` status.
struct RefreshCompletionSheet: View {
    let summary: RefreshCompletionSummary
    let revealItem: (String) -> Void
    let onViewQueue: () -> Void
    let close: () -> Void

    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var pad: PadFocus

    private var titleText: String {
        if summary.items.count <= 1, let single = summary.items.first {
            return single.succeeded
                ? String(format: loc.t("refreshDone.sheetTitleSingle"), single.name)
                : String(format: loc.t("notify.failedTitle"), single.name)
        }
        let succeeded = summary.items.filter(\.succeeded).count
        let failed = summary.items.count - succeeded
        if failed == 0 {
            return String(format: loc.t("refreshDone.sheetTitleBatch"), succeeded)
        }
        return String(format: loc.t("refreshDone.sheetTitlePartial"), succeeded, failed)
    }

    static let sheetWidth: CGFloat = 560

    var body: some View {
        DSSheet(
            width: Self.sheetWidth,
            title: titleText,
            message: loc.t("refreshDone.sheetSubtitle")
        ) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                VStack(spacing: 0) {
                    ForEach(Array(summary.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            DS.Color.separator.frame(height: 1).padding(.horizontal, DS.Space.m)
                        }
                        itemRow(item)
                    }
                }
                .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.separator))

                if !summary.manualReplaceItems.isEmpty {
                    let allMSL = summary.manualReplaceItems.allSatisfy { item in
                        if case .manualReplace(let path, _) = item.imgStatus {
                            return QueueEntryImgStatus.isMSLFallback(path)
                        }
                        return false
                    }
                    HStack(alignment: .top, spacing: DS.Space.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LauncherPalette.building)
                            .padding(.top, 1)
                            .accessibilityHidden(true)
                        Text(loc.t(allMSL ? "refreshDone.manualActionHintMsl" : "refreshDone.manualActionHint"))
                            .font(DS.Font.callout)
                            .foregroundStyle(DS.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(DS.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.separator))
                }
            }
        } buttons: {
            if summary.isBatch {
                Button(loc.t("refreshDone.viewQueue")) { onViewQueue() }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .padTarget("refreshDone.queue", scope: "refreshDone") { onViewQueue() }
            }
            DSSheetPrimaryButton(loc.t("refreshDone.close"), action: close)
                .padTarget("refreshDone.close", scope: "refreshDone", focusColor: DS.Color.accentOn) { close() }
        }
        .background(PadKeyboardInput(focus: pad, scope: "refreshDone", back: close))
        .padScope("refreshDone", pad)
        .onAppear {
            pad.scope = "refreshDone"
            if pad.visible {
                DispatchQueue.main.async { pad.show(default: "refreshDone.close") }
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: RefreshNoticeItem) -> some View {
        let statusLine = RefreshCompletionFormatter.itemLineStatus(item, t: loc.t)
        let platformLabel = item.target == BuildTarget.mac ? loc.t("batchRefresh.platformMac") : loc.t("batchRefresh.platformIOS")
        let manualPath: String? = {
            if case .manualReplace(let path, _) = item.imgStatus, !path.isEmpty {
                return path
            }
            return nil
        }()
        HStack(alignment: .center, spacing: DS.Space.m) {
            Image(systemName: statusIconName(for: item))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(statusColor(for: item))
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xs) {
                    Text(item.name)
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(DS.Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    DSTag(platformLabel)
                }
                Text(statusLine)
                    .font(DS.Font.callout)
                    .foregroundStyle(detailColor(for: item))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let manualPath {
                Button(loc.t("install.reveal")) { revealItem(manualPath) }
                    .buttonStyle(DSRowButtonStyle())
                    .help(manualPath)
                    .padTarget("refreshDone.reveal." + item.id.uuidString, scope: "refreshDone") {
                        revealItem(manualPath)
                    }
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s + 2)
    }

    private func statusIconName(for item: RefreshNoticeItem) -> String {
        guard item.succeeded else { return "xmark.circle.fill" }
        switch item.imgStatus {
        case .unchanged, .transferred:
            return "checkmark.circle.fill"
        case .manualReplace:
            return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(for item: RefreshNoticeItem) -> Color {
        guard item.succeeded else { return DS.Color.statusError }
        switch item.imgStatus {
        case .unchanged, .transferred:
            return DS.Color.statusSuccess
        case .manualReplace:
            return LauncherPalette.building
        }
    }

    private func detailColor(for item: RefreshNoticeItem) -> Color {
        guard item.succeeded else { return DS.Color.statusError }
        switch item.imgStatus {
        case .unchanged, .transferred:
            return DS.Color.textSecondary
        case .manualReplace:
            return LauncherPalette.building
        }
    }
}
