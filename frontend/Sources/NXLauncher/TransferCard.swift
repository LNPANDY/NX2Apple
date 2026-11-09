import SwiftUI
import NXCore
import NXModel

/// "Game data transfers" (LNPANDY/NX2Apple#1036): the game data on its way to devices, apart from the build's progress. One row per
/// game: the game and its device, the current data progress, the state in words, and Retry / Cancel. A device that went away is
/// "Waiting for device" and the transfer continues from the verified parts. Observes the transfer queue.
package struct TransferCard: View {
    @ObservedObject var transfers: TransferQueueStore
    let showInFinder: (TransferEntry) -> Void
    @EnvironmentObject var loc: Localizer

    package init(transfers: TransferQueueStore, showInFinder: @escaping (TransferEntry) -> Void) {
        self.transfers = transfers
        self.showInFinder = showInFinder
    }

    package var body: some View {
        if !transfers.isEmpty {
            CardGroup(loc.t("transfer.title")) {
                ForEach(Array(transfers.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { CardDivider() }
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: TransferEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.manrope(14, .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(entry.deviceName).font(.manrope(12.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(loc.t("transfer.status." + (entry.status == .cancelling ? "sending" : entry.status.rawValue))).font(.manrope(12.5, .semibold)).foregroundStyle(color(entry.status))
            }
            if entry.status == .sending || entry.status == .cancelling {
                LauncherProgressBar(value: entry.totalBytes > 0 ? Double(entry.doneBytes) / Double(entry.totalBytes) : nil, height: 6)
                if entry.totalBytes > 0 {
                    Text(String(format: loc.t("transfer.progress"), ShellInstall.sizeText(entry.doneBytes), ShellInstall.sizeText(entry.totalBytes)))
                        .font(.manrope(12.5)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if entry.status == .waiting {
                Text(String(format: loc.t("transfer.waitingNote"), entry.deviceName)).font(.manrope(12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if entry.status == .cancelling {
                Text(loc.t("transfer.cancelling")).font(.manrope(12.5)).foregroundStyle(.secondary)
            }
            if entry.status == .failed, let reason = entry.reason {
                Text(reason).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if entry.status == .failed {
                    Button(loc.t("transfer.retry")) { transfers.retry(entry.id) }
                        .disabled(entry.status == .cancelling)
                        .accessibilityLabel(String(format: loc.t("transfer.retryNamed"), entry.name))
                    Button(loc.t("shell.showInFinder")) { showInFinder(entry) }
                        .accessibilityLabel(String(format: loc.t("transfer.finderNamed"), entry.name))
                }
                Button(loc.t("transfer.cancel")) { transfers.cancel(entry.id) }
                    .disabled(entry.status == .cancelling)
                    .accessibilityLabel(String(format: loc.t("transfer.cancelNamed"), entry.name))
            }
            .buttonStyle(LauncherSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 13)
        .accessibilityElement(children: .contain)
    }

    private func color(_ status: TransferEntry.Status) -> Color {
        switch status {
        case .done: return LauncherPalette.ready
        case .sending, .waiting: return LauncherPalette.building
        case .failed: return .red
        case .queued, .cancelling: return .secondary
        }
    }
}
