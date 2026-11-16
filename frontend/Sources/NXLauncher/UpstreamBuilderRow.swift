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
                Text("MacNativeGames").tag(EngineUpstreamKind.macNativeGames)
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
                    pick()
                }
                .disabled(build.running)
            }
        }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        p.message = loc.t("upstream.mngPickMessage")
        if p.runModal() == .OK, let u = p.url {
            build.macNativeGamesPath = u.path
        }
    }
}
