import AppKit
import SwiftUI
import NXCore
import NXModel

/// Data-driven list of available engines rendered inside the Build engine dropdown overlay.
package struct EngineDropdownPanel: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.launcherDropdownMaxHeight) private var envMaxHeight
    let maxHeight: CGFloat
    let close: () -> Void
    @State private var hoveredKind: EngineUpstreamKind?

    package init(build: BuildStore, maxHeight: CGFloat = EngineSwitcherCard.panelMaxHeight, close: @escaping () -> Void) {
        self.build = build
        self.maxHeight = maxHeight
        self.close = close
    }

    package var body: some View {
        let limit = max(80, min(maxHeight, envMaxHeight ?? maxHeight))
        ViewThatFits(in: .vertical) {
            rowsList
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) {
                rowsList
            }
            .frame(height: limit)
        }
        .padScope("engineDropdown", pad)
        .background(PadKeyboardInput(focus: pad, scope: "engineDropdown", back: close).frame(width: 0, height: 0))
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                .padTarget("engineDropdown.cancel", scope: "engineDropdown", activate: close)
        }
        .onAppear { pad.scope = "engineDropdown"; pad.focused = actionID(build.buildUpstream) }
        .onDisappear { if pad.scope == "engineDropdown" { pad.scope = "main"; pad.focused = "set.build.engine" } }
        .onChange(of: build.upstreamDownloads) { _ in
            if let id = pad.focused, let kind = panelKinds.first(where: { id.hasSuffix("." + $0.rawValue) }) {
                pad.focused = actionID(kind)
            }
        }
        .onChange(of: build.upstreamAutoSwitchRevision) { _ in
            close()
        }
    }

    /// Only nxkit (Beta) carries the Experimental badge, right next to its name (#1498 review). The other engines carry none.
    package static func showsExperimentalBadge(_ kind: EngineUpstreamKind) -> Bool { kind == .nxkit }

    /// An installed engine that is not picked shows "Switch". The nxkit row does not: clicking the row still picks it.
    package static func showsSwitchLabel(_ kind: EngineUpstreamKind) -> Bool { kind != .nxkit }

    private func name(_ kind: EngineUpstreamKind) -> String {
        kind == .nxkit ? loc.t("nxkit.name") : kind.displayName
    }

    private func isBlockedByGame(_ kind: EngineUpstreamKind) -> Bool {
        build.isUpstreamBlockedByCurrentGame(kind)
    }

    private func blockedReason(_ kind: EngineUpstreamKind) -> String {
        loc.t(build.blockedReasonKey(for: kind))
    }

    private func platformBadgeText(_ kind: EngineUpstreamKind) -> String {
        kind.supportsIOS ? loc.t("engine.platform.macIOS") : loc.t("engine.platform.macOnly")
    }

    private func engineGuideSummary(_ kind: EngineUpstreamKind) -> String {
        let scope = loc.t(kind.scopeSummaryKey)
        let highlights = loc.t(kind.highlightsKey)
        return highlights.isEmpty ? scope : "\(scope) \u{00b7} \(highlights)"
    }

    private func actionID(_ kind: EngineUpstreamKind) -> String {
        switch build.upstreamState(kind) {
        case .builtIn, .installed: return "set.build.engine." + kind.rawValue
        case .downloading, .extracting: return "set.build.engine.cancel." + kind.rawValue
        case .notInstalled, .failed: return "set.build.engine.download." + kind.rawValue
        }
    }

    /// The engines this panel lists: general engines followed by game-tuned engines.
    private var panelKinds: [EngineUpstreamKind] {
        let visible = build.availableUpstreams.filter { kind in
            kind != .nxkit || build.nxkitSelectable || build.buildUpstream == .nxkit
        }
        return visible.filter { $0.group == .general } + visible.filter { $0.group == .gameTuned }
    }

    private var generalKinds: [EngineUpstreamKind] {
        panelKinds.filter { $0.group == .general }
    }

    private var tunedKinds: [EngineUpstreamKind] {
        panelKinds.filter { $0.group == .gameTuned }
    }

    private func move(_ kind: EngineUpstreamKind, by step: Int) -> Bool {
        let kinds = panelKinds.filter { !(isBlockedByGame($0) && !build.upstreamState($0).isBusy) }
        guard let index = kinds.firstIndex(of: kind), !kinds.isEmpty else { return false }
        pad.focused = actionID(kinds[(index + step + kinds.count) % kinds.count])
        return true
    }

    private func shortcut(_ kind: EngineUpstreamKind) -> KeyboardShortcut? {
        pad.focused == actionID(kind) ? KeyboardShortcut(.return, modifiers: []) : nil
    }

    private var rowsList: some View {
        let general = generalKinds
        let tuned = tunedKinds
        return VStack(alignment: .leading, spacing: 6) {
            if let recommended = build.recommendedTunedEngine {
                recommendedBanner(recommended)
            }
            if !general.isEmpty {
                sectionHeader(loc.t("engine.group.general"))
                ForEach(general, id: \.self) { kind in
                    engineRow(kind)
                }
            }
            if !tuned.isEmpty {
                if !general.isEmpty {
                    CardDivider().padding(.vertical, 2)
                }
                sectionHeader(loc.t("engine.group.tuned"))
                ForEach(tuned, id: \.self) { kind in
                    engineRow(kind)
                }
            }
        }
        .padding(8)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.manrope(11, .bold))
            .foregroundStyle(LauncherPalette.secondaryText)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 1)
    }

    private func recommendedBanner(_ kind: EngineUpstreamKind) -> some View {
        let installed = build.isUpstreamInstalled(kind)
        let state = build.upstreamState(kind)
        return HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LauncherPalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: loc.t("engine.guide.recommendedTitle"), name(kind)))
                    .font(.manrope(12, .bold))
                    .foregroundStyle(LauncherPalette.text)
                    .lineLimit(1)
                Text(loc.t(kind.highlightsKey))
                    .font(.manrope(11))
                    .foregroundStyle(LauncherPalette.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if state.isBusy {
                ProgressView().controlSize(.mini)
            } else {
                Button {
                    build.downloadAndSwitchToUpstream(kind)
                    if installed { close() }
                } label: {
                    Text(loc.t(installed ? "upstream.switchBtn" : "upstream.download"))
                        .font(.manrope(11.5, .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(LauncherActionButtonStyle(.capsule))
                .fixedSize()
                .disabled(build.running)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(LauncherPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(LauncherPalette.accent.opacity(0.24)))
    }

    @ViewBuilder
    private func engineRow(_ kind: EngineUpstreamKind) -> some View {
        let state = build.upstreamState(kind)
        let selected = build.buildUpstream == kind
        switch state {
        case .builtIn, .installed:
            installedRow(kind: kind, selected: selected)
        case .notInstalled:
            notInstalledRow(kind: kind)
        case .downloading(let fraction, let progressText):
            busyRow(kind: kind, fraction: fraction, statusText: progressLine(progressText))
        case .extracting:
            busyRow(kind: kind, fraction: nil, statusText: loc.t("upstream.extracting"))
        case .failed(let reason):
            failedRow(kind: kind, reason: reason)
        }
    }

    private func progressLine(_ progressText: String) -> String {
        progressText.isEmpty
            ? loc.t("upstream.downloading")
            : String(format: loc.t("upstream.downloadingProgress"), progressText)
    }

    private func installedRow(kind: EngineUpstreamKind, selected: Bool) -> some View {
        let blocked = isBlockedByGame(kind)
        let hovered = hoveredKind == kind && !blocked
        let badgeText = build.upstreamVersionBadge(kind)
        let hasUpdate = build.upstreamHasUpdate(kind)
        let tooltip = build.upstreamUpdateTooltip(kind)
        let canSelect = !build.running && !blocked
        let reason = blockedReason(kind)
        let subtitle = blocked ? reason : engineGuideSummary(kind)
        let helpText = blocked ? reason : (tooltip ?? loc.t(selected ? "upstream.activeBadge" : "upstream.readySwitch"))
        let displayName = name(kind)
        return HStack(spacing: 8) {
            Button {
                build.selectUpstream(kind)
                close()
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(selected ? LauncherPalette.ready : LauncherPalette.unbuilt.opacity(0.55))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(displayName)
                                .font(.manrope(13.5, selected ? .bold : .semibold))
                                .foregroundStyle(LauncherPalette.text)
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                            EnginePlatformBadge(text: platformBadgeText(kind))
                            UpstreamVersionPill(
                                text: badgeText,
                                highlighted: hasUpdate && !blocked,
                                selectedTint: selected,
                                fontSize: 10.5,
                                hPad: 6,
                                vPad: 1.5,
                                tooltip: tooltip
                            )
                            if Self.showsExperimentalBadge(kind) {
                                EngineExperimentalBadge(text: loc.t("engine.experimental"), compact: true)
                            }
                        }
                        Text(subtitle)
                            .font(.manrope(11.5))
                            .foregroundStyle(LauncherPalette.secondaryText)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if !hasUpdate {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(LauncherPalette.ready)
                                .padding(.trailing, 4)
                        } else if Self.showsSwitchLabel(kind) {
                            Text(loc.t("upstream.switchBtn"))
                                .font(.manrope(12, .semibold))
                                .foregroundStyle(LauncherPalette.secondaryText)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(LauncherPalette.secondaryFill, in: Capsule())
                                .overlay(DSPill().strokeBorder(LauncherPalette.secondaryBorder))
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSelect)
            .opacity(blocked ? 0.52 : 1)
            .help(helpText)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .keyboardShortcut(shortcut(kind))
            .padTarget(actionID(kind), scope: "engineDropdown", radius: 9, enabled: canSelect, activate: { build.selectUpstream(kind); close() }, vertical: { move(kind, by: $0) })

            if kind == .nxkit {
                Button {
                    NSWorkspace.shared.open(build.nxkitSendFeedbackURL)
                } label: {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(LauncherIconButtonStyle(size: 24))
                .help(loc.t("nxkit.feedback.sendHelp"))
                .accessibilityLabel(loc.t("nxkit.feedback.send"))
                .accessibilityIdentifier("engine.nxkit.feedback")
            }

            if hasUpdate {
                Button {
                    build.downloadUpstream(kind)
                } label: {
                    Text(loc.t("upstream.update"))
                        .font(.manrope(11.5, .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                }
                .buttonStyle(LauncherActionButtonStyle(.capsule))
                .disabled(build.running)
                .help(tooltip ?? loc.t("upstream.update"))

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(LauncherPalette.ready)
                        .padding(.trailing, 2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            hovered ? LauncherPalette.ink(0.08) : (selected ? LauncherPalette.selectedFill : .clear),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? LauncherPalette.selectedBorder.opacity(0.45) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { inside in
            if inside && !blocked { hoveredKind = kind } else if hoveredKind == kind { hoveredKind = nil }
        }
    }

    private func notInstalledRow(kind: EngineUpstreamKind) -> some View {
        let blocked = isBlockedByGame(kind)
        let canAct = !build.running && !blocked
        return HStack(spacing: 10) {
            Circle()
                .fill(LauncherPalette.unbuilt.opacity(0.45))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name(kind))
                        .font(.manrope(13.5, .semibold))
                        .foregroundStyle(LauncherPalette.text)
                        .lineLimit(1)
                    EnginePlatformBadge(text: platformBadgeText(kind))
                    if Self.showsExperimentalBadge(kind) {
                        EngineExperimentalBadge(text: loc.t("engine.experimental"), compact: true)
                    }
                }
                Text(blocked ? blockedReason(kind) : engineGuideSummary(kind))
                    .font(.manrope(11.5))
                    .foregroundStyle(LauncherPalette.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 10)
            Button {
                build.downloadUpstream(kind)
            } label: {
                Text(loc.t("upstream.download"))
                    .font(.manrope(12, .bold))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }
            .buttonStyle(LauncherActionButtonStyle(.capsule))
            .fixedSize()
            .disabled(!canAct)
            .keyboardShortcut(shortcut(kind))
            .padTarget(actionID(kind), scope: "engineDropdown", enabled: canAct, activate: { build.downloadUpstream(kind) }, vertical: { move(kind, by: $0) })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(blocked ? 0.52 : 1)
        .background(LauncherPalette.ink(0.025), in: RoundedRectangle(cornerRadius: 9))
    }

    private func busyRow(kind: EngineUpstreamKind, fraction: Double?, statusText: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(LauncherPalette.building)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(name(kind))
                        .font(.manrope(13.5, .semibold))
                        .foregroundStyle(LauncherPalette.text)
                        .lineLimit(1)
                    if Self.showsExperimentalBadge(kind) {
                        EngineExperimentalBadge(text: loc.t("engine.experimental"), compact: true)
                    }
                    if fraction == nil {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                if let fraction {
                    GeometryReader { geo in
                        let clamped = min(max(fraction, 0), 1)
                        ZStack(alignment: .leading) {
                            Capsule().fill(LauncherPalette.ink(0.12))
                            Capsule()
                                .fill(LauncherPalette.accent)
                                .frame(width: max(6, geo.size.width * clamped))
                        }
                    }
                    .frame(height: 5)
                }
                Text(statusText)
                    .font(.manrope(11.5))
                    .monospacedDigit()
                    .foregroundStyle(LauncherPalette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            Button {
                build.cancelUpstreamDownload(kind)
            } label: {
                Text(loc.t("upstream.cancel"))
                    .font(.manrope(12, .semibold))
                    .foregroundStyle(LauncherPalette.text)
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(LauncherPalette.secondaryFill, in: Capsule())
                    .overlay(DSPill().strokeBorder(LauncherPalette.secondaryBorder))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .keyboardShortcut(shortcut(kind))
            .padTarget(actionID(kind), scope: "engineDropdown", activate: { build.cancelUpstreamDownload(kind) }, vertical: { move(kind, by: $0) })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LauncherPalette.ink(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private func failedRow(kind: EngineUpstreamKind, reason: UpstreamInstallState.FailureReason) -> some View {
        let blocked = isBlockedByGame(kind)
        let canAct = !build.running && !blocked
        let messageKey = reason == .download ? "upstream.downloadFailed" : "upstream.extractFailed"
        return HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(LauncherPalette.building)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name(kind))
                        .font(.manrope(13.5, .semibold))
                        .foregroundStyle(LauncherPalette.text)
                        .lineLimit(1)
                    EnginePlatformBadge(text: platformBadgeText(kind))
                    if Self.showsExperimentalBadge(kind) {
                        EngineExperimentalBadge(text: loc.t("engine.experimental"), compact: true)
                    }
                }
                Text(blocked ? blockedReason(kind) : loc.t(messageKey))
                    .font(.manrope(11.5))
                    .foregroundStyle(blocked ? LauncherPalette.secondaryText : LauncherPalette.building)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            Button {
                build.downloadUpstream(kind)
            } label: {
                Text(loc.t("upstream.retry"))
                    .font(.manrope(12, .semibold))
                    .foregroundStyle(LauncherPalette.text)
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(LauncherPalette.secondaryFill, in: Capsule())
                    .overlay(DSPill().strokeBorder(LauncherPalette.secondaryBorder))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(!canAct)
            .keyboardShortcut(shortcut(kind))
            .padTarget(actionID(kind), scope: "engineDropdown", enabled: canAct, activate: { build.downloadUpstream(kind) }, vertical: { move(kind, by: $0) })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(blocked ? 0.52 : 1)
        .background(LauncherPalette.ink(0.035), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// Compact platform pill showing supported build targets (`Mac` or `Mac · iPhone`).
struct EnginePlatformBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.manrope(10, .semibold))
            .foregroundStyle(LauncherPalette.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(LauncherPalette.secondaryFill, in: Capsule())
            .overlay(DSPill().strokeBorder(LauncherPalette.secondaryBorder))
            .fixedSize()
    }
}

/// Compact amber pill marking nxkit (Beta) as experimental, next to its name.
struct EngineExperimentalBadge: View {
    let text: String
    var compact = false

    var body: some View {
        Text(text)
            .font(.manrope(compact ? 10.5 : 11, .semibold))
            .foregroundStyle(LauncherPalette.building)
            .lineLimit(1)
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, compact ? 1.5 : 2)
            .background(LauncherPalette.building.opacity(0.14), in: Capsule())
            .overlay(DSPill().strokeBorder(LauncherPalette.building.opacity(0.35)))
            .fixedSize()
    }
}

struct UpstreamVersionPill: View {
    let text: String
    let highlighted: Bool
    var selectedTint: Bool = false
    let fontSize: CGFloat
    let hPad: CGFloat
    let vPad: CGFloat
    let tooltip: String?

    var body: some View {
        let fg = highlighted
            ? LauncherPalette.accent
            : (selectedTint ? LauncherPalette.accent : LauncherPalette.secondaryText)
        let bg = highlighted ? LauncherPalette.accent.opacity(0.14) : LauncherPalette.secondaryFill
        let border = highlighted ? LauncherPalette.accent.opacity(0.28) : Color.clear
        let pill = Text(text)
            .font(.manrope(fontSize, .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(fg)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(bg, in: Capsule())
            .overlay(DSPill().strokeBorder(border))
        if let tooltip, !tooltip.isEmpty {
            pill.help(tooltip)
        } else {
            pill
        }
    }
}
