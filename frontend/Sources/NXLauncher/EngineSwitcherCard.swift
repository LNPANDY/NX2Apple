import AppKit
import SwiftUI
import NXCore
import NXModel

private struct EngineDropdownInitiallyOpenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Opens the Build engine dropdown on appear for deterministic offscreen Visual QA captures.
    package var engineDropdownInitiallyOpen: Bool {
        get { self[EngineDropdownInitiallyOpenKey.self] }
        set { self[EngineDropdownInitiallyOpenKey.self] = newValue }
    }
}

/// Top card on the Builds page: a compact single-row Build engine selector whose dropdown embeds
/// on-demand download, progress, cancellation, retry, and one-click switching across available engines.
package struct EngineSwitcherCard: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.launcherDropdownHost) private var dropdownHost
    @Environment(\.engineDropdownInitiallyOpen) private var envInitiallyOpen
    private let initiallyOpen: Bool
    private let revealSaveTarget: (MacNativeGamesSaveEngine.SaveTarget) -> Void
    @State private var dropdownID = UUID()
    @State private var fallbackPopoverOpen = false
    @State private var didApplyInitialOpen = false

    package static let panelWidth: CGFloat = 492
    package static let panelMaxHeight: CGFloat = 440

    package init(
        build: BuildStore,
        initiallyOpen: Bool = false,
        revealSaveTarget: @escaping (MacNativeGamesSaveEngine.SaveTarget) -> Void = MacNativeGamesSaveFinder.reveal
    ) {
        self.build = build
        self.initiallyOpen = initiallyOpen
        self.revealSaveTarget = revealSaveTarget
    }

    private var isOpen: Bool {
        if let dropdownHost {
            return dropdownHost.custom?.id == dropdownID
        }
        return fallbackPopoverOpen
    }

    private var backgroundBusyEngine: (kind: EngineUpstreamKind, state: UpstreamInstallState)? {
        for kind in build.availableUpstreams {
            let state = build.upstreamState(kind)
            if state.isBusy {
                return (kind, state)
            }
        }
        return nil
    }

    private var backgroundFailedEngine: (kind: EngineUpstreamKind, reason: UpstreamInstallState.FailureReason)? {
        for kind in build.availableUpstreams {
            if case .failed(let reason) = build.upstreamState(kind) {
                return (kind, reason)
            }
        }
        return nil
    }

    package var body: some View {
        let active = build.buildUpstream
        let badgeText = build.upstreamVersionBadge(active)
        let activeHasUpdate = build.upstreamHasUpdate(active)
        let activeTooltip = build.upstreamUpdateTooltip(active)
        let busy = backgroundBusyEngine
        let failed = busy == nil ? backgroundFailedEngine : nil
        return CardGroup(loc.t("engine.title")) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Circle()
                        .fill((busy != nil || failed != nil) ? LauncherPalette.building : LauncherPalette.ready)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(loc.t("engine.switcherTitle"))
                                .font(DS.Font.bodyStrong)
                                .foregroundStyle(LauncherPalette.text)
                                .lineLimit(1)
                            UpstreamVersionPill(
                                text: badgeText,
                                highlighted: activeHasUpdate,
                                fontSize: 11,
                                hPad: 7,
                                vPad: 2,
                                tooltip: activeTooltip
                            )
                        }
                        Text(loc.t("engine.switcherNote"))
                            .font(DS.Font.callout)
                            .foregroundStyle(LauncherPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if active == .nxkit {
                            // nxkit (Beta) is chosen: feedback goes to v0lumehi/nxkit at any time, not only after a build (#1460, #1498 review)
                            Button(loc.t("nxkit.feedback.send")) { NSWorkspace.shared.open(build.nxkitSendFeedbackURL) }
                                .buttonStyle(DSTextButtonStyle())
                                .help(loc.t("nxkit.feedback.sendHelp"))
                                .accessibilityIdentifier("engine.nxkit.feedback")
                                .padTarget("set.build.nxkitFeedback", scope: "main", enabled: !build.running) {
                                    NSWorkspace.shared.open(build.nxkitSendFeedbackURL)
                                }
                        }
                        if let busy {
                            Text(busyStatusText(busy))
                                .font(.manrope(12))
                                .monospacedDigit()
                                .foregroundStyle(LauncherPalette.building)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let failed {
                            HStack(spacing: 8) {
                                Text(failedStatusText(failed))
                                    .font(.manrope(12))
                                    .foregroundStyle(LauncherPalette.building)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button(loc.t("upstream.retry")) {
                                    build.downloadUpstream(failed.kind)
                                }
                                .buttonStyle(.plain)
                                .font(.manrope(11.5, .semibold))
                                .foregroundStyle(LauncherPalette.text)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(LauncherPalette.secondaryFill, in: Capsule())
                                .overlay(DSPill().strokeBorder(LauncherPalette.secondaryBorder))
                                .fixedSize()
                                .disabled(build.running)
                            }
                            .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 12)
                    triggerButton(active: active)
                        .launcherRowControls()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .frame(minHeight: 56)

                if active == .macNativeGames {
                    CardDivider()
                    mngSaveLocationBar()
                }
                if let recommended = build.recommendedTunedEngine {
                    CardDivider()
                    tunedRecommendBar(recommended)
                }
            }
        }
        .onAppear {
            build.refreshUpstreamLocalVersions()
            guard !didApplyInitialOpen, (initiallyOpen || envInitiallyOpen) else { return }
            didApplyInitialOpen = true
            DispatchQueue.main.async {
                openDropdown(triggerCheck: false)
            }
        }
        .onChange(of: build.running) { isRunning in
            if isRunning && isOpen {
                closeDropdown()
            }
        }
    }

    private func busyStatusText(
        _ busy: (kind: EngineUpstreamKind, state: UpstreamInstallState)
    ) -> String {
        switch busy.state {
        case .downloading(_, let progressText):
            let progress = progressText.isEmpty
                ? loc.t("upstream.downloading")
                : String(format: loc.t("upstream.downloadingProgress"), progressText)
            return "\(busy.kind.displayName) · \(progress)"
        case .extracting:
            return "\(busy.kind.displayName) · \(loc.t("upstream.extracting"))"
        default:
            return ""
        }
    }

    private func failedStatusText(
        _ failed: (kind: EngineUpstreamKind, reason: UpstreamInstallState.FailureReason)
    ) -> String {
        let key = failed.reason == .download ? "upstream.downloadFailed" : "upstream.extractFailed"
        return "\(failed.kind.displayName) · \(loc.t(key))"
    }

    @ViewBuilder
    private func triggerButton(active: EngineUpstreamKind) -> some View {
        let activeName = active == .nxkit ? loc.t("nxkit.name") : active.displayName
        if dropdownHost != nil {
            Button {
                if isOpen {
                    closeDropdown()
                } else {
                    openDropdown()
                }
            } label: {
                triggerFace(title: activeName, open: isOpen)
            }
            .buttonStyle(.plain)
            .disabled(build.running)
            .opacity(build.running ? 0.55 : 1)
            .anchorPreference(key: LauncherDropdownAnchorKey.self, value: .bounds) { [dropdownID: $0] }
            .accessibilityLabel(loc.t("engine.title"))
            .accessibilityValue(activeName)
            .padTarget("set.build.engine", scope: "main", enabled: !build.running) { isOpen ? closeDropdown() : openDropdown() }
        } else {
            Button {
                let willOpen = !fallbackPopoverOpen
                fallbackPopoverOpen.toggle()
                if willOpen {
                    _ = build.checkUpstreamUpdates()
                }
            } label: {
                triggerFace(title: activeName, open: fallbackPopoverOpen)
            }
            .buttonStyle(.plain)
            .disabled(build.running)
            .opacity(build.running ? 0.55 : 1)
            .popover(isPresented: $fallbackPopoverOpen, arrowEdge: .bottom) {
                EngineDropdownPanel(build: build, maxHeight: Self.panelMaxHeight) {
                    fallbackPopoverOpen = false
                }
                .frame(width: Self.panelWidth)
                .launcherAppearance()
            }
            .accessibilityLabel(loc.t("engine.title"))
            .accessibilityValue(activeName)
            .padTarget("set.build.engine", scope: "main", enabled: !build.running) { isOpen ? closeDropdown() : openDropdown() }
        }
    }

    private func triggerFace(title: String, open: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        return HStack(spacing: 8) {
            Text(title)
                .font(DS.Font.bodyStrong)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.leading, 14)
            Image(systemName: LauncherDropdownKind.popUp.indicator)   // a pop-up: it shows the engine in use (Apple HIG)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DS.Color.symbolDefault)
                .accessibilityHidden(true)
                .padding(.trailing, 14)
        }
        .padding(.horizontal, 15)
        .frame(width: LauncherControl.width, height: LauncherControl.height)
        .background(open ? LauncherPalette.secondaryPressed : LauncherPalette.secondaryFill, in: shape)
        .overlay(shape.strokeBorder(open ? LauncherPalette.dropdownOpenBorder : LauncherPalette.secondaryBorder))
        .foregroundStyle(LauncherPalette.text)
        .contentShape(shape)
        .launcherMeasured(label: Text(title).font(DS.Font.bodyStrong), room: LauncherControl.choiceWidth)
    }

    private func openDropdown(triggerCheck: Bool = true) {
        guard !build.running else { return }
        if triggerCheck {
            _ = build.checkUpstreamUpdates()
        }
        if let dropdownHost {
            let label = loc.t("engine.title")
            let store = build
            let localizer = loc
            let focus = pad
            dropdownHost.custom = LauncherCustomDropdown(
                id: dropdownID,
                width: Self.panelWidth,
                maxHeight: Self.panelMaxHeight,
                label: label
            ) { close in
                AnyView(
                    EngineDropdownPanel(build: store, maxHeight: Self.panelMaxHeight, close: close)
                        .environmentObject(localizer).environmentObject(focus)
                )
            }
        } else {
            fallbackPopoverOpen = true
        }
    }

    private func closeDropdown() {
        if let dropdownHost {
            if dropdownHost.custom?.id == dropdownID {
                dropdownHost.close()
            }
        } else {
            fallbackPopoverOpen = false
        }
    }

    private func tunedRecommendBar(_ kind: EngineUpstreamKind) -> some View {
        let state = build.upstreamState(kind)
        let installed = build.isUpstreamInstalled(kind)
        let noteText: String = {
            if kind == .macNativeGames {
                return loc.t("upstream.mngRecommendNote")
            }
            return String(format: loc.t("engine.guide.recommendBar"), kind.displayName, loc.t(kind.highlightsKey))
        }()
        let buttonTitle: String = {
            if kind == .macNativeGames {
                return loc.t(installed ? "upstream.mngSwitchBtn" : "upstream.mngDownloadSwitchBtn")
            }
            return String(format: loc.t(installed ? "engine.guide.switchTo" : "engine.guide.downloadSwitchTo"), kind.displayName)
        }()
        return HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LauncherPalette.accent)
            Text(noteText)
                .font(DS.Font.callout)
                .foregroundStyle(LauncherPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if state.isBusy {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(loc.t(state == .extracting ? "upstream.extracting" : "upstream.downloading"))
                        .font(.manrope(12, .semibold))
                        .foregroundStyle(LauncherPalette.secondaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(LauncherPalette.secondaryFill, in: Capsule())
            } else {
                Button {
                    build.downloadAndSwitchToUpstream(kind)
                } label: {
                    Text(buttonTitle)
                        .font(.manrope(12, .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                }
                .buttonStyle(LauncherActionButtonStyle(.capsule))
                .fixedSize()
                .disabled(build.running)
                .padTarget("set.build.mngRecommend", scope: "main", enabled: !build.running) {
                    build.downloadAndSwitchToUpstream(kind)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(LauncherPalette.accent.opacity(0.05))
    }

    private func mngSaveLocationBar() -> some View {
        let shared = build.isMacNativeGamesSharedSaveSupported
        let target = build.mngSaveDisplayTarget()
        let noteKey = shared ? "mng.saves.sharedNote" : "mng.saves.externalNote"
        return HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LauncherPalette.secondaryText)
            Text(loc.t(noteKey))
                .font(DS.Font.callout)
                .foregroundStyle(LauncherPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(loc.t("savesloc.show")) {
                revealSaveTarget(target)
            }
            .buttonStyle(LauncherSecondaryButtonStyle())
            .fixedSize()
            .padTarget("set.build.mngShowSaves", scope: "main") {
                revealSaveTarget(target)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }
}

/// Finder reveal helper shared by all MacNativeGames save notices: highlights `<uid>` when present, else opens `profile`.
package enum MacNativeGamesSaveFinder {
    package static func reveal(_ target: MacNativeGamesSaveEngine.SaveTarget) {
        if target.revealURL == target.displaySaveURL {
            NSWorkspace.shared.activateFileViewerSelecting([target.revealURL])
        } else {
            NSWorkspace.shared.open(target.revealURL)
        }
    }
}
