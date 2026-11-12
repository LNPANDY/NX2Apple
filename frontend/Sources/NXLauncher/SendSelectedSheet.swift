import AppKit
import SwiftUI
import NXCore
import NXModel

/// Checklist sheet for sending or copying game data of one or more packed library games (#1080).
package struct SendSelectedSheet: View {
    package enum Mode: String, Identifiable {
        case device
        case drive
        package var id: String { rawValue }
    }

    let mode: Mode
    @ObservedObject var build: BuildStore
    let close: () -> Void
    @EnvironmentObject var loc: Localizer
    @State private var checked: Set<String> = []
    @State private var didSeedSelection = false

    package init(mode: Mode, build: BuildStore, close: @escaping () -> Void) {
        self.mode = mode
        self.build = build
        self.close = close
    }

    private var sources: [TransferSource] { build.sharedAppDataSources() }

    private var selectedSources: [TransferSource] {
        sources.filter { checked.contains($0.titleID.uppercased()) }
    }

    private var allChecked: Bool {
        !sources.isEmpty && selectedSources.count == sources.count
    }

    private var batchDriveState: DriveState? {
        guard mode == .drive, !selectedSources.isEmpty else { return nil }
        return build.driveBatchState(for: selectedSources)
    }

    private var canConfirm: Bool {
        guard !selectedSources.isEmpty else { return false }
        switch mode {
        case .device:
            return build.canSendAllGameData
        case .drive:
            guard !build.running, let state = batchDriveState else { return false }
            return state.problem == nil && state.volume != nil
        }
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(loc.t("shell.selectGamesTitle"))
                        .font(.manrope(26, .heavy))
                        .tracking(-0.5)
                    Text(loc.t(mode == .device ? "shell.selectGamesDeviceNote" : "shell.selectGamesDriveNote"))
                        .font(.manrope(13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if !sources.isEmpty {
                    Button(loc.t(allChecked ? "shell.clearSelection" : "shell.selectAll")) {
                        if allChecked {
                            checked.removeAll()
                        } else {
                            checked = Set(sources.map { $0.titleID.uppercased() })
                        }
                    }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .fixedSize()
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 28)
            .padding(.bottom, 18)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sources, id: \.titleID) { source in
                        let key = source.titleID.uppercased()
                        let isChecked = checked.contains(key)
                        let bytes = build.transferSourceBytes(source)
                        Button { toggle(key) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 17))
                                    .foregroundStyle(isChecked ? LauncherPalette.ready : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.name)
                                        .font(.manrope(14, .medium))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text(source.titleID.uppercased())
                                        .font(.mono(11.5))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 8)
                                if bytes > 0 {
                                    Text(ShellInstall.sizeText(bytes))
                                        .font(.manrope(12.5, .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.horizontal, 30)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isChecked ? .isSelected : [])
                    }
                }
            }

            if mode == .drive, let state = batchDriveState {
                driveBanner(state)
                    .padding(.horizontal, 30)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
            }

            Divider().opacity(0.3)

            HStack(spacing: 12) {
                Spacer()
                Button(loc.t("saves.cancel"), action: close)
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { confirm() } label: {
                    Text(loc.t(mode == .device ? "shell.sendSelectedConfirm" : "shell.copySelectedConfirm"))
                        .font(.manrope(14, .semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(LauncherActionButtonStyle())
                .disabled(!canConfirm)
                .opacity(canConfirm ? 1 : 0.4)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 16)
        }
        .frame(width: 680)
        .frame(maxHeight: min(720, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
        .background(LauncherPalette.background)
        .launcherAppearance()
        .onAppear {
            if !didSeedSelection {
                didSeedSelection = true
                checked = Set(sources.map { $0.titleID.uppercased() })
            }
        }
    }

    @ViewBuilder private func driveBanner(_ state: DriveState) -> some View {
        switch state.problem {
        case .fat32:
            bannerRow(symbol: "exclamationmark.triangle.fill", color: .red, text: loc.t("shell.driveFat32"))
        case .readOnly:
            bannerRow(symbol: "exclamationmark.triangle.fill", color: .red, text: loc.t("shell.driveReadOnly"))
        case .noSpace(let needed, let free):
            bannerRow(
                symbol: "exclamationmark.triangle.fill",
                color: .red,
                text: String(format: loc.t("shell.driveNoSpace"), ShellInstall.sizeText(needed), ShellInstall.sizeText(free))
            )
        case nil:
            if let volume = state.volume {
                let gameDataRow = L10n.string("ios.ui.gameData", loc.lang)
                bannerRow(
                    symbol: "info.circle",
                    color: .secondary,
                    text: String(
                        format: loc.t("shell.driveNote"),
                        ShellInstall.sizeText(state.needed),
                        ShellInstall.sizeText(volume.freeBytes),
                        DriveCopy.fileSystemName(volume.fileSystem),
                        gameDataRow
                    )
                )
            }
        }
    }

    private func bannerRow(symbol: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 13)
            Text(text)
                .font(.manrope(12.5))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func toggle(_ key: String) {
        if checked.contains(key) {
            checked.remove(key)
        } else {
            checked.insert(key)
        }
    }

    private func confirm() {
        switch mode {
        case .device:
            build.sendSelectedGameData(titleIDs: checked)
        case .drive:
            build.copySelectedToDrive(titleIDs: checked)
        }
        close()
    }
}
