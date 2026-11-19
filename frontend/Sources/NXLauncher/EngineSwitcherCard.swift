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
    @State private var dropdownID = UUID()
    @State private var fallbackPopoverOpen = false
    @State private var didApplyInitialOpen = false

    package static let panelWidth: CGFloat = 376
    package static let panelMaxHeight: CGFloat = 260

    package init(build: BuildStore, initiallyOpen: Bool = false) {
        self.build = build
        self.initiallyOpen = initiallyOpen
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

    package var body: some View {
        let active = build.buildUpstream
        let badgeKey = active.isBuiltIn ? "upstream.builtinBadge" : "upstream.installedBadge"
        let busy = backgroundBusyEngine
        return CardGroup(loc.t("engine.title")) {
            HStack(spacing: 12) {
                Circle()
                    .fill(busy != nil ? LauncherPalette.building : LauncherPalette.ready)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(active.displayName)
                            .font(DS.Font.bodyStrong)
                            .foregroundStyle(LauncherPalette.text)
                        Text(loc.t(badgeKey))
                            .font(.manrope(11, .semibold))
                            .foregroundStyle(LauncherPalette.secondaryText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(LauncherPalette.secondaryFill, in: Capsule())
                    }
                    Text(collapsedSubtitle(active: active, busy: busy))
                        .font(DS.Font.callout)
                        .foregroundStyle(LauncherPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                triggerButton(active: active)
                    .launcherRowControls()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .frame(minHeight: 56)
        }
        .onAppear {
            guard !didApplyInitialOpen, (initiallyOpen || envInitiallyOpen) else { return }
            didApplyInitialOpen = true
            DispatchQueue.main.async {
                openDropdown()
            }
        }
        .onChange(of: build.running) { isRunning in
            if isRunning && isOpen {
                closeDropdown()
            }
        }
    }

    private func collapsedSubtitle(
        active: EngineUpstreamKind,
        busy: (kind: EngineUpstreamKind, state: UpstreamInstallState)?
    ) -> String {
        guard let busy else {
            return loc.t(active.cardNoteKey)
        }
        switch busy.state {
        case .downloading(_, let progressText):
            let progress = progressText.isEmpty
                ? loc.t("upstream.downloading")
                : String(format: loc.t("upstream.downloadingProgress"), progressText)
            return "\(busy.kind.displayName) · \(progress)"
        case .extracting:
            return "\(busy.kind.displayName) · \(loc.t("upstream.extracting"))"
        default:
            return loc.t(active.cardNoteKey)
        }
    }

    @ViewBuilder
    private func triggerButton(active: EngineUpstreamKind) -> some View {
        if dropdownHost != nil {
            Button {
                if isOpen {
                    closeDropdown()
                } else {
                    openDropdown()
                }
            } label: {
                triggerFace(title: active.displayName, open: isOpen)
            }
            .buttonStyle(.plain)
            .disabled(build.running)
            .opacity(build.running ? 0.55 : 1)
            .anchorPreference(key: LauncherDropdownAnchorKey.self, value: .bounds) { [dropdownID: $0] }
            .accessibilityLabel(loc.t("engine.title"))
            .accessibilityValue(active.displayName)
            .padTarget("set.build.engine", scope: "main", enabled: !build.running) { isOpen ? closeDropdown() : openDropdown() }
        } else {
            Button {
                fallbackPopoverOpen.toggle()
            } label: {
                triggerFace(title: active.displayName, open: fallbackPopoverOpen)
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
            .accessibilityValue(active.displayName)
            .padTarget("set.build.engine", scope: "main", enabled: !build.running) { isOpen ? closeDropdown() : openDropdown() }
        }
    }

    private func triggerFace(title: String, open: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        return HStack(spacing: 0) {
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
        .padding(.vertical, 9)
        .frame(width: LauncherControl.width, height: LauncherControl.height)
        .background(open ? LauncherPalette.secondaryPressed : LauncherPalette.secondaryFill, in: shape)
        .overlay(shape.strokeBorder(open ? LauncherPalette.dropdownOpenBorder : LauncherPalette.secondaryBorder))
        .foregroundStyle(LauncherPalette.text)
        .contentShape(shape)
        .launcherMeasured(label: Text(title).font(DS.Font.bodyStrong), room: LauncherControl.choiceWidth)
    }

    private func openDropdown() {
        guard !build.running else { return }
        if let dropdownHost {
            let label = loc.t("engine.title")
            let store = build
            let localizer = loc
            let focus = pad
            withAnimation(.easeOut(duration: 0.12)) {
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
}

/// Data-driven list of available engines rendered inside the Build engine dropdown overlay.
package struct EngineDropdownPanel: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    let maxHeight: CGFloat
    let close: () -> Void
    @State private var hoveredKind: EngineUpstreamKind?

    package init(build: BuildStore, maxHeight: CGFloat = EngineSwitcherCard.panelMaxHeight, close: @escaping () -> Void) {
        self.build = build
        self.maxHeight = maxHeight
        self.close = close
    }

    package var body: some View {
        ViewThatFits(in: .vertical) {
            rowsList
            ScrollView(.vertical) {
                rowsList
            }
            .frame(maxHeight: maxHeight)
        }
        .padScope("engineDropdown", pad)
        .background(PadKeyboardInput(focus: pad, scope: "engineDropdown", back: close))
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                .padTarget("engineDropdown.cancel", scope: "engineDropdown", activate: close)
        }
        .onAppear { pad.scope = "engineDropdown"; pad.focused = actionID(build.buildUpstream) }
        .onDisappear { if pad.scope == "engineDropdown" { pad.scope = "main"; pad.focused = "set.build.engine" } }
        .onChange(of: build.upstreamDownloads) { _ in
            if let id = pad.focused, let kind = build.availableUpstreams.first(where: { id.hasSuffix("." + $0.rawValue) }) {
                pad.focused = actionID(kind)
            }
        }
        .onChange(of: build.upstreamAutoSwitchRevision) { _ in
            close()
        }
    }

    private func actionID(_ kind: EngineUpstreamKind) -> String {
        switch build.upstreamState(kind) {
        case .builtIn, .installed: return "set.build.engine." + kind.rawValue
        case .downloading, .extracting: return "set.build.engine.cancel." + kind.rawValue
        case .notInstalled, .failed: return "set.build.engine.download." + kind.rawValue
        }
    }

    private func move(_ kind: EngineUpstreamKind, by step: Int) -> Bool {
        let kinds = build.availableUpstreams
        guard let index = kinds.firstIndex(of: kind), !kinds.isEmpty else { return false }
        pad.focused = actionID(kinds[(index + step + kinds.count) % kinds.count])
        return true
    }

    private func shortcut(_ kind: EngineUpstreamKind) -> KeyboardShortcut? {
        pad.focused == actionID(kind) ? KeyboardShortcut(.return, modifiers: []) : nil
    }

    private var rowsList: some View {
        let kinds = build.availableUpstreams
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(kinds, id: \.self) { kind in
                engineRow(kind)
            }
        }
        .padding(8)
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
        let hovered = hoveredKind == kind
        let badgeKey = kind.isBuiltIn ? "upstream.builtinBadge" : "upstream.installedBadge"
        return Button {
            build.selectUpstream(kind)
            close()
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(selected ? LauncherPalette.ready : LauncherPalette.unbuilt.opacity(0.55))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(kind.displayName)
                            .font(.manrope(13.5, selected ? .bold : .semibold))
                            .foregroundStyle(LauncherPalette.text)
                            .lineLimit(1)
                        Text(loc.t(badgeKey))
                            .font(.manrope(10.5, .semibold))
                            .foregroundStyle(selected ? DS.Color.textPrimary : DS.Color.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(LauncherPalette.secondaryFill, in: Capsule())
                    }
                    Text(loc.t(kind.cardNoteKey))
                        .font(.manrope(11.5))
                        .foregroundStyle(LauncherPalette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(LauncherPalette.ready)
                        .padding(.trailing, 4)
                } else {
                    Text(loc.t("upstream.switchBtn"))
                        .font(.manrope(12, .semibold))
                        .foregroundStyle(LauncherPalette.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(LauncherPalette.secondaryFill, in: Capsule())
                        .overlay(DSPill().strokeBorder(LauncherPalette.secondaryBorder))
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
        }
        .buttonStyle(.plain)
        .disabled(build.running)
        .onHover { inside in
            if inside { hoveredKind = kind } else if hoveredKind == kind { hoveredKind = nil }
        }
        .help(loc.t(selected ? "upstream.activeBadge" : "upstream.readySwitch"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .keyboardShortcut(shortcut(kind))
        .padTarget(actionID(kind), scope: "engineDropdown", radius: 9, enabled: !build.running, activate: { build.selectUpstream(kind); close() }, vertical: { move(kind, by: $0) })
    }

    private func notInstalledRow(kind: EngineUpstreamKind) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(LauncherPalette.unbuilt.opacity(0.45))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName)
                    .font(.manrope(13.5, .semibold))
                    .foregroundStyle(LauncherPalette.text)
                    .lineLimit(1)
                Text(loc.t(kind.cardNoteKey))
                    .font(.manrope(11.5))
                    .foregroundStyle(LauncherPalette.secondaryText)
                    .lineLimit(1)
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
            .disabled(build.running)
            .keyboardShortcut(shortcut(kind))
            .padTarget(actionID(kind), scope: "engineDropdown", enabled: !build.running, activate: { build.downloadUpstream(kind) }, vertical: { move(kind, by: $0) })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(LauncherPalette.ink(0.025), in: RoundedRectangle(cornerRadius: 9))
    }

    private func busyRow(kind: EngineUpstreamKind, fraction: Double?, statusText: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(LauncherPalette.building)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(kind.displayName)
                        .font(.manrope(13.5, .semibold))
                        .foregroundStyle(LauncherPalette.text)
                        .lineLimit(1)
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
            .keyboardShortcut(shortcut(kind))
            .padTarget(actionID(kind), scope: "engineDropdown", activate: { build.cancelUpstreamDownload(kind) }, vertical: { move(kind, by: $0) })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LauncherPalette.ink(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private func failedRow(kind: EngineUpstreamKind, reason: UpstreamInstallState.FailureReason) -> some View {
        let messageKey = reason == .download ? "upstream.downloadFailed" : "upstream.extractFailed"
        return HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(LauncherPalette.building)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName)
                    .font(.manrope(13.5, .semibold))
                    .foregroundStyle(LauncherPalette.text)
                    .lineLimit(1)
                Text(loc.t(messageKey))
                    .font(.manrope(11.5))
                    .foregroundStyle(LauncherPalette.building)
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
            .disabled(build.running)
            .keyboardShortcut(shortcut(kind))
            .padTarget(actionID(kind), scope: "engineDropdown", enabled: !build.running, activate: { build.downloadUpstream(kind) }, vertical: { move(kind, by: $0) })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(LauncherPalette.ink(0.035), in: RoundedRectangle(cornerRadius: 9))
    }
}
