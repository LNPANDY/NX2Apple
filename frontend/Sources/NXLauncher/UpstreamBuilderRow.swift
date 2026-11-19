import SwiftUI
import AppKit
import NXCore
import NXModel

package struct UpstreamBuilderRow: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer

    package init(build: BuildStore) {
        self.build = build
    }

    private var availableOptions: [(value: String, label: String)] {
        var opts: [(value: String, label: String)] = [
            (EngineUpstreamKind.nxnative.rawValue, "nxnative")
        ]
        if MacNativeGamesBuilder.featureEnabled && (build.macNativeGamesInstalled || build.buildUpstream == .macNativeGames) {
            opts.append((EngineUpstreamKind.macNativeGames.rawValue, "MacNativeGames"))
        }
        if S2ArmBuilder.featureEnabled && (build.s2armInstalled || build.buildUpstream == .s2arm) {
            opts.append((EngineUpstreamKind.s2arm.rawValue, "S2Arm"))
        }
        if build.nxkitSelectable || build.buildUpstream == .nxkit {
            opts.append((EngineUpstreamKind.nxkit.rawValue, loc.t("nxkit.name")))
        }
        return opts
    }

    private var nxkitShown: Bool { build.buildUpstream == .nxkit && build.nxkitSelectable }

    /// The engine row's message: with nxkit (Beta) chosen its note or its update's state, else why this Mac cannot choose nxkit.
    private var engineMessage: DSRowMessage? {
        if nxkitShown {
            let m = build.nxkitStatusMessage
            switch m.tone {
            case .info: return .info(m.text)
            case .warning: return .warning(m.text)
            case .error: return .error(m.text)
            }
        }
        guard NxkitBuilder.featureEnabled else { return nil }
        switch build.nxkitAvailability {
        case .available: return nil
        case .needsNewerMacOS: return .info(loc.t("nxkit.needsMacOS26"))
        case .needsAppleSilicon: return .info(loc.t("nxkit.needsAppleSilicon"))
        }
    }

    /// "…" beside the engine with nxkit (Beta): Check for updates, Use previous version.
    private var nxkitMenu: [(value: String, label: String)] {
        var options = [(value: "check", label: loc.t("nxkit.checkForUpdates"))]
        if let previous = build.nxkitPreviousVersion { options.append((value: "previous", label: String(format: loc.t("nxkit.usePrevious"), previous))) }
        return options
    }

    package var body: some View {
        CardRow(loc.t("upstream.title"), detail: nxkitShown ? build.nxkitStatusLine : loc.t("upstream.note"), message: engineMessage) {
            if nxkitShown {
                DSOverflowMenu(label: loc.t("nxkit.more"), options: nxkitMenu, padID: "set.upstream.nxkit.more") { value in
                    if value == "check" { build.checkNxkitUpdate(manual: true) } else if value == "previous" { build.useNxkitPreviousVersion() }
                }
                .disabled(build.running || build.nxkitUpdate == .checking)
            }
            LauncherDropdown(
                options: availableOptions,
                selection: build.buildUpstream.rawValue,
                label: loc.t("upstream.title"),
                style: .button
            ) { raw in
                if let kind = EngineUpstreamKind(rawValue: raw) {
                    build.selectUpstream(kind)
                }
            }
            .disabled(build.running)
            .padTarget("set.upstream", scope: "main", enabled: !build.running, activate: { cycle(1) }, adjust: cycle)
        }
        if MacNativeGamesBuilder.featureEnabled && (build.macNativeGamesInstalled || build.buildUpstream == .macNativeGames) {
            CardDivider()
            let usable = build.macNativeGamesInstalled
            let detailText: String = {
                if build.macNativeGamesPath.isEmpty {
                    return loc.t("upstream.notSelected")
                }
                if usable {
                    return RepoLayout.shortPath(build.macNativeGamesPath)
                }
                return String(format: loc.t("upstream.mngInvalid"), RepoLayout.shortPath(build.macNativeGamesPath))
            }()
            CardRow(
                loc.t("upstream.mngFolder"),
                detail: detailText,
                dot: usable ? LauncherPalette.ready : LauncherPalette.building,
                help: build.macNativeGamesPath
            ) {
                Button(loc.t("upstream.choose")) {
                    pickMNG()
                }
                .disabled(build.running)
                .padTarget("set.upstream.mngFolder", scope: "main", enabled: !build.running) { if !build.running { pickMNG() } }
            }
        }
        if S2ArmBuilder.featureEnabled && (build.s2armInstalled || build.buildUpstream == .s2arm) {
            CardDivider()
            let usable = build.s2armInstalled
            let detailText: String = {
                if build.s2armPath.isEmpty {
                    return loc.t("upstream.notSelected")
                }
                if usable {
                    return RepoLayout.shortPath(build.s2armPath)
                }
                return String(format: loc.t("upstream.s2armInvalid"), RepoLayout.shortPath(build.s2armPath))
            }()
            CardRow(
                loc.t("upstream.s2armFolder"),
                detail: detailText,
                dot: usable ? LauncherPalette.ready : LauncherPalette.building,
                help: build.s2armPath
            ) {
                Button(loc.t("upstream.choose")) {
                    pickS2Arm()
                }
                .disabled(build.running)
                .padTarget("set.upstream.s2armFolder", scope: "main", enabled: !build.running) { if !build.running { pickS2Arm() } }
            }
        }
    }

    private func cycle(_ by: Int) {
        let options = availableOptions
        guard !build.running, let index = options.firstIndex(where: { $0.value == build.buildUpstream.rawValue }), !options.isEmpty,
              let kind = EngineUpstreamKind(rawValue: options[(index + by + options.count) % options.count].value) else { return }
        build.selectUpstream(kind)
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
