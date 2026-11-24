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

    private var maxSheetHeight: CGFloat {
        min(640, (NSScreen.main?.visibleFrame.height ?? 800) - 80)
    }

    var body: some View {
        DSSheet(
            title: titleText,
            message: loc.t("refreshDone.sheetSubtitle")
        ) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                DSCard {
                    VStack(spacing: 0) {
                        ForEach(Array(summary.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { CardDivider() }
                            itemRow(item)
                        }
                    }
                }
                if !summary.manualReplaceItems.isEmpty {
                    Text(loc.t("refreshDone.manualActionHint"))
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } buttons: {
            if summary.isBatch {
                Button(loc.t("refreshDone.viewQueue")) { onViewQueue() }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .padTarget("refreshDone.queue", scope: "refreshDone") { onViewQueue() }
            }
            DSSheetPrimaryButton(loc.t("refreshDone.close"), action: close)
                .padTarget("refreshDone.close", scope: "refreshDone") { close() }
        }
        .frame(width: 600)
        .frame(maxHeight: maxSheetHeight)
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
            Circle()
                .fill(dotColor(for: item))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xs) {
                    Text(item.name)
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(DS.Color.textPrimary)
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
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func dotColor(for item: RefreshNoticeItem) -> Color {
        guard item.succeeded else { return DS.Color.statusError }
        switch item.imgStatus {
        case .unchanged, .transferred:
            return LauncherPalette.ready
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
