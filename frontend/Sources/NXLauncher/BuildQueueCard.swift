import SwiftUI
import NXCore
import NXModel

/// The build queue (LNPANDY/NX2Apple#943): follows the current job's progress and result, above the log. Observes the queue store.
/// Rows: name and status, the input summary, then Move up / Move down / Remove. No drag gestures.
package struct BuildQueueCard: View {
    @ObservedObject var queue: BuildQueueStore
    let onSelectGames: () -> Void
    @EnvironmentObject var loc: Localizer
    @State private var confirmingCancel = false

    package init(queue: BuildQueueStore, onSelectGames: @escaping () -> Void) {
        self.queue = queue
        self.onSelectGames = onSelectGames
    }

    package var body: some View {
        CardGroup(queue.queued.isEmpty ? loc.t("queue.title") : loc.t("queue.title") + " · " + String(format: loc.t("queue.count"), queue.queued.count),
                  trailing: queue.paused ? loc.t("queue.paused") : "") {
            if queue.awaitingResume {
                VStack(alignment: .leading, spacing: 6) {
                    Text(loc.t("queue.resumeTitle")).font(.manrope(14, .medium))
                    Text(loc.t("queue.resumeNote")).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(loc.t("queue.resume")) { queue.resume() }.buttonStyle(LauncherSecondaryButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 13)
                if !queue.entries.isEmpty { CardDivider() }
            }
            ForEach(Array(queue.entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { CardDivider() }
                row(entry)
            }
            if !queue.entries.isEmpty { CardDivider() }
            HStack(spacing: 12) {
                Button(loc.t("queue.cancel")) {
                    if queue.queued.isEmpty { queue.cancelQueued() } else { confirmingCancel = true }
                }
                .buttonStyle(LauncherSecondaryButtonStyle()).disabled(queue.queued.isEmpty)
                Spacer(minLength: 8)
                if queue.paused {
                    Button { queue.resume() } label: {
                        Text(loc.t("queue.resume")).font(.manrope(14, .semibold)).padding(.horizontal, 20).padding(.vertical, 10)
                    }
                    .buttonStyle(LauncherActionButtonStyle())
                }
                Button(loc.t("queue.select"), action: onSelectGames).buttonStyle(LauncherSecondaryButtonStyle())
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
        }
        .confirmationDialog(String(format: loc.t("queue.cancelConfirm"), queue.queued.count), isPresented: $confirmingCancel) {
            Button(loc.t("queue.cancel"), role: .destructive) { queue.cancelQueued() }
            Button(loc.t("queue.keep"), role: .cancel) {}
        }
    }

    private func row(_ entry: QueueEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.manrope(14, .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let reason = entry.reason {
                        Text(reason).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text(loc.t("queue.status." + entry.status.rawValue)).font(.manrope(12.5, .semibold)).foregroundStyle(color(entry.status))
            }
            Text(entry.inputSummary(loc.t)).font(.manrope(12.5)).foregroundStyle(.secondary)
            if entry.status == .queued {
                HStack(spacing: 8) {
                    Button(loc.t("queue.moveUp")) { queue.moveUp(entry.id) }.disabled(!queue.canMoveUp(entry.id))
                        .accessibilityLabel(String(format: loc.t("queue.moveUpNamed"), entry.name))
                    Button(loc.t("queue.moveDown")) { queue.moveDown(entry.id) }.disabled(!queue.canMoveDown(entry.id))
                        .accessibilityLabel(String(format: loc.t("queue.moveDownNamed"), entry.name))
                    Button(loc.t("queue.remove")) { queue.remove(entry.id) }
                        .accessibilityLabel(String(format: loc.t("queue.removeNamed"), entry.name))
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 13)
        .accessibilityElement(children: .contain)
    }

    private func color(_ status: QueueEntry.Status) -> Color {
        switch status {
        case .done: return LauncherPalette.ready
        case .running: return LauncherPalette.building
        case .failed: return .red
        case .queued, .skipped: return .secondary
        }
    }
}
