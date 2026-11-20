import SwiftUI
import AppKit
import NXCore
import NXModel

/// The engine pop-up (nxnative, nxkit (Beta) and the other engines that can build): the control of Settings > Tools > Build engine (#1458).
package struct UpstreamPicker: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer

    package init(build: BuildStore) { self.build = build }

    package var body: some View {
        LauncherDropdown(
            options: UpstreamBuilderRow.options(build, loc),
            selection: build.buildUpstream.rawValue,
            label: loc.t("engine.title"),
            style: .button,
            disabledValues: UpstreamBuilderRow.disabledValues(build)
        ) { raw in
            if let kind = UpstreamBuilderRow.downloadKind(raw) {
                if !build.running { build.downloadUpstream(kind) }   // the Builds page's download: progress, Cancel and Retry in its folder row
            } else if let kind = EngineUpstreamKind(rawValue: raw) {
                build.selectUpstream(kind)
            }
        }
        .disabled(build.running)
        .padTarget("set.upstream", scope: "main", enabled: !build.running, activate: { cycle(1) }, adjust: cycle)
    }

    private func cycle(_ by: Int) {
        let disabled = UpstreamBuilderRow.disabledValues(build)
        // left and right choose among the engines that are there: a download starts only from the list
        let options = UpstreamBuilderRow.options(build, loc).filter { !disabled.contains($0.value) && UpstreamBuilderRow.downloadKind($0.value) == nil }
        guard !build.running, let index = options.firstIndex(where: { $0.value == build.buildUpstream.rawValue }), !options.isEmpty,
              let kind = EngineUpstreamKind(rawValue: options[(index + by + options.count) % options.count].value) else { return }
        build.selectUpstream(kind)
    }
}

/// The folder rows of the other engines (MacNativeGames, S2Arm), under the build tools' rows. Which engine builds is the
/// Build engine row's pop-up (UpstreamPicker). What that row shows for nxkit (Beta) comes from `engineRow`.
package struct UpstreamBuilderRow: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer

    package init(build: BuildStore) {
        self.build = build
    }

    /// The pop-up's value of "Download" for an engine that is not there: `download.` and the engine's raw value.
    static let downloadPrefix = "download."

    /// The engine a "Download" entry of the pop-up fetches, nil for any other value.
    package static func downloadKind(_ value: String) -> EngineUpstreamKind? {
        guard value.hasPrefix(downloadPrefix) else { return nil }
        return EngineUpstreamKind(rawValue: String(value.dropFirst(downloadPrefix.count)))
    }

    /// The external engines this Mac may use that are not there yet and not being fetched: MacNativeGames, and S2Arm only with
    /// NX2APPLE_ENABLE_S2ARM=1. Each is a "Download" entry in the pop-up. Any title may download MacNativeGames, choosing it stays
    /// for its five titles.
    package static func downloadable(_ build: BuildStore) -> [EngineUpstreamKind] {
        [EngineUpstreamKind.macNativeGames, .s2arm].filter { kind in
            let enabled = kind == .macNativeGames ? MacNativeGamesBuilder.featureEnabled : S2ArmBuilder.featureEnabled
            return enabled && build.availableUpstreams.contains(kind) && !build.isUpstreamInstalled(kind) && build.buildUpstream != kind
                && !build.upstreamState(kind).isBusy
        }
    }

    /// The engines the pop-up offers: nxnative, and each other one that is set up or chosen. nxkit (Beta) only on a Mac that runs it.
    /// Then a "Download" entry for each external engine that is not there (`downloadable`).
    package static func options(_ build: BuildStore, _ loc: Localizer) -> [(value: String, label: String)] {
        var opts: [(value: String, label: String)] = [
            (EngineUpstreamKind.nxnative.rawValue, "nxnative")
        ]
        if MacNativeGamesBuilder.featureEnabled && (build.macNativeGamesInstalled || build.buildUpstream == .macNativeGames) {
            opts.append((EngineUpstreamKind.macNativeGames.rawValue, "MacNativeGames"))
        }
        if S2ArmBuilder.featureEnabled && (build.s2armInstalled || build.buildUpstream == .s2arm) {
            opts.append((EngineUpstreamKind.s2arm.rawValue, "S2Arm"))
        }
        if build.nxkitSelectable || build.buildUpstream == .nxkit && NxkitBuilder.featureEnabled && build.nxkitAvailability == .available {
            opts.append((EngineUpstreamKind.nxkit.rawValue, loc.t("nxkit.name")))
        }
        for kind in downloadable(build) {
            opts.append((downloadPrefix + kind.rawValue, kind.displayName + " \u{00b7} " + loc.t("upstream.download")))
        }
        return opts
    }

    /// The engines the pop-up shows but this game cannot take: MacNativeGames for a title outside the five it maintains (#1473).
    package static func disabledValues(_ build: BuildStore) -> Set<String> {
        build.isMNGBlockedByCurrentGame ? [EngineUpstreamKind.macNativeGames.rawValue] : []
    }

    /// MacNativeGames is in the pop-up and the picked game is not one of its five: the row says why it is dimmed.
    static func mngBlocked(_ build: BuildStore) -> Bool {
        MacNativeGamesBuilder.featureEnabled && (build.macNativeGamesInstalled || build.buildUpstream == .macNativeGames) && build.isMNGBlockedByCurrentGame
    }

    /// The Build engine row has the engine pop-up: more than one engine can build on this Mac.
    package static func offersPicker(_ build: BuildStore, _ loc: Localizer) -> Bool { options(build, loc).count > 1 }

    /// What the Build engine row takes from the build store (#1460). With nxkit (Beta) chosen: its version and update state as the
    /// subtitle, its Beta note or the update's problem as the message, Check for updates and Use previous version in the "…".
    /// With another engine chosen: only why this Mac cannot choose nxkit, and the row keeps the engine store's subtitle and actions.
    package static func engineRow(_ build: BuildStore, _ loc: Localizer) -> BuildEngineRow {
        if build.buildUpstream == .nxkit && build.nxkitSelectable {
            let status = build.nxkitStatusMessage
            let message: DSRowMessage
            switch status.tone {
            case .info: message = .info(status.text)
            case .warning: message = .warning(status.text)
            case .error: message = .error(status.text)
            }
            var options = [(value: "check", label: loc.t("nxkit.checkForUpdates"))]
            if let previous = build.nxkitPreviousVersion {
                options.append((value: "previous", label: String(format: loc.t("nxkit.usePrevious"), previous)))
            }
            let menu = BuildEngineRow.Menu(label: loc.t("nxkit.more"), options: options, padID: "set.upstream.nxkit.more",
                                           disabled: build.running || build.nxkitUpdate == .checking) { value in
                if value == "check" { build.checkNxkitUpdate(manual: true) } else if value == "previous" { build.useNxkitPreviousVersion() }
            }
            return BuildEngineRow(detail: build.nxkitStatusLine, message: message, menu: menu)
        }
        if mngBlocked(build) { return BuildEngineRow(message: .info(loc.t("upstream.mngOnlyFiveTitles"))) }
        guard NxkitBuilder.featureEnabled else { return BuildEngineRow() }
        switch build.nxkitAvailability {
        case .available: return BuildEngineRow()
        case .needsNewerMacOS: return BuildEngineRow(message: .info(loc.t("nxkit.needsMacOS26")))
        case .needsAppleSilicon: return BuildEngineRow(message: .info(loc.t("nxkit.needsAppleSilicon")))
        }
    }

    package var body: some View {
        if MacNativeGamesBuilder.featureEnabled && (build.macNativeGamesInstalled || build.buildUpstream == .macNativeGames || Self.fetching(build, .macNativeGames)) {
            CardDivider()
            folderRow(.macNativeGames, title: loc.t("upstream.mngFolder"), path: build.macNativeGamesPath, usable: build.macNativeGamesInstalled,
                      invalidKey: "upstream.mngInvalid", padID: "set.upstream.mngFolder", pick: pickMNG)
        }
        if S2ArmBuilder.featureEnabled && (build.s2armInstalled || build.buildUpstream == .s2arm || Self.fetching(build, .s2arm)) {
            CardDivider()
            folderRow(.s2arm, title: loc.t("upstream.s2armFolder"), path: build.s2armPath, usable: build.s2armInstalled,
                      invalidKey: "upstream.s2armInvalid", padID: "set.upstream.s2armFolder", pick: pickS2Arm)
        }
    }

    /// The engine is being downloaded, or its download failed: its folder row shows how far it is, or Retry.
    static func fetching(_ build: BuildStore, _ kind: EngineUpstreamKind) -> Bool {
        switch build.upstreamState(kind) {
        case .downloading, .extracting, .failed: return true
        default: return false
        }
    }

    /// One external engine's row (#1473): its folder, its version as a tag (an arrow and text.primary when GitHub has a newer one),
    /// Update in the column when it has, Check for updates and Choose in the "…". While it downloads the column says how far.
    @ViewBuilder private func folderRow(_ kind: EngineUpstreamKind, title: String, path: String, usable: Bool, invalidKey: String,
                                        padID: String, pick: @escaping () -> Void) -> some View {
        let state = build.upstreamState(kind)
        let hasUpdate = build.upstreamHasUpdate(kind)
        let detail = path.isEmpty ? loc.t("upstream.notSelected")
            : usable ? RepoLayout.shortPath(path) : String(format: loc.t(invalidKey), RepoLayout.shortPath(path))
        let failure = UpstreamStatusText.failure(state, loc)
        let idle = !build.running && !state.isBusy
        let download = { if idle { _ = build.downloadUpstream(kind) } }
        CardRow(title, detail: detail, dot: usable ? LauncherPalette.ready : LauncherPalette.building, help: path,
                message: failure.map { .error($0) }) {
            if usable {
                DSTag(build.upstreamVersionBadge(kind), emphasized: hasUpdate)
                    .help(build.upstreamUpdateTooltip(kind) ?? "")
            }
            if let busy = UpstreamStatusText.busy(state, loc) {
                DSTag(busy)
                let cancel = { build.cancelUpstreamDownload(kind) }
                SettingsUpdateAction(loc.t("upstream.cancel"), action: cancel)   // the tag beside it says how far it is
                    .padTarget(padID + ".cancel", scope: "main", activate: cancel)
            } else if hasUpdate || failure != nil {
                DSOverflowMenu(label: loc.t("upstream.choose"), options: [("choose", loc.t("upstream.choose"))], padID: padID) { _ in
                    if idle { pick() }
                }
                .disabled(!idle)
                SettingsUpdateAction(loc.t(hasUpdate ? "upstream.update" : "upstream.retry"), prominent: hasUpdate, action: download)
                    .disabled(!idle)
                    .help(build.upstreamUpdateTooltip(kind) ?? "")
                    .padTarget(padID + ".update", scope: "main", enabled: idle, activate: download)
            } else {
                if usable {
                    DSOverflowMenu(label: loc.t("repo.check"), options: [("check", loc.t("repo.check"))], padID: padID + ".check") { _ in
                        if idle { _ = build.checkUpstreamUpdates(kinds: [kind], force: true) }
                    }
                    .disabled(!idle)
                }
                Button(loc.t("upstream.choose"), action: pick)
                    .disabled(build.running)
                    .padTarget(padID, scope: "main", enabled: !build.running) { if !build.running { pick() } }
            }
        }
        .onAppear { build.refreshUpstreamLocalVersion(for: kind) }
    }

    private func pickMNG() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        p.message = loc.t("upstream.mngPickMessage")
        if p.runModal() == .OK, let u = p.url {
            build.macNativeGamesPath = u.path
        }
    }

    private func pickS2Arm() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        p.message = loc.t("upstream.s2armPickMessage")
        if p.runModal() == .OK, let u = p.url {
            build.s2armPath = u.path
        }
    }
}
