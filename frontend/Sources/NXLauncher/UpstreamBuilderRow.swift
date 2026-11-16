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

    package var body: some View {
        CardRow(loc.t("upstream.title"), detail: loc.t("upstream.note")) {
            Picker(loc.t("upstream.title"), selection: $build.buildUpstream) {
                Text("nxnative").tag(EngineUpstreamKind.nxnative)
                if MacNativeGamesBuilder.featureEnabled {
                    Text("MacNativeGames").tag(EngineUpstreamKind.macNativeGames)
                }
                if S2ArmBuilder.featureEnabled {
                    Text("S2Arm").tag(EngineUpstreamKind.s2arm)
                }
            }
            .labelsHidden()
            .disabled(build.running)
        }
        if build.buildUpstream == .macNativeGames {
            CardDivider()
            let usable = MacNativeGamesBuilder.isUsableTree(build.macNativeGamesPath)
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
            }
        } else if build.buildUpstream == .s2arm {
            CardDivider()
            let usable = S2ArmBuilder.isUsableTree(build.s2armPath)
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
