import SwiftUI
import NXCore
import NXModel

/// Three-state modal sheet for build-seed zstd compression: prompt, live progress, and completion summary.
package struct SeedCompressionSheet: View {
    package static let sheetWidth: CGFloat = 600

    @ObservedObject var store: SeedCompressionStore
    let gameNameResolver: (String) -> String?
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @State private var dontAskAgain = false
    @State private var showAllPromptGames = false

    package init(store: SeedCompressionStore, gameNameResolver: @escaping (String) -> String? = { _ in nil }) {
        self.store = store
        self.gameNameResolver = gameNameResolver
    }

    package var body: some View {
        Group {
            switch store.phase {
            case .prompt(let scan):
                promptSheet(scan)
            case .running(let state):
                progressSheet(state)
            case .done(let summary):
                doneSheet(summary)
            case nil:
                EmptyView()
            }
        }
        .padScope("seedCompress", pad)
        .onAppear { setInitialFocus() }
        .onChange(of: phaseFocusKey) { _ in setInitialFocus() }
    }

    private var phaseFocusKey: String {
        switch store.phase {
        case .prompt: return "prompt"
        case .running: return "running"
        case .done: return "done"
        case nil: return "none"
        }
    }

    private func setInitialFocus() {
        pad.scope = "seedCompress"
        switch store.phase {
        case .prompt: pad.focused = "seedCompress.compressNow"
        case .running: pad.focused = "seedCompress.stop"
        case .done: pad.focused = "seedCompress.finish"
        case nil: break
        }
    }

    // MARK: - 1. Prompt state

    private func promptSheet(_ scan: SeedScanResult) -> some View {
        let savedPct = percentageSaved(before: scan.uncompressedBytes, after: scan.estimatedCompressedBytes)
        let displayedGames = showAllPromptGames ? scan.games : Array(scan.games.prefix(4))
        let hiddenCount = max(0, scan.games.count - 4)

        return DSSheet(
            width: Self.sheetWidth,
            title: loc.t("seedCompress.prompt.title"),
            message: loc.t("seedCompress.prompt.subtitle")
        ) {
            HStack(alignment: .top, spacing: DS.Space.s) {
                metricCard(
                    label: loc.t("seedCompress.prompt.currentSize"),
                    value: ShellInstall.sizeText(scan.uncompressedBytes),
                    accentValue: false
                )
                metricCard(
                    label: loc.t("seedCompress.prompt.estimatedSize"),
                    value: ShellInstall.sizeText(scan.estimatedCompressedBytes),
                    accentValue: false
                )
                metricCard(
                    label: loc.t("seedCompress.prompt.estimatedSaved"),
                    value: String(format: loc.t("seedCompress.prompt.saveSummary"), ShellInstall.sizeText(scan.estimatedSavedBytes), savedPct),
                    accentValue: true
                )
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(String(format: loc.t("seedCompress.prompt.gamesTitle"), scan.totalGames))
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.textPrimary)

                VStack(spacing: 0) {
                    ForEach(Array(displayedGames.enumerated()), id: \.element.id) { index, game in
                        if index > 0 {
                            DS.Color.separator.frame(height: 1).padding(.horizontal, DS.Space.m)
                        }
                        HStack(spacing: DS.Space.s) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName(for: game.titleID, fallback: game.appName))
                                    .font(DS.Font.body)
                                    .foregroundStyle(DS.Color.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(game.titleID)
                                    .font(DS.Font.mono)
                                    .foregroundStyle(DS.Color.textTertiary)
                            }
                            Spacer(minLength: DS.Space.s)
                            Text(ShellInstall.sizeText(game.uncompressedBytes))
                                .font(DS.Font.callout)
                                .monospacedDigit()
                                .foregroundStyle(DS.Color.textSecondary)
                        }
                        .padding(.horizontal, DS.Space.m)
                        .padding(.vertical, DS.Space.xs)
                    }

                    if !showAllPromptGames && hiddenCount > 0 {
                        DS.Color.separator.frame(height: 1).padding(.horizontal, DS.Space.m)
                        Button {
                            showAllPromptGames = true
                        } label: {
                            HStack {
                                Text(String(format: loc.t("seedCompress.prompt.moreGames"), hiddenCount))
                                    .font(DS.Font.callout.weight(.medium))
                                    .foregroundStyle(DS.Color.textSecondary)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(DS.Color.symbolDefault)
                            }
                            .padding(.horizontal, DS.Space.m)
                            .padding(.vertical, DS.Space.xs)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .dsRowHover(radius: 0)
                        .padTarget("seedCompress.moreGames", scope: "seedCompress") {
                            showAllPromptGames = true
                        }
                    }
                }
                .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.separator))
            }

            DSRowMessageView(.info(loc.t("seedCompress.prompt.note")))
                .padding(DS.Space.s)
                .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.separator))
        } leading: {
            Toggle(isOn: $dontAskAgain) {
                Text(loc.t("seedCompress.prompt.dontAskAgain"))
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            .toggleStyle(.checkbox)
            .padTarget("seedCompress.dontAsk", scope: "seedCompress") {
                dontAskAgain.toggle()
            }
        } buttons: {
            Button(loc.t("seedCompress.prompt.later")) {
                store.dismissPrompt(dontAskAgain: dontAskAgain)
            }
            .buttonStyle(DSSecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)
            .padTarget("seedCompress.later", scope: "seedCompress") {
                store.dismissPrompt(dontAskAgain: dontAskAgain)
            }

            DSSheetPrimaryButton(loc.t("seedCompress.prompt.compressNow")) {
                _ = store.startCompression()
            }
            .padTarget("seedCompress.compressNow", scope: "seedCompress", focusColor: DS.Color.accentOn) {
                _ = store.startCompression()
            }
        }
    }

    // MARK: - 2. Progress state

    private func progressSheet(_ state: SeedCompressionStore.RunningState) -> some View {
        let fraction: Double = state.totalBytes > 0
            ? min(1.0, max(0.0, Double(state.processedBytes) / Double(state.totalBytes)))
            : (state.totalGames > 0 ? Double(state.currentIndex) / Double(state.totalGames) : 0)
        let currentIndex = state.currentIndex > 0 ? state.currentIndex : (state.totalGames > 0 ? 1 : 0)
        let activeName = state.currentTitleID.isEmpty
            ? (state.items.first.map { displayName(for: $0.titleID, fallback: $0.appName) } ?? "")
            : displayName(for: state.currentTitleID, fallback: state.currentName)

        return DSSheet(
            width: Self.sheetWidth,
            title: loc.t("seedCompress.progress.title"),
            message: loc.t("seedCompress.progress.subtitle")
        ) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(String(format: loc.t("seedCompress.progress.currentGame"), currentIndex, max(1, state.totalGames), activeName))
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                LauncherProgressBar(value: fraction, height: 8)
                    .frame(height: 8)

                HStack {
                    Text(String(
                        format: loc.t("seedCompress.progress.processed"),
                        ShellInstall.sizeText(state.processedBytes),
                        ShellInstall.sizeText(state.totalBytes)
                    ))
                    .font(DS.Font.callout)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.textSecondary)
                    Spacer()
                    Text(String(format: loc.t("seedCompress.progress.freed"), ShellInstall.sizeText(state.freedBytes)))
                        .font(DS.Font.callout.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(DS.Color.statusSuccess)
                }
            }
            .padding(DS.Space.m)
            .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.separator))

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            DS.Color.separator.frame(height: 1).padding(.horizontal, DS.Space.m)
                        }
                        progressItemRow(item)
                    }
                }
            }
            .frame(maxHeight: 260)
            .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.separator))
        } leading: {
            Text(loc.t("seedCompress.progress.safeStopNote"))
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            Button(loc.t(state.stopping ? "seedCompress.progress.stopping" : "seedCompress.progress.stop")) {
                store.stopCompression()
            }
            .buttonStyle(DSSecondaryButtonStyle(accent: LauncherPalette.building))
            .disabled(state.stopping)
            .padTarget("seedCompress.stop", scope: "seedCompress", enabled: !state.stopping) {
                store.stopCompression()
            }
        }
    }

    private func progressItemRow(_ item: SeedCompressionStore.ItemProgress) -> some View {
        HStack(spacing: DS.Space.s) {
            statusGlyph(for: item.status)
                .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: item.titleID, fallback: item.appName))
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if item.status == .failed, let err = item.error, !err.isEmpty {
                    Text(err)
                        .font(DS.Font.footnote)
                        .foregroundStyle(DS.Color.statusError)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: DS.Space.s)

            if item.status == .done {
                let pct = percentageSaved(before: item.beforeBytes, after: item.afterBytes)
                Text("\(ShellInstall.sizeText(item.beforeBytes)) → \(ShellInstall.sizeText(item.afterBytes)) (-\(pct)%)")
                    .font(DS.Font.footnote)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.statusSuccess)
            } else {
                Text(ShellInstall.sizeText(item.beforeBytes))
                    .font(DS.Font.footnote)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.textTertiary)
            }

            DSTag(progressStatusLabel(item.status), emphasized: item.status == .compressing)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.xs)
    }

    @ViewBuilder private func statusGlyph(for status: SeedCompressionStore.ItemStatus) -> some View {
        switch status {
        case .waiting:
            Image(systemName: "circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Color.textTertiary)
        case .compressing:
            DSSpinner(size: 12)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Color.statusSuccess)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Color.statusError)
        }
    }

    private func progressStatusLabel(_ status: SeedCompressionStore.ItemStatus) -> String {
        switch status {
        case .waiting: return loc.t("seedCompress.progress.statusWaiting")
        case .compressing: return loc.t("seedCompress.progress.statusCompressing")
        case .done: return loc.t("seedCompress.progress.statusDone")
        case .failed: return loc.t("seedCompress.progress.statusFailed")
        }
    }

    // MARK: - 3. Done state

    private func doneSheet(_ summary: SeedCompressSummary) -> some View {
        let titleKey: String
        let subtitleKey: String
        switch summary.status {
        case .completed:
            titleKey = "seedCompress.done.title"
            subtitleKey = "seedCompress.done.subtitle"
        case .partial:
            titleKey = "seedCompress.done.titlePartial"
            subtitleKey = "seedCompress.done.subtitlePartial"
        case .stopped:
            titleKey = "seedCompress.done.titleStopped"
            subtitleKey = "seedCompress.done.subtitleStopped"
        }

        let savedPct = percentageSaved(before: summary.beforeBytes, after: summary.afterBytes)
        let ratioPct = ratioPercent(before: summary.beforeBytes, after: summary.afterBytes)
        let ratioFraction = summary.beforeBytes > 0
            ? min(1.0, max(0.02, Double(summary.afterBytes) / Double(summary.beforeBytes)))
            : 0.0

        return DSSheet(
            width: Self.sheetWidth,
            title: loc.t(titleKey),
            message: loc.t(subtitleKey)
        ) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(String(
                    format: loc.t("seedCompress.done.sizeChange"),
                    ShellInstall.sizeText(summary.beforeBytes),
                    ShellInstall.sizeText(summary.afterBytes)
                ))
                .font(DS.Font.headline)
                .monospacedDigit()
                .foregroundStyle(DS.Color.textPrimary)

                Text(String(format: loc.t("seedCompress.done.savedSummary"), ShellInstall.sizeText(summary.savedBytes), savedPct))
                    .font(DS.Font.title)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.statusSuccess)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.Color.separator)
                        Capsule()
                            .fill(DS.Color.accent)
                            .frame(width: summary.afterBytes > 0 ? max(8, geo.size.width * ratioFraction) : 0)
                    }
                }
                .frame(height: 8)
                .padding(.top, DS.Space.xxs)

                Text(String(format: loc.t("seedCompress.done.ratioNote"), ratioPct))
                    .font(DS.Font.callout)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.textSecondary)
            }
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.separator))

            if !summary.results.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(loc.t("seedCompress.done.detailsTitle"))
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(DS.Color.textPrimary)

                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(summary.results.enumerated()), id: \.element.id) { index, item in
                                if index > 0 {
                                    DS.Color.separator.frame(height: 1).padding(.horizontal, DS.Space.m)
                                }
                                doneItemRow(item)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.separator))
                }
            }
        } leading: {
            HStack(spacing: DS.Space.xs) {
                Text(String(format: loc.t("seedCompress.done.completedCount"), summary.completedGames))
                    .font(DS.Font.footnote)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.textSecondary)
                if summary.failedGames > 0 {
                    Text(String(format: loc.t("seedCompress.done.failedCount"), summary.failedGames))
                        .font(DS.Font.footnote)
                        .monospacedDigit()
                        .foregroundStyle(DS.Color.statusError)
                }
                Text(String(format: loc.t("seedCompress.done.elapsed"), formatElapsed(summary.elapsedSec)))
                    .font(DS.Font.footnote)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.textTertiary)
            }
        } buttons: {
            DSSheetPrimaryButton(loc.t("seedCompress.done.finish")) {
                store.finishDone()
            }
            .keyboardShortcut(.cancelAction)
            .padTarget("seedCompress.finish", scope: "seedCompress", focusColor: DS.Color.accentOn) {
                store.finishDone()
            }
        }
    }

    private func doneItemRow(_ item: SeedCompressItemResult) -> some View {
        let isError = item.status == "error"
        return HStack(spacing: DS.Space.s) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isError ? DS.Color.statusError : DS.Color.statusSuccess)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: item.titleID, fallback: ""))
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isError, let err = item.error, !err.isEmpty {
                    Text(err)
                        .font(DS.Font.footnote)
                        .foregroundStyle(DS.Color.statusError)
                        .lineLimit(2)
                } else {
                    Text(item.titleID)
                        .font(DS.Font.mono)
                        .foregroundStyle(DS.Color.textTertiary)
                }
            }

            Spacer(minLength: DS.Space.s)

            if !isError {
                let pct = percentageSaved(before: item.beforeBytes, after: item.afterBytes)
                Text("\(ShellInstall.sizeText(item.beforeBytes)) → \(ShellInstall.sizeText(item.afterBytes)) (-\(pct)%)")
                    .font(DS.Font.callout)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.xs)
    }

    // MARK: - Helpers

    private func metricCard(label: String, value: String, accentValue: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(label)
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
            Text(value)
                .font(DS.Font.headline)
                .monospacedDigit()
                .foregroundStyle(accentValue ? DS.Color.statusSuccess : DS.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(DS.Space.s)
        .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.separator))
    }

    private func displayName(for titleID: String, fallback: String) -> String {
        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let resolved = gameNameResolver(tid), !resolved.isEmpty {
            return resolved
        }
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? tid : trimmed
    }

    private func percentageSaved(before: Int64, after: Int64) -> Int {
        guard before > 0 else { return 0 }
        let saved = max(0, before - after)
        return Int((Double(saved) / Double(before) * 100.0).rounded())
    }

    private func ratioPercent(before: Int64, after: Int64) -> Int {
        guard before > 0 else { return 0 }
        return Int((Double(max(0, after)) / Double(before) * 100.0).rounded())
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 {
            return "\(total)s"
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
