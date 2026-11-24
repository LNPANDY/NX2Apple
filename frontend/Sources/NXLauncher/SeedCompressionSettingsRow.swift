import SwiftUI
import NXCore
import NXModel

/// Settings → Tools → Storage row for scanning and compressing legacy `.img` build seeds.
package struct SeedCompressionSettingsRow: View {
    @ObservedObject var store: SeedCompressionStore
    let buildRunning: Bool
    @EnvironmentObject var loc: Localizer

    package init(store: SeedCompressionStore, buildRunning: Bool) {
        self.store = store
        self.buildRunning = buildRunning
    }

    private var dotColor: Color? {
        if store.isScanning { return nil }
        switch store.scanState {
        case .idle, .scanning:
            return nil
        case .failed:
            return DSTone.warning.color
        case .ready(let hasAny, let scan, _):
            if scan.hasUncompressed {
                return DSTone.warning.color
            }
            return hasAny ? DSTone.success.color : nil
        }
    }

    private var statusDetail: String {
        if store.isScanning, case .idle = store.scanState {
            return loc.t("settings.update.checking")
        }
        switch store.scanState {
        case .idle, .scanning:
            return loc.t("seedCompress.settings.statusEmpty")
        case .failed(let message):
            return message
        case .ready(let hasAny, let scan, _):
            if scan.hasUncompressed {
                return String(format: loc.t("seedCompress.settings.statusFound"), scan.totalGames, ShellInstall.sizeText(scan.uncompressedBytes))
            }
            return loc.t(hasAny ? "seedCompress.settings.statusAllCompressed" : "seedCompress.settings.statusEmpty")
        }
    }

    private var warningMessage: DSRowMessage? {
        if store.zstdMissing {
            return .warning(loc.t("seedCompress.settings.zstdMissing"))
        }
        return nil
    }

    private var canCompress: Bool {
        !buildRunning && !store.isScanning && !store.isRunning && !store.zstdMissing
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardRow(loc.t("seedCompress.settings.title"), detail: statusDetail, dot: dotColor, message: warningMessage) {
                Button(loc.t("seedCompress.settings.rescanButton")) {
                    _ = store.scan(autoPromptOnFind: false)
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .disabled(store.isScanning || store.isRunning)
                .padTarget("set.seedCompressRescan", scope: "main", enabled: !store.isScanning && !store.isRunning) {
                    if !store.isScanning && !store.isRunning {
                        _ = store.scan(autoPromptOnFind: false)
                    }
                }
            }

            HStack(spacing: DS.Space.s) {
                if store.isScanning {
                    DSSpinner(size: 12)
                } else if store.noneNoticeVisible {
                    Text(loc.t("seedCompress.settings.noneNotice"))
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(loc.t("seedCompress.settings.compressButton")) {
                    _ = store.openManualPrompt()
                }
                .buttonStyle(LauncherSecondaryButtonStyle(accent: store.hasUncompressedSeeds ? LauncherPalette.cream : nil))
                .disabled(!canCompress)
                .fixedSize()
                .padTarget("set.seedCompressNow", scope: "main", enabled: canCompress) {
                    if canCompress {
                        _ = store.openManualPrompt()
                    }
                }
            }
            .padding(.leading, DSRowInset.title)
            .padding(.trailing, DS.Space.m)
            .padding(.bottom, DS.Space.s)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
