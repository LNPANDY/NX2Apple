import SwiftUI
import AppKit
import NXCore
import NXModel

/// The engine pop-up (nxnative and the other engines that can build): the control of Settings > Tools > Build engine (#1458).
package struct UpstreamPicker: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer

    package init(build: BuildStore) { self.build = build }

    package var body: some View {
        LauncherDropdown(
            options: UpstreamBuilderRow.options(build),
            selection: build.buildUpstream.rawValue,
            label: loc.t("engine.title"),
            style: .button
        ) { raw in
            if let kind = EngineUpstreamKind(rawValue: raw) {
                build.selectUpstream(kind)
            }
        }
        .disabled(build.running)
        .padTarget("set.upstream", scope: "main", enabled: !build.running, activate: { cycle(1) }, adjust: cycle)
    }

    private func cycle(_ by: Int) {
        let options = UpstreamBuilderRow.options(build)
        guard !build.running, let index = options.firstIndex(where: { $0.value == build.buildUpstream.rawValue }), !options.isEmpty,
              let kind = EngineUpstreamKind(rawValue: options[(index + by + options.count) % options.count].value) else { return }
        build.selectUpstream(kind)
    }
}

/// The folder rows of the other engines (MacNativeGames, S2Arm), under the build tools' rows. Which engine builds is the
/// Build engine row's pop-up (UpstreamPicker).
package struct UpstreamBuilderRow: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer

    package init(build: BuildStore) {
        self.build = build
    }

    /// The engines the pop-up offers: nxnative, and each other one that is set up or chosen.
    static func options(_ build: BuildStore) -> [(value: String, label: String)] {
        var opts: [(value: String, label: String)] = [
            (EngineUpstreamKind.nxnative.rawValue, "nxnative")
        ]
        if MacNativeGamesBuilder.featureEnabled && (build.macNativeGamesInstalled || build.buildUpstream == .macNativeGames) {
            opts.append((EngineUpstreamKind.macNativeGames.rawValue, "MacNativeGames"))
        }
        if S2ArmBuilder.featureEnabled && (build.s2armInstalled || build.buildUpstream == .s2arm) {
            opts.append((EngineUpstreamKind.s2arm.rawValue, "S2Arm"))
        }
        return opts
    }

    package var body: some View {
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
